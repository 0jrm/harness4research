#!/usr/bin/env bash
# usage: guard/run ripples <run_dir>
# One line per precursor: PASS, RIPPLE, HANDLED or UNCHECKED. Exit 1 on any RIPPLE, which means stop new submissions.
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: guard/run ripples <run_dir>" >&2; exit 64; }
run_dir=${1%/}; run_id=$(basename "$run_dir")
base=${HPC_GUARD_REF:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}
status=0
# A terminal gets an aligned table, coloured unless NO_COLOR is set or TERM=dumb; a pipe, preflight, launch and the
# atlas get the TSV, and HPC_RIPPLES_TSV=1 forces it for a program that reads through a terminal (ssh -t, a pty).
table=0; [ -t 1 ] && [ "${HPC_RIPPLES_TSV:-0}" != 1 ] && table=1
declare -A hue=()
[ $table = 0 ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ] || hue=([RIPPLE]=$'\e[1;31m' [HANDLED]=$'\e[33m' [UNCHECKED]=$'\e[2m' [PASS]=$'\e[32m' [off]=$'\e[0m')
say() {
  if [ $table = 1 ]; then printf '%s%-9s%s  %-25s  %s\n' "${hue[$1]:-}" "$1" "${hue[$1]:+${hue[off]}}" "$2" "$3"
  else printf '%s\t%s\t%s\n' "$1" "$2" "$3"; fi
  [ "$1" = RIPPLE ] && status=1; return 0
}
card=$(git show "$base:guard/budget.card" 2>/dev/null) || { say RIPPLE guard "no guard/budget.card on $base; merge the guard pull request, or git fetch"; exit 1; }
get() { awk -F': *' -v k="$1" '$1==k{print $2; exit}' <<<"$card"; }
acct=$(get account); start=$(get start_date); max_ch=$(get max_core_hours)
mapfile -t watch < <(git show "$base:guard/watch.list" 2>/dev/null | sed 's/#.*//' | awk 'NF')

changed=$( { git diff --name-only "$base"...HEAD -- guard; git status --porcelain --untracked-files=all -- guard; } | sort -u)
if [ -z "$changed" ]; then say PASS guard-untouched ""; else say RIPPLE guard-untouched "$(echo $changed); restore it with git restore --source=$base --staged --worktree -- guard, commit, and remove any untracked file under guard/"; fi

q="$run_dir/question.card"
if [ "$(git log --format=%H -- "$q" 2>/dev/null | wc -l)" -gt 1 ]; then say RIPPLE question-card-frozen "$q edited after its first commit; stop, the next call is the human's"
elif ! git diff --quiet HEAD -- "$q" 2>/dev/null; then say RIPPLE question-card-frozen "$q has uncommitted edits; revert them with git checkout HEAD -- $q"
else say PASS question-card-frozen ""; fi

if [ ${#watch[@]} -gt 0 ]; then
  w=$( { git diff --name-only "$base"...HEAD -- "${watch[@]}"; git status --porcelain --untracked-files=all -- "${watch[@]}"; } | sort -u)
  if [ -z "$w" ]; then say PASS watched-paths ""; else say RIPPLE watched-paths "$(echo $w); revert them to $base and commit, since a human changes watched paths"; fi
else say UNCHECKED watched-paths "a human lists verifier, test and threshold paths in guard/watch.list"; fi

# launch.sh runs only for a project that opted in or a run with a ledger, so a Slurm project pays nothing for it.
launch=""; lh=$(get launch_hosts)
if { [ -n "$lh" ] && [ "$lh" != none ] && [[ $lh != *"<"* ]]; } || git cat-file -e "HEAD:$run_dir/execution.tsv" 2>/dev/null; then
  launch=$(git show "$base:guard/bin/launch.sh" 2>/dev/null)
fi
launched() { bash -c "$launch" guard/bin/launch.sh "$@"; }
# On a launch host, launch records answer sacct's row query, so the job checks below cover launched jobs too.
if [ -n "$launch" ] && launched --here; then
  sacct() { [ -z "$(type -P sacct)" ] || command sacct "$@"; [[ $* != *JobName* ]] || launched --sacct; }
fi
nosacct="sacct not found on PATH on this host; run ripples on the cluster login node to check"
# A job is handled once a committed $run_dir/incidents/*.md has the line `job: <id>`.
declare -A incident=() acked=()
while IFS=: read -r _ path line; do id=${line#job:}; incident[${id// /}]=incidents/$(basename "$path")
done < <(git grep -E '^job: *[0-9A-Za-z][0-9A-Za-z_.-]* *$' HEAD -- "$run_dir/incidents/" 2>/dev/null)
# A committed execution.tsv restart or resume row citing a job handles it the same way.
[ -z "$launch" ] || while read -r id ref; do [ -n "${incident[$id]+x}" ] || incident[$id]=$ref; done < <(launched --handled "$run_dir")
sort_out() {  # sort_out <check> "<id>:<detail> ..." <next step>: HANDLED for entries with an incident, RIPPLE for the rest
  local open="" done="" e id
  for e in $2; do id=${e%%:*}
    if [ -n "${incident[$id]+x}" ]; then done+="$e->${incident[$id]} "; acked[$id]=1; else open+="$e "; fi
  done
  [ -n "$done" ] && say HANDLED "$1" "$done"
  if [ -n "$open" ]; then say RIPPLE "$1" "${open% }${3:+ ($3)}"; elif [ -z "$done" ]; then say PASS "$1" ""; fi
}

# A host whose sacct answers for another cluster, or for none, lists no rows and exits 0, so no rows is no verdict.
blind=""
if ! command -v sacct >/dev/null; then blind=$nosacct
elif ! rows=$(sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o JobID,JobName,State,ElapsedRaw,TimelimitRaw); then
  blind="sacct failed on this host; run ripples on the cluster login node to check"
else
  rows=$(awk -F'|' -v r="$run_id" '$2==r' <<<"$rows")
  [ -n "$rows" ] || blind="sacct lists no job named $run_id on account $acct since $start from this host, so there is nothing to judge; if the run has submitted jobs, run ripples on the cluster login node"
fi
if [ -z "$blind" ]; then
  incident_step="diagnose, then commit $run_dir/incidents/<n>.md with a job: <id> line for each"
  sort_out job-states "$(awk -F'|' '$3 ~ /TIMEOUT|OUT_OF_ME|NODE_FAIL|FAILED|PREEMPTED/ {printf "%s:%s ", $1, $3}' <<<"$rows")" \
    "$incident_step; a resource stop of a launch continues with an execution.tsv restart or resume row instead"
  sort_out walltime-headroom "$(awk -F'|' '$5>0 && $4 > 0.8*$5*60 {printf "%s:%d%% ", $1, 100*$4/($5*60)}' <<<"$rows")" "$incident_step"
  nfail=0
  for id in $(awk -F'|' 'NF && $3 !~ /COMPLETED|RUNNING|PENDING/ {print $1}' <<<"$rows"); do
    if [ -n "${incident[$id]+x}" ]; then acked[$id]=1; else nfail=$((nfail+1)); fi
  done
  if [ "$nfail" -le 1 ]; then say PASS retries "$nfail not completed without an incident"
  else say RIPPLE retries "$nfail not completed without an incident; diagnose, then commit one in $run_dir/incidents/ for each"; fi
  cap=$(get max_handled_failures); [[ $cap =~ ^[0-9]+$ ]] || cap=2
  if [ ${#acked[@]} -gt "$cap" ]; then say RIPPLE handled-failures "${#acked[@]} handled, over max_handled_failures=$cap; the next call is the human's"
  else say PASS handled-failures "${#acked[@]} of $cap"; fi
else
  for k in job-states walltime-headroom retries handled-failures; do say UNCHECKED "$k" "$blind"; done
fi

if [ -z "$(type -P sacct)" ]; then say UNCHECKED budget "$nosacct"
elif ! cpu=$(command sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o CPUTimeRAW); then
  say UNCHECKED budget "sacct failed on this host; run ripples on the cluster login node to check"
elif [ -z "$cpu" ]; then
  say UNCHECKED budget "sacct lists no job on account $acct since $start from this host, so spend is unknown here; run ripples on the cluster login node to check"
else
  spent=$(awk '{s+=$1} END{printf "%d", s/3600}' <<<"$cpu")
  if [[ $max_ch =~ ^[0-9]+$ ]] && [ $(( spent * 100 )) -gt $(( max_ch * 80 )) ]; then say RIPPLE budget "$spent of $max_ch core-h, over 80%; a human decides whether to raise max_core_hours"
  else say PASS budget "$spent of ${max_ch:-?} core-h"; fi
fi

qcmd=$(get quota_pct_cmd)
if [ -n "$qcmd" ] && [[ $qcmd != *"<"* ]]; then
  pct=$(bash -c "$qcmd" 2>/dev/null | tr -dc '0-9' | head -c3)
  if [ -z "$pct" ]; then  # most often its path is not mounted on this host, as with a cluster file system seen from a workstation
    why=$(bash -c "$qcmd" 2>&1 >/dev/null | head -n1)
    say UNCHECKED quota "quota_pct_cmd printed no number on this host${why:+ ($why)}; run ripples where its path exists, or a human fixes quota_pct_cmd in guard/budget.card"
  elif [ "$pct" -gt 80 ]; then say RIPPLE quota "${pct}%, over 80%; find what grew, since deleting or moving shared files is the human's call"; else say PASS quota "${pct}%"; fi
else say UNCHECKED quota "a human sets quota_pct_cmd in guard/budget.card"; fi

found=0
for c in "$run_dir"/checks/*; do
  [ -x "$c" ] || continue; found=1
  out=$("$c" "$run_dir" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then say PASS "check:$(basename "$c")" "$(tail -n1 <<<"$out")"
  elif [ $rc -eq 77 ]; then say UNCHECKED "check:$(basename "$c")" "$(tail -n1 <<<"$out"); it exits 77 until its input exists"
  else say RIPPLE "check:$(basename "$c")" "$(tail -n1 <<<"$out"); run $c $run_dir for its full output"; fi
done
[ $found -eq 1 ] || say UNCHECKED domain-checks "no executable $run_dir/checks/*; add a script there that exits non-zero when a result looks wrong"
# launch prints nothing unless launch_hosts names a host, so a project that never opted in gets no new line.
if [ -n "$launch" ]; then
  while IFS=$'\t' read -r s k d n; do
    if [ "$s" = ENTRIES ]; then sort_out "$k" "$d" "$n"; else say "$s" "$k" "$d"; fi
  done < <(launched --checks "$run_dir")
fi
exit $status
