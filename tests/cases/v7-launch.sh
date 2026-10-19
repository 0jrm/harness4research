# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture: lib/guard/launch.sh's supervisor and record views, called as lib/broker/host.py
# calls them, with a state dir, a project id and nothing read from git or a card. tests/cases/70-host.sh covers host.py.
echo "== launch"
L=$here/lib/guard/launch.sh S=$tmp/state
proj_id=0123456789abcdef0123456789abcdef01234567
boot=$(cat /proc/sys/kernel/random/boot_id)
ago() { date -u -d "-$1" +%FT%TZ; }
rec() {  # rec <id> <file>: write one record file by hand from stdin, in the documented format
  mkdir -p "$tmp/state/$1"; cat > "$tmp/state/$1/$2"
}
req() {  # req <id> <run_id> <gpus> <time_limit_seconds> <requested> [host] [mem_gb] [shm]: a request record for this project
  rec "$1" request <<REQ
job_id: $1
run_id: $2
run_dir: $PWD/runs/$2
project: $proj_id
origin: $tmp/origin.git
host: ${6:-skynet}
cwd: $tmp/scratch
log: $tmp/scratch/launch-$1.log
gpus: $3
time_limit_seconds: $4
mem_limit_gb: ${7:-1}
shm: ${8:-}
stop_grace_seconds: 1
host_min_available_gb: 0
command: sleep 30
requested: $5
session: s-launch
REQ
}
start_rec() {  # start_rec <id> <boot_id> <supervisor_pid> <supervisor_start> <job_pid> <job_start> [started]
  rec "$1" start <<START
started: ${7:-$(ago '1 hour')}
boot_id: $2
supervisor_pid: $3
supervisor_start: $4
job_pid: $5
job_start: $6
sid: $5
log_fd: ok
START
}
end_rec() {  # end_rec <id> <elapsed> <exit> <stop>
  rec "$1" end <<END
ended: $(ago '1 min')
elapsed_seconds: $2
exit: $3
stop: $4
peak_mem_gb: 0.5
leftover_killed: 0
writer: supervisor
END
}
beat_rec() {  # beat_rec <id> <elapsed> <mem_gb> [time] [extra line]
  rec "$1" beat <<BEAT
time: ${4:-$(ago '1 min')}
elapsed_seconds: $2
mem_gb: $3
peak_mem_gb: $3
host_available_gb: 100.0
low_polls: 0${5:+
$5}
BEAT
}
mkdir -p "$tmp/scratch"
F=runs/2026-10-02-fixtures; mkdir -p "$F"
expect launch-usage fail 'usage: launch.sh --supervise' -- bash "$L"
req skynet-20260901T000000Z 2026-10-02-fixtures 0,1 36000 "$(ago '10 hours')"; end_rec skynet-20260901T000000Z 33966 0 none
req skynet-20260901T010000Z 2026-10-02-fixtures 2 21600 "$(ago '9 hours')"; end_rec skynet-20260901T010000Z 1276 130 mem
req skynet-20260901T020000Z 2026-10-02-fixtures 0,1 36000 "$(ago '8 hours')"
start_rec skynet-20260901T020000Z 00000000-0000-0000-0000-000000000000 1 1 1 1; beat_rec skynet-20260901T020000Z 3600 10.0
req skynet-20260901T030000Z 2026-10-02-fixtures none 60 "$(ago '10 min')"
req skynet-20260901T040000Z 2026-10-02-fixtures none 60 "$(date -u +%FT%TZ)"
req skynet-20260901T050000Z 2026-10-02-fixtures none 60 "$(ago '5 min')"
touch "$tmp/scratch/launch-skynet-20260901T050000Z.log"; env HPC_JOB_ID=skynet-20260901T050000Z sleep 30 & alive_pid=$!
req skynet-20260901T060000Z 2026-10-02-fixtures none 3600 "$(ago '2 hours')"
start_rec skynet-20260901T060000Z "$boot" 2 999999999 3 999999999; printf 'ended: half' > "$tmp/state/skynet-20260901T060000Z/end.tmp.123"
req skynet-20260901T070000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')"; end_rec skynet-20260901T070000Z 3300 0 none
mkdir -p "$tmp/state/skynet-20260901T080000Z"
req gpu2-20260901T000000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')" gpu2
req gpu2-20260901T010000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')" gpu2; end_rec gpu2-20260901T010000Z 10 1 none
req skynet-20260801T000000Z 2026-10-02-fixtures 3 36000 "2026-08-01T00:00:00Z"; end_rec skynet-20260801T000000Z 36000 0 none
sacct_rows=$(bash "$L" --sacct "$S" "$proj_id" 2026-09-01T00:00:00Z)
expect sacct-completed ok '^skynet-20260901T000000Z\|2026-10-02-fixtures\|COMPLETED\|33966\|600$' -- echo "$sacct_rows"
expect sacct-oom ok '^skynet-20260901T010000Z\|2026-10-02-fixtures\|OUT_OF_MEMORY\|1276\|360$' -- echo "$sacct_rows"
expect crash-reboot ok '^skynet-20260901T020000Z\|2026-10-02-fixtures\|NODE_FAIL\|3600\|600$' -- echo "$sacct_rows"
expect crash-no-start-stale ok '^skynet-20260901T030000Z\|2026-10-02-fixtures\|LAUNCH_FAILED\|0\|1$' -- echo "$sacct_rows"
expect crash-no-start-fresh ok '^skynet-20260901T040000Z\|2026-10-02-fixtures\|PENDING\|0\|1$' -- echo "$sacct_rows"
expect crash-no-start-alive ok '^skynet-20260901T050000Z\|2026-10-02-fixtures\|RUNNING\|[0-9]+\|1$' -- echo "$sacct_rows"
expect crash-half-written ok '^skynet-20260901T060000Z\|2026-10-02-fixtures\|SUPERVISOR_FAILED\|0\|60$' -- echo "$sacct_rows"
expect crash-empty-dir fail - -- grep skynet-20260901T080000Z <<<"$sacct_rows"
expect crash-remote-unended fail - -- grep gpu2-20260901T000000Z <<<"$sacct_rows"
expect crash-remote-ended ok '^gpu2-20260901T010000Z\|2026-10-02-fixtures\|FAILED\|10\|60$' -- echo "$sacct_rows"
expect sacct-before-start-date fail - -- grep skynet-20260801 <<<"$sacct_rows"
expect list-header ok '^job	state	elapsed	limit	mem_gb	mem_limit_gb	gpus	log$' -- bash "$L" --list "$S" "$proj_id"
expect list-incomplete ok '^skynet-20260901T080000Z	incomplete$' -- bash "$L" --list "$S" "$proj_id"
expect list-remote ok '^gpu2-20260901T000000Z	REMOTE	0	3600	-	1	1	' -- bash "$L" --list "$S" "$proj_id" 2026-10-02-fixtures
expect list-running ok '^skynet-20260901T050000Z	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- bash "$L" --list "$S" "$proj_id" 2026-10-02-fixtures
kill "$alive_pid" 2>/dev/null; wait "$alive_pid" 2>/dev/null
sup() {  # sup <id> <time_limit_seconds> <mem_gb> <shm> <gpus> -- <command...>: a request plus a detached supervisor, as launch starts it
  local id=$1; req "$1" 2026-10-02-sup "$5" "$2" "$(date -u +%FT%TZ)" skynet "$3" "$4"; shift 6
  setsid -f bash "$L" --supervise "$tmp/state/$id" -- "$@"
}
wait_end() {  # wait_end <id>...: wait up to 10 s for each end record
  local id i; for id in "$@"; do for ((i = 0; i < 100; i++)); do [ -f "$tmp/state/$id/end" ] && break; sleep 0.1; done; done
}
E=runs/2026-10-02-sup; mkdir -p "$E" "$tmp/shm-m"
sup s-completed 60 1 "" none -- true
sup s-failed 60 1 "" none -- false
sup s-walltime 2 1 "" none -- sleep 30
sup s-mem 60 0.01 "$tmp/shm-m" none -- bash -c 'head -c 20000000 /dev/zero > "$1/blob"; sleep 30' _ "$tmp/shm-m"
sup s-mem-pss 60 0.01 "" none -- bash -c 'x=$(head -c 20000000 /dev/zero | tr "\0" a); sleep 30; echo "${#x}"'
sup s-gentle 1 1 "" none -- bash -c 'trap "echo checkpointed; exit 0" INT; sleep 30 & wait'
sup s-escalates 1 1 "" none -- bash -c 'trap "" INT TERM; sleep 30'
sup s-leftovers 60 1 "" none -- bash -c 'sleep 300 & exit 0'
sup s-escape 60 1 "" none -- bash -c 'setsid sleep 300 & sleep 0.2; exit 0'
sup s-env 60 1 "" 1 -- env
sup s-usr1 60 1 "" none -- sleep 30
sup s-term 60 1 "" none -- bash -c 'trap "echo trapped; exit 0" INT; sleep 30 & wait'
sup s-caller 60 1 "" none -- bash -c 'sleep 2; echo alive'
sleep 1
expect sup-start-written ok '^log_fd: ok$' -- cat "$tmp/state/s-usr1/start"
expect sup-start-sid ok - -- bash -c '[ "$(grep ^job_pid: "$1" | cut -d" " -f2)" = "$(grep ^sid: "$1" | cut -d" " -f2)" ]' _ "$tmp/state/s-usr1/start"
expect sup-list-running ok '^s-usr1	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- bash "$L" --list "$S" "$proj_id" 2026-10-02-sup
kill -USR1 "$(grep ^supervisor_pid: "$tmp/state/s-usr1/start" | cut -d' ' -f2)"
kill -TERM "$(grep ^supervisor_pid: "$tmp/state/s-term/start" | cut -d' ' -f2)"
wait_end s-completed s-failed s-walltime s-mem s-mem-pss s-gentle s-escalates s-leftovers s-escape s-env s-usr1 s-term s-caller
expect sup-completed ok '^stop: none$' -- cat "$tmp/state/s-completed/end"
expect sup-completed-exit ok '^exit: 0$' -- cat "$tmp/state/s-completed/end"
expect sup-failed ok '^exit: 1$' -- cat "$tmp/state/s-failed/end"
expect sup-walltime ok '^stop: walltime$' -- cat "$tmp/state/s-walltime/end"
expect sup-mem ok '^stop: mem$' -- cat "$tmp/state/s-mem/end"
expect sup-mem-pss ok '^stop: mem$' -- cat "$tmp/state/s-mem-pss/end"
expect sup-gentle-log ok '^checkpointed$' -- cat "$tmp/scratch/launch-s-gentle.log"
expect sup-gentle-end ok '^exit: 0$' -- cat "$tmp/state/s-gentle/end"
expect sup-escalates ok '^exit: 137$' -- cat "$tmp/state/s-escalates/end"
expect sup-escalates-log ok ' KILL$' -- cat "$tmp/state/s-escalates/supervisor.log"
expect sup-leftovers ok '^leftover_killed: 1$' -- cat "$tmp/state/s-leftovers/end"
expect sup-leftovers-gone fail - -- grep -lzx HPC_JOB_ID=s-leftovers /proc/[0-9]*/environ
expect sup-escape ok '^leftover_killed: 1$' -- cat "$tmp/state/s-escape/end"
expect sup-env ok '^HPC_JOB_ID=s-env$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-env-cuda ok '^CUDA_VISIBLE_DEVICES=1$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-env-order ok '^CUDA_DEVICE_ORDER=PCI_BUS_ID$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-usr1 ok '^stop: requested$' -- cat "$tmp/state/s-usr1/end"
expect sup-term ok '^stop: signal$' -- cat "$tmp/state/s-term/end"
expect sup-term-trapped ok '^trapped$' -- cat "$tmp/scratch/launch-s-term.log"
expect sup-caller ok '^alive$' -- cat "$tmp/scratch/launch-s-caller.log"
states=$(bash "$L" --sacct "$S" "$proj_id")
expect sup-states-completed ok '^s-completed\|2026-10-02-sup\|COMPLETED\|' -- echo "$states"
expect sup-states-failed ok '^s-failed\|2026-10-02-sup\|FAILED\|' -- echo "$states"
expect sup-states-timeout ok '^s-walltime\|2026-10-02-sup\|TIMEOUT\|[2-9]\|1$' -- echo "$states"
expect sup-states-oom ok '^s-mem\|2026-10-02-sup\|OUT_OF_MEMORY\|' -- echo "$states"
expect sup-states-cancelled ok '^s-usr1\|2026-10-02-sup\|CANCELLED\|' -- echo "$states"
expect sup-states-preempted ok '^s-term\|2026-10-02-sup\|PREEMPTED\|' -- echo "$states"
expect sup-no-leftover-processes fail - -- grep -lzE '^HPC_JOB_ID=s-' /proc/[0-9]*/environ
tick_job() {  # tick_job <id> <mem_gb> <started> <time_limit_seconds> [mem_limit_gb]: a running job with a start record and a beat, polled by --tick
  req "$1" 2026-10-02-tick none "$4" "$(ago '1 hour')" skynet "${5:-1000}"
  local pid; pid=$( env HPC_JOB_ID="$1" setsid sleep 30 >/dev/null 2>&1 & echo $! ); sleep 0.1
  start_rec "$1" "$boot" $$ "$(sed 's/^.*) //' /proc/$$/stat | awk '{print $20}')" "$pid" "$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')" "$3"
  beat_rec "$1" 10 "$2" "$(date -u +%FT%TZ)"
}
tick_job t-big 400.0 "$(ago '1 hour')" 36000; tick_job t-small 200.0 "$(ago '30 min')" 36000
expect tick-no-pressure ok 'reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=104857600 bash "$L" --tick "$tmp/state/t-big"
sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-big/request" "$tmp/state/t-small/request"
expect tick-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-big"
expect tick-small-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-small"
expect tick-small-not-elected ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-small"
expect tick-big-elected ok 'low=2 reason=host-mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-big"
expect tick-big-end ok '^stop: host-mem$' -- cat "$tmp/state/t-big/end"
expect tick-big-elected-detail ok '^elected: largest of 2 live, 400.0 GB$' -- cat "$tmp/state/t-big/end"
expect tick-big-writer ok '^writer: tick$' -- cat "$tmp/state/t-big/end"
expect tick-small-alive fail - -- test -f "$tmp/state/t-small/end"
expect tick-small-state ok '^t-small\|2026-10-02-tick\|RUNNING\|' -- bash "$L" --sacct "$S" "$proj_id"
expect tick-big-state ok '^t-big\|2026-10-02-tick\|HOST_OUT_OF_MEMORY\|' -- bash "$L" --sacct "$S" "$proj_id"
tick_job t-stopping 400.0 "$(ago '1 hour')" 36000; tick_job t-other 200.0 "$(ago '30 min')" 36000
beat_rec t-stopping 10 400.0 "$(date -u +%FT%TZ)" "stopping: host-mem"; sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-other/request"
expect tick-other-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-other"
expect tick-yields-to-stopping ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 bash "$L" --tick "$tmp/state/t-other"
expect tick-stopping-not-elected fail - -- bash -c 'test -e "$1/t-other/end" || test -e "$1/t-stopping/end"' _ "$tmp/state"
expect tick-big-beat-stopping ok '^stopping: host-mem$' -- cat "$tmp/state/t-big/beat"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-stopping/start" | cut -d' ' -f2)" "$(grep ^job_pid: "$tmp/state/t-other/start" | cut -d' ' -f2)" 2>/dev/null
tick_job t-wall 1.0 "$(ago '2 hours')" 3600
expect tick-walltime ok 'reason=walltime$' -- bash "$L" --tick "$tmp/state/t-wall"
expect tick-walltime-end ok '^exit: unknown$' -- cat "$tmp/state/t-wall/end"
expect tick-walltime-measure ok '^charge_measure: rss_anon$' -- cat "$tmp/state/t-wall/end"
tick_job t-pss 0.5 "$(ago '1 hour')" 36000 1
expect tick-mem-not-confirmed ok 'charge=2.0G .*reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=524288 bash "$L" --tick "$tmp/state/t-pss"
expect tick-mem-confirmed ok 'charge=1.5G .*reason=mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=1572864 bash "$L" --tick "$tmp/state/t-pss"
expect tick-mem-confirmed-measure ok '^charge_measure: pss$' -- cat "$tmp/state/t-pss/end"
expect tick-mem-confirmed-peak ok '^peak_mem_gb: 2.0$' -- cat "$tmp/state/t-pss/end"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-small/start" | cut -d' ' -f2)" 2>/dev/null

# --stop: a supervised job stops gently; one whose supervisor died is stopped by --stop itself.
sup s-stop 60 1 "" none -- sleep 30
sup s-crash 60 1 "" none -- sleep 30
for _ in $(seq 50); do [ -f "$S/s-stop/start" ] && [ -f "$S/s-crash/start" ] && break; sleep 0.1; done
expect launch-stop ok '^RUNNING CANCELLED$' -- bash "$L" --stop "$S" "$proj_id" s-stop --reason=done
expect launch-stop-end ok '^stop: requested$' -- cat "$S/s-stop/end"
expect launch-stop-reason ok '^reason: done$' -- cat "$S/s-stop/end"
expect launch-stop-writer ok '^writer: supervisor$' -- cat "$S/s-stop/end"
expect launch-stop-again ok '^CANCELLED CANCELLED$' -- bash "$L" --stop "$S" "$proj_id" s-stop
kill -9 "$(grep ^supervisor_pid: "$S/s-crash/start" | cut -d' ' -f2)"
expect crash-supervisor-killed-list ok '^s-crash	RUNNING	' -- bash "$L" --list "$S" "$proj_id" 2026-10-02-sup
expect crash-stop-unsupervised ok '^RUNNING CANCELLED$' -- bash "$L" --stop "$S" "$proj_id" s-crash
expect crash-stop-unsupervised-end ok '^exit: unknown$' -- cat "$S/s-crash/end"
expect crash-stop-unsupervised-writer ok '^writer: stop$' -- cat "$S/s-crash/end"
req foreign-1 other none 60 "$(date -u +%FT%TZ)"; sed -i 's/^project: .*/project: 0000000000000000000000000000000000000000/' "$S/foreign-1/request"
expect launch-stop-foreign fail 'launch.sh: foreign-1 belongs to another project' -- bash "$L" --stop "$S" "$proj_id" foreign-1
expect launch-stop-unknown fail 'launch.sh: no launch nope-1 in' -- bash "$L" --stop "$S" "$proj_id" nope-1
expect launch-relative-state fail 'must be an absolute path' -- bash "$L" --list state "$proj_id"

# --view: this host's memory, live launches and their GPUs, nvidia-smi's GPUs, GPU-seconds and strays.
rm -rf "${S:?}"
req v-live 2026-10-02-view 1,2 3600 "$(ago '5 min')" skynet 4
touch "$tmp/scratch/launch-v-live.log"; env HPC_JOB_ID=v-live sleep 60 & view_pid=$!
beat_rec v-live 300 1.0 "$(date -u +%FT%TZ)"
req v-done 2026-10-02-view 0,1 3600 "$(ago '2 hours')"; end_rec v-done 1800 0 none
req v-old 2026-10-02-view 3 3600 "2026-08-01T00:00:00Z"; end_rec v-old 3600 0 none
req v-remote 2026-10-02-view 0 3600 "$(ago '5 min')" gpu2
vw() { bash "$L" --view "$S" "$proj_id" 2026-09-01T00:00:00Z 1000 "${1:-none}"; }
view=$(vw)
expect view-host ok '^host	skynet$' -- echo "$view"
expect view-memory ok '^mem_available_kb	[0-9]+$' -- echo "$view"
expect view-reserved ok '^reserved_kb	3145728$' -- echo "$view"
expect view-live ok '^live	v-live$' -- echo "$view"
expect view-held-gpus ok '^held_gpus	1 2$' -- echo "$view"
expect view-nvidia-smi ok '^nvidia_smi	ok$' -- echo "$view"
expect view-gpus ok '^gpus	0 1 2 3$' -- echo "$view"
expect view-busy-none ok '^busy_gpus	$' -- echo "$view"
expect view-gpu-seconds ok '^gpu_seconds	4[12][0-9]{2} [0-9]+$' -- echo "$view"
expect view-strays-none ok '^strays	$' -- echo "$view"
expect view-keys-once ok '^10$' -- bash -c 'cut -f1 <<<"$1" | sort -u | wc -l' _ "$view"
expect view-no-nvidia-smi ok '^nvidia_smi	missing$' -- env PATH="$(path_without nvidia-smi)" bash "$L" --view "$S" "$proj_id" - 1000 none
expect view-test-memory ok '^mem_available_kb	1234$' -- env HPC_LAUNCH_TEST_AVAILABLE_KB=1234 bash "$L" --view "$S" "$proj_id" - 1000 none
sleep 60 & stray_pid=$!
printf 'GPU-aaaa, %s\nGPU-cccc, %s\n' "$stray_pid" "$view_pid" > "$tmp/apps"
expect view-busy ok '^busy_gpus	0 2$' -- env MOCK_NVSMI_APPS="$tmp/apps" bash -c 'bash "$1" --view "$2" "$3" - 1000 none' _ "$L" "$S" "$proj_id"
expect view-strays-gpu ok "^strays	pid$stray_pid:0\.[0-9]+G:gpu:sleep_60\$" -- env MOCK_NVSMI_APPS="$tmp/apps" bash -c 'bash "$1" --view "$2" "$3" - 1000 none' _ "$L" "$S" "$proj_id"
expect view-strays-ignore ok '^strays	$' -- env MOCK_NVSMI_APPS="$tmp/apps" bash -c 'bash "$1" --view "$2" "$3" - 1000 "^sleep 60$"' _ "$L" "$S" "$proj_id"
kill "$stray_pid" "$view_pid" 2>/dev/null; wait "$stray_pid" "$view_pid" 2>/dev/null

# A boxed job's gentle stop reaches the job inside, not the box's outer bwrap, so a checkpoint handler exits 0.
if ! bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  skip launch-boxed-gentle "bwrap cannot make a user namespace on this host"
else
  req b-gentle 2026-10-02-box none 1 "$(date -u +%FT%TZ)"; echo "boxed: yes" >> "$S/b-gentle/request"
  setsid -f bash "$L" --supervise "$S/b-gentle" -- bash "$here/lib/box.sh" --no-tty --bind "$tmp/scratch" "$tmp/scratch" \
    --env HPC_JOB_ID=b-gentle -- bash -c 'trap "echo checkpointed; exit 0" INT; sleep 30 & wait'
  for _ in $(seq 100); do [ -f "$S/b-gentle/end" ] && break; sleep 0.1; done
  expect launch-boxed-gentle ok '^exit: 0$' -- cat "$S/b-gentle/end"
  expect launch-boxed-gentle-stop ok '^stop: walltime$' -- cat "$S/b-gentle/end"
  expect launch-boxed-gentle-log ok '^checkpointed$' -- cat "$tmp/scratch/launch-b-gentle.log"
fi
expect launch-no-job-left fail - -- grep -lzE '^HPC_JOB_ID=(s-|t-|v-|b-|skynet-)' /proc/[0-9]*/environ
rm -rf "${S:?}" "${tmp:?}/scratch"
