# shellcheck shell=bash
# Sourced by tests/run.sh from $tmp: the host backend, lib/broker/host.py over lib/guard/launch.sh and lib/box.sh.
echo "== host backend"
hp=$tmp/host-proj hb=$tmp/host-broker hs=$tmp/host-state hh=$tmp/host-home
git init -q --bare -b main "$tmp/host-origin.git"
git clone -q "$tmp/host-origin.git" "$hp" 2>/dev/null
mkdir -p "$hp/guard" "$hp/runs" "$hb" "$hh/.ssh"
echo canary-ssh-key > "$hh/.ssh/id_ed25519"
cat > "$hp/guard/budget.card" <<CARD
account: g
start_date: 2026-01-01
stop_date: 2099-01-01
cores_per_node: 8
max_walltime_minutes: 600
max_nodes_per_job: 2
max_concurrent_jobs: 4
max_core_hours: 1000
max_gpu_hours: 10
launch_hosts: skynet
host_max_walltime_minutes: 600
host_max_mem_gb: 4
host_min_available_gb: 0
host_stop_grace_seconds: 1
host_state_dir: $hs
CARD
printf '#!/bin/bash\necho "GUARD_JOB_ID=$GUARD_JOB_ID"\necho "GH=${GH_TOKEN:-unset}"\necho "HOME=$HOME"\ncat ~/.ssh/id_ed25519 %s/.ssh/id_ed25519 2>&1 | sed "s/^/ssh: /"\necho "args=$*"\nls /dev | grep -c nvidia | sed "s/^/nvidia nodes: /"\n' "$hh" > "$hp/runs/job.sh"
printf '#!/bin/bash\ntrap "echo checkpointed; exit 0" INT\nsleep 120 & wait\n' > "$hp/runs/long.sh"
printf '#!/bin/bash\ntrap "" INT TERM\nsleep 300\n' > "$hp/runs/stubborn.sh"
printf '#!/bin/bash\nsleep 3\necho short done\n' > "$hp/runs/short.sh"
git -C "$hp" add -A; git -C "$hp" commit -q -m init; git -C "$hp" push -q origin HEAD:main 2>/dev/null
project_id=$(git -C "$hp" rev-list --max-parents=0 HEAD)
printf '{"session": "s-host", "project": "%s", "paths": [["%s", "%s"]], "origin": "%s", "slurm_bin": null, "user": "tester"}\n' \
  "$hp" "$hp" "$hp" "$tmp/host-origin.git" > "$hb/config.json"
drive=$tmp/host-drive  # drive launch <run_dir> <why> -- <options> <script> [args] | wait <id> | stop <id> | view | py <code>
cat > "$drive" <<PY
#!/usr/bin/env python3
import json, os, sys, time
sys.path.insert(0, "$here/lib"); import _path
import refusals
from broker import host, scheduler, server
from policy import Request
from policy.invocation import parse, split_command
cfg = json.load(open("$hb/config.json"))
b = scheduler.Broker("$hb", cfg)
verb, rest = sys.argv[1], sys.argv[2:]
if verb == "launch":
    run_dir, why, words = rest[0], rest[1], rest[3:]
    options, script, args = split_command(words)
    req = Request("run", run_dir, why, options=options, script=script, args=args, cwd=os.getcwd())
    inv, spec = parse(req, open(os.path.join(os.getcwd(), script), "rb").read(), cfg["session"], time.time())
    h = host.Host.of(b)
    r = host.check(inv, spec, h.limits, h.view(), run_dir) or h.launch(inv, spec, run_dir)
    if isinstance(r, refusals.Refusal):
        sys.stderr.write(refusals.render(r)); sys.exit(r.exit)
    print(r.job_id, ",".join(r.gpus) or "none", r.log)
elif verb in ("wait", "stop"):
    reply = server.answer(b, "scheduler", {"verb": verb, "id": rest[0], "reason": "test"})
    sys.stderr.write(reply.get("err", ""))
    if verb == "wait" and reply["rc"] == 0:
        w = json.loads(reply["out"])
        sys.stdout.write(w["tail"])
        print("state:", w["state"], "code:", w["code"], "slurm:", w["slurm_state"], "log:", w["log"], "elapsed:", w["elapsed"])
    else:
        sys.stdout.write(reply.get("out", ""))
    sys.exit(reply["rc"])
elif verb == "view":
    v = host.Host.of(b).view()
    for k, x in vars(v).items(): print(f"{k}: {x}")
else:
    exec(rest[0])
PY
chmod +x "$drive"
hd() { (cd "$hp" && env HOME="$hh" GH_TOKEN=gho_planted "$drive" "$@"); }
hpy() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path; exec(sys.argv[2])' "$here" "$1"; }

# The translation table, pure.
expect host-translate-count ok '^\(.0., .2.\) none$' -- hpy '
from policy import SbatchSpec, Limits
from broker.host import translate, HostReport
L = Limits("a", "x", "y", 8, 60, 1, 4, 100, host_max_mem_gb=48)
v = HostReport(name="skynet", in_launch_hosts=True, available_gb=100, gpus_free=("0", "2", "3"))
print(translate(SbatchSpec(time_min=5, gpus=2), L, v).gpus, ",".join(translate(SbatchSpec(time_min=5), L, v).gpus) or "none")'
expect host-translate-mem-default ok '^48.0 7 300$' -- hpy '
from policy import SbatchSpec, Limits
from broker.host import translate, HostReport
L = Limits("a", "x", "y", 8, 60, 1, 4, 100, host_max_mem_gb=48)
t = translate(SbatchSpec(time_min=5), L, HostReport(name="h", in_launch_hosts=True, available_gb=1))
print(float(t.mem_gb), translate(SbatchSpec(time_min=5, mem_gb=7), L, None if False else HostReport(name="h", in_launch_hosts=True, available_gb=1)).mem_gb, t.time_limit_seconds)'
expect host-cpus-cost-only ok '^8 1.0 none$' -- hpy '
from policy import SbatchSpec, Limits
from policy.cost import cost
from broker.host import translate, HostReport
L = Limits("a", "x", "y", 8, 60, 1, 4, 100)
s = SbatchSpec(time_min=7.5 * 0 + 7, cpus_per_task=8)
t = translate(s, L, HostReport(name="h", in_launch_hosts=True, available_gb=1))
c = cost(SbatchSpec(time_min=60, cpus_per_task=8), L, "host")
print(c.cores, c.core_hours / 8, ",".join(t.gpus) or "none")'

# R13 and R14, through the drive's launch: the card's host limits, Slurm-only flags, then this host now.
for flag in --nodes=2 --partition=gpu --array=0-3 --dependency=afterok:1 --ntasks=4; do
  expect_refusal "host-r13-${flag%%=*}" R13 -- hd launch runs/r1 'Run job.sh.' -- --time=5 "$flag" runs/job.sh
done
expect host-r13-line2-drops-flag ok "^guard run runs/r1 --why 'Run job.sh.' -- --time=5 runs/job.sh$" -- bash -c 'hd() { (cd "$1" && "$2" "${@:3}"); }; hd "$1" "$2" launch runs/r1 "Run job.sh." -- --time=5 -p gpu runs/job.sh 2>&1 | tail -1' _ "$hp" "$drive"
expect_refusal host-r13-time R13 -- hd launch runs/r1 'Run job.sh.' -- --time=11:00:00 runs/job.sh
expect host-r13-time-line2 ok '--time=600 runs/job.sh$' -- bash -c '(cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=11:00:00 runs/job.sh 2>&1 | tail -1)' _ "$hp" "$drive"
expect_refusal host-r13-mem R13 -- hd launch runs/r1 'Run job.sh.' -- --time=5 --mem=8G runs/job.sh
expect host-r13-mem-line2 ok '^H4R-R13 mem 8 GB exceeds host_max_mem_gb$' -- bash -c '(cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 --mem=8G runs/job.sh 2>&1 | head -1)' _ "$hp" "$drive"
expect_refusal host-r13-gpu-hours R13 -- hd launch runs/r1 'Run job.sh.' -- --time=360 --gpus=2 runs/job.sh
expect host-r13-gpu-hours-line2 fail '12.0 GPU-h over the remaining 10.0 of max_gpu_hours' -- bash -c '(cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=360 --gpus=2 runs/job.sh 2>&1)' _ "$hp" "$drive"
expect host-r13-gpu-hours-fits ok '--gpus=2 --time=300 runs/job.sh$' -- bash -c '(cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=360 --gpus=2 runs/job.sh 2>&1 | tail -1)' _ "$hp" "$drive"
printf 'GPU-aaaa, 1\nGPU-bbbb, 1\nGPU-cccc, 1\n' > "$tmp/host-apps"
expect_refusal host-r14-gpus R14 -- env MOCK_NVSMI_APPS="$tmp/host-apps" bash -c 'cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 --gpus=2 runs/job.sh' _ "$hp" "$drive"
expect host-r14-gpus-reason ok '^H4R-R14 1 GPUs free, 2 asked$' -- env MOCK_NVSMI_APPS="$tmp/host-apps" bash -c 'cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 --gpus=2 runs/job.sh 2>&1 | head -1' _ "$hp" "$drive"
expect_refusal host-r14-nvidia-smi R14 -- env PATH="$(path_without nvidia-smi)" bash -c 'cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 --gpus=1 runs/job.sh' _ "$hp" "$drive"
expect_refusal host-r14-memory R14 -- env HPC_LAUNCH_TEST_AVAILABLE_KB=1048576 bash -c 'cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 --mem=2G runs/job.sh' _ "$hp" "$drive"
expect_refusal host-r14-bwrap R14 -- env PATH="$(path_without bwrap)" bash -c 'cd "$1" && "$2" launch runs/r1 "Run job.sh." -- --time=5 runs/job.sh' _ "$hp" "$drive"

# view(): this host, its memory, free GPUs, bwrap, strays; another host is not a launch host.
v=$(hd view)
expect host-view-name ok '^name: skynet$' -- echo "$v"
expect host-view-in-launch-hosts ok '^in_launch_hosts: True$' -- echo "$v"
expect host-view-gpus-free ok "^gpus_free: \('0', '1', '2', '3'\)$" -- echo "$v"
expect host-view-nvidia-smi ok '^nvidia_smi: ok$' -- echo "$v"
expect host-view-memory ok '^available_gb: [0-9]+\.[0-9]+$' -- echo "$v"
expect host-view-other-host ok '^in_launch_hosts: False$' -- env MOCK_HOSTNAME=login1 bash -c 'cd "$1" && "$2" view' _ "$hp" "$drive"
sleep 60 & host_stray=$!
printf 'GPU-bbbb, %s\n' "$host_stray" > "$tmp/host-apps"
expect host-view-strays ok "^strays: \('pid$host_stray:" -- env MOCK_NVSMI_APPS="$tmp/host-apps" bash -c 'cd "$1" && "$2" view' _ "$hp" "$drive"
expect host-view-busy-not-free ok "^gpus_free: \('0', '2', '3'\)$" -- env MOCK_NVSMI_APPS="$tmp/host-apps" bash -c 'cd "$1" && "$2" view' _ "$hp" "$drive"
kill "$host_stray" 2>/dev/null; wait "$host_stray" 2>/dev/null

# spent_gpu_hours sums this project's records since start_date: 0,1 for 1800 s and 2 for 3600 s is 2.0 GPU-h.
for r in "skynet-20260901T000000Z 0,1 1800" "skynet-20260901T010000Z 2 3600" "skynet-20250101T000000Z 3 3600"; do
  set -- $r; mkdir -p "$hs/$1"
  printf 'job_id: %s\nrun_id: old\nproject: %s\nhost: skynet\nsession: s-old\ngpus: %s\ntime_limit_seconds: 3600\nmem_limit_gb: 1\nrequested: %s\n' \
    "$1" "$project_id" "$2" "$([ "${1:7:4}" = 2025 ] && echo 2025-01-01T00:00:00Z || echo 2026-09-01T00:00:00Z)" > "$hs/$1/request"
  printf 'ended: 2026-09-01T02:00:00Z\nelapsed_seconds: %s\nexit: 0\nstop: none\n' "$3" > "$hs/$1/end"
done
expect host-spent-gpu-hours ok '^spent_gpu_hours: 2.0$' -- hd view
expect_refusal host-wait-other-session W02 -- hd wait skynet-20260901T000000Z
expect_refusal host-wait-unknown W01 -- hd wait skynet-20991231T000000Z
expect_refusal host-stop-unknown W01 -- hd stop nope
rm -rf "${hs:?}"

if ! bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  skip host-boxed "bwrap cannot make a user namespace on this host"
else
  # git never runs in the agent's checkout: a hook that git's index commands run, and a git on PATH that logs where.
  printf '#!/bin/sh\ntouch %s/host-fsmonitor-ran\n' "$tmp" > "$tmp/host-fsmonitor"; chmod +x "$tmp/host-fsmonitor"
  git -C "$hp" config core.fsmonitor "$tmp/host-fsmonitor"
  mkdir -p "$tmp/host-git-bin"
  printf '#!/bin/sh\necho "$PWD|$*" >> %s/host-git.log\nexec %s "$@"\n' "$tmp" "$(command -v git)" > "$tmp/host-git-bin/git"
  chmod +x "$tmp/host-git-bin/git"
  hg() { (cd "$hp" && env HOME="$hh" GH_TOKEN=gho_planted PATH="$tmp/host-git-bin:$PATH" "$drive" "$@"); }
  long=$(hg launch runs/2026-10-19-long 'Train until stopped.' -- --time=5 runs/long.sh)
  long_id=${long%% *}
  expect host-launch-id ok '^skynet-[0-9]{8}T[0-9]{6}Z none '"$hp"'/launch-skynet-' -- echo "$long"
  wall=$(hg launch runs/2026-10-19-wall 'Run past the walltime.' -- --time=1 runs/stubborn.sh)
  wall_id=${wall%% *}
  job=$(hg launch runs/2026-10-19-job 'Show the box.' -- sbatch --time=5 runs/job.sh one two)
  job_id=${job%% *}
  for _ in $(seq 100); do [ -f "$hs/$job_id/end" ] && break; sleep 0.1; done
  expect host-job-completed ok '^state: exited code: 0 slurm: COMPLETED log: '"$hp"'/launch-' -- hg wait "$job_id"
  out=$(hg wait "$job_id")
  expect host-job-guard-job-id ok "^GUARD_JOB_ID=$job_id$" -- echo "$out"
  expect host-job-no-token ok '^GH=unset$' -- echo "$out"
  expect host-job-empty-home ok "^HOME=$hh$" -- echo "$out"
  expect host-job-no-ssh ok '^ssh: cat: .*No such file or directory$' -- echo "$out"
  expect host-job-no-ssh-key fail - -- grep -q canary-ssh-key "$hp/launch-$job_id.log"
  expect host-job-args ok '^args=one two$' -- echo "$out"
  expect host-job-no-gpus ok '^nvidia nodes: 0$' -- echo "$out"
  expect host-job-run-dir ok - -- test -d "$hp/runs/2026-10-19-job"
  expect host-supervisor-no-token fail - -- grep -qz gho_planted "/proc/$(sed -n 's/^supervisor_pid: //p' "$hs/$long_id/start")/environ"
  expect host-request-boxed ok '^boxed: yes$' -- cat "$hs/$long_id/request"
  expect host-request-session ok '^session: s-host$' -- cat "$hs/$long_id/request"
  expect host-request-mem-default ok '^mem_limit_gb: 4$' -- cat "$hs/$long_id/request"
  expect host-wait-running ok '^state: running code: None slurm: RUNNING log: .* elapsed: [0-9]+m[0-9]+s$' -- hg wait "$long_id"
  expect host-stop ok "^job $long_id RUNNING -> CANCELLED$" -- hg stop "$long_id"
  expect host-stop-gentle ok '^checkpointed$' -- cat "$hp/launch-$long_id.log"
  expect host-stop-exit ok '^exit: 0$' -- cat "$hs/$long_id/end"
  expect host-five-records ok '^beat end request start stop$' -- bash -c 'ls "$1" | grep -v log | paste -sd " "' _ "$hs/$long_id"
  expect host-no-git-hook fail - -- test -e "$tmp/host-fsmonitor-ran"
  expect host-git-only-mirror fail - -- grep -v -e "--git-dir $hb/mirror.git" -e "|init -q --bare $hb/mirror.git" "$tmp/host-git.log"
  git -C "$hp" config --unset core.fsmonitor
  for _ in $(seq 150); do [ -f "$hs/$wall_id/end" ] && break; sleep 0.5; done
  expect host-walltime ok '^stop: walltime$' -- cat "$hs/$wall_id/end"
  expect host-walltime-state ok '^state: timeout code: [0-9]+ slurm: TIMEOUT ' -- hg wait "$wall_id"
  expect host-walltime-after-grace ok '^elapsed_seconds: 6[0-9]$' -- cat "$hs/$wall_id/end"
  if [ -e /dev/nvidia0 ] && [ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)" ]; then
    gj=$(hg launch runs/2026-10-19-gpu 'Show a GPU.' -- --time=5 --gpus=1 runs/job.sh)
    for _ in $(seq 100); do [ -f "$hs/${gj%% *}/end" ] && break; sleep 0.1; done
    expect host-job-gpu-node ok '^nvidia nodes: [1-9]' -- cat "$hp/launch-${gj%% *}.log"
  else
    skip host-job-gpu-node "no idle /dev/nvidia0 here"
  fi
  # guard wait and guard wait --stop reach a host job through the scheduler socket (lib/wait.py, U3).
  mkdir -p "$tmp/host-sock"
  python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path
from broker import scheduler, server
b = scheduler.Broker(sys.argv[2], json.load(open(sys.argv[2] + "/config.json")))
s = server.bind(sys.argv[3] + "/scheduler.sock", "scheduler", b)
open(sys.argv[3] + "/ready", "w").close()
s.serve_forever()' "$here" "$hb" "$tmp/host-sock" & host_srv=$!
  for _ in $(seq 50); do [ -e "$tmp/host-sock/ready" ] && break; sleep 0.1; done
  gw() { env GUARD_SESSION=s-host GUARD_SOCK_DIR="$tmp/host-sock" "$guard" wait "$@"; }
  short=$(hg launch runs/2026-10-19-short 'Sleep a little.' -- --time=5 runs/short.sh)
  expect host-guard-wait-ends ok "^job ${short%% *} (RUNNING -> )?COMPLETED" -- gw "${short%% *}"
  expect host-guard-wait-tail ok '^short done$' -- gw "${short%% *}"
  stop_me=$(hg launch runs/2026-10-19-stopme 'Train until stopped.' -- --time=5 runs/long.sh)
  expect host-guard-wait-stop ok "^job ${stop_me%% *} RUNNING -> CANCELLED$" -- gw --stop "${stop_me%% *}"
  expect_refusal host-guard-wait-w01 W01 -- gw skynet-20991231T000000Z
  kill "$host_srv" 2>/dev/null; wait "$host_srv" 2>/dev/null
  expect host-no-job-left fail - -- grep -lzE '^HPC_JOB_ID=skynet-' /proc/[0-9]*/environ
fi

rm -rf "${hs:?}"
