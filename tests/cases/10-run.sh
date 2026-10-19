# shellcheck shell=bash
# Sourced by tests/run.sh: guard run (U2). decide() on its own, then the verb end to end in local mode against a
# fake Slurm: a project with guard/budget.card on main, no broker, and sbatch, sacct and squeue from $rb.
echo "== guard run"
dec=$tmp/decide.py  # dec '<python>': runs it after the names below; d(...) prints "verdict code backend | next"
cat > "$dec" <<PY
import sys; sys.path.insert(0, "$here/lib"); import _path, dataclasses
from policy import Request, Limits, HostView, Cost
from policy.cost import cost
from policy.decide import RunView, ViewJob, backend, decide
from policy.invocation import parse
L = Limits("gom", "2026-01-01", "2099-01-01", 4, 10, 1, 4, 100, partitions=("short", "long"),
           verification_reserve_core_hours=10, launch_hosts=("gpu1",), max_gpu_hours=8, host_max_mem_gb=64,
           host_min_available_gb=32, host_max_walltime_minutes=120)
V = RunView(0, 0, 0, project="/home/agent/p")
HOST = HostView("gpu1", True, 100.0, gpus_free=("0", "1"), bwrap=True)
def job(seq, run, state="RUNNING", options=("--time=5",), args=(), sha="s0", jid=None, ch=0.33):
    return ViewJob(seq=seq, job_id=jid or str(1000 + seq), run_id=run, backend="slurm", state="submitted",
                   submitted_ts=float(seq), why="w", cost=Cost("slurm", 5, 1, 4, 0, None, ch, 0), comment="c",
                   script_sha256=sha, options=options, args=args, log="/home/agent/p/slurm-%d.out" % (1000 + seq),
                   sched_state=state)
def d(options, view=V, limits=L, run="runs/sim", args=(), cause=None, script=b"#!/bin/bash\n", ts=1.8e9, show="next"):
    inv, s = parse(Request("run", run, "Run it.", cause, tuple(options), "job.sh", tuple(args), "/home/agent/p"),
                   script, "s1", ts)
    inv = dataclasses.replace(inv, script_sha256="s0")
    x = decide(inv, s, cost(s, limits, backend(limits, view)), limits, view)
    print(x.verdict, x.code, x.backend, "|", getattr(x, show))
exec(sys.argv[1])
PY
dt() { python3 "$dec" "$1"; }
expect run-decide-runs ok '^run None slurm \| None$' -- dt 'd(["--time=5"])'
expect run-r02 ok "^refuse R02 slurm \| guard run runs/sim --why 'Run it.' -- --time=10 job.sh$" -- dt 'd(["--time", "30"])'
expect run-r02-sbatch-line ok '^refuse R02 slurm \| guard run runs/sim --why .* -- --time=10 job.sh$' -- \
  dt 'd([], script=b"#!/bin/bash\n#SBATCH --time=30\n")'
expect run-r03 ok "^refuse R03 slurm \| guard run runs/sim --why 'Run it.' -- --time=5 --nodes=1 job.sh$" -- dt 'd(["-N", "2", "--time=5"])'
expect run-r04 ok "^refuse R04 slurm \| .* -- --time=5 --gpus=0 job.sh$" -- dt 'd(["--time=5", "-G2"], limits=dataclasses.replace(L, max_gpu_hours=0))'
expect run-r05-other-run ok "^refuse R05 slurm \| cat /home/agent/p/slurm-1001.out$" -- \
  dt 'd(["--time=5"], run="runs/next", view=dataclasses.replace(V, last_failed_job=job(1, "sim", "TIMEOUT")))'
expect run-r05-line1 ok "^refuse R05 slurm \| job 1001 ended TIMEOUT; read its log" -- \
  dt 'd(["--time=5"], run="runs/next", view=dataclasses.replace(V, last_failed_job=job(1, "sim", "TIMEOUT")), show="reason")'
expect run-r05-cause ok '^run None' -- \
  dt 'd(["--time=5"], cause="the step count was wrong", view=dataclasses.replace(V, last_failed_job=job(1, "sim", "FAILED")))'
expect run-r06 ok '^refuse R06 slurm \| git checkout origin/main -- sim.py guard/budget.card$' -- \
  dt 'd(["--time=5"], view=dataclasses.replace(V, changed_paths_vs_main=("sim.py", "guard/budget.card")))'
expect run-r07 ok '^refuse R07 slurm \| guard status$' -- dt 'd(["--time=5"], view=dataclasses.replace(V, script_exists=False))'
expect run-r08-budget ok '^queue R08 slurm \| 1000 core-h is over the remaining 90; queued as ask \{ask\}' -- \
  dt 'd(["--time=10", "--array=0-1499"], limits=dataclasses.replace(L, max_concurrent_jobs=2000), show="reason")'
expect run-r08-run-cap ok "^queue R08 slurm \| 0.67 core-h is over run sim's cap 1" -- \
  dt 'd(["--time=10"], limits=dataclasses.replace(L, default_run_core_hours=1), view=dataclasses.replace(V, run_jobs={"sim": (job(1, "sim", "COMPLETED", ch=0.5),)}), show="reason")'
expect run-approval-queue ok '^queue R08 slurm \| approval is queue' -- \
  dt 'd(["--time=5"], limits=dataclasses.replace(L, approval="queue"), show="reason")'
expect run-r08-waiting ok '^queue R08 slurm \| a3$' -- \
  dt 'd(["--time=5"], view=dataclasses.replace(V, open_asks=({"id": "a3", "effect": {"kind": "submit", "run_id": "sim"}},)), show="ask_id")'
expect run-yes-lifts ok '^run None slurm \| a4$' -- dt '
from policy import SbatchSpec
yes = {"id": "a4", "answer": "yes", "effect": {"kind": "submit", "run_id": "sim", "script_sha256": "s0",
       "spec": dataclasses.asdict(SbatchSpec(time_min=5))}}
d(["--time=5"], limits=dataclasses.replace(L, approval="queue"), view=dataclasses.replace(V, open_asks=(yes,)), show="ask_id")'
expect run-yes-not-r02 ok '^refuse R02' -- dt '
from policy import SbatchSpec
yes = {"id": "a4", "answer": "yes", "effect": {"kind": "submit", "run_id": "sim", "script_sha256": "s0",
       "spec": dataclasses.asdict(SbatchSpec(time_min=30))}}
d(["--time=30"], view=dataclasses.replace(V, open_asks=(yes,)))'
expect run-yes-pinned ok '^queue R08' -- dt '
from policy import SbatchSpec
yes = {"id": "a4", "answer": "yes", "effect": {"kind": "submit", "run_id": "sim", "script_sha256": "other",
       "spec": dataclasses.asdict(SbatchSpec(time_min=5))}}
d(["--time=5"], limits=dataclasses.replace(L, approval="queue"), view=dataclasses.replace(V, open_asks=(yes,)))'
expect run-r10 ok '^refuse R10 slurm \| guard wait 1001$' -- \
  dt 'd(["--time=5"], view=dataclasses.replace(V, live_jobs=tuple(job(i, "r%d" % i) for i in range(1, 5))))'
live1='view=dataclasses.replace(V, live_jobs=(job(1, "sim", args=("a",)),), run_jobs={"sim": (job(1, "sim", args=("a",)),)})'
expect run-r11 ok '^refuse R11 slurm \| guard wait 1001$' -- dt "d(['--time=5'], args=('a',), $live1)"
expect run-r11-state ok '^refuse R11 slurm \| this exact job is already RUNNING as 1001$' -- dt "d(['--time=5'], args=('a',), $live1, show='reason')"
expect run-r11-new-args ok '^run None' -- dt "d(['--time=5'], args=('b',), $live1)"
live9='view=dataclasses.replace(V, live_jobs=(job(1, "sim", args=("a",), sha="s9"),), run_jobs={"sim": (job(1, "sim", args=("a",), sha="s9"),)})'
expect run-r11-changed-script ok '^run None' -- dt "d(['--time=5'], args=('a',), $live9)"
expect run-r11-afterok ok '^run None' -- dt "d(['--time=5', '--dependency=afterok:1001'], args=('a',), $live1)"
expect run-r12 ok '^refuse R12 slurm \| cd /home/agent/p$' -- dt 'd(["--time=5"], view=dataclasses.replace(V, run_dir_in_project=False))'
expect run-r16 ok "^refuse R16 slurm \| guard ask 'stop_date passed; extend it\?' --default no --deadline 2h$" -- \
  dt 'd(["--time=5"], limits=dataclasses.replace(L, stop_date="2026-10-01"), ts=1.8e9)'
expect run-r17 ok "^refuse R17 slurm \| .* -- --time=5 --partition=short job.sh$" -- dt 'd(["--time=5", "-p", "gpu"])'
expect run-r18 ok "^refuse R18 slurm \| guard run runs/sim --why 'Run it.' -- --time=5 job.sh$" -- dt 'd(["--time=5", "--dependency=afterok:77"])'
expect run-r18-own ok '^run None' -- \
  dt 'd(["--time=5", "--dependency=afterok:1001"], view=dataclasses.replace(V, run_jobs={"sim": (job(1, "sim", "COMPLETED"),)}))'
expect run-r19 ok "^refuse R19 slurm \| .* -- --time=5 --output=runs/sim/slurm-%j.out job.sh$" -- dt 'd(["--time=5", "--output=/tmp/x.out"])'
expect run-r19-up ok '^refuse R19' -- dt 'd(["--time=5", "-o", "../x.out"])'
host='view=dataclasses.replace(V, host=HOST)'
expect run-backend-host ok '^run None host' -- dt "d(['--time=30', '--gpus=1', '--mem=8G'], $host)"
expect run-backend-slurm-elsewhere ok '^run None slurm' -- dt "d(['--time=5'], view=dataclasses.replace(V, host=HostView('login1', False, 100.0)))"
expect run-r13-time ok "^refuse R13 host \| .* -- --time=120 job.sh$" -- dt "d(['--time=200'], $host)"
expect run-r13-mem ok "^refuse R13 host \| .* -- --time=5 --mem=64G job.sh$" -- dt "d(['--time=5', '--mem=100G'], $host)"
expect run-r13-gpu-hours ok "^refuse R13 host \| .* -- --time=120 --gpus=4 job.sh$" -- \
  dt "d(['--time=120', '--gpus=6'], view=dataclasses.replace(V, host=HostView('gpu1', True, 100.0, gpus_free=tuple('012345'), bwrap=True)))"
expect run-r13-slurm-only ok "^refuse R13 host \| guard run runs/sim --why 'Run it.' -- --time=5 job.sh$" -- dt "d(['--time=5', '-N', '2', '--array=0-3'], $host)"
expect run-r13-slurm-only-line1 ok '^refuse R13 host \| --nodes/--array is not for a launch host$' -- dt "d(['--time=5', '-N', '2', '--array=0-3'], $host, show='reason')"
expect run-r13-sbatch-nodes ok "^refuse R13 host \| guard run runs/sim --why 'Run it.' -- --time=5 --nodes=1 job.sh$" -- \
  dt "d(['--time=5'], $host, script=b'#!/bin/bash\n#SBATCH -N 2\n')"
expect run-r13-sbatch-partition ok '^refuse R13 host \| guard status$' -- \
  dt "d(['--time=5'], $host, script=b'#!/bin/bash\n#SBATCH -p short\n')"
expect run-r14-memory ok '^refuse R14 host \| guard wait gpu1-20261019T120000Z$' -- \
  dt "d(['--time=5'], view=dataclasses.replace(V, host=HostView('gpu1', True, 20.0, bwrap=True, live_launches=('gpu1-20261019T120000Z',))))"
expect run-r14-gpus ok '^refuse R14 host \| 2 GPUs free, 3 asked$' -- dt "d(['--time=5', '--gpus=3'], $host, show='reason')"
expect run-r14-bwrap ok '^refuse R14 host \| no bwrap$' -- dt "d(['--time=5'], view=dataclasses.replace(V, host=HostView('gpu1', True, 100.0)), show='reason')"

# End to end, local mode: no socket and no GUARD_SESSION, so guard run answers in-process.
rb=$tmp/run-bin; rs=$tmp/run-slurm; mkdir -p "$rb" "$rs/state"
# The broker runs the scheduler's clients with a cleared environment, so the fake's state path is written into it.
cat > "$rb/sbatch" <<SH
#!/usr/bin/env bash
[ ! -e $rs/err ] || { echo "sbatch: error: \$(cat $rs/err)" >&2; exit 1; }
n=\$(( \$(cat $rs/next 2>/dev/null || echo 1000) + 1 )); echo \$n > $rs/next
printf '%s\n' "\$*" >> $rs/sbatch.log; echo RUNNING > $rs/state/\$n; echo "user=\$USER" >> $rs/user.log; echo \$n
SH
cat > "$rb/sacct" <<SH
#!/usr/bin/env bash
case \$* in
  *JobID,State*) ids=\${*##*--jobs=}; for j in \${ids//,/ }; do [ ! -e $rs/state/\$j ] || echo "\$j|\$(cat $rs/state/\$j)"; done ;;
  *CPUTimeRAW*) cat $rs/cpu 2>/dev/null || : ;;
esac
SH
printf '#!/usr/bin/env bash\n' > "$rb/squeue"; printf '#!/usr/bin/env bash\necho "scancel $*"\n' > "$rb/scancel"
chmod +x "$rb"/*; ln -s "$guard" "$rb/guard"
rp=$tmp/run-proj; git init -q --bare -b main "$tmp/run-origin.git"; git clone -q "$tmp/run-origin.git" "$rp" 2>/dev/null
mkdir -p "$rp/guard"
cat > "$rp/guard/budget.card" <<'CARD'
account: gom
start_date: 2026-01-01
stop_date: 2099-01-01
partitions: short long
cores_per_node: 4
max_walltime_minutes: 10
max_nodes_per_job: 1
max_concurrent_jobs: 4
max_core_hours: 100
verification_reserve_core_hours: 10
max_gpu_hours: 0
CARD
printf 'sim.py\n' > "$rp/guard/watch.list"; echo 'print(1)' > "$rp/sim.py"
printf '#!/bin/bash\n#SBATCH --time=5\npython3 sim.py\n' > "$rp/job.sh"; printf '#!/bin/bash\necho hi\n' > "$rp/notime.sh"
git -C "$rp" add -A; git -C "$rp" commit -q -m init; git -C "$rp" push -q -u origin main
gsh() { (cd "$rp" && env -u GUARD_SESSION GUARD_SOCK_DIR="$tmp/run-nosock" PATH="$rb:$PATH" bash -c "$1"); }
gr() { (cd "$rp" && env -u GUARD_SESSION GUARD_SOCK_DIR="$tmp/run-nosock" PATH="$rb:$PATH" guard run "$@"); }
ended() { for f in "$rs"/state/*; do echo COMPLETED > "$f"; done; }  # ended: every fake job has finished
expect run-submits ok '^job 1001 submitted for run sim: 5 min x 1 node\(s\) x 4 cores = 0.33 core-h; guard wait 1001$' -- \
  gr runs/sim --why "Run the configured steps." -- job.sh
expect run-card-local ok '^written_by: guard run, local, unsigned$' -- git -C "$tmp/run-origin.git" show run/sim:runs/sim/question.card
expect run-card-keys ok '^why command backend minutes nodes cores gpus tasks core_hours gpu_hours session written_by $' -- \
  bash -c "git -C '$tmp/run-origin.git' show run/sim:runs/sim/question.card | cut -d: -f1 | tr '\n' ' '"
# Local mode is the user's own shell: its sbatch sees the user's environment (USER is how a site's client, and the
# evaluation's fake Slurm, names the job's owner, so sacct and guard wait find the job).
expect run-local-env ok '^user=tester$' -- tail -1 "$rs/user.log"
expect run-sbatch-argv ok '--account=gom --job-name=sim --comment=guard:local:1 --time=5 --nodes=1' -- tail -1 "$rs/sbatch.log"
expect_refusal run-r11-e2e R11 -- gr runs/sim --why "Run the configured steps." -- job.sh
ended
expect run-launcher-stripped ok '^job 1002 submitted' -- gr runs/sim --why w -- sbatch --time=4 job.sh
expect run-launcher-spec ok '--time=4 --nodes=1' -- tail -1 "$rs/sbatch.log"
expect run-launcher-bash ok '^job 1003 submitted' -- gr runs/sim --why w -- bash --time=3 job.sh
expect_refusal run-r01-no-dashes R01 -- gr runs/sim --why w job.sh
expect run-r01-line fail "^guard run runs/sim --why w -- job.sh$" -- gr runs/sim --why w job.sh
expect_refusal run-r01-no-time R01 -- gr runs/sim --why w -- notime.sh
expect run-r01-time-line fail "^guard run runs/sim --why w -- --time=10 notime.sh$" -- gr runs/sim --why w -- notime.sh
expect_refusal run-r01-unknown R01 -- gr runs/sim --why w -- --gres=gpu:1 job.sh
expect run-r01-unknown-line fail "^guard run runs/sim --why w -- job.sh$" -- gr runs/sim --why w -- --gres=gpu:1 job.sh
expect_refusal run-r02-e2e R02 -- gr runs/sim --why w -- --time=30 job.sh
ended
expect run-r02-next-submits ok '^job 1004 submitted' -- gsh 'eval "$(guard run runs/sim --why w -- --time=20 job.sh 2>&1 | tail -1)"' 
expect_refusal run-r07-e2e R07 -- gr runs/sim --why w -- --time=5 nope.sh
expect_refusal run-r07-sbatch R07 -- gsh "echo 'Invalid account' > $rs/err; guard run runs/sim --why w -- --time=2 job.sh; rc=\$?; rm -f '$rs/err'; exit \$rc"
expect_refusal run-r12-e2e R12 -- gr ../elsewhere --why w -- --time=5 job.sh
expect_refusal run-r17-e2e R17 -- gr runs/sim --why w -- --time=5 --partition=gpu job.sh
expect_refusal run-r18-e2e R18 -- gr runs/sim --why w -- --time=5 --dependency=afterok:77 job.sh
expect_refusal run-r19-e2e R19 -- gr runs/sim --why w -- --time=5 --output=/tmp/x.out job.sh
expect run-afterok-own ok 'submitted' -- gr runs/sim --why w -- --time=5 --dependency=afterok:1001 job.sh
echo 'print(2)' > "$rp/sim.py"
expect_refusal run-r06-e2e R06 -- gr runs/sim --why w -- --time=1 job.sh
git -C "$rp" checkout -q -- sim.py
ended; echo FAILED > "$rs/state/1001"
expect_refusal run-r05-e2e R05 -- gr runs/other --why w -- --time=5 job.sh
expect run-r05-log fail "^cat $rp/slurm-1001.out$" -- gr runs/other --why w -- --time=5 job.sh
expect run-cause-submits ok 'submitted for run other' -- gr runs/other --why w --cause "sim.py read a stale config" -- --time=5 job.sh
expect run-incident ok '^sim.py read a stale config$' -- git -C "$tmp/run-origin.git" show run/sim:runs/sim/incidents/1.md
expect run-incident-job ok '^job: 1001$' -- git -C "$tmp/run-origin.git" show run/sim:runs/sim/incidents/1.md
expect run-job-log-row ok '"why": "w"' -- grep -h '"state": "intent"' "$rp/.git/guard/broker/ledger.jsonl"
expect run-refusal-log ok '"code": "R06"' -- cat "$rp/.git/guard/broker/refusals.jsonl"
if [ -e "$here/lib/broker/asks.py" ]; then
  ended
  expect_refusal run-r08-e2e R08 -- gr runs/big --why w -- --time=10 --array=0-999 job.sh
  expect_refusal run-r08-again R08 -- gr runs/big --why w -- --time=5 job.sh
  expect run-r08-again-line1 fail '^H4R-R08 run big already waits on ask a1, default no at [0-9:]+ UTC$' -- gr runs/big --why w -- --time=5 job.sh
  gr runs/sim --why w -- --time=40 job.sh >/dev/null 2>&1
  expect run-overage-twice fail '^H4R-R08 time 40 exceeds max_walltime_minutes 10; .*; asked a person as ask a2, default no' -- \
    gr runs/sim --why w -- --time=40 job.sh
  yes() { (cd "$rp" && PATH="$rb:$PATH" python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path
from broker import asks, local, run
b = local.project_broker()
a = asks.fold(asks.rows(b))[0][sys.argv[2]]
r = run.redecide(b, a["effect"]); print(r.get("out", "") + r.get("err", ""))' "$here" "$1"); }
  expect run-yes-pinned-script ok '^H4R-R08' -- bash -c "echo '# changed' >> '$rp/job.sh'; $(declare -f yes); here='$here' rp='$rp' rb='$rb'; yes a1"
  git -C "$rp" checkout -q -- job.sh
  expect run-yes-submits ok '^job [0-9]+ submitted for run big: 10 min x 1 node\(s\) x 4 cores x 1000 tasks' -- yes a1
  expect run-yes-overage-refuses ok '^H4R-R02' -- yes a2
  expect run-overage-ask ok '"question": "allow 40 min for run sim\?"' -- cat "$rp/.git/guard/broker/records/asks.jsonl"
else
  skip run-r08-e2e "lib/broker/asks.py (U4) is not in this harness"
fi

# On a host in launch_hosts (tests/mock-bin/hostname says skynet) the same guard run line launches under the supervisor,
# boxed, with no sbatch on PATH; guard wait ends it, and a Slurm-only flag is R13 before anything starts.
hq=$tmp/run-host; git init -q --bare -b main "$tmp/run-host-origin.git"; git clone -q "$tmp/run-host-origin.git" "$hq" 2>/dev/null
mkdir -p "$hq/guard"
cat > "$hq/guard/budget.card" <<CARD
account: gom
start_date: 2026-01-01
stop_date: 2099-01-01
cores_per_node: 4
max_walltime_minutes: 10
max_nodes_per_job: 1
max_concurrent_jobs: 4
max_core_hours: 100
max_gpu_hours: 1
launch_hosts: skynet
host_max_walltime_minutes: 30
host_max_mem_gb: 1
host_min_available_gb: 0
host_stop_grace_seconds: 1
host_state_dir: $tmp/run-host-state
CARD
printf '#!/bin/bash\necho "host job $GUARD_JOB_ID"\n' > "$hq/job.sh"
git -C "$hq" add -A; git -C "$hq" commit -q -m init; git -C "$hq" push -q -u origin main
ghr() { (cd "$hq" && env -u GUARD_SESSION GUARD_SOCK_DIR="$tmp/run-nosock" PATH="$(path_without sbatch)" "$guard" "$@"); }
expect_refusal run-host-r13-e2e R13 -- ghr run runs/h --why "Run it here." -- --time=5 --nodes=2 job.sh
expect run-host-r13-e2e-line fail "^guard run runs/h --why 'Run it here.' -- --time=5 job.sh$" -- \
  ghr run runs/h --why "Run it here." -- --time=5 --nodes=2 job.sh
expect_refusal run-host-r13-gpu-e2e R13 -- ghr run runs/g --why "Run it here." -- --time=30 --gpus=4 job.sh
if bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  hl=$(ghr run runs/h --why "Run it here." -- --time=5 job.sh 2>&1)
  expect run-host-launched ok '^job skynet-[0-9]{8}T[0-9]{6}Z launched for run h: 5 min x 1 cores x 0 GPUs = 0.08 core-h, 0 GPU-h; guard wait skynet-' -- echo "$hl"
  hid=$(sed -n 's/^job \([^ ]*\) launched.*/\1/p' <<<"$hl")
  for _ in $(seq 100); do [ -f "$tmp/run-host-state/$hid/end" ] && break; sleep 0.1; done
  expect run-host-wait-ends ok "^job $hid (RUNNING -> )?COMPLETED" -- ghr wait "$hid"
  expect run-host-wait-log ok "^host job $hid$" -- ghr wait "$hid"
  expect run-host-card ok '^backend: host$' -- git -C "$tmp/run-host-origin.git" show run/h:runs/h/question.card
  expect run-host-log-row ok '"backend": "host"' -- grep -h '"state": "intent"' "$hq/.git/guard/broker/ledger.jsonl"
else
  skip run-host-launched "bwrap cannot make a user namespace on this host"
fi
rm -rf "${tmp:?}/run-host-state"

# guard atlas reads guard run's records: the CardRecord and the --cause incident on run/<run_id>, not a question card.
printf '#!/bin/sh\n' > "$rp/guard/run"; git -C "$rp" add guard/run; git -C "$rp" commit -q -m 'guard/run'; git -C "$rp" push -q
git -C "$rp" fetch -q origin
expect run-atlas-draws ok - -- gsh "guard atlas --no-ripples --out '$tmp/run-atlas.html' --json '$tmp/run-atlas.json'"
atl() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); r = {x["id"]: x for x in d["runs"]}; exec(sys.argv[2])' "$tmp/run-atlas.json" "$1"; }
expect run-atlas-card ok '^guard run, local, unsigned origin/run/sim$' -- atl 'print(r["sim"]["card"]["written_by"], r["sim"]["card_from"])'
expect run-atlas-incident ok '^1001 sim.py read a stale config$' -- atl 'i = r["sim"]["incidents"][0]; print(i["job"], i["root_cause"])'
expect run-atlas-no-partner-rule ok '^\[\]$' -- atl 'print([v for v in r["sim"]["violations"] if "partner" in v])'
expect run-atlas-not-in-map ok - -- bash -c '! sed -n "/<section id=\"questions\"/,/<\/section>/p" "$1" | grep -q "href=\"#run-sim\""' _ "$tmp/run-atlas.html"
expect run-atlas-listed ok 'href="#run-sim"' -- cat "$tmp/run-atlas.html"
expect run-atlas-html ok '<dt>Why</dt><dd>Run the configured steps.</dd>' -- cat "$tmp/run-atlas.html"
