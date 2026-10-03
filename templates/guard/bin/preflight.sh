#!/usr/bin/env bash
# usage: guard/run preflight <run_dir> <job_script> [sbatch options...]
# Submits only if guard/ matches the protected branch, the question card is committed and frozen,
# and the job fits guard/budget.card as it exists on the protected branch.
# HPC_SPEND_RESERVE=1 lets verifier jobs draw on the verification reserve.
# It also skips the ripples gate, because a ripple pauses new spending, not diagnosis within the reserve.
# A run_dir named explore-* needs no question card but gets small caps, and the fence keeps its results out of reports.
set -euo pipefail
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
  [ -n "$v" ] || fail "budget card has no '$1'"
  [[ $v != *"<"* ]] || fail "budget card '$1' is still a placeholder: $v"
  echo "$v"
}
whole() {
  local v; v=$(need "$1")
  [[ $v =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]] || fail "budget card '$1' must be a whole number: $v"
  echo "${BASH_REMATCH[1]}"
}
to_min() {
  local t=$1 d=0 h=0 m=0 s=0 a b c
  [[ $t == *-* ]] && { d=${t%%-*}; t=${t#*-}; }
  IFS=: read -r a b c <<<"$t"
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c; elif [ -n "${b:-}" ]; then h=$a; m=$b; else m=$a; fi
  echo $(( 10#$d*1440 + 10#$h*60 + 10#$m + (10#$s > 0) ))
}
opt() {
  local name=$1 v a; shift
  v=$(sed -n "s/^#SBATCH[[:space:]]*--$name=\([^[:space:]]*\).*/\1/p" "$job" | tail -n1)
  for a in "$@"; do [[ $a == --$name=* ]] && v=${a#--$name=}; done
  echo "$v"
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
card=$(git show "$base:$card_path" 2>/dev/null) || fail "no $card_path on $base"
changed=$( { git diff --name-only "$base"...HEAD -- guard; git status --porcelain --untracked-files=all -- guard; } | sort -u)
[ -z "$changed" ] || fail "guard/ differs from $base: $(echo $changed)"

explore=0; [[ $run_id == explore-* ]] && explore=1
if [ $explore = 0 ]; then
  q="$run_dir/question.card"
  git ls-files --error-unmatch "$q" >/dev/null 2>&1 || fail "$q is not committed"
  git diff --quiet HEAD -- "$q" || fail "$q has uncommitted edits"
  [ "$(git log --format=%H -- "$q" | wc -l)" -le 1 ] || fail "$q was edited after its first commit; start a new run id instead"
fi

if [ "${HPC_SPEND_RESERVE:-0}" != 1 ]; then
  ripples=$(git show "$base:guard/bin/ripples.sh" 2>/dev/null) || fail "ripples could not run (no guard/bin/ripples.sh on $base)"
  rc=0; out=$(bash -c "$ripples" guard/bin/ripples.sh "$run_dir") || rc=$?
  [ $rc -ne 1 ] || fail "ripples reports $(awk -F'\t' '$1=="RIPPLE" {sub(/ +$/, "", $3); printf "%s%s %s", sep, $2, $3; sep="; "}' <<<"$out"); fix the cause or record it in an incident, or set HPC_SPEND_RESERVE=1 for a diagnostic job"
  [ $rc -eq 0 ] || fail "ripples could not run (exit $rc)"
fi

stop=$(need stop_date)
[[ ! $(date +%F) > $stop ]] || fail "past stop_date $stop"

acct=$(need account); start=$(need start_date); max_ch=$(whole max_core_hours)
reserve=0; [ -z "$(get verification_reserve_core_hours)" ] || reserve=$(whole verification_reserve_core_hours)
cpn=$(whole cores_per_node); max_nodes=$(whole max_nodes_per_job)
max_wall=$(whole max_walltime_minutes); max_conc=$(whole max_concurrent_jobs)

wall=$(opt time "$@"); nodes=$(opt nodes "$@"); array=$(opt array "$@")
[ -n "$wall" ] || fail "state --time=... explicitly"
[[ $nodes =~ ^[0-9]+$ ]] || fail "state --nodes=N explicitly as one integer (got '${nodes}')"
wmin=$(to_min "$wall"); n=$(tasks "$array")
if [ $explore = 1 ]; then
  max_nodes=$(get explore_max_nodes); max_nodes=${max_nodes:-1}
  max_wall=$(get explore_max_walltime_minutes); max_wall=${max_wall:-60}
  [ "$n" -eq 1 ] || fail "explore- runs submit one task at a time"
fi
[ "$nodes" -le "$max_nodes" ] || fail "--nodes=$nodes exceeds max_nodes_per_job=$max_nodes"
[ "$wmin" -le "$max_wall" ] || fail "--time=$wall ($wmin min) exceeds max_walltime_minutes=$max_wall"

spent=$(sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o CPUTimeRAW | awk '{s+=$1} END{printf "%d", s/3600}')
queued=$(squeue -A "$acct" -u "$USER" -h -t PENDING -o "%C %l" | while read -r c l; do echo "$c $(to_min "$l")"; done \
  | awk '{s+=$1*$2} END{printf "%d", s/60}')
proj=$(( nodes * cpn * wmin * n / 60 ))
if [ "${HPC_SPEND_RESERVE:-0}" = 1 ]; then held=0; else held=$reserve; fi
avail=$(( max_ch - held ))
[ $(( spent + queued + proj )) -le "$avail" ] \
  || fail "spent $spent + queued $queued + this job $proj core-h exceeds $avail available (max $max_ch, reserve held $held)"
qget() { [ $explore = 1 ] || awk -F': *' -v k="$1" '$1==k && $2 !~ /</ {print $2; exit}' <<<"$(git show "HEAD:$run_dir/question.card")"; }
deadline=$(qget deadline)
[ -z "$deadline" ] || [[ ! $(date +%F) > $deadline ]] || fail "past deadline $deadline in $run_dir/question.card"
run_max=$(qget budget_core_hours); run_max=${run_max:-$(get default_run_core_hours)}
if [[ $run_max =~ ^[0-9]+$ ]] && [ "$run_max" -gt 0 ]; then
  run_spent=$(sacct -A "$acct" -u "$USER" -S "$start" -X -n -P -o JobName,CPUTimeRAW | awk -F'|' -v r="$run_id" '$1==r {s+=$2} END{printf "%d", s/3600}')
  [ $(( run_spent + proj )) -le "$run_max" ] || fail "this run spent $run_spent + this job $proj core-h exceeds budget_core_hours=$run_max"
fi
live=$(squeue -A "$acct" -u "$USER" -h | wc -l)
[ $(( live + n )) -le "$max_conc" ] || fail "$live live + $n new jobs exceeds max_concurrent_jobs=$max_conc"

echo "PREFLIGHT OK: $run_id nodes=$nodes time=${wmin}m tasks=$n projected=$proj spent=$spent queued=$queued available=$avail" >&2
exec sbatch "$@" --account="$acct" --job-name="$run_id" --comment="run:$run_id" "$job"
