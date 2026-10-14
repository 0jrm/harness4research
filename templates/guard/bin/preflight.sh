#!/usr/bin/env bash
# usage: guard/run preflight <run_dir> <job_script> [sbatch options...]
# Submits only if guard/ matches the protected branch, the question card is committed and frozen,
# and the job fits guard/budget.card as it exists on the protected branch.
# HPC_SPEND_RESERVE=1 lets verifier jobs draw on the verification reserve.
# It also skips the ripples gate, because a ripple pauses new spending, not diagnosis within the reserve.
# A run_dir named explore-* needs no question card but gets small caps, and the fence keeps its results out of reports.
set -euo pipefail
# cron, containers and Slurm epilogs may leave USER unset, and set -u would stop at its first use.
USER=${USER:-$(id -un)}
[ $# -ge 2 ] || { echo "usage: guard/run preflight <run_dir> <job_script> [sbatch options...]" >&2; exit 64; }
command -v sbatch >/dev/null || { echo "preflight: no scheduler on this host; guard/run manifest is the only allowed step here" >&2; exit 2; }
run_dir=${1%/}; job=$2; shift 2
base=${HPC_GUARD_REF:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}
card_path=guard/budget.card
run_id=$(basename "$run_dir")

fail() { echo "PREFLIGHT FAIL: $*" >&2; exit 2; }
get() { awk -F': *' -v k="$1" '$1==k{print $2; exit}' <<<"$card"; }
need() {
  local v; v=$(get "$1")
  [ -n "$v" ] || fail "budget card has no '$1'; a human adds it to guard/budget.card on the protected branch"
  [[ $v != *"<"* ]] || fail "budget card '$1' is still a placeholder: $v; a human fills it in guard/budget.card on the protected branch"
  echo "$v"
}
whole() {
  local v; v=$(need "$1")
  [[ $v =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] || fail "budget card '$1' must be a whole number: $v; a human fixes it in guard/budget.card on the protected branch"
  echo "${BASH_REMATCH[1]}"
}
# to_min <T>: Slurm time syntax (M, M:S, H:M:S, D-H, D-H:M, D-H:M:S) to minutes, seconds rounded up; prints nothing
# when malformed, such as squeue's UNLIMITED. Two fields mean M:S, and H:M only after a day count.
to_min() {
  local t=$1 d=0 days=0 h=0 m=0 s=0 a b c
  [[ $t == *-* ]] && { days=1; d=${t%%-*}; t=${t#*-}; }
  [[ $d =~ ^[0-9]+$ && $t =~ ^[0-9]+(:[0-9]+){0,2}$ ]] || return 0
  IFS=: read -r a b c <<<"$t"
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c
  elif [ -n "${b:-}" ]; then if [ $days = 1 ]; then h=$a; m=$b; else m=$a; s=$b; fi
  elif [ $days = 1 ]; then h=$a
  else m=$a; fi
  echo $(( 10#$d*1440 + 10#$h*60 + 10#$m + (10#$s > 0) ))
}
# sbatch's options in Slurm 24.05, from its --help and --usage: long ones that take a value, may take one with =, or
# take none, and short ones that take a value or none. -I, --immediate, is missing from the help.
long_val=' account array bb bbf begin chdir cluster-constraint clusters comment constraint core-spec cores-per-socket
  cpu-freq cpus-per-gpu cpus-per-task deadline delay-boot dependency distribution error exclude export-file
  extra-node-info gid gpu-bind gpu-freq gpus gpus-per-node gpus-per-socket gpus-per-task gres gres-flags input job-name
  licenses mail-type mail-user mcs-label mem mem-bind mem-per-cpu mem-per-gpu mincpus network nodefile nodelist nodes
  ntasks ntasks-per-core ntasks-per-node ntasks-per-socket output partition power priority profile qos reservation
  signal sockets-per-node switches thread-spec threads-per-core time time-min tmp tres-bind tres-per-task uid wckey '
long_other=' exclusive export nice propagate wrap container container-id contiguous get-user-env help hold ignore-pbs
  no-kill no-requeue overcommit oversubscribe parsable quiet reboot requeue resv-ports spread-job usage use-min-nodes
  verbose version wait '
short_val=ABCDFGJLMNSabcdeimnopqtwx
# read_sbopts <word...>: sets wall, nodes and array to the last value sbatch takes for them from the words, in the
# forms --long=V, --long V, -sV and -s V. It refuses a word it cannot map to exactly one option: a shortened long
# option, short options bundled after one that takes no value, and a word that is neither an option nor its value.
read_sbopts() {
  local w name v c o
  while [ $# -gt 0 ]; do
    w=$1; shift; name=""
    case $w in
      --) fail "-- ends sbatch's options early; drop it" ;;
      --?*)
        name=${w#--}; name=${name%%=*}
        [ -n "$name" ] || fail "'$w' is not an sbatch option"
        if [[ $long_val$long_other != *[[:space:]]"$name"[[:space:]]* ]]; then
          c=""; for o in $long_val$long_other; do [[ $o != "$name"* ]] || c="$c --$o"; done
          [ -z "$c" ] || fail "${w%%=*} shortens$c; write the option in full"
          continue
        fi
        [[ $long_val == *[[:space:]]"$name"[[:space:]]* ]] || continue
        if [[ $w == *=* ]]; then v=${w#*=}; else [ $# -gt 0 ] || fail "$w has no value"; v=$1; shift; fi ;;
      -?*)
        name=${w:1:1}
        if [[ $short_val != *"$name"* ]]; then [ ${#w} -eq 2 ] || fail "split $w into separate options"; continue; fi
        if [ ${#w} -gt 2 ]; then v=${w:2}; else [ $# -gt 0 ] || fail "$w has no value"; v=$1; shift; fi ;;
      *) fail "'$w' is not an sbatch option; preflight takes the job script as its second argument" ;;
    esac
    case $name in
      t|time) wall=$v ;;
      N|nodes) nodes=$v ;;
      a|array) array=$v ;;
    esac
  done
}
tasks() {
  local spec=${1%%\%*} n=0 part lo hi step parts
  [ -z "$spec" ] && { echo 1; return; }
  IFS=, read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ $part == *-* ]]; then
      step=1; [[ $part == *:* ]] && { step=${part#*:}; part=${part%:*}; }
      lo=${part%-*}; hi=${part#*-}; n=$(( n + (hi - lo) / step + 1 ))
    else n=$(( n + 1 )); fi
  done
  echo "$n"
}

git rev-parse --verify -q "$base" >/dev/null || fail "guard ref $base not found (git fetch?)"
card=$(git show "$base:$card_path" 2>/dev/null) || fail "no $card_path on $base; merge the guard pull request, or git fetch"
changed=$( { git diff --name-only "$base"...HEAD -- guard; git status --porcelain --untracked-files=all -- guard; } | sort -u)
[ -z "$changed" ] || fail "guard/ differs from $base: $(echo $changed); restore it with git restore --source=$base --staged --worktree -- guard, commit, and remove any untracked file under guard/"

explore=0; [[ $run_id == explore-* ]] && explore=1
if [ $explore = 0 ]; then
  q="$run_dir/question.card"
  git ls-files --error-unmatch "$q" >/dev/null 2>&1 || fail "$q is not committed; commit it first"
  git diff --quiet HEAD -- "$q" || fail "$q has uncommitted edits; revert them with git checkout HEAD -- $q, or start a new run id for a new design"
  [ "$(git log --format=%H -- "$q" | wc -l)" -le 1 ] || fail "$q was edited after its first commit; start a new run id instead"
fi

if [ "${HPC_SPEND_RESERVE:-0}" != 1 ]; then
  ripples=$(git show "$base:guard/bin/ripples.sh" 2>/dev/null) || fail "ripples could not run (no guard/bin/ripples.sh on $base); a human runs guard init --update"
  rc=0; out=$(bash -c "$ripples" guard/bin/ripples.sh "$run_dir") || rc=$?
  [ $rc -ne 1 ] || fail "ripples reports $(awk -F'\t' '$1=="RIPPLE" {sub(/ +$/, "", $3); printf "%s%s %s", sep, $2, $3; sep=" | "}' <<<"$out"); fix the cause or record it in an incident, or set HPC_SPEND_RESERVE=1 for a diagnostic job"
  [ $rc -eq 0 ] || fail "ripples could not run (exit $rc); run guard/run ripples $run_dir to see why"
fi

stop=$(need stop_date)
[[ ! $(date +%F) > $stop ]] || fail "past stop_date $stop; a human extends stop_date in guard/budget.card on the protected branch"

acct=$(need account); start=$(need start_date); max_ch=$(whole max_core_hours)
reserve=0; [ -z "$(get verification_reserve_core_hours)" ] || reserve=$(whole verification_reserve_core_hours)
cpn=$(whole cores_per_node); max_nodes=$(whole max_nodes_per_job)
max_wall=$(whole max_walltime_minutes); max_conc=$(whole max_concurrent_jobs)
# squeue and sacct come from the card on the protected branch, never from PATH, which the caller sets.
sbin=$(get slurm_bin); sbin=${sbin:-/usr/bin}
[ -x "$sbin/squeue" ] && [ -x "$sbin/sacct" ] || fail "no squeue and sacct in slurm_bin=$sbin; a human sets slurm_bin in guard/budget.card on the protected branch to the directory that holds them"

# The options sbatch reads, in its order: each #SBATCH line up to the script's first command, then the command line.
wall=""; nodes=""; array=""
while IFS= read -r line; do
  read -ra w <<<"$line"; read_sbopts ${w[@]+"${w[@]}"}
done < <(awk '/^#SBATCH/ { sub(/^#SBATCH/, ""); sub(/#.*/, ""); print; next } /^[[:space:]]*(#|$)/ { next } { exit }' "$job")
read_sbopts "$@"
[ -n "$wall" ] || fail "state --time=... explicitly"
[[ $nodes =~ ^[0-9]+$ ]] || fail "state --nodes=N explicitly as one integer (got '${nodes}')"
idx='[0-9]+(-[0-9]+(:[0-9]+)?)?'
[[ -z $array || $array =~ ^$idx(,$idx)*(%[0-9]+)?$ ]] || fail "--array=$array is not an index list (0-9, 1,3,5, 0-15:4, with an optional %N)"
wmin=$(to_min "$wall"); n=$(tasks "$array")
[ -n "$wmin" ] || fail "--time=$wall is not a Slurm time (M, M:S, H:M:S, D-H, D-H:M, D-H:M:S)"
if [ $explore = 1 ]; then
  e=$(get explore_max_nodes); max_nodes=$(( ${e:-1} < max_nodes ? ${e:-1} : max_nodes ))
  e=$(get explore_max_walltime_minutes); max_wall=$(( ${e:-60} < max_wall ? ${e:-60} : max_wall ))
  [ "$n" -eq 1 ] || fail "explore- runs submit one task at a time; drop --array, or use a run with a question card"
fi
[ "$nodes" -le "$max_nodes" ] || fail "--nodes=$nodes exceeds max_nodes_per_job=$max_nodes; ask for fewer"
[ "$wmin" -le "$max_wall" ] || fail "--time=$wall ($wmin min) exceeds max_walltime_minutes=$max_wall; ask for less, and checkpoint to resume"

# slurm <sacct|squeue> <args...>: sets got to the command's output. A count it cannot read is not zero, so a failure
# stops preflight with the command's first error line.
slurm() {
  local err rc=0 line what=queue
  [ "$1" != sacct ] || what=accounting
  err=$(mktemp); got=$("$sbin/$1" "${@:2}" 2>"$err") || rc=$?
  line=$(grep -m 1 -v '^[[:space:]]*$' "$err" || true)
  [ $rc -eq 0 ] || { rm -f "$err"; fail "$what unavailable ($1 failed: ${line:-exit $rc}); not submitting"; }
  cat "$err" >&2; rm -f "$err"
}
slurm sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o CPUTimeRAW
spent=$(awk '{s+=$1} END{printf "%d", s/3600}' <<<"$got")
slurm squeue -A "$acct" -u "$USER" -h -t PENDING -o "%C %l"
queued=$(while read -r c l; do [ -z "$c" ] || echo "$c $(to_min "$l")"; done <<<"$got" | awk '{s+=$1*$2} END{printf "%d", s/60}')
proj=$(( nodes * cpn * wmin * n / 60 ))
if [ "${HPC_SPEND_RESERVE:-0}" = 1 ]; then held=0; else held=$reserve; fi
avail=$(( max_ch - held ))
[ $(( spent + queued + proj )) -le "$avail" ] \
  || fail "spent $spent + queued $queued + this job $proj core-h exceeds $avail available (max $max_ch, reserve held $held); ask for less, wait for queued jobs, or a human raises max_core_hours"
qget() { [ $explore = 1 ] || awk -F': *' -v k="$1" '$1==k && $2 !~ /</ {print $2; exit}' <<<"$(git show "HEAD:$run_dir/question.card")"; }
deadline=$(qget deadline)
[ -z "$deadline" ] || [[ ! $(date +%F) > $deadline ]] || fail "past deadline $deadline in $run_dir/question.card; a human decides whether a new run continues it"
run_max=$(qget budget_core_hours); run_max=${run_max:-$(get default_run_core_hours)}
if [[ $run_max =~ ^[0-9]+$ ]] && [ "$run_max" -gt 0 ]; then
  slurm sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o JobName,CPUTimeRAW
  run_spent=$(awk -F'|' -v r="$run_id" '$1==r {s+=$2} END{printf "%d", s/3600}' <<<"$got")
  [ $(( run_spent + proj )) -le "$run_max" ] || fail "this run spent $run_spent + this job $proj core-h exceeds budget_core_hours=$run_max; a human decides whether a new run continues it"
fi
slurm squeue -A "$acct" -u "$USER" -h
live=$(grep -c . <<<"$got" || true)
[ $(( live + n )) -le "$max_conc" ] || fail "$live live + $n new jobs exceeds max_concurrent_jobs=$max_conc; wait for running jobs to finish"
# The checked time, nodes and array follow the caller's options, so sbatch takes them over any other form or variable,
# and --ignore-pbs keeps sbatch from reading an array or a walltime from #PBS lines, which preflight does not read.
# The --comment before them is spare: a last caller option that wants a value takes it, and the rest stand.
set -- "$@" --comment="run:$run_id" --ignore-pbs --time="$wall" --nodes="$nodes" ${array:+--array="$array"}
unset SBATCH_ARRAY_INX

echo "PREFLIGHT OK: $run_id nodes=$nodes time=${wmin}m tasks=$n projected=$proj spent=$spent queued=$queued available=$avail" >&2
exec sbatch "$@" --account="$acct" --job-name="$run_id" --comment="run:$run_id" "$job"
