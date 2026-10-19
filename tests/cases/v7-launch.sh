# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== launch"
expect ripples-not-opted-in fail - -- bash -c 'guard/run ripples "$1" | grep -q "gpu-hours"' _ "$R"
git switch -q -c launch-base origin/main
cat >> guard/budget.card <<CARD
launch_hosts: skynet
max_gpu_hours: 10
host_max_walltime_minutes: 720
host_max_mem_gb: 1000
host_min_available_gb: 0
host_stop_grace_seconds: 1
host_state_dir: $tmp/state
explore_max_gpus: 1
CARD
git commit -q -am "chore(guard): opt skynet in"; git push -q origin launch-base; git fetch -q origin
git switch -q -c launch/agent origin/launch-base
export HPC_GUARD_REF=origin/launch-base
proj_id=$(git rev-list --max-parents=0 origin/main | tail -n1)
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
guard_commit: $(git rev-parse origin/launch-base)
card: none
cwd: $tmp/scratch
cwd_commit: none
cwd_dirty: none
log: $tmp/scratch/launch-$1.log
gpus: $3
time_limit_seconds: $4
mem_limit_gb: ${7:-1}
shm: ${8:-}
stop_grace_seconds: 1
host_min_available_gb: 0
command: sleep 30
requested: $5
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
expect launch-usage fail 'usage: guard/run launch' -- guard/run launch
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
sacct_rows=$(guard/run launch --sacct)
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
expect list-header ok '^job	state	elapsed	limit	mem_gb	mem_limit_gb	gpus	log$' -- guard/run launch --list
expect list-incomplete ok '^skynet-20260901T080000Z	incomplete$' -- guard/run launch --list
expect list-remote ok '^gpu2-20260901T000000Z	REMOTE	0	3600	-	1	1	' -- guard/run launch --list "$F"
expect list-running ok '^skynet-20260901T050000Z	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- guard/run launch --list "$F"
rip=$(env PATH="$(path_without sacct)" guard/run ripples "$F")
expect ripples-launch-states ok 'RIPPLE	job-states	skynet-20260901T060000Z:SUPERVISOR_FAILED skynet-20260901T030000Z:LAUNCH_FAILED skynet-20260901T020000Z:NODE_FAIL skynet-20260901T010000Z:OUT_OF_MEMORY gpu2-20260901T010000Z:FAILED' -- echo "$rip"
expect ripples-launch-walltime ok 'RIPPLE	walltime-headroom	skynet-20260901T070000Z:91%' -- echo "$rip"
expect ripples-launch-retries ok 'RIPPLE	retries	5 not completed' -- echo "$rip"
expect ripples-launch-budget-unchanged ok '^UNCHECKED	budget	sacct not found on PATH on this host; run ripples on the cluster login node to check$' -- echo "$rip"
expect ripples-gpu-hours ok 'RIPPLE	gpu-hours	22\.1 of 10 GPU-h \(0\.0 in 1 running\)' -- echo "$rip"
expect ripples-supervision-alive ok '^RIPPLE	host-supervision	skynet-20260901T050000Z:no-supervisor-started-it \(stop each with guard/run launch --stop <id> --reason=<why>, or tell the human\)$' -- echo "$rip"
expect ripples-host-memory-pass ok 'PASS	host-memory	[0-9.]+G available; 1 live, at most 80% of --mem' -- echo "$rip"
expect ripples-strays-pass ok 'PASS	host-strays	$' -- echo "$rip"
expect ripples-log-errors-pass ok 'PASS	host-log-errors	1 running log\(s\) scanned' -- echo "$rip"
printf '100|2026-10-02-fixtures|TIMEOUT|14400|240\n' > "$tmp/rows"
expect ripples-launch-plus-sacct fail 'RIPPLE	job-states	100:TIMEOUT skynet-20260901T060000Z:SUPERVISOR_FAILED' -- env MOCK_SACCT_ROWS=$tmp/rows guard/run ripples "$F"
expect ripples-launch-plus-budget fail 'PASS	budget	30 of 10000 core-h' -- env MOCK_SACCT_ROWS=$tmp/rows guard/run ripples "$F"
expect ripples-other-host fail 'UNCHECKED	host-strays	login1 is not in launch_hosts \(skynet\); run ripples on a launch host to check$' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
expect ripples-other-host-gpu-hours fail 'RIPPLE	gpu-hours	22\.1 of 10' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
expect ripples-other-host-no-rows fail 'UNCHECKED	job-states	sacct not found' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
kill "$alive_pid" 2>/dev/null; wait "$alive_pid" 2>/dev/null
rip=$(env PATH="$(path_without sacct)" guard/run ripples "$F")
expect ripples-alive-gone ok 'skynet-20260901T050000Z:LAUNCH_FAILED' -- echo "$rip"
expect ripples-remote-unended ok 'UNCHECKED	host-supervision	1 launch\(es\) unended on gpu2; run ripples there' -- echo "$rip"
mkdir -p "$F/incidents"; printf '# Incident 1\njob: skynet-20260901T010000Z\n' > "$F/incidents/1.md"; printf '# Incident 2\njob: ../x\n' > "$F/incidents/2.md"
git add -A; git commit -q -m "run: incidents"
expect ripples-incident-alnum fail 'HANDLED	job-states	skynet-20260901T010000Z:OUT_OF_MEMORY->incidents/1.md' -- merged env PATH="$(path_without sacct)" guard/run ripples "$F"
git reset -q --hard HEAD~1
sleep 60 & stray_pid=$!
printf 'GPU-aaaa, %s\n' "$stray_pid" > "$tmp/apps"
expect ripples-strays-gpu fail "RIPPLE	host-strays	pid$stray_pid:0\.[0-9]+G:gpu:sleep_60" -- env MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
expect ripples-strays-no-nvsmi fail 'UNCHECKED	host-strays	no memory strays; GPU strays unchecked, nvidia-smi not found or timed out; put nvidia-smi on PATH and rerun$' -- env PATH="$(path_without nvidia-smi)" guard/run ripples "$F"
git switch -q -c launch-ignore origin/launch-base; echo 'stray_ignore: ^sleep 60$' >> guard/budget.card; git commit -q -am "ignore"
expect ripples-strays-ignore fail 'PASS	host-strays	$' -- env HPC_GUARD_REF=HEAD MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
git switch -q launch/agent
req skynet-20260901T090000Z 2026-10-02-fixtures none 60 "$(ago '5 min')"
touch "$tmp/scratch/launch-skynet-20260901T090000Z.log"; env HPC_JOB_ID=skynet-20260901T090000Z sleep 60 & launch_pid=$!
printf 'GPU-aaaa, %s\n' "$launch_pid" > "$tmp/apps"
expect ripples-strays-live-launch fail 'PASS	host-strays	$' -- env MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
kill "$stray_pid" "$launch_pid" 2>/dev/null; wait "$stray_pid" "$launch_pid" 2>/dev/null

sup() {  # sup <id> <time_limit_seconds> <mem_gb> <shm> <gpus> -- <command...>: a request plus a detached supervisor, as launch starts it
  local id=$1; req "$1" 2026-10-02-sup "$5" "$2" "$(date -u +%FT%TZ)" skynet "$3" "$4"; shift 6
  setsid -f guard/run launch --supervise "$tmp/state/$id" -- "$@"
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
expect sup-list-running ok '^s-usr1	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- guard/run launch --list "$E"
expect sup-supervision-pass ok 'PASS	host-supervision	[0-9]+ live, supervised' -- bash -c 'guard/run ripples "$1" | grep host-supervision' _ "$E"
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
states=$(guard/run launch --sacct)
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
expect tick-no-pressure ok 'reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=104857600 guard/run launch --tick "$tmp/state/t-big"
sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-big/request" "$tmp/state/t-small/request"
expect tick-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-big"
expect tick-small-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-small"
expect tick-small-not-elected ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-small"
expect tick-big-elected ok 'low=2 reason=host-mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-big"
expect tick-big-end ok '^stop: host-mem$' -- cat "$tmp/state/t-big/end"
expect tick-big-elected-detail ok '^elected: largest of 2 live, 400.0 GB$' -- cat "$tmp/state/t-big/end"
expect tick-big-writer ok '^writer: tick$' -- cat "$tmp/state/t-big/end"
expect tick-small-alive fail - -- test -f "$tmp/state/t-small/end"
expect tick-small-state ok '^t-small\|2026-10-02-tick\|RUNNING\|' -- guard/run launch --sacct
expect tick-big-state ok '^t-big\|2026-10-02-tick\|HOST_OUT_OF_MEMORY\|' -- guard/run launch --sacct
tick_job t-stopping 400.0 "$(ago '1 hour')" 36000; tick_job t-other 200.0 "$(ago '30 min')" 36000
beat_rec t-stopping 10 400.0 "$(date -u +%FT%TZ)" "stopping: host-mem"; sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-other/request"
expect tick-other-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-other"
expect tick-yields-to-stopping ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-other"
expect tick-stopping-not-elected fail - -- bash -c 'test -e "$1/t-other/end" || test -e "$1/t-stopping/end"' _ "$tmp/state"
expect tick-big-beat-stopping ok '^stopping: host-mem$' -- cat "$tmp/state/t-big/beat"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-stopping/start" | cut -d' ' -f2)" "$(grep ^job_pid: "$tmp/state/t-other/start" | cut -d' ' -f2)" 2>/dev/null
tick_job t-wall 1.0 "$(ago '2 hours')" 3600
expect tick-walltime ok 'reason=walltime$' -- guard/run launch --tick "$tmp/state/t-wall"
expect tick-walltime-end ok '^exit: unknown$' -- cat "$tmp/state/t-wall/end"
expect tick-walltime-measure ok '^charge_measure: rss_anon$' -- cat "$tmp/state/t-wall/end"
tick_job t-pss 0.5 "$(ago '1 hour')" 36000 1
expect tick-mem-not-confirmed ok 'charge=2.0G .*reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=524288 guard/run launch --tick "$tmp/state/t-pss"
expect tick-mem-confirmed ok 'charge=1.5G .*reason=mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=1572864 guard/run launch --tick "$tmp/state/t-pss"
expect tick-mem-confirmed-measure ok '^charge_measure: pss$' -- cat "$tmp/state/t-pss/end"
expect tick-mem-confirmed-peak ok '^peak_mem_gb: 2.0$' -- cat "$tmp/state/t-pss/end"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-small/start" | cut -d' ' -f2)" 2>/dev/null

rm -rf "$tmp/state"
R2=runs/2026-10-02-launch; mkdir -p "$R2"; cp runs/_template/question.card "$R2/"; git add -A; git commit -q -m "run: launch card"
L() { env HPC_SPEND_RESERVE=1 guard/run launch "$@"; }
expect launch-off-by-default fail '^LAUNCH FAIL: skynet is not in launch_hosts \(none\)' -- env HPC_GUARD_REF=origin/main HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=none --mem=0.01 -- true
expect launch-other-host fail 'login1 is not in launch_hosts' -- env MOCK_HOSTNAME=login1 HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=none --mem=0.01 -- true
expect launch-usage-no-command fail 'usage: guard/run launch' -- L "$R2" --time=1 --gpus=none --mem=0.01
expect launch-needs-time fail 'state --time' -- L "$R2" --gpus=none --mem=0.01 -- true
expect launch-needs-gpus fail 'state --gpus' -- L "$R2" --time=1 --mem=0.01 -- true
expect launch-needs-mem fail 'state --mem' -- L "$R2" --time=1 --gpus=none -- true
expect launch-bad-time fail 'is not a Slurm time' -- L "$R2" --time=abc --gpus=none --mem=0.01 -- true
expect launch-shm-relative fail 'absolute' -- L "$R2" --time=1 --gpus=none --mem=0.01 --shm=shm -- true
expect launch-cwd-missing fail 'not a writable directory' -- L "$R2" --time=1 --gpus=none --mem=0.01 --cwd="$tmp/nope" -- true
expect launch-no-card fail 'runs/2026-10-02-nocard/question.card is not committed' -- L runs/2026-10-02-nocard --time=1 --gpus=none --mem=0.01 -- true
echo "metric: changed" >> "$R2/question.card"; git commit -q -am "edit card"
expect launch-card-frozen fail 'edited after its first commit' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
git switch -q --detach HEAD; sed -i '/^checks: /d' guard/budget.card; git commit -q -am "no project waiver"
expect launch-no-checks fail "^LAUNCH FAIL: no executable domain check in $R2/checks/ on HEAD; commit them there with the question card" -- env HPC_GUARD_REF=HEAD HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -
git switch -q --detach HEAD; echo "card_on_main: yes" >> guard/budget.card; git commit -q -am "cards on main"; git branch -q -f launch-card-base HEAD
R11=runs/2026-10-14-unread-launch; mkdir -p "$R11"; cp runs/_template/question.card "$R11/"; git add -A; git commit -q -m "run: a card nobody read"
expect launch-card-not-on-main fail "^LAUNCH FAIL: card_on_main is yes in guard/budget.card, and $R11/question.card is not on launch-card-base as committed here" -- \
  env HPC_GUARD_REF=launch-card-base HPC_SPEND_RESERVE=1 guard/run launch "$R11" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -; git branch -q -D launch-card-base
sed -i 's/^max_gpu_hours: .*/max_gpu_hours: 999/' guard/budget.card; git commit -q -am "raise"
expect launch-guard-touched fail 'guard/ differs' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
same_refusal() {  # same_refusal <name> <preflight args...> -- <launch args...>: the text after the two prefixes is identical
  local name=$1 p l; shift; local pre=(); while [ "$1" != -- ]; do pre+=("$1"); shift; done; shift
  p=$(guard/run preflight "${pre[@]}" 2>&1); l=$(L "$@" 2>&1)
  expect "$name" ok - -- test "${p#PREFLIGHT FAIL: }" = "${l#LAUNCH FAIL: }"
}
same_refusal launch-gates-match-guard "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
same_refusal launch-gates-match-no-card runs/2026-10-02-nocard job.sh -- runs/2026-10-02-nocard --time=1 --gpus=none --mem=0.01 -- true
echo "metric: changed" >> "$R2/question.card"; git commit -q -am "edit card"
same_refusal launch-gates-match-frozen "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
git switch -q -c launch-past; sed -i 's/^stop_date: .*/stop_date: 2000-01-01/' guard/budget.card; git commit -q -am "past"
export HPC_GUARD_REF=HEAD
expect launch-past-stop fail '^LAUNCH FAIL: past stop_date 2000-01-01; a human extends stop_date in guard/budget.card on the protected branch$' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
same_refusal launch-gates-match-stop-date "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -c launch-floor launch/agent; sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 999999/' guard/budget.card; git commit -q -am "floor"
expect launch-host-memory fail 'MemAvailable .* leaves less than --mem=0.01G plus host_min_available_gb=999999' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
export HPC_GUARD_REF=origin/launch-base; git switch -q launch/agent
expect launch-walltime-cap fail 'exceeds host_max_walltime_minutes=720' -- L "$R2" --time=13:00:00 --gpus=none --mem=0.01 -- true
expect launch-explore-gpus fail 'exceeds explore_max_gpus=1' -- L runs/explore-l --time=1 --gpus=0,1 --mem=0.01 -- true
expect launch-explore-time fail 'exceeds explore_max_walltime_minutes=60' -- L runs/explore-l --time=02:00:00 --gpus=none --mem=0.01 -- true
expect launch-mem-cap fail 'exceeds host_max_mem_gb=1000' -- L "$R2" --time=1 --gpus=none --mem=1001 -- true
expect launch-gpu-unknown fail 'no GPU 7 on skynet' -- L "$R2" --time=1 --gpus=7 --mem=0.01 -- true
printf 'GPU-aaaa, 999\n' > "$tmp/apps"
expect launch-gpu-busy fail 'GPU 0 is busy \(pid 999\)' -- env MOCK_NVSMI_APPS=$tmp/apps HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=0 --mem=0.01 -- true
expect launch-gpu-budget fail 'this job 12.0 GPU-h exceeds 10 GPU-h' -- L "$R2" --time=06:00:00 --gpus=0,1 --mem=0.01 -- true
expect launch-no-nvidia-smi fail 'nvidia-smi not found' -- env PATH="$(path_without nvidia-smi)" HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=0 --mem=0.01 -- true
expect launch-cpu-without-nvidia-smi ok '^skynet-' -- env PATH="$(path_without nvidia-smi)" HPC_SPEND_RESERVE=1 guard/run launch runs/explore-cpu --time=1 --gpus=none --mem=0.01 -- true
expect launch-no-user ok '^skynet-' -- env -u USER HPC_SPEND_RESERVE=1 guard/run launch runs/explore-cpu --time=1 --gpus=none --mem=0.01 -- true
held=$(L runs/explore-held --time=1 --gpus=1 --mem=0.01 -- sleep 30 2>/dev/null)
expect launch-gpu-held fail "GPU 1 is held by $held" -- L "$R2" --time=1 --gpus=1 --mem=0.01 -- true
L runs/explore-race --time=1 --gpus=3 --mem=0.01 -- sleep 1 >"$tmp/race1" 2>&1 &
L runs/explore-race --time=1 --gpus=3 --mem=0.01 -- sleep 1 >"$tmp/race2" 2>&1 &
wait
expect launch-gpu-race ok '^1$' -- bash -c 'grep -c "^LAUNCH OK" "$1" "$2" | awk -F: "{s+=\$2} END{print s}"' _ "$tmp/race1" "$tmp/race2"
expect launch-gpu-race-loser ok 'GPU 3 is held by skynet-' -- cat "$tmp/race1" "$tmp/race2"
id=$(L "$R2" --time=1 --gpus=2 --mem=0.01 -- env 2>"$tmp/launch.err")
expect launch-prints-id ok '^skynet-[0-9]{8}T[0-9]{6}Z$' -- echo "$id"
expect launch-ok-line ok '^LAUNCH OK: 2026-10-02-launch job=skynet-.* gpus=2 time=1m mem=0.01G gpu_h_spent=0.0 available=[0-9.]+ log=' -- cat "$tmp/launch.err"
expect launch-manifest ok "^job_id: $id$" -- cat "$R2/manifest-$id.txt"
expect launch-manifest-cuda ok '^cuda_visible_devices: unset$' -- cat "$R2/manifest-$id.txt"
expect launch-request-cwd-commit ok "^cwd_commit: $(git rev-parse HEAD)$" -- cat "$tmp/state/$id/request"
expect launch-request-card ok "^card: $(git rev-parse "HEAD:$R2/question.card")$" -- cat "$tmp/state/$id/request"
expect launch-request-run-dir ok "^run_dir: $PWD/$R2$" -- cat "$tmp/state/$id/request"
absid=$(L "$PWD/runs/explore-abs" --time=1 --gpus=none --mem=0.01 -- true 2>/dev/null)
expect launch-request-run-dir-absolute ok "^run_dir: $PWD/runs/explore-abs$" -- cat "$tmp/state/$absid/request"
idem=$(L runs/explore-idem --time=1 --gpus=none --mem=0.01 -- bash -c 'guard/run manifest "$HPC_RUN_DIR" x' 2>/dev/null)
cwdid=$(L runs/explore-cwd --time=1 --gpus=none --mem=0.01 --cwd="$tmp/scratch" -- pwd 2>/dev/null)
caller=$(setsid bash -c 'env HPC_SPEND_RESERVE=1 guard/run launch runs/explore-caller --time=1 --gpus=none --mem=0.01 -- bash -c "sleep 1; echo alive" 2>/dev/null; kill -HUP 0')
local=$(env HPC_GUARD_LOCAL=1 HPC_SPEND_RESERVE=1 guard/run launch runs/explore-local --time=1 --gpus=none --mem=0.01 -- true 2>/dev/null)
expect launch-local-copy ok '^skynet-' -- echo "$local"
secs=$(L runs/explore-secs --time=0:15 --gpus=none --mem=0.01 -- true 2>"$tmp/secs.err")
expect launch-ok-seconds ok ' time=15s ' -- cat "$tmp/secs.err"
failed=$(L runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- false 2>/dev/null)
wait_end "$id" "$idem" "$cwdid" "$caller" "$local" "$failed" "$absid" "$secs"
expect launch-env ok "^HPC_JOB_ID=$id$" -- cat "launch-$id.log"
expect launch-env-cuda ok '^CUDA_VISIBLE_DEVICES=2$' -- cat "launch-$id.log"
expect launch-env-run-dir ok "^HPC_RUN_DIR=$PWD/$R2$" -- cat "launch-$id.log"
expect launch-manifest-idempotent ok 'manifest exists' -- cat "launch-$idem.log"
expect launch-cwd-log ok "^$tmp/scratch$" -- cat "$tmp/scratch/launch-$cwdid.log"
expect launch-survives-caller ok '^alive$' -- cat "launch-$caller.log"
expect launch-completed ok "^$local	COMPLETED	" -- guard/run launch --list runs/explore-local
expect launch-ripples-gate fail "ripples reports job-states: $failed:FAILED" -- guard/run launch runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- true
expect launch-ripples-reserve ok '^skynet-' -- L runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- true
expect launch-stop ok '^CANCELLED$' -- guard/run launch --stop "$held" --reason=done
expect launch-stop-end ok '^stop: requested$' -- cat "$tmp/state/$held/end"
expect launch-stop-reason ok '^reason: done$' -- cat "$tmp/state/$held/end"
expect launch-stop-writer ok '^writer: supervisor$' -- cat "$tmp/state/$held/end"
expect launch-stop-again ok '^already ended: CANCELLED$' -- guard/run launch --stop "$held"
req foreign-1 other none 60 "$(date -u +%FT%TZ)"; sed -i 's/^project: .*/project: 0000000000000000000000000000000000000000/' "$tmp/state/foreign-1/request"
expect launch-stop-foreign fail 'belongs to another project' -- guard/run launch --stop foreign-1
expect launch-stop-unknown fail 'no launch nope-1' -- guard/run launch --stop nope-1
crash=$(L runs/explore-crash --time=1 --gpus=none --mem=0.01 -- sleep 30 2>/dev/null)
kill -9 "$(grep ^supervisor_pid: "$tmp/state/$crash/start" | cut -d' ' -f2)"
expect crash-supervisor-killed fail "RIPPLE	host-supervision	$crash:pid[0-9]+-has-no-supervisor" -- guard/run ripples runs/explore-crash
expect crash-supervisor-killed-list ok "^$crash	RUNNING	" -- guard/run launch --list runs/explore-crash
expect crash-stop-unsupervised ok '^CANCELLED$' -- guard/run launch --stop "$crash"
expect crash-stop-unsupervised-end ok '^exit: unknown$' -- cat "$tmp/state/$crash/end"
expect crash-stop-unsupervised-writer ok '^writer: stop$' -- cat "$tmp/state/$crash/end"
expect crash-stop-supervision-pass ok 'PASS	host-supervision	0 live, supervised' -- bash -c 'guard/run ripples runs/explore-crash | grep host-supervision'
wait_end "$(cat "$tmp/race1" "$tmp/race2" | grep -o 'job=skynet-[0-9TZ]*' | cut -d= -f2)"
expect launch-no-job-left fail - -- grep -lzE '^HPC_JOB_ID=skynet-' /proc/[0-9]*/environ
X=runs/2026-10-02-ledger; mkdir -p "$X"; cp runs/_template/question.card "$X/"
req x-1-done 2026-10-02-ledger 1 3600 "$(ago '2 hours')" skynet 100; end_rec x-1-done 1800 0 none
req x-2-oom 2026-10-02-ledger 1 3600 "$(ago '1 hour')" skynet 100; end_rec x-2-oom 1200 130 mem
git add -A; git commit -q -m "run: ledger card"
expect ripples-no-ledger-no-line fail - -- bash -c 'guard/run ripples "$1" | grep -q execution-within-envelope' _ "$X"
expect launch-after-resource-stop fail 'x-2-oom ended OUT_OF_MEMORY; commit an execution.tsv row \(restart or resume\) citing it, then launch again' -- L "$X" --time=1 --gpus=none --mem=0.01 -- true
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\t2026-10-02T12:00:00Z\thost\tskynet\tthe A100 box\tnone\nx2\t2026-10-02T12:01:00Z\tmem_stop_gb\t300\tshm staging\tnone\nx3\t2026-10-02T12:02:00Z\trestart\tx-2-oom\tOOM at epoch 3\tlaunch-x-2-oom.log\nx4\t2026-10-02T12:03:00Z\tresume\t%s/scratch/ckpt/epoch3.pt\tcheckpoint\tnone\n' "$tmp" > "$X/execution.tsv"
expect ripples-ledger-uncommitted fail - -- bash -c 'guard/run ripples "$1" | grep -q execution-within-envelope' _ "$X"
git add -A; git commit -q -m "run: ledger"
rip=$(guard/run ripples "$X")
expect ripples-envelope-pass ok 'PASS	execution-within-envelope	4 rows: host x1, mem_stop_gb x2, restart x3, resume x4' -- echo "$rip"
expect ripples-restart-handles ok 'HANDLED	job-states	x-2-oom:OUT_OF_MEMORY->execution.tsv:x3' -- echo "$rip"
expect ripples-restart-counts ok 'PASS	handled-failures	1 of 2' -- echo "$rip"
expect ripples-envelope-without-launch fail 'RIPPLE	execution-within-envelope	x1: host skynet is not in launch_hosts \(none\)' -- env HPC_GUARD_REF=origin/main guard/run ripples "$X"
expect launch-after-restart-row ok '^skynet-' -- guard/run launch "$X" --time=1 --gpus=none --mem=0.01 -- true
X2=runs/2026-10-02-badledger; mkdir -p "$X2"; cp runs/_template/question.card "$X2/"
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\tsetting\tfloat32\tw\te\nx3\tt\thost\tlogin1\tw\te\nx3\tt\tmem_stop_gb\t2000\tw\te\nx4\tt\trestart\tx-1-done\tw\te\nx5\tt\tresume\t/nowhere/ckpt\tw\te\n' > "$X2/execution.tsv"
git add -A; git commit -q -m "run: bad ledger"
rip=$(guard/run ripples "$X2")
expect ripples-envelope-design fail 'RIPPLE	execution-within-envelope	x1: setting is design; a change to it needs a new card' -- guard/run ripples "$X2"
expect ripples-envelope-order ok 'x3: ids run x1, x2, \.\.\. in order; this is row 2' -- echo "$rip"
expect ripples-envelope-host ok 'x3: host login1 is not in launch_hosts \(skynet\)' -- echo "$rip"
expect ripples-envelope-mem ok 'x3: mem_stop_gb 2000 is over host_max_mem_gb=1000' -- echo "$rip"
expect ripples-envelope-restart ok 'x4: restart x-1-done is not a resource stop of this run' -- echo "$rip"
expect ripples-envelope-resume ok 'x5: resume /nowhere/ckpt is under no launch cwd of this run' -- echo "$rip"
X5=runs/2026-10-14-outcome; mkdir -p "$X5"; cp runs/_template/question.card "$X5/"
printf 'id\tts\tfield\tvalue\twhy\tevidence\n# a comment\nx1\tt\thost\tskynet\tw\te\nx2\tt\tstage\tdone\tjob finished\te\n' > "$X5/execution.tsv"
git add -A; git commit -q -m "run: an outcome in the ledger"
expect ripples-ledger-outcome fail 'RIPPLE	execution-within-envelope	x2: stage is not a ledger field \(host gpus .* or void <id>\); job outcomes go in report.md, and a void row in a records-only pull request retracts this one; the ledger is append-only' -- guard/run ripples "$X5"
printf 'x3\tt\tvoid\tx2\tan outcome, not an execution fact\tnone\n' >> "$X5/execution.tsv"; git commit -q -am "run: void the outcome"
expect ripples-ledger-voided ok 'PASS	execution-within-envelope	3 rows: host x1, stage x2, void x3' -- guard/run ripples "$X5"
printf 'x5\tt\tvoid\tx3\tw\te\nx6\tt\tvoid\tx4\tw\te\n' >> "$X/execution.tsv"; git commit -q -am "run: void the restart and the resume"
expect ripples-voided-restart-not-handled fail 'RIPPLE	job-states	.*x-2-oom:OUT_OF_MEMORY' -- guard/run ripples "$X"
git reset -q --hard HEAD~1
X3=runs/2026-10-02-science; mkdir -p "$X3"; cp runs/_template/question.card "$X3/"
X4=runs/2026-10-02-capped; mkdir -p "$X4"; sed 's/^budget_gpu_hours: .*/budget_gpu_hours: 1/' runs/_template/question.card > "$X4/question.card"
X5=runs/2026-10-02-late; mkdir -p "$X5"; sed 's/^deadline: .*/deadline: 2000-01-01/' runs/_template/question.card > "$X5/question.card"
git add -A; git commit -q -m "run: science, capped and late cards"
req x-3-fail 2026-10-02-science none 60 "$(ago '1 hour')"; end_rec x-3-fail 10 1 none
expect launch-after-science-stop fail 'x-3-fail ended FAILED, a science stop; the human decides whether this run continues' -- L "$X3" --time=1 --gpus=none --mem=0.01 -- true
req x-3-stopped 2026-10-02-science none 60 "$(ago '30 min')"; end_rec x-3-stopped 10 unknown requested
expect launch-after-cancelled-is-resource fail 'x-3-stopped ended CANCELLED; commit an execution.tsv row \(restart or resume\) citing it' -- L "$X3" --time=1 --gpus=none --mem=0.01 -- true
printf '2026-10-02-science|CANCELLED by 1000\n' > "$tmp/staterow"
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\trestart\tx-3-stopped\tw\te\nx2\tt\trestart\t12345\tw\te\n' > "$X3/execution.tsv"; git add -A; git commit -q -m "run: science ledger"
expect ripples-restart-cancelled-rows fail 'PASS	execution-within-envelope	2 rows: restart x1, restart x2' -- env MOCK_SACCT_STATE=$tmp/staterow guard/run ripples "$X3"
req x-4-spent 2026-10-02-capped 1 3600 "$(ago '2 hours')" skynet 100; end_rec x-4-spent 1800 0 none
expect launch-run-gpu-budget fail 'this run spent 0.5 \+ running 0.0 \+ this job 1.0 GPU-h exceeds budget_gpu_hours=1' -- L "$X4" --time=1:00:00 --gpus=0 --mem=0.01 -- true
capped=$(L "$X4" --time=0:30:00 --gpus=0 --mem=0.01 -- true 2>/dev/null)
expect launch-run-gpu-budget-fits ok '^skynet-' -- echo "$capped"
req x-5-more 2026-10-02-capped 1 3600 "$(ago '1 hour')" skynet 100; end_rec x-5-more 1900 0 none
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\tgpus\t0\tw\te\n' > "$X4/execution.tsv"; git add -A; git commit -q -m "run: capped ledger"
expect ripples-envelope-spend fail 'execution-within-envelope	.*spent 1.0 GPU-h over budget_gpu_hours=1' -- guard/run ripples "$X4"
expect launch-deadline fail 'past deadline 2000-01-01 in runs/2026-10-02-late/question.card' -- L "$X5" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -c launch-default; echo "default_run_gpu_hours: 1" >> guard/budget.card; git commit -q -am "default run budget"
expect launch-default-run-budget fail 'this job 2.0 GPU-h exceeds budget_gpu_hours=1' -- env HPC_GUARD_REF=HEAD HPC_SPEND_RESERVE=1 guard/run launch "$X" --time=2:00:00 --gpus=0 --mem=0.01 -- true
git switch -q launch/agent
wait_end "$capped"
rm -f launch-*.log; rm -rf runs/explore-*; git checkout -q -- .
rm -rf "$tmp/state"; unset HPC_GUARD_REF
