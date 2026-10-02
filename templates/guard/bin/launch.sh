#!/usr/bin/env bash
# usage: guard/run launch <run_dir> --time=T --gpus=<i,j|none> --mem=<GB> [--shm=DIR]... [--cwd=DIR] -- <command...>
#        guard/run launch --stop <job_id> [--reason=<text>]
#        guard/run launch --list [run_dir]
# Runs one job on a host named in launch_hosts, under a supervisor that owns that job and nothing else.
# The supervisor enforces --time and --mem, stops gently (INT, then TERM, then KILL), and writes the
# job's record. Nothing here runs on a host that launch_hosts does not name.
#
# Internal entry points, called only by this file and by ripples.sh from the same base commit:
#   --supervise <record_dir> -- <command...>   the resident supervisor, started detached by launch
#   --tick <record_dir>                        one supervisor poll on a job somebody else started, for tests
#   --here                                     exit 0 when this host is in launch_hosts
#   --sacct                                    this project's launches as sacct rows JobID|JobName|State|ElapsedRaw|TimelimitRaw
#   --handled <run_dir>                        "<job_id> execution.tsv:<row>" for every committed restart or resume row
#   --checks <run_dir>                         check lines for ripples: STATUS<TAB>check<TAB>detail,
#                                              or ENTRIES<TAB>check<TAB><id>:<detail> ... for ripples' sort_out
#
# Invariants:
#   - Every record file is written once, by one writer, through link(2), so a reader sees it whole or not at all.
#     `beat` is the one file that is replaced, through rename(2).
#   - A record's state is derived, never stored: from which files exist, the boot id, and /proc. See state_of.
#   - A job is the set of this user's processes in the job's session or carrying HPC_JOB_ID=<id>. See members.
#   - No path here deletes a file. Leftover shm dirs are reported, never removed.
#   - The enforcement loop never waits on the state dir: every write there runs under timeout.
#   - Only the supervisor and --stop ever signal a job. Ripples reports; it never stops anything.
#
# Views (--list, --sacct, --checks) read every record and every process once, into arrays, and the accessors
# below set $r, $st or $el instead of printing, because a `$(...)` per field would fork hundreds of times per call.
set -uo pipefail

readonly POLL_FAST=1 POLL=5 FAST_FOR=60 BEAT_EVERY=60 START_WAIT=15
readonly LOG_ERRORS='Traceback \(most recent call last\)|CUDA out of memory|OutOfMemoryError|CUDA error|NCCL error|Segmentation fault|(^|[^[:alpha:]])[Ll]oss[^[:alnum:]]{0,4}(nan|inf)'
readonly RESOURCE_STOPS='^(OUT_OF_MEMORY|HOST_OUT_OF_MEMORY|NODE_FAIL|PREEMPTED|SUPERVISOR_FAILED)$'
readonly ENVELOPE_FIELDS=' host gpus start concurrency workers staging mem_stop_gb stage_minutes resume restart '

base=${HPC_GUARD_REF:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}

usage() {
  echo "usage: guard/run launch <run_dir> --time=T --gpus=<i,j|none> --mem=<GB> [--shm=DIR]... [--cwd=DIR] -- <command...>" >&2
  echo "       guard/run launch --stop <job_id> [--reason=<text>] | --list [run_dir]" >&2; exit 64
}
fail() { echo "LAUNCH FAIL: $*" >&2; exit 2; }
say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
now() { date -u +%FT%TZ; }
epoch() { printf '%(%s)T' -1; }
iso_epoch() { date -u -d "${1:-@0}" +%s 2>/dev/null || echo 0; }
# kb_gb <kB> and gb_kb <GB, decimals allowed>: integer arithmetic, three decimals of GB.
kb_gb() {
  local m=$(( ${1:-0} * 1000 / 1048576 ))
  if [ $m -ge 1000 ]; then printf '%d.%d' $(( m / 1000 )) $(( m % 1000 / 100 )); else printf '0.%03d' $m; fi
}
gb_kb() { local g=${1%%.*} f=${1#*.}; [ "$f" != "$1" ] || f=0; f=${f}000; echo $(( 10#${g:-0} * 1048576 + 10#${f:0:3} * 1048576 / 1000 )); }
gpu_n() { local IFS=,; if [ "${1:-none}" = none ] || [ -z "${1:-}" ]; then echo 0; else set -- $1; echo $#; fi; }

# Card access, the same rules as preflight: first match wins, `<...>` is unset. Copied, not shared, so
# preflight.sh stays byte-identical. need exits a subshell, so callers add `|| exit $?`.
declare -A cardv=()
load_card() {
  local k v
  card=$(git show "$base:guard/budget.card" 2>/dev/null) || fail "no guard/budget.card on $base"
  while IFS=$'\t' read -r k v; do [ -n "${cardv[$k]+x}" ] || cardv[$k]=$v; done < <(awk -F': *' 'NF>1 { v=$0; sub(/^[^:]*: */, "", v); printf "%s\t%s\n", $1, v }' <<<"$card")
}
get() { echo "${cardv[$1]-}"; }
need() {
  local v; v=$(get "$1")
  [ -n "$v" ] || fail "budget card has no '$1'"
  [[ $v != *"<"* ]] || fail "budget card '$1' is still a placeholder: $v"
  echo "$v"
}
card_or_default() { local v=${cardv[$1]-}; if [ -z "$v" ] || [[ $v == *"<"* ]]; then echo "$2"; else echo "$v"; fi; }
launch_hosts() { card_or_default launch_hosts none; }
state_dir() {
  local d; d=$(card_or_default host_state_dir '~/.local/state/guard/launches')
  case $d in '~') d=$HOME ;; '~/'*) d=$HOME/${d#'~/'} ;; esac
  [[ $d == /* ]] || fail "host_state_dir must be an absolute path: $d"
  echo "$d"
}
this_host() { hostname -s; }
boot_id() { local b; read -r b < /proc/sys/kernel/random/boot_id; echo "$b"; }
mem_available_kb() {
  if [ "${test_mode:-0}" = 1 ] && [ -n "${HPC_LAUNCH_TEST_AVAILABLE_KB:-}" ]; then echo "$HPC_LAUNCH_TEST_AVAILABLE_KB"; return; fi
  awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
}
on_launch_host() { [[ " $(launch_hosts) " == *" $host "* ]]; }
project_id() { git rev-list --max-parents=0 "$base" 2>/dev/null | tail -n1; }

# to_sec <T>: Slurm time syntax (M, M:S, H:M:S, D-H, D-H:M, D-H:M:S) to seconds; prints nothing when malformed.
to_sec() {
  local t=$1 d=0 a b c
  [[ $t == *-* ]] && { d=${t%%-*}; t=${t#*-}; }
  [[ $d =~ ^[0-9]+$ && $t =~ ^[0-9]+(:[0-9]+){0,2}$ ]] || return 0
  IFS=: read -r a b c <<<"$t"
  if [ -n "${c:-}" ]; then echo $(( 10#$d*86400 + 10#$a*3600 + 10#$b*60 + 10#$c ))
  elif [ -n "${b:-}" ]; then if [ "$d" != 0 ]; then echo $(( 10#$d*86400 + 10#$a*3600 + 10#$b*60 )); else echo $(( 10#$a*60 + 10#$b )); fi
  elif [ "$d" != 0 ]; then echo $(( 10#$d*86400 + 10#$a*3600 ))
  else echo $(( 10#$a*60 )); fi
}

# ---------------------------------------------------------------- record store
# <state_dir>/<job_id>/ holds request (launch), start, beat, end (the supervisor, or --stop when the supervisor is
# dead), stop (--stop), and supervisor.log. Files are flat `key: value` lines. A dir without `request` is ignored.

# rkey <file> <key>: first value of <key> in <file>, read now; empty when the file or key is absent.
rkey() { awk -F': *' -v k="$2" '$1==k { sub(/^[^:]*: */, ""); print; exit }' "$1" 2>/dev/null; }
put_once() { timeout 20 bash -c 'printf "%s\n" "$2" > "$1.tmp.$$" && ln "$1.tmp.$$" "$1"; rc=$?; rm -f "$1.tmp.$$"; exit $rc' _ "$1" "$2" 2>/dev/null; }
put_replace() { timeout 20 bash -c 'printf "%s\n" "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"' _ "$1" "$2" 2>/dev/null; }

# index_records: one awk pass over every request, start, end and beat into rec[], and RECORDS, newest first.
declare -A rec=() state_cache=() members_cache=()
RECORDS=()
index_records() {
  local f k v d
  while IFS=$'\t' read -r f k v; do rec["$f:$k"]=$v; done < <(
    awk -F': *' 'FNR==1 { delete seen } !($1 in seen) { seen[$1]=1; v=$0; sub(/^[^:]*: */, "", v); printf "%s\t%s\t%s\n", FILENAME, $1, v }' \
      "$sd"/*/request "$sd"/*/start "$sd"/*/end "$sd"/*/beat 2>/dev/null)
  for d in "$sd"/*/; do d=${d%/}; [ -f "$d/request" ] && RECORDS+=("$d"); done
  [ ${#RECORDS[@]} -eq 0 ] || mapfile -t RECORDS < <(printf '%s\n' "${RECORDS[@]}" | sort -r)
}
# rk <record_dir> <file> <key>: sets r to the indexed value, empty when absent.
rk() { r=${rec["$1/$2:$3"]-}; }
# records [project]: indexed record dirs, newest first, optionally one project's.
records() { local d; for d in ${RECORDS[@]+"${RECORDS[@]}"}; do rk "$d" request project; [ -z "${1:-}" ] || [ "$r" = "$1" ] || continue; echo "$d"; done; }
# run_records <run_id>: this project's records of one run, newest first.
run_records() { local d; for d in $(records "$project"); do rk "$d" request run_id; [ "$r" = "$1" ] && echo "$d"; done; return 0; }

# ---------------------------------------------------------------- the job's processes

# members <job_id> [sid]: pids of processes in session <sid> or whose environ holds HPC_JOB_ID=<job_id>, read now.
# The env tag finds a child that called setsid; the session finds a child that scrubbed its environment.
members() {
  { [ -z "${2:-}" ] || ps -o pid=,state= -s "$2" 2>/dev/null
    grep -lzx "HPC_JOB_ID=$1" /proc/[0-9]*/environ 2>/dev/null; } \
    | awk '$2 == "Z" { next } { n = split($0, a, "/"); p = (n > 1 ? a[3] : $1) + 0; if (p > 0 && !seen[p]++) print p }'
}
# index_procs: every process once, so views answer rec_members from arrays. by_sid[sid] and by_tag[job_id] hold pid lists.
declare -A by_sid=() by_tag=()
index_procs() {
  local p s t
  while read -r p s t; do
    by_sid[$s]="${by_sid[$s]-} $p"; [ -z "$t" ] || by_tag[$t]="${by_tag[$t]-} $p"
  done < <( { ps -e -o pid=,sid=,state= 2>/dev/null; grep -zoE '^HPC_JOB_ID=[^[:cntrl:]]+' /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n'; } \
    | awk '/^\/proc\// { split($0, a, "/"); sub(/^[^=]*=/, "", $0); tag[a[3]] = $0; next } $3 != "Z" { pid[$1] = $2 } END { for (p in pid) print p, pid[p], tag[p] }')
}
# rec_members <record_dir>: the members of a record's job from the process index. The supervisor and --stop
# call members directly because they act on what is alive now.
rec_members() {
  local d=$1 pids p
  if [ -z "${members_cache[$d]+x}" ]; then
    rk "$d" start sid; pids=${by_sid[${r:-none}]-}; rk "$d" request job_id; pids="$pids ${by_tag[$r]-}"
    members_cache[$d]=$(for p in $pids; do echo "$p"; done | sort -un)
  fi
  echo "${members_cache[$d]}"
}
# anon_kb <pid>: Pss_Anon from smaps_rollup, RssAnon when the kernel lacks the field. Pss, so forked workers'
# shared pages count once; anon only, so pages mapped from the shm dirs are not counted twice.
anon_kb() {
  local v; v=$(awk '/^Pss_Anon:/ {print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null)
  [ -n "$v" ] || v=$(awk '/^RssAnon:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null)
  echo "${v:-0}"
}
# shm_kb <dirs, comma-separated or empty>: du over the declared shm dirs that exist.
shm_kb() {
  local d v kb=0 IFS=,
  for d in $1; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    v=$(timeout 10 du -sk "$d" 2>/dev/null | cut -f1); kb=$(( kb + ${v:-0} ))
  done
  echo "$kb"
}
# charge_kb <record_dir>: the job's charge, anon memory of its members plus its declared shm dirs.
charge_kb() {
  local p kb; rk "$1" request shm; kb=$(shm_kb "$r")
  for p in $(rec_members "$1"); do kb=$(( kb + $(anon_kb "$p") )); done
  echo "$kb"
}
# pstat <pid>: PSTAT holds /proc/<pid>/stat past the comm field, so PSTAT[1] is the parent and PSTAT[19] the start time.
pstat() { local s; { read -r s < "/proc/$1/stat"; } 2>/dev/null || return 1; read -ra PSTAT <<<"${s##*) }"; }
starttime() { pstat "$1" && echo "${PSTAT[19]}"; }
pid_is() { [ -n "${1:-}" ] && [ -n "${2:-}" ] && pstat "$1" && [ "${PSTAT[19]}" = "$2" ] && [ "${PSTAT[0]}" != Z ]; }
signal_members() { local p; for p in $(members "$2" "$3"); do kill "-$1" "$p" 2>/dev/null; done; return 0; }

# ---------------------------------------------------------------- state, derived

# state_of <record_dir>: sets st to Slurm's word where Slurm has one, so ripples' job checks apply unchanged.
#   end present:      stop=walltime -> TIMEOUT, mem -> OUT_OF_MEMORY, host-mem -> HOST_OUT_OF_MEMORY,
#                     requested -> CANCELLED, signal -> PREEMPTED, none -> COMPLETED when exit is 0, else FAILED
#   no end, request.host is another host                          -> REMOTE (left out of --sacct rows)
#   no end, start present, start.boot_id differs from this boot   -> NODE_FAIL
#   no end, members alive                                          -> RUNNING   (with or without a supervisor)
#   no end, start present, supervisor pid_is alive                 -> RUNNING   (finishing; end is seconds away)
#   no end, start present, nothing alive                           -> SUPERVISOR_FAILED
#   no end, no start, requested under 4*START_WAIT seconds ago     -> PENDING
#   no end, no start, nothing alive                                -> LAUNCH_FAILED
# Every word a dead job can get matches ripples' job-states pattern except CANCELLED, which, as with scancel,
# counts only toward retries. A dead job never reads as PASS.
state_of() {
  local d=$1 sup
  if [ -n "${state_cache[$d]+x}" ]; then st=${state_cache[$d]}; return; fi
  if [ -f "$d/end" ]; then
    rk "$d" end stop
    case $r in
      walltime) st=TIMEOUT ;; mem) st=OUT_OF_MEMORY ;; host-mem) st=HOST_OUT_OF_MEMORY ;;
      requested) st=CANCELLED ;; signal) st=PREEMPTED ;;
      *) rk "$d" end exit; if [ "$r" = 0 ]; then st=COMPLETED; else st=FAILED; fi ;;
    esac
  else
    rk "$d" request host
    if [ "$r" != "$host" ]; then st=REMOTE
    elif [ -f "$d/start" ] && { rk "$d" start boot_id; [ "$r" != "$this_boot" ]; }; then st=NODE_FAIL
    elif [ -n "$(rec_members "$d")" ]; then st=RUNNING
    elif [ -f "$d/start" ]; then
      rk "$d" start supervisor_pid; sup=$r; rk "$d" start supervisor_start
      if pid_is "$sup" "$r"; then st=RUNNING; else st=SUPERVISOR_FAILED; fi
    else
      rk "$d" request requested
      if [ $(( $(epoch) - $(iso_epoch "$r") )) -lt $(( 4 * START_WAIT )) ]; then st=PENDING; else st=LAUNCH_FAILED; fi
    fi
  fi
  state_cache[$d]=$st
}
# elapsed_of <record_dir> <state>: sets el to the seconds the job held its GPUs. GPU-hours are gpus * elapsed, never stored.
elapsed_of() {
  case $2 in
    RUNNING) rk "$1" start started; [ -n "$r" ] || rk "$1" request requested; el=$(( $(epoch) - $(iso_epoch "$r") )) ;;
    NODE_FAIL|SUPERVISOR_FAILED|REMOTE) rk "$1" beat elapsed_seconds; el=${r:-0} ;;
    PENDING|LAUNCH_FAILED) el=0 ;;
    *) rk "$1" end elapsed_seconds; el=${r:-0} ;;
  esac
}
since_start_date() { rk "$1" request requested; [ -z "$start_date" ] || [[ ! $r < "$start_date" ]]; }

# ---------------------------------------------------------------- views

cmd_sacct() {
  local d st el id rid lim
  for d in $(records "$project"); do
    since_start_date "$d" || continue
    state_of "$d"; [ "$st" = REMOTE ] && continue
    elapsed_of "$d" "$st"; rk "$d" request job_id; id=$r; rk "$d" request run_id; rid=$r; rk "$d" request time_limit_seconds; lim=$r
    printf '%s|%s|%s|%s|%s\n' "$id" "$rid" "$st" "$el" $(( (lim + 59) / 60 ))
  done
}

cmd_list() {
  local rid="" d st el gb id lim mlim gpus log
  [ -z "${1:-}" ] || rid=$(basename "${1%/}")
  printf 'job\tstate\telapsed\tlimit\tmem_gb\tmem_limit_gb\tgpus\tlog\n'
  for d in "$sd"/*/; do
    d=${d%/}; [ -d "$d" ] || continue
    [ -f "$d/request" ] || { [ -n "$rid" ] || printf '%s\tincomplete\n' "$(basename "$d")"; continue; }
    rk "$d" request project; [ "$r" = "$project" ] || continue
    rk "$d" request run_id; [ -z "$rid" ] || [ "$r" = "$rid" ] || continue
    state_of "$d"; elapsed_of "$d" "$st"
    if [ "$st" = RUNNING ]; then gb=$(kb_gb "$(charge_kb "$d")")
    else rk "$d" end peak_mem_gb; [ -n "$r" ] || rk "$d" beat peak_mem_gb; gb=${r:--}; fi
    rk "$d" request job_id; id=$r; rk "$d" request time_limit_seconds; lim=$r; rk "$d" request mem_limit_gb; mlim=$r
    rk "$d" request gpus; gpus=$r; rk "$d" request log; log=$r
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$st" "$el" "$lim" "$gb" "$mlim" "$gpus" "$log"
  done
}

# ---------------------------------------------------------------- checks for ripples
# Nothing prints while launch_hosts is none, so a project that never opted in sees no new line.
# Scope: job lines follow the run ripples was given, host lines cover the host, spend covers the project.

# gpu_seconds <run_id or ''>: sets spent, running, remaining (GPU-seconds) and nrun over this project's records
# since start_date; remaining is what the running launches may still hold under their --time.
gpu_seconds() {
  local d st el n; spent=0 running=0 remaining=0 nrun=0
  for d in $(records "$project"); do
    since_start_date "$d" || continue
    rk "$d" request run_id; [ -z "$1" ] || [ "$r" = "$1" ] || continue
    state_of "$d"; elapsed_of "$d" "$st"; rk "$d" request gpus; n=$(gpu_n "$r")
    spent=$(( spent + n * el ))
    [ "$st" = RUNNING ] || continue
    running=$(( running + n * el )); nrun=$((nrun+1)); rk "$d" request time_limit_seconds
    [ "$el" -ge "$r" ] || remaining=$(( remaining + n * (r - el) ))
  done
}
gpu_h() { printf '%d.%d' $(( $1 / 3600 )) $(( $1 % 3600 * 10 / 3600 )); }
# qval <key>: the run's committed question card value, empty when absent or a placeholder. load_qcard <run_dir> first.
load_qcard() { qcard=$(git show "HEAD:${1%/}/question.card" 2>/dev/null) || qcard=""; }
qval() { local v; v=$(awk -F': *' -v k="$1" '$1==k{print $2; exit}' <<<"$qcard"); if [ -z "$v" ] || [[ $v == *"<"* ]]; then echo ""; else echo "$v"; fi; }
# run_budget <card key> <budget.card default key>: the run's cap, the workspace default when the card is silent, 0 for none.
run_budget() { local v; v=$(qval "$1"); [ -n "$v" ] || v=$(card_or_default "$2" 0); if [[ $v =~ ^[0-9]+$ ]]; then echo "$v"; else echo 0; fi; }

# ---------------------------------------------------------------- the execution envelope
# The question card is design, frozen at first commit. Execution facts go in runs/<id>/execution.tsv, an
# append-only ledger the agent commits: `id ts field value why evidence`, ids x1, x2, ... in order. Only committed
# rows count. The vocabulary is ENVELOPE_FIELDS, fixed here and in fence.sh, not in a card, so an agent cannot extend it.

ledger_rows() { git show "HEAD:${1%/}/execution.tsv" 2>/dev/null; }
# resume_owner <run_id> <path>: the latest launch of the run whose cwd contains <path>; prints its job id.
resume_owner() {
  local d
  for d in $(run_records "$1"); do rk "$d" request cwd; [[ $2 == "$r"/* ]] && { rk "$d" request job_id; echo "$r"; return 0; }; done
  return 1
}
# restart_ok <run_id> <job id>: the job belongs to the run and ended in a resource stop, by launch record or by sacct.
restart_ok() {
  local d row
  for d in $(run_records "$1"); do
    rk "$d" request job_id; [ "$r" = "$2" ] || continue
    state_of "$d"; [[ $st =~ $RESOURCE_STOPS ]]; return
  done
  [[ $2 =~ ^[0-9][0-9_]*$ ]] && [ -n "$(type -P sacct)" ] || return 1
  row=$(sacct -j "$2" -X -n -P -o JobName,State 2>/dev/null | head -n1)
  [ "${row%%|*}" = "$1" ] && [[ ${row#*|} =~ ^(OUT_OF_MEMORY|NODE_FAIL|PREEMPTED) ]]
}
# ledger_check <run_dir>: sets bad (the problems, `; ` separated) and summary over the committed ledger.
ledger_check() {
  local rd=${1%/} rid id ts field value why evidence n=0 header=0 cap
  bad="" summary=""; rid=$(basename "$rd")
  while IFS=$'\t' read -r id ts field value why evidence; do
    if [ $header = 0 ]; then
      header=1; [ "$id	$ts	$field	$value	$why	$evidence" = "id	ts	field	value	why	evidence" ] || bad="$bad; header must be id, ts, field, value, why, evidence"
      continue
    fi
    [ -n "$id" ] || continue
    n=$((n+1)); summary="$summary, $field $id"
    [ "$id" = "x$n" ] || bad="$bad; $id: ids run x1, x2, ... in order; this is row $n"
    [[ $ENVELOPE_FIELDS == *" $field "* ]] || { bad="$bad; $id: $field is design; a change to it needs a new card"; continue; }
    case $field in
      host) [[ " $(launch_hosts) " == *" $value "* ]] || bad="$bad; $id: host $value is not in launch_hosts ($(launch_hosts))" ;;
      mem_stop_gb) cap=$(card_or_default host_max_mem_gb 64)
        [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$(gb_kb "$value")" -le "$(gb_kb "$cap")" ] || bad="$bad; $id: mem_stop_gb $value is over host_max_mem_gb=$cap" ;;
      resume) resume_owner "$rid" "$value" >/dev/null || bad="$bad; $id: resume $value is under no launch cwd of this run" ;;
      restart) restart_ok "$rid" "$value" || bad="$bad; $id: restart $value is not a resource stop of this run" ;;
    esac
  done < <(ledger_rows "$rd")
  summary="$n rows: ${summary#, }"
  load_qcard "$rd"
  cap=$(run_budget budget_gpu_hours default_run_gpu_hours)
  if [ "$cap" != 0 ]; then gpu_seconds "$rid"; [ "$spent" -le $(( cap * 3600 )) ] || bad="$bad; spent $(gpu_h "$spent") GPU-h over budget_gpu_hours=$cap"; fi
  cap=$(run_budget budget_core_hours default_run_core_hours)
  if [ "$cap" != 0 ] && [ -n "$(type -P sacct)" ]; then
    n=$(sacct -A "$(card_or_default account "")" -u "$USER" -S "$(card_or_default start_date "")" -X -n -P -o JobName,CPUTimeRAW 2>/dev/null \
      | awk -F'|' -v r="$rid" '$1==r {s+=$2} END{printf "%d", s/3600}')
    [ "${n:-0}" -le "$cap" ] || bad="$bad; spent $n core-h over budget_core_hours=$cap"
  fi
}
# cmd_handled <run_dir>: "<job id> execution.tsv:<row id>" for every valid restart or resume row, so ripples treats
# the job as handled, exactly like an incident naming it.
cmd_handled() {
  local rd=${1%/} rid id ts field value rest owner; rid=$(basename "$rd")
  while IFS=$'\t' read -r id ts field value rest; do
    case $field in
      restart) restart_ok "$rid" "$value" && echo "$value execution.tsv:$id" ;;
      resume) owner=$(resume_owner "$rid" "$value") && echo "$owner execution.tsv:$id" ;;
    esac
  done < <(ledger_rows "$rd" | tail -n +2)
  return 0
}

cmd_checks() {
  local rd=${1%/} rid bad summary; rid=$(basename "$rd")
  if ledger_rows "$rd" >/dev/null; then
    ledger_check "$rd"
    if [ -n "$bad" ]; then say RIPPLE execution-within-envelope "${bad#; }"; else say PASS execution-within-envelope "$summary"; fi
  fi
  [ "$(launch_hosts)" != none ] || return 0
  local spent running nrun cap live=0 ent="" d id st el kb lim log m avail floor remote=0 hosts="" i sup
  if [ -d "$sd" ] && ! timeout 10 ls "$sd" >/dev/null 2>&1; then say UNCHECKED gpu-hours "cannot read $sd"
  else
    gpu_seconds ""; cap=$(card_or_default max_gpu_hours 0)
    if [ $(( spent * 100 )) -gt $(( cap * 3600 * 80 )) ]; then say RIPPLE gpu-hours "$(gpu_h "$spent") of $cap GPU-h ($(gpu_h "$running") in $nrun running)"
    else say PASS gpu-hours "$(gpu_h "$spent") of $cap GPU-h ($(gpu_h "$running") in $nrun running)"; fi
  fi
  if ! on_launch_host; then
    for m in host-supervision host-memory host-strays host-log-errors; do say UNCHECKED "$m" "$host is not in launch_hosts ($(launch_hosts))"; done; return 0
  fi

  local -a live_ids=() live_dirs=()
  for d in $(run_records "$rid"); do
    [ -f "$d/end" ] && continue
    rk "$d" request host; if [ "$r" != "$host" ]; then remote=$((remote+1)); hosts="$hosts $r"; continue; fi
    state_of "$d"; [ "$st" = RUNNING ] || continue
    live=$((live+1)); rk "$d" request job_id; id=$r
    live_ids+=("$id"); live_dirs+=("$d")
    rk "$d" start supervisor_pid; sup=$r; rk "$d" start supervisor_start
    if [ ! -f "$d/start" ]; then ent="$ent $id:no-supervisor-started-it"
    elif ! pid_is "$sup" "$r"; then rk "$d" start job_pid; ent="$ent $id:pid$r-has-no-supervisor"
    else rk "$d" start log_fd; [ "$r" = ok ] || ent="$ent $id:log_fd-${r// /_}"; fi
  done
  if [ -n "$ent" ]; then say ENTRIES host-supervision "${ent# }"
  elif [ $remote -gt 0 ]; then say UNCHECKED host-supervision "$remote launch(es) unended on$(tr ' ' '\n' <<<"$hosts" | sort -u | tr '\n' ' ' | sed 's/ $//'); run ripples there"
  else say PASS host-supervision "$live live, supervised"; fi

  ent=""; avail=$(mem_available_kb); floor=$(gb_kb "$(card_or_default host_min_available_gb 32)")
  for i in ${live_dirs[@]+"${!live_dirs[@]}"}; do
    d=${live_dirs[i]}; rk "$d" request mem_limit_gb; lim=$(gb_kb "$r"); kb=$(charge_kb "$d")
    [ $(( kb * 100 )) -gt $(( lim * 80 )) ] && ent="$ent ${live_ids[i]}:$(kb_gb "$kb")/${r}G"
  done
  for d in $(run_records "$rid"); do
    [ -f "$d/end" ] || continue; rk "$d" request mem_limit_gb; lim=$(gb_kb "$r"); rk "$d" request shm
    for m in ${r//,/ }; do
      [ -d "$m" ] || continue
      kb=$(shm_kb "$m"); if [ $(( kb * 100 )) -gt $(( lim * 10 )) ]; then rk "$d" request job_id; ent="$ent $r:shm=$m:$(kb_gb "$kb")G-left"; fi
    done
  done
  [ "$avail" -lt $(( 2 * floor )) ] && ent="$ent host:$(kb_gb "$avail")G-available-floor-$(kb_gb "$floor")G"
  if [ -n "$ent" ]; then say ENTRIES host-memory "${ent# }"; else say PASS host-memory "$(kb_gb "$avail")G available; $live live, at most 80% of --mem"; fi

  local s rc; s=$(strays); rc=$?
  if [ -n "$s" ]; then say RIPPLE host-strays "$(tr '\n' ' ' <<<"$s" | sed 's/ $//')"
  elif [ $rc -ne 0 ]; then say UNCHECKED host-strays "no memory strays; GPU strays unchecked, nvidia-smi not found or timed out"
  else say PASS host-strays ""; fi

  ent=""
  for i in ${live_dirs[@]+"${!live_dirs[@]}"}; do
    rk "${live_dirs[i]}" request log; log=$r
    if m=$(timeout 10 tail -c 1048576 "$log" 2>/dev/null | grep -E -o -m1 "$LOG_ERRORS"); then ent="$ent ${live_ids[i]}:${m// /_}"
    elif [ ! -r "$log" ]; then ent="$ent ${live_ids[i]}:log-unreadable"; fi
  done
  if [ -n "$ent" ]; then say ENTRIES host-log-errors "${ent# }"; else say PASS host-log-errors "$live running log(s) scanned"; fi
}

# strays: this user's processes holding a GPU compute context or more than half of host_max_mem_gb, minus members
# of every live launch in the state dir, minus this process's ancestors, minus command lines matching stray_ignore.
# Exit 1 when nvidia-smi could not answer, so the caller can say UNCHECKED.
strays() {
  local d p rss args kb half ign out="" rc=0 gpu_pids="" skip=" " uuid
  half=$(( $(gb_kb "$(card_or_default host_max_mem_gb 64)") / 2 ))
  ign=$(card_or_default stray_ignore none)
  for d in $(records); do
    [ -f "$d/end" ] && continue; rk "$d" request host; [ "$r" = "$host" ] || continue
    skip="$skip$(rec_members "$d" | tr '\n' ' ')"
  done
  p=$$; while [ "$p" -gt 1 ] && pstat "$p"; do skip="$skip$p "; p=${PSTAT[1]}; done
  if command -v nvidia-smi >/dev/null; then
    gpu_pids=$(timeout 20 nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader 2>/dev/null | awk -F', *' 'NF>1 {print $2}') || rc=1
  else rc=1; fi
  while read -r uuid p rss args; do
    kb=0; [ "$rss" -gt "$half" ] && kb=$(anon_kb "$p")
    [ "$uuid" = gpu ] || [ "$kb" -gt "$half" ] || continue
    [ "$ign" = none ] || ! grep -qE -- "$ign" <<<"$args" || continue
    out="$out pid$p:$(kb_gb "$kb")G:$uuid:$(cut -c1-40 <<<"$args" | tr ' ' '_')"
  done < <(ps -u "$UID" -o pid=,rss=,args= 2>/dev/null | awk -v half="$half" -v gp="$gpu_pids" -v skip="$skip" '
    BEGIN { n = split(gp, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") g[a[i]] = 1 }
    index(skip, " " $1 " ") { next }
    ($1 in g) || $2 > half { print (($1 in g) ? "gpu" : "nogpu"), $0 }')
  [ -z "$out" ] || printf '%s\n' "${out# }"
  return $rc
}


# ---------------------------------------------------------------- supervisor
# One supervisor owns one job. It reads every limit from <record_dir>/request, the single source of truth, so a
# card edit mid-run changes nothing; argv carries only the command. It sits outside the job's session as the
# parent of the session leader, so a signal to the job's session reaches the job but not its recorder.

log() { echo "$(now) $*" >&2; }
load_request() {
  rec_dir=$1; sd=$(dirname "$rec_dir"); host=$(this_host)
  job_id=$(rkey "$rec_dir/request" job_id); run_dir_abs=$(rkey "$rec_dir/request" run_dir)
  cwd=$(rkey "$rec_dir/request" cwd); log_path=$(rkey "$rec_dir/request" log); gpus=$(rkey "$rec_dir/request" gpus)
  time_limit=$(rkey "$rec_dir/request" time_limit_seconds); mem_limit_kb=$(gb_kb "$(rkey "$rec_dir/request" mem_limit_gb)")
  shm=$(rkey "$rec_dir/request" shm); grace=$(rkey "$rec_dir/request" stop_grace_seconds)
  floor_kb=$(gb_kb "$(rkey "$rec_dir/request" host_min_available_gb)")
  want="" reason="" elected_detail="" peak=0 low=0 last_beat=0 elapsed=0 charge=0 avail=0
}
job_charge_kb() {
  if [ "${test_mode:-0}" = 1 ] && [ -n "${HPC_LAUNCH_TEST_CHARGE_KB:-}" ]; then echo "$HPC_LAUNCH_TEST_CHARGE_KB"; return; fi
  local p kb; kb=$(shm_kb "$shm")
  for p in $(members "$job_id" "$sid"); do kb=$(( kb + $(anon_kb "$p") )); done
  echo "$kb"
}
write_beat() {
  put_replace "$rec_dir/beat" "time: $(now)
elapsed_seconds: $elapsed
mem_gb: $(kb_gb "$charge")
peak_mem_gb: $(kb_gb "$peak")
host_available_gb: $(kb_gb "$avail")
low_polls: $low" || true
}
# leader_of <wrapper pid>: the session leader, the wrapper's child once it exists; the wrapper itself when the job
# is already gone.
leader_of() {
  local i p
  for ((i = 0; i < 30; i++)); do
    p=$(ps -o pid= --ppid "$1" 2>/dev/null | tr -d ' '); [ -z "$p" ] || { echo "$p"; return; }
    [ "$(ps -o sid= -p "$1" 2>/dev/null | tr -d ' ')" != "$1" ] && pstat "$1" && [ "${PSTAT[0]}" != Z ] || break
    sleep 0.1
  done
  echo "$1"
}
# fd_check <pid>: ok when the job's stdout and stderr are the recorded log, else what they are.
fd_check() {
  local o e want; want=$(readlink -f "$log_path")
  o=$(readlink "/proc/$1/fd/1" 2>/dev/null) || { echo "exited before the check"; return; }
  e=$(readlink "/proc/$1/fd/2" 2>/dev/null)
  if [ "$o" = "$want" ] && [ "$e" = "$want" ]; then echo ok; else echo "stdout=$o stderr=$e"; fi
}
# elected: under host pressure every supervisor reads the fresh beats of the live local launches and runs the same
# election: the largest charge stops, ties to the later start. True when this job is the one. A stray that is not
# a launch cannot be elected; ripples' host-strays names it.
elected() {
  local d t gb started best="" bestgb=-1 beststart="" n=0 e; e=$(epoch)
  for d in "$sd"/*/; do
    d=${d%/}; [ -f "$d/request" ] && [ -f "$d/beat" ] && [ ! -f "$d/end" ] || continue
    [ "$(rkey "$d/request" host)" = "$host" ] || continue
    t=$(iso_epoch "$(rkey "$d/beat" time)"); [ $(( e - t )) -le $(( 3 * POLL )) ] || continue
    gb=$(rkey "$d/beat" mem_gb); started=$(rkey "$d/start" started); n=$((n+1))
    if awk -v a="$gb" -v b="$bestgb" -v sa="$started" -v sb="$beststart" 'BEGIN { exit !(a > b || (a == b && sa > sb)) }'; then best=$d; bestgb=$gb; beststart=$started; fi
  done
  elected_detail="largest of $n live, $bestgb GB"
  [ "$best" = "$rec_dir" ]
}
# poll_once: one supervisor poll. Measures the job, updates peak, low and the beat, and sets reason to walltime,
# mem, host-mem, requested, signal or nothing. Under pressure (MemAvailable under twice the floor) the beat is
# written every poll, so an election reads current charges; otherwise every BEAT_EVERY seconds.
poll_once() {
  elapsed=$(( $(epoch) - started_epoch ))
  charge=$(job_charge_kb); [ "$charge" -le "$peak" ] || peak=$charge
  avail=$(mem_available_kb)
  if [ "$avail" -lt "$floor_kb" ]; then low=$((low+1)); else low=0; fi
  if [ "$avail" -lt $(( 2 * floor_kb )) ] || [ $(( elapsed - last_beat )) -ge "$BEAT_EVERY" ]; then write_beat; last_beat=$elapsed; fi
  reason=$want
  [ -n "$reason" ] || if [ "$elapsed" -ge "$time_limit" ]; then reason=walltime
  elif [ "$charge" -gt "$mem_limit_kb" ]; then reason=mem
  elif [ "$low" -ge 2 ] && elected; then reason=host-mem
  else elected_detail=""; fi
}
# ladder <kill_below_kb>: INT to every member; wait up to grace for none to remain; TERM; wait grace/2; KILL; wait 5 s.
# Members are re-read before every signal, so a process born mid-ladder is still signalled. During the INT wait,
# MemAvailable under <kill_below_kb> skips straight to KILL: the host outranks the checkpoint.
ladder() {
  local i
  log "INT to $(members "$job_id" "$sid" | wc -l) process(es)"; signal_members INT "$job_id" "$sid"
  for ((i = 0; i < grace * 2; i++)); do
    [ -n "$(members "$job_id" "$sid")" ] || return 0
    [ "$(mem_available_kb)" -ge "$1" ] || { log "host under $(kb_gb "$1")G available; KILL now"; break; }
    sleep 0.5
  done
  if [ "$(mem_available_kb)" -ge "$1" ]; then
    log "TERM"; signal_members TERM "$job_id" "$sid"
    for ((i = 0; i < grace; i++)); do [ -n "$(members "$job_id" "$sid")" ] || return 0; sleep 0.5; done
  fi
  log "KILL"; signal_members KILL "$job_id" "$sid"
  for ((i = 0; i < 10; i++)); do [ -n "$(members "$job_id" "$sid")" ] || return 0; sleep 0.5; done
}
# finish <exit> <writer>: kill what the leader left behind, then write end, retrying until the state dir takes it.
finish() {
  local n i text; n=$(members "$job_id" "$sid" | wc -l)
  if [ "$n" -gt 0 ]; then
    log "$n process(es) left after the leader; TERM"; signal_members TERM "$job_id" "$sid"
    for ((i = 0; i < 20; i++)); do [ -n "$(members "$job_id" "$sid")" ] || break; sleep 0.5; done
    [ -z "$(members "$job_id" "$sid")" ] || { log "KILL leftovers"; signal_members KILL "$job_id" "$sid"; sleep 1; }
  fi
  text="ended: $(now)
elapsed_seconds: $elapsed
exit: $1
stop: ${reason:-none}
peak_mem_gb: $(kb_gb "$peak")
leftover_killed: $n
writer: $2"
  [ -z "$elected_detail" ] || text="$text
elected: $elected_detail"
  [ "$reason" != requested ] || text="$text
reason: $(rkey "$rec_dir/stop" reason)"
  until put_once "$rec_dir/end" "$text"; do [ -f "$rec_dir/end" ] && break; sleep 30; done
  log "wrote end"
}
stop_job() {  # stop_job: the ladder for $reason, with the skip-to-KILL floor only for the elected host-mem stop
  local below=0; [ "$reason" != host-mem ] || below=$(( floor_kb / 2 ))
  log "stop $reason${elected_detail:+ ($elected_detail)}"; ladder "$below"
}
cmd_supervise() {
  local rec_dir=$1 cuda rc sl; shift; [ "${1:-}" != -- ] || shift
  cd / || exit 1
  load_request "$rec_dir"
  trap 'want=${want:-requested}' USR1; trap 'want=${want:-signal}' TERM INT HUP
  cuda=$gpus; [ "$cuda" != none ] || cuda=""
  # Job control on for the fork: a plain `&` in a script starts the child with SIGINT ignored, and a shell that
  # inherits an ignored INT cannot trap it, so the gentle stop would never reach the job's checkpoint handler.
  # Job control also makes the child a group leader, which setsid would have to fork away from, so the child is a
  # bash wrapper: its foreground setsid is not a leader, becomes the session leader in place, and the wrapper
  # reports the leader's status in bash's convention (128+n for a signal). The wrapper is outside the session and
  # carries no tag, so it is never a member.
  set -m
  bash -c 'setsid env HPC_JOB_ID="$1" HPC_RUN_DIR="$2" CUDA_VISIBLE_DEVICES="$3" CUDA_DEVICE_ORDER=PCI_BUS_ID \
      bash -c "cd -- \"\$1\" && shift && exec \"\$@\"" _ "${@:4}"; rc=$?; exit $rc' _ "$job_id" "$run_dir_abs" "$cuda" "$cwd" "$@" \
    </dev/null >>"$log_path" 2>&1 &
  job=$!; set +m; started_epoch=$(epoch); wrapper_start=$(starttime "$job")
  leader=$(leader_of "$job"); job_start=$(starttime "$leader")
  sid=$(ps -o sid= -p "$leader" 2>/dev/null | tr -d ' '); sid=${sid:-$leader}
  log "started job pid $leader in session $sid"
  put_once "$rec_dir/start" "started: $(now)
boot_id: $(boot_id)
supervisor_pid: $$
supervisor_start: $(starttime $$)
job_pid: $leader
job_start: $job_start
sid: $sid
log_fd: $(fd_check "$leader")" || log "could not write start"
  while pid_is "$job" "$wrapper_start"; do
    poll_once
    [ -z "$reason" ] || { stop_job; break; }
    sleep $(( elapsed < FAST_FOR ? POLL_FAST : POLL )) & sl=$!; wait $sl; kill $sl 2>/dev/null
  done
  wait "$job"; rc=$?
  log "job leader exited $rc"
  finish "$rc" supervisor
}
# cmd_tick <record_dir>: one poll on a job that something else started, for tests. The job's exit status is
# unknown here, so an end written by a tick says so.
cmd_tick() {
  test_mode=1
  load_request "$1"
  job=$(rkey "$rec_dir/start" job_pid); job_start=$(rkey "$rec_dir/start" job_start); sid=$(rkey "$rec_dir/start" sid)
  started_epoch=$(iso_epoch "$(rkey "$rec_dir/start" started)")
  peak=$(gb_kb "$(rkey "$rec_dir/beat" peak_mem_gb)"); low=$(rkey "$rec_dir/beat" low_polls); low=${low:-0}
  last_beat=$(rkey "$rec_dir/beat" elapsed_seconds); last_beat=${last_beat:--$BEAT_EVERY}
  [ ! -f "$rec_dir/stop" ] || want=requested
  poll_once
  echo "tick: elapsed=$elapsed charge=$(kb_gb "$charge")G available=$(kb_gb "$avail")G low=$low reason=${reason:-none}"
  [ -n "$reason" ] || return 0
  stop_job; finish unknown tick
}

# ---------------------------------------------------------------- launch

# parse_launch_args <run_dir> [options] -- <command...>: sets run_dir, run_id, time_s, gpus, mem_gb, mem_kb, shm, cwd, cmd.
# Boundary validation lives here and only here.
parse_launch_args() {
  run_dir=${1%/}; shift; run_id=$(basename "$run_dir")
  time_s="" gpus="" mem_gb="" shm="" cwd=$PWD; cmd=()
  while [ $# -gt 0 ]; do
    case $1 in
      --time=*) time_s=$(to_sec "${1#*=}"); [ -n "$time_s" ] || fail "--time=${1#*=} is not a Slurm time (M, M:S, H:M:S, D-H, D-H:M, D-H:M:S)" ;;
      --gpus=*) gpus=${1#*=} ;;
      --mem=*) mem_gb=${1#*=} ;;
      --shm=*) [[ ${1#*=} == /* ]] || fail "--shm must be an absolute path: ${1#*=}"; shm=${shm:+$shm,}${1#*=} ;;
      --cwd=*) cwd=${1#*=}; [[ $cwd == /* ]] || cwd=${HPC_CALLER_DIR:-$PWD}/$cwd ;;
      --) shift; cmd=("$@"); break ;;
      *) usage ;;
    esac; shift
  done
  [ ${#cmd[@]} -gt 0 ] || usage
  [ -n "$time_s" ] || fail "state --time=... explicitly"
  [ -n "$gpus" ] || fail "state --gpus=<i,j> or --gpus=none explicitly"
  [ -n "$mem_gb" ] || fail "state --mem=<GB> explicitly"
  [[ $gpus == none || $gpus =~ ^[0-9]+(,[0-9]+)*$ ]] || fail "--gpus takes comma-separated indices or none: $gpus"
  [[ $mem_gb =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "--mem takes GB as a number: $mem_gb"
  [ -d "$cwd" ] && [ -w "$cwd" ] || fail "--cwd=$cwd is not a writable directory"
  cwd=$(cd "$cwd" && pwd -P); mem_kb=$(gb_kb "$mem_gb")
}

# gate_static: the cheap refusals, in preflight's order and words where preflight has the same gate.
gate_static() {
  local changed q stop max_wall
  on_launch_host || fail "$host is not in launch_hosts ($(launch_hosts)) on $base; compute here needs a human to opt in"
  changed=$( { git diff --name-only "$base"...HEAD -- guard; git status --porcelain --untracked-files=all -- guard; } | sort -u)
  [ -z "$changed" ] || fail "guard/ differs from $base: $(echo $changed)"
  explore=0; [[ $run_id == explore-* ]] && explore=1
  qcard=""
  if [ $explore = 0 ]; then
    q="$run_dir/question.card"
    git ls-files --error-unmatch "$q" >/dev/null 2>&1 || fail "$q is not committed"
    git diff --quiet HEAD -- "$q" || fail "$q has uncommitted edits"
    [ "$(git log --format=%H -- "$q" | wc -l)" -le 1 ] || fail "$q was edited after its first commit; start a new run id instead"
    load_qcard "$run_dir"
  fi
  stop=$(need stop_date) || exit $?
  [[ ! $(date +%F) > $stop ]] || fail "past stop_date $stop"
  stop=$(qval deadline); [ -z "$stop" ] || [[ ! $(date +%F) > $stop ]] || fail "past deadline $stop in $run_dir/question.card"
  max_wall=$(( $(card_or_default host_max_walltime_minutes 720) * 60 ))
  if [ $explore = 1 ]; then
    [ "$time_s" -le $(( $(card_or_default explore_max_walltime_minutes 60) * 60 )) ] || fail "--time=$(( time_s / 60 )) min exceeds explore_max_walltime_minutes=$(card_or_default explore_max_walltime_minutes 60)"
    [ "$(gpu_n "$gpus")" -le "$(card_or_default explore_max_gpus 1)" ] || fail "--gpus=$gpus exceeds explore_max_gpus=$(card_or_default explore_max_gpus 1)"
  fi
  [ "$time_s" -le "$max_wall" ] || fail "--time=$(( time_s / 60 )) min exceeds host_max_walltime_minutes=$(card_or_default host_max_walltime_minutes 720)"
  [ "$mem_kb" -le "$(gb_kb "$(card_or_default host_max_mem_gb 64)")" ] || fail "--mem=$mem_gb exceeds host_max_mem_gb=$(card_or_default host_max_mem_gb 64)"
}

# gate_ripples: launch refuses when ripples for the run exits 1, as preflight does. Ripples calls this file only
# through --here, --sacct, --handled and --checks, so there is no recursion. HPC_SPEND_RESERVE=1 skips the gate.
gate_ripples() {
  local script out rc
  [ "${HPC_SPEND_RESERVE:-0}" != 1 ] || return 0
  script=$(git show "$base:guard/bin/ripples.sh" 2>/dev/null) || fail "ripples could not run: no guard/bin/ripples.sh on $base"
  out=$(bash -c "$script" guard/bin/ripples.sh "$run_dir" 2>&1); rc=$?
  case $rc in
    0) ;;
    1) fail "ripples reports $(awk -F'\t' '$1=="RIPPLE" { printf "%s%s: %s", (n++ ? "; " : ""), $2, $3 }' <<<"$out"); fix the cause, record it, or set HPC_SPEND_RESERVE=1 for a diagnostic run" ;;
    *) fail "ripples could not run (exit $rc): $(tail -n1 <<<"$out")" ;;
  esac
}

# gate_host: memory, GPUs and GPU-hours, under the host lock so two launches cannot claim the same resource.
#   memory:    MemAvailable minus the unused headroom of live local launches covers --mem plus the floor
#   GPUs:      each index exists, holds no compute app, and is not in a live local launch's --gpus
#   GPU-hours: project spent + remaining time of running launches + this job fits max_gpu_hours
gate_host() {
  local d st avail floor reserved=0 nlive=0 lim beat i uuid line busy="" held cap n
  avail=$(mem_available_kb); floor=$(gb_kb "$(card_or_default host_min_available_gb 32)")
  for d in $(records); do
    [ -f "$d/end" ] && continue; rk "$d" request host; [ "$r" = "$host" ] || continue
    state_of "$d"; [ "$st" = RUNNING ] || [ "$st" = PENDING ] || continue
    nlive=$((nlive+1)); rk "$d" request mem_limit_gb; lim=$(gb_kb "$r"); rk "$d" beat mem_gb; beat=$(gb_kb "${r:-0}")
    [ "$beat" -ge "$lim" ] || reserved=$(( reserved + lim - beat ))
  done
  [ $(( avail - reserved )) -ge $(( mem_kb + floor )) ] \
    || fail "MemAvailable $(kb_gb "$avail")G minus $(kb_gb "$reserved")G reserved by $nlive live launch(es) leaves less than --mem=${mem_gb}G plus host_min_available_gb=$(card_or_default host_min_available_gb 32)"
  if [ "$gpus" != none ]; then
    command -v nvidia-smi >/dev/null || fail "nvidia-smi not found on PATH; --gpus=none runs a CPU job"
    declare -A uuid_of=()
    while IFS=, read -r i uuid; do uuid_of[${i// /}]=${uuid// /}; done < <(timeout 20 nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null)
    [ ${#uuid_of[@]} -gt 0 ] || fail "nvidia-smi listed no GPU on $host"
    busy=$(timeout 20 nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader 2>/dev/null)
    for i in ${gpus//,/ }; do
      [ -n "${uuid_of[$i]+x}" ] || fail "no GPU $i on $host (nvidia-smi lists ${#uuid_of[@]})"
      line=$(grep -m1 "^${uuid_of[$i]}," <<<"$busy") && fail "GPU $i is busy (pid ${line#*, })"
      held=$(held_by "$i"); [ -z "$held" ] || fail "GPU $i is held by $held"
    done
  fi
  n=$(gpu_n "$gpus"); cap=$(run_budget budget_gpu_hours default_run_gpu_hours)
  if [ "$cap" != 0 ]; then
    gpu_seconds "$run_id"
    [ $(( spent + remaining + n * time_s )) -le $(( cap * 3600 )) ] \
      || fail "this run spent $(gpu_h "$spent") + running $(gpu_h "$remaining") + this job $(gpu_h $(( n * time_s ))) GPU-h exceeds budget_gpu_hours=$cap"
  fi
  cap=$(card_or_default max_gpu_hours 0); gpu_seconds ""
  [ $(( spent + remaining + n * time_s )) -le $(( cap * 3600 )) ] \
    || fail "spent $(gpu_h "$spent") + running $(gpu_h "$remaining") + this job $(gpu_h $(( n * time_s ))) GPU-h exceeds $cap GPU-h (max_gpu_hours)"
}
# gate_restart: a carded run whose latest launch ended in a resource stop continues only through a committed
# restart or resume row citing that job; after a science stop the human decides; after COMPLETED nothing is needed.
gate_restart() {
  local d last="" st
  [ $explore = 0 ] || return 0
  for d in $(run_records "$run_id"); do last=$d; break; done
  [ -n "$last" ] || return 0
  state_of "$last"; rk "$last" request job_id
  if [[ $st =~ $RESOURCE_STOPS ]]; then
    grep -q "^$r " <<<"$(cmd_handled "$run_dir")" || fail "$r ended $st; commit an execution.tsv row (restart or resume) citing it, then launch again"
  elif [[ $st =~ ^(FAILED|TIMEOUT|LAUNCH_FAILED|CANCELLED)$ ]]; then
    fail "$r ended $st, a science stop; the human decides whether this run continues"
  fi
}
held_by() {  # held_by <gpu index>: the live launch whose --gpus names the index, if any
  local d g
  for d in $(records); do
    [ -f "$d/end" ] && continue; rk "$d" request host; [ "$r" = "$host" ] || continue
    state_of "$d"; [ "$st" = RUNNING ] || [ "$st" = PENDING ] || continue
    rk "$d" request gpus; for g in ${r//,/ }; do [ "$g" = "$1" ] && { rk "$d" request job_id; echo "$r"; return; }; done
  done
}

# new_job_id: <host>-<UTC stamp>, claimed by mkdir under the host lock; on a collision wait a second and retry.
new_job_id() {
  local id
  mkdir -p "$sd" || fail "cannot create host_state_dir $sd"
  while :; do id=$host-$(date -u +%Y%m%dT%H%M%SZ); mkdir "$sd/$id" 2>/dev/null && { echo "$id"; return; }; sleep 1; done
}
request_text() {
  local cc=none cd=none
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cc=$(git -C "$cwd" rev-parse HEAD 2>/dev/null || echo none); cd=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l)
  fi
  cat <<REQ
job_id: $id
run_id: $run_id
run_dir: $PWD/$run_dir
project: $project
origin: $(git remote get-url origin 2>/dev/null || echo none)
host: $host
guard_commit: $(git rev-parse "$base")
card: $([ -n "$qcard" ] && git rev-parse "HEAD:$run_dir/question.card" || echo none)
cwd: $cwd
cwd_commit: $cc
cwd_dirty: $cd
log: $cwd/launch-$id.log
gpus: $gpus
time_limit_seconds: $time_s
mem_limit_gb: $mem_gb
shm: $shm
stop_grace_seconds: $(card_or_default host_stop_grace_seconds 60)
host_min_available_gb: $(card_or_default host_min_available_gb 32)
command: ${cmd[*]}
requested: $(now)
REQ
}
# spawn_supervisor <record_dir> -- <command...>: the supervisor runs the same bytes launch ran, detached in its own session.
spawn_supervisor() {
  if [ -n "${BASH_EXECUTION_STRING:-}" ]; then setsid -f bash -c "$BASH_EXECUTION_STRING" "$0" --supervise "$@" </dev/null >/dev/null 2>&1
  else setsid -f bash "$0" --supervise "$@" </dev/null >/dev/null 2>&1; fi
}
# cmd_launch: gates, claim, request, manifest, supervisor, handshake. Prints the job id alone on stdout.
# Crash points: before mkdir nothing exists; after it an empty dir that --list shows as incomplete; after request
# a record that reads LAUNCH_FAILED once PENDING expires; after the spawn the supervisor carries on without us.
cmd_launch() {
  local id rdir i
  parse_launch_args "$@"
  gate_static
  gate_ripples
  exec 9>"${TMPDIR:-/tmp}/guard-launch-$USER.lock"
  flock -w 30 9 || fail "another launch has held the host lock for 30 s"
  index_records; index_procs
  gate_restart
  gate_host
  id=$(new_job_id) || exit $?; rdir=$sd/$id
  put_once "$rdir/request" "$(request_text)" || fail "could not write $rdir/request"
  flock -u 9
  mkdir -p "$run_dir"
  HPC_JOB_ID=$id bash -c "$(git show "$base:guard/bin/manifest.sh")" guard/bin/manifest.sh "$run_dir" "${cmd[@]}" >/dev/null 2>&1 \
    || echo "launch: manifest not written for $run_dir" >&2
  spawn_supervisor "$rdir" -- "${cmd[@]}"
  for ((i = 0; i < START_WAIT * 10; i++)); do [ -f "$rdir/start" ] && break; sleep 0.1; done
  [ -f "$rdir/start" ] || fail "the supervisor did not start the job within ${START_WAIT}s; see $rdir/supervisor.log"
  echo "LAUNCH OK: $run_id job=$id gpus=$gpus time=$(( time_s / 60 ))m mem=${mem_gb}G gpu_h_spent=$(gpu_h "$spent") available=$(gpu_h $(( $(card_or_default max_gpu_hours 0) * 3600 - spent - remaining ))) log=$cwd/launch-$id.log" >&2
  echo "$id"
}

# ---------------------------------------------------------------- stop

# cmd_stop <job_id> <reason>: stop this project's job gently, wait for its end record, print its state.
#   ended already                  -> "already ended: <state>", exit 0
#   another project's record       -> LAUNCH FAIL (the skill: never cancel what the run did not submit)
#   supervisor alive               -> USR1 to the supervisor; it runs the ladder with stop: requested
#   supervisor dead, members alive -> the ladder runs here, then end with exit: unknown and writer: stop;
#                                     put_once loses cleanly if a slow supervisor wrote end first
cmd_stop() {
  local d=$sd/$1 sup i
  [ -f "$d/request" ] || fail "no launch $1 in $sd"
  rk "$d" request project; [ "$r" = "$project" ] || fail "$1 belongs to another project; never cancel what the run did not submit"
  state_of "$d"
  case $st in
    RUNNING|PENDING) ;;
    REMOTE) rk "$d" request host; fail "$1 runs on $r; stop it there" ;;
    *) echo "already ended: $st"; return 0 ;;
  esac
  put_once "$d/stop" "requested: $(now)
reason: $2
by: $USER pid $$" || true
  rk "$d" start supervisor_pid; sup=$r; rk "$d" start supervisor_start
  if pid_is "$sup" "$r"; then kill -USR1 "$sup"
  else
    load_request "$d"; sid=$(rkey "$d/start" sid); reason=requested
    rk "$d" start started; [ -n "$r" ] || rk "$d" request requested; started_epoch=$(iso_epoch "$r"); elapsed=$(( $(epoch) - started_epoch ))
    rk "$d" beat peak_mem_gb; peak=$(gb_kb "${r:-0}")
    stop_job; finish unknown stop
  fi
  for ((i = 0; i < grace_wait * 5; i++)); do [ -f "$d/end" ] && break; sleep 0.2; done
  [ -f "$d/end" ] || fail "$1 has not ended after ${grace_wait}s; see $d/supervisor.log"
  index_records; unset "state_cache[$d]"; state_of "$d"; echo "$st"
}

# ---------------------------------------------------------------- dispatch

# The supervisor reads only its request, never the card or git, so it is dispatched first.
case ${1:-} in
  --supervise) [ $# -ge 3 ] || usage; shift; cmd_supervise "$@" >>"$1/supervisor.log" 2>&1; exit ;;
  --tick)      [ $# -eq 2 ] || usage; cmd_tick "$2" 2>>"$2/supervisor.log"; exit ;;
esac

load_card
host=$(this_host); sd=$(state_dir) || exit $?; project=$(project_id); this_boot=$(boot_id); start_date=$(card_or_default start_date "")
grace_wait=$(( $(card_or_default host_stop_grace_seconds 60) * 3 / 2 + 20 ))
case ${1:-} in
  --here)      on_launch_host; exit ;;
  --sacct)     on_launch_host || exit 0 ;;
  --list|--checks|--stop|--handled) ;;
  ""|-*)       usage ;;
esac
case $1 in
  --list)      index_records; index_procs; cmd_list "${2:-}" ;;
  --sacct)     index_records; index_procs; cmd_sacct ;;
  --checks)    [ $# -eq 2 ] || usage; index_records; index_procs; cmd_checks "$2" ;;
  --handled)   [ $# -eq 2 ] || usage; index_records; index_procs; cmd_handled "$2" ;;
  --stop)      reason_arg=${3:---reason=}; [ $# -ge 2 ] && [ $# -le 3 ] && [[ $reason_arg == --reason=* ]] || usage
               index_records; index_procs; cmd_stop "$2" "${reason_arg#--reason=}" ;;
  *)           cmd_launch "$@" ;;
esac
