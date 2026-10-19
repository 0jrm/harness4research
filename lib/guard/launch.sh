#!/usr/bin/env bash
# usage: launch.sh --supervise <record_dir> -- <command...>
#        launch.sh --tick <record_dir>
#        launch.sh --list  <state_dir> <project> [run_id]
#        launch.sh --sacct <state_dir> <project> [start_date]
#        launch.sh --stop  <state_dir> <project> <job_id> [--reason=<text>]
#        launch.sh --view  <state_dir> <project> <start_date|-> <host_max_mem_gb> <stray_ignore|none>
# The supervisor of one host job and the views over its records. Every entry point is internal, called only by
# lib/broker/host.py from the same checkout, which owns parsing, gating and writing the request; nothing here reads
# git or a card. A supervisor owns one job and nothing else: it enforces the request's time and memory limits, stops
# gently (INT, then TERM, then KILL), and writes the job's record.
#
#   --supervise   the resident supervisor, started detached by host.py after it writes <record_dir>/request
#   --tick        one supervisor poll on a job somebody else started, for tests
#   --list        tab-separated rows, header first: job state elapsed limit mem_gb mem_limit_gb gpus log
#   --sacct       sacct rows JobID|JobName|State|ElapsedRaw|TimelimitRaw since start_date; REMOTE rows left out
#   --stop        stop one job of <project>; prints "<state before> <state after>"
#   --view        this host's resources as key<TAB>value lines, for host.py's gates
#
# Invariants:
#   - Every record file is written once, by one writer, through link(2), so a reader sees it whole or not at all.
#     `beat` is the one file that is replaced, through rename(2).
#   - A record's state is derived, never stored: from which files exist, the boot id, and /proc. See state_of.
#   - A job is the set of this user's processes in the job's session or carrying HPC_JOB_ID=<id>. See members.
#   - No path here deletes a file. Leftover shm dirs are reported, never removed.
#   - The enforcement loop never waits on the state dir: every write there runs under timeout.
#   - Only the supervisor and --stop ever signal a job.
#
# Views read every record and every process once, into arrays, and the accessors below set $r, $st or $el instead
# of printing, because a `$(...)` per field would fork hundreds of times per call.
set -uo pipefail
# cron, containers and Slurm epilogs may leave USER unset, and set -u would stop at its first use.
USER=${USER:-$(id -un)}

readonly POLL_FAST=1 POLL=5 FAST_FOR=60 BEAT_EVERY=60 START_WAIT=15

usage() { sed -n '2,7{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" >&2; exit 64; }
fail() { echo "launch.sh: $*" >&2; exit 2; }
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

this_host() { hostname -s; }
boot_id() { local b; read -r b < /proc/sys/kernel/random/boot_id; echo "$b"; }
mem_available_kb() {
  if [ "${test_mode:-0}" = 1 ] && [ -n "${HPC_LAUNCH_TEST_AVAILABLE_KB:-}" ]; then echo "$HPC_LAUNCH_TEST_AVAILABLE_KB"; return; fi
  awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
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
  local d=$1 pids p out=""
  if [ -z "${members_cache[$d]+x}" ]; then
    local -A seen=()
    rk "$d" start sid; pids=${by_sid[${r:-none}]-}; rk "$d" request job_id; pids="$pids ${by_tag[$r]-}"
    for p in $pids; do [ -n "${seen[$p]+x}" ] || { seen[$p]=1; out="$out$p"$'\n'; }; done
    members_cache[$d]=${out%$'\n'}
  fi
  echo "${members_cache[$d]}"
}
# anon_kb <pid>: RssAnon from /proc/<pid>/status, the cheap measure used on every poll and in every view. Anon only,
# so pages mapped from the shm dirs are not counted twice. Forked workers' shared copy-on-write pages count once per
# worker, so the sum is an upper bound.
anon_kb() { local v; v=$(awk '/^RssAnon:/ {print $2; exit}' "/proc/$1/status" 2>/dev/null); echo "${v:-0}"; }
# pss_anon_kb <pid>: Pss_Anon from smaps_rollup, which counts shared pages once but costs seconds of kernel time
# for a process that maps a large /dev/shm. Used only to confirm a mem stop. Falls back to RssAnon.
pss_anon_kb() {
  local v; v=$(timeout 20 awk '/^Pss_Anon:/ {print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null)
  [ -n "$v" ] && echo "$v" || anon_kb "$1"
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

# state_of <record_dir>: sets st to Slurm's word where Slurm has one, so a host job reads like a Slurm job.
#   end present:      stop=walltime -> TIMEOUT, mem -> OUT_OF_MEMORY, host-mem -> HOST_OUT_OF_MEMORY,
#                     requested -> CANCELLED, signal -> PREEMPTED, none -> COMPLETED when exit is 0, else FAILED
#   no end, request.host is another host                          -> REMOTE (left out of --sacct rows)
#   no end, start present, start.boot_id differs from this boot   -> NODE_FAIL
#   no end, members alive                                          -> RUNNING   (with or without a supervisor)
#   no end, start present, supervisor pid_is alive                 -> RUNNING   (finishing; end is seconds away)
#   no end, start present, nothing alive                           -> SUPERVISOR_FAILED
#   no end, no start, requested under 4*START_WAIT seconds ago     -> PENDING
#   no end, no start, nothing alive                                -> LAUNCH_FAILED
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
  local rid=${1:-} d st el gb id lim mlim gpus log
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

# gpu_seconds: sets spent and remaining (GPU-seconds) over this project's records since start_date; remaining is
# what the running launches may still hold under their time limit.
gpu_seconds() {
  local d st el n; spent=0 remaining=0
  for d in $(records "$project"); do
    since_start_date "$d" || continue
    state_of "$d"; elapsed_of "$d" "$st"; rk "$d" request gpus; n=$(gpu_n "$r")
    spent=$(( spent + n * el ))
    [ "$st" = RUNNING ] || continue
    rk "$d" request time_limit_seconds
    [ "$el" -ge "$r" ] || remaining=$(( remaining + n * (r - el) ))
  done
}

# strays: this user's processes holding a GPU compute context (from $apps, nvidia-smi's compute apps) or more than
# half of host_max_mem_gb of RssAnon, minus members of every live launch in the state dir, minus this process's
# ancestors, minus command lines matching stray_ignore. One awk pass over /proc/*/status finds the candidates; ps
# runs only for those.
strays() {
  local d p args kb half out="" gpu_pids skip=" " uuid
  half=$(( $(gb_kb "$max_mem_gb") / 2 ))
  for d in $(records); do
    [ -f "$d/end" ] && continue; rk "$d" request host; [ "$r" = "$host" ] || continue
    skip="$skip$(rec_members "$d" | tr '\n' ' ')"
  done
  p=$$; while [ "$p" -gt 1 ] && pstat "$p"; do skip="$skip$p "; p=${PSTAT[1]}; done
  gpu_pids=$(awk -F', *' 'NF>1 {print $2}' <<<"$apps")
  while read -r uuid p kb; do
    args=$(ps -o args= -p "$p" 2>/dev/null) || continue
    [ "$stray_ignore" = none ] || ! grep -qE -- "$stray_ignore" <<<"$args" || continue
    out="$out pid$p:$(kb_gb "$kb")G:$uuid:$(cut -c1-40 <<<"$args" | tr ' ' '_')"
  done < <(awk -v uid="$UID" -v half="$half" -v gp="$gpu_pids" -v skip="$skip" '
    function flush() { if (pid != "" && u == uid && index(skip, " " pid " ") == 0 && ((pid in g) || kb > half)) print ((pid in g) ? "gpu" : "nogpu"), pid, kb }
    BEGIN { n = split(gp, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") g[a[i]] = 1 }
    FNR == 1 { flush(); pid = ""; u = -1; kb = 0 }
    $1 == "Pid:" { pid = $2 } $1 == "Uid:" { u = $2 } $1 == "RssAnon:" { kb = $2 }
    END { flush() }' /proc/[0-9]*/status 2>/dev/null)
  echo "${out# }"
}

# cmd_view: one key<TAB>value line per key, each once, in a fixed order. Live launches are RUNNING or PENDING on
# this host, any project, newest first; reserved_kb is the headroom they may still grow into under their mem limit.
cmd_view() {
  local d st lim beat reserved=0 live="" held="" nvsmi=missing q i uuid gpu_list="" busy="" apps=""
  for d in $(records); do
    [ -f "$d/end" ] && continue; rk "$d" request host; [ "$r" = "$host" ] || continue
    state_of "$d"; [ "$st" = RUNNING ] || [ "$st" = PENDING ] || continue
    rk "$d" request job_id; live="$live $r"
    rk "$d" request gpus; [ "$r" = none ] || held="$held ${r//,/ }"
    rk "$d" request mem_limit_gb; lim=$(gb_kb "$r"); rk "$d" beat mem_gb; beat=$(gb_kb "${r:-0}")
    [ "$beat" -ge "$lim" ] || reserved=$(( reserved + lim - beat ))
  done
  if command -v nvidia-smi >/dev/null; then
    if q=$(timeout 20 nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null) \
        && apps=$(timeout 20 nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader 2>/dev/null); then
      nvsmi=ok
      while IFS=, read -r i uuid; do
        i=${i// /}; uuid=${uuid// /}; [ -n "$i" ] || continue
        gpu_list="$gpu_list $i"; ! grep -q "^$uuid," <<<"$apps" || busy="$busy $i"
      done <<<"$q"
    else nvsmi=failed apps=""; fi
  fi
  gpu_seconds
  printf '%s\t%s\n' host "$host" mem_available_kb "$(mem_available_kb)" reserved_kb "$reserved" live "${live# }" \
    held_gpus "${held# }" nvidia_smi "$nvsmi" gpus "${gpu_list# }" busy_gpus "${busy# }" \
    gpu_seconds "$spent $remaining" strays "$(strays)"
}

# ---------------------------------------------------------------- supervisor
# One supervisor owns one job. It reads every limit from <record_dir>/request, the single source of truth, so a
# change elsewhere mid-run changes nothing; argv carries only the command. It sits outside the job's session as the
# parent of the session leader, so a signal to the job's session reaches the job but not its recorder.

log() { echo "$(now) $*" >&2; }
load_request() {
  rec_dir=$1; sd=$(dirname "$rec_dir"); host=$(this_host)
  job_id=$(rkey "$rec_dir/request" job_id); run_dir_abs=$(rkey "$rec_dir/request" run_dir)
  cwd=$(rkey "$rec_dir/request" cwd); log_path=$(rkey "$rec_dir/request" log); gpus=$(rkey "$rec_dir/request" gpus)
  time_limit=$(rkey "$rec_dir/request" time_limit_seconds); mem_limit_kb=$(gb_kb "$(rkey "$rec_dir/request" mem_limit_gb)")
  shm=$(rkey "$rec_dir/request" shm); grace=$(rkey "$rec_dir/request" stop_grace_seconds)
  floor_kb=$(gb_kb "$(rkey "$rec_dir/request" host_min_available_gb)"); boxed=$(rkey "$rec_dir/request" boxed)
  want="" reason="" elected_detail="" stopping="" charge_measure=rss_anon last_confirm=-$BEAT_EVERY peak=0 low=0 last_beat=0 elapsed=0 charge=0 avail=0
}
# job_charge_kb [pss]: the job's charge, declared shm dirs plus RssAnon of every member, or Pss_Anon with `pss`.
job_charge_kb() {
  local p kb measure=anon_kb var=HPC_LAUNCH_TEST_CHARGE_KB
  [ "${1:-}" != pss ] || { measure=pss_anon_kb; var=HPC_LAUNCH_TEST_PSS_KB; }
  if [ "${test_mode:-0}" = 1 ] && [ -n "${!var:-}" ]; then echo "${!var}"; return; fi
  kb=$(shm_kb "$shm")
  for p in $(members "$job_id" "$sid"); do kb=$(( kb + $($measure "$p") )); done
  echo "$kb"
}
write_beat() {
  put_replace "$rec_dir/beat" "time: $(now)
elapsed_seconds: $elapsed
mem_gb: $(kb_gb "$charge")
peak_mem_gb: $(kb_gb "$peak")
host_available_gb: $(kb_gb "$avail")
low_polls: $low${stopping:+
stopping: $stopping}" || true
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
# election: the largest charge stops, ties to the later start. True when this job is the one. A launch whose fresh
# beat says it is already stopping settles the election for everyone else: one cause, one stop. A stray that is not
# a launch cannot be elected; --view's strays names it.
elected() {
  local d t gb started best="" bestgb=-1 beststart="" n=0 e; e=$(epoch)
  for d in "$sd"/*/; do
    d=${d%/}; [ -f "$d/request" ] && [ -f "$d/beat" ] && [ ! -f "$d/end" ] || continue
    [ "$(rkey "$d/request" host)" = "$host" ] || continue
    t=$(iso_epoch "$(rkey "$d/beat" time)"); [ $(( e - t )) -le $(( 3 * POLL )) ] || continue
    gb=$(rkey "$d/beat" stopping); [ -z "$gb" ] || { elected_detail="$(basename "$d") is already stopping ($gb)"; return 1; }
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
  [ -z "$reason" ] || return 0
  if [ "$elapsed" -ge "$time_limit" ]; then reason=walltime
  elif [ "$charge" -gt "$mem_limit_kb" ] && confirmed_over_limit; then reason=mem
  elif [ "$low" -ge 2 ] && elected; then reason='host-mem'
  else elected_detail=""; fi
}
# confirmed_over_limit: the cheap charge is an upper bound, so a mem stop is confirmed with Pss_Anon first.
# peak_mem_gb keeps the per-poll RssAnon measure; charge_measure names what decided the stop. A "no" holds for
# BEAT_EVERY seconds, so a job whose shared copy-on-write pages keep RssAnon over the limit pays the slow read once a minute.
confirmed_over_limit() {
  local pss
  [ $(( elapsed - last_confirm )) -ge "$BEAT_EVERY" ] || return 1
  last_confirm=$elapsed; pss=$(job_charge_kb pss)
  log "charge $(kb_gb "$charge")G by RssAnon over $(kb_gb "$mem_limit_kb")G; Pss_Anon says $(kb_gb "$pss")G"
  [ "$pss" -gt "$mem_limit_kb" ] || return 1
  charge=$pss; charge_measure=pss
}
# gentle <INT|TERM>: a boxed job's session leader is the outer bwrap, which dies of INT whatever the job inside does
# with it, so a box's gentle signals go only to the tagged processes inside. KILL always goes to every member.
gentle() { if [ "$boxed" = yes ]; then signal_members "$1" "$job_id" ""; else signal_members "$1" "$job_id" "$sid"; fi; }
# ladder <kill_below_kb>: INT to every member; wait up to grace for none to remain; TERM; wait grace/2; KILL; wait 5 s.
# Members are re-read before every signal, so a process born mid-ladder is still signalled. During the INT wait,
# MemAvailable under <kill_below_kb> skips straight to KILL: the host outranks the checkpoint. Every wait writes the
# beat with `stopping:`, so the other supervisors' elections see this stop instead of a stale beat.
ladder() {
  local i
  log "INT to $(members "$job_id" "$sid" | wc -l) process(es)"; gentle INT
  for ((i = 0; i < grace * 2; i++)); do
    [ -n "$(members "$job_id" "$sid")" ] || return 0
    [ "$(mem_available_kb)" -ge "$1" ] || { log "host under $(kb_gb "$1")G available; KILL now"; break; }
    write_beat; sleep 0.5
  done
  if [ "$(mem_available_kb)" -ge "$1" ]; then
    log "TERM"; gentle TERM
    for ((i = 0; i < grace; i++)); do [ -n "$(members "$job_id" "$sid")" ] || return 0; write_beat; sleep 0.5; done
  fi
  log "KILL"; signal_members KILL "$job_id" "$sid"
  for ((i = 0; i < 10; i++)); do [ -n "$(members "$job_id" "$sid")" ] || return 0; write_beat; sleep 0.5; done
}
# finish <exit> <writer>: kill what the leader left behind, then write end, retrying until the state dir takes it.
finish() {
  local n i text; n=$(members "$job_id" "$sid" | wc -l)
  if [ "$n" -gt 0 ]; then
    log "$n process(es) left after the leader; TERM"; gentle TERM
    for ((i = 0; i < 20; i++)); do [ -n "$(members "$job_id" "$sid")" ] || break; sleep 0.5; done
    [ -z "$(members "$job_id" "$sid")" ] || { log "KILL leftovers"; signal_members KILL "$job_id" "$sid"; sleep 1; }
  fi
  text="ended: $(now)
elapsed_seconds: $elapsed
exit: $1
stop: ${reason:-none}
peak_mem_gb: $(kb_gb "$peak")
charge_measure: $charge_measure
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
  stopping=$reason; write_beat
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
  bash -c 'setsid env HPC_JOB_ID="$1" GUARD_JOB_ID="$1" HPC_RUN_DIR="$2" CUDA_VISIBLE_DEVICES="$3" CUDA_DEVICE_ORDER=PCI_BUS_ID \
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

# ---------------------------------------------------------------- stop

# cmd_stop <job_id> <reason>: stop this project's job gently, wait for its end record, print "<before> <after>".
#   ended already                  -> its state twice
#   another project's record       -> refused (never cancel what the run did not submit)
#   supervisor alive               -> USR1 to the supervisor; it runs the ladder with stop: requested
#   supervisor dead, members alive -> the ladder runs here, then end with exit: unknown and writer: stop;
#                                     put_once loses cleanly if a slow supervisor wrote end first
cmd_stop() {
  local d=$sd/$1 sup i before grace_wait
  [ -f "$d/request" ] || fail "no launch $1 in $sd"
  rk "$d" request project; [ "$r" = "$project" ] || fail "$1 belongs to another project"
  rk "$d" request stop_grace_seconds; grace_wait=$(( ${r:-60} * 3 / 2 + 20 ))
  state_of "$d"; before=$st
  case $st in
    RUNNING|PENDING) ;;
    REMOTE) rk "$d" request host; fail "$1 runs on $r; stop it there" ;;
    *) echo "$st $st"; return 0 ;;
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
  index_records; unset "state_cache[$d]"; state_of "$d"; echo "$before $st"
}

# ---------------------------------------------------------------- dispatch

case ${1:-} in
  --supervise) [ $# -ge 3 ] || usage; shift; cmd_supervise "$@" >>"$1/supervisor.log" 2>&1; exit ;;
  --tick)      [ $# -eq 2 ] || usage; cmd_tick "$2" 2>>"$2/supervisor.log"; exit ;;
  --list|--sacct) [ $# -ge 3 ] && [ $# -le 4 ] || usage ;;
  --stop)      [ $# -ge 4 ] && [ $# -le 5 ] && [[ ${5:---reason=} == --reason=* ]] || usage ;;
  --view)      [ $# -eq 6 ] || usage
               [[ $5 =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "host_max_mem_gb takes GB as a number: $5"
               [ -z "${HPC_LAUNCH_TEST_AVAILABLE_KB:-}" ] || test_mode=1 ;;
  *)           usage ;;
esac
sd=$2 project=$3 host=$(this_host) this_boot=$(boot_id) start_date=""
[[ $sd == /* ]] || fail "the state dir must be an absolute path: $sd"
index_records; index_procs
case $1 in
  --list)  cmd_list "${4:-}" ;;
  --sacct) start_date=${4:-}; cmd_sacct ;;
  --stop)  reason_arg=${5:---reason=}; cmd_stop "$4" "${reason_arg#--reason=}" ;;
  --view)  [ "$4" = - ] || start_date=$4; max_mem_gb=$5 stray_ignore=$6; cmd_view ;;
esac
