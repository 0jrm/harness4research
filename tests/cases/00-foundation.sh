# shellcheck shell=bash
# Sourced by tests/run.sh: U1's shapes, cost(), the refusal table, the verb registry and the transport.
echo "== foundation"
export TMPDIR_FOUNDATION=$tmp
py() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path; exec(sys.argv[2])' "$here" "$1"; }
expect foundation-cost-both ok '^slurm 384.0 1.5 256 / host 12.0 1.5 8$' -- py '
from policy import SbatchSpec, Limits
from policy.cost import cost
L = Limits("a", "2026-01-01", "2099-01-01", 128, 720, 4, 5, 1000)
s = SbatchSpec(time_min=90, nodes=2, cpus_per_task=8, gpus=1)
a, b = cost(s, L, "slurm"), cost(s, L, "host")
print("slurm", a.core_hours, a.gpu_hours, a.cores, "/ host", b.core_hours, b.gpu_hours, b.cores)'
expect foundation-cost-array ok '^60.0$' -- py '
from policy import SbatchSpec, Limits
from policy.cost import cost
print(cost(SbatchSpec(time_min=30, array="0-3", array_n=4), Limits("a", "x", "y", 30, 720, 4, 5, 1000), "slurm").core_hours)'
expect foundation-launcher-stripped ok "^\(\('--time', '5'\), 'job.sh', \('a',\)\)$" -- py '
from policy.invocation import split_command
print(split_command(["sbatch", "--time", "5", "job.sh", "a"]))'
expect foundation-argv-over-sbatch ok '^30 2 5 3$' -- py '
from policy import Request
from policy.invocation import parse
inv, s = parse(Request("run", "runs/r1", "Why.", options=("--time=30",), script="job.sh"),
               b"#!/bin/bash\n#SBATCH --nodes=2\n#SBATCH --time=10\n#SBATCH --mem=4500M\n#SBATCH -G 3\necho\n", "s1", 0.0)
print(s.time_min, s.nodes, s.mem_gb, s.gpus)'
expect foundation-unknown-option fail 'sbatch option --gres is not one guard run takes' -- py '
from policy import Request
from policy.invocation import parse
parse(Request("run", "runs/r1", "Why.", options=("--time=30", "--gres=gpu:1"), script="job.sh"), b"", "s1", 0.0)'
expect foundation-card-placeholders fail 'has no account, start_date' -- py '
from policy.cost import limits
limits(open(sys.argv[1] + "/templates/guard/budget.card").read())'
expect foundation-card-lists ok "^\('a', 'b'\) \(\) 0.0$" -- py '
from policy.cost import limits
L = limits("account: g\nstart_date: 1\nstop_date: 2\ncores_per_node: 8\nmax_walltime_minutes: 60\nmax_nodes_per_job: 1\nmax_concurrent_jobs: 2\nmax_core_hours: 9\npartitions: a, b\nlaunch_hosts: none\nmax_gpu_hours: 0\n")
print(L.partitions, L.launch_hosts, L.max_gpu_hours)'
expect foundation-refusals-doc ok '^refusals: [0-9]+ codes, docs/refusals.md current$' -- "$here/tests/refusals.sh"
expect foundation-next-rule fail 'line 2 breaks the line 2 rule' -- py '
import refusals
refusals.refuse("R02", time="9h", max=720, next="guard run runs/<id> -- job.sh")'

# The registry: a verb whose module is missing answers X00, over a real socket, and a v7 verb still reaches its store.
send=$tmp/send  # send <verb>: one request through lib/broker/transport.py; its reply printed, its rc the exit status
cat > "$send" <<PY
#!/usr/bin/env python3
import sys; sys.path.insert(0, "$here/lib"); import _path
from broker import transport
r = transport.send({"verb": sys.argv[1]})
sys.stdout.write(r.get("out", "")); sys.stderr.write(r.get("err", "")); sys.exit(r["rc"])
PY
chmod +x "$send"
fsock=$tmp/fsock; mkdir -p "$fsock"
python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path, os
from broker import server
server.MODULES["scheduler"]["nope"] = "nope"
class Store:
    def handle(self, req): return {"rc": 0, "out": "v7 " + req["verb"] + "\n"}
s = server.bind(os.path.join(sys.argv[2], "scheduler.sock"), "scheduler", Store())
open(os.path.join(sys.argv[2], "ready"), "w").close()
s.serve_forever()' "$here" "$fsock" & fpid=$!
for _ in $(seq 50); do [ -e "$fsock/ready" ] && break; sleep 0.1; done
expect_refusal foundation-x00-socket X00 -- env GUARD_SOCK_DIR="$fsock" GUARD_SESSION=s1 "$send" nope
expect foundation-v7-verb ok '^v7 queue$' -- env GUARD_SOCK_DIR="$fsock" GUARD_SESSION=s1 "$send" queue
kill "$fpid"; wait "$fpid" 2>/dev/null
expect_refusal foundation-r15-down R15 -- env GUARD_SOCK_DIR="$fsock" GUARD_SESSION=s1 "$send" queue
expect_refusal foundation-local-x00 X00 -- env -u GUARD_SESSION GUARD_SOCK_DIR="$tmp/nosock" "$send" queue

# A verb module sees the session of the socket it answered on, never the request's, and the broker's own methods and
# attribute writes go through to the one Broker the project keeps.
expect foundation-session-per-socket ok '^s-a s-a None 1 / s-b s-b None 2 / proj proj None 3$' -- py '
import os, types, sys as s
from broker import server
probe = types.ModuleType("broker.probe")
def handle(req, broker):
    broker.calls = getattr(broker, "calls", 0) + 1
    return {"rc": 0, "out": " ".join(map(str, (broker.cfg["session"], broker.stamp(), req.get("session"), broker.calls)))}
probe.handle = handle
s.modules["broker.probe"] = probe
server.MODULES["scheduler"]["probe"] = "probe"
class Broker:
    cfg = {"session": "proj"}
    def stamp(self): return self.cfg["session"]
b = Broker()
tmp = os.environ["TMPDIR_FOUNDATION"]
a = server.bind(os.path.join(tmp, "a.sock"), "scheduler", b, session="s-a")
c = server.bind(os.path.join(tmp, "b.sock"), "scheduler", b, session="s-b")
forged = {"verb": "probe", "session": "forged"}
print(a.answer(forged)["out"], "/", c.answer(forged)["out"], "/", server.answer(b, "scheduler", forged)["out"])'
expect foundation-h03-next ok '^guard status$' -- py '
import refusals
print(refusals.refuse("H03", n=3).next)'

# bin/guard: a verb not yet in lib/verbs/ is X00; the v7 agent commands are R09 with the guard run line; review,
# merge and ship inside a sandbox are G01.
fh=$tmp/fharness; mkdir -p "$fh/bin" "$fh/lib"; cp "$here/bin/guard" "$fh/bin/"; cp -R "$here/lib/refusals.py" "$here/lib/policy" "$fh/lib/"
expect_refusal foundation-verb-x00 X00 -- "$fh/bin/guard" status
expect_refusal foundation-r09-preflight R09 -- "$guard" preflight runs/2026-10-19-a job.sh --array=0-3
expect foundation-r09-line fail "^guard run runs/2026-10-19-a --why 'Run job.sh for run 2026-10-19-a.' -- --array=0-3 job.sh$" -- \
  "$guard" preflight runs/2026-10-19-a job.sh --array=0-3
expect_refusal foundation-r09-launch R09 -- "$guard" launch runs/x --time=30 --gpus=0,1 --mem=8 -- python3 train.py
expect_refusal foundation-r09-card R09 -- "$guard" card add x x.card
expect_refusal foundation-g01 G01 -- env GUARD_SESSION=s1 "$guard" review 1
expect foundation-modellog-codes ok '^True$' -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/eval"); import modellog
print(modellog.is_harness_refusal("H4R-R02 time 900 exceeds max_walltime_minutes 720\nguard run x"))' "$here"

# guard enter's session serves records.sock beside scheduler.sock (v7-guard-enter-broker.sh's fixture, en and $ep_).
if ! declare -F en >/dev/null || ! bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  skip foundation-enter-records "no guard enter fixture or no user namespace on this host"
else
  expect foundation-enter-records ok '^Nothing needs you\.$' -- en enter "$ep_" -- python3 -c 'import json, socket
c = socket.socket(socket.AF_UNIX); c.connect("/run/guard/records.sock")
c.sendall(json.dumps({"verb": "list", "store": "needs-you"}).encode() + b"\n")
print(json.loads(c.makefile().readline()).get("out", "").strip())'
  en broker stop >/dev/null 2>&1
fi
