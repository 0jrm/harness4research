# shellcheck shell=bash
# Sourced by tests/run.sh: guard wait (lib/wait.py) and guard status (lib/verbs/status.py, lib/broker/status.py).
echo "== wait and status"
wpy() {  # wpy <python>: runs it with lib/wait.py imported and its clock, scheduler and pid seams patchable
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path, wait; exec(sys.argv[2])' "$here" "$1"; }
wd=$tmp/wait-dir

# A buffered child's first line is in the log within 5 s; the wait returns at its --timeout, still running (124).
out=$(env GUARD_WAIT_DIR="$wd" "$guard" wait --timeout 3s -- python3 -c 'print("first"); import time; time.sleep(25)'); rc=$?
pg=$(sed -n 's/^stop it: kill -- -//p' <<<"$out"); [ -z "$pg" ] || kill -- "-$pg" 2>/dev/null
expect wait-unbuffered-first-line ok '^first$' -- printf '%s\n' "$out"
expect wait-still-running-exit ok '^124$' -- echo "$rc"
expect wait-keep-waiting-line ok '^keep waiting: guard wait [0-9]+$' -- printf '%s\n' "$out"
expect wait-stop-line ok '^stop it: kill -- -[0-9]+$' -- printf '%s\n' "$out"
expect wait-command-exit-code fail 'pid [0-9]+ exited with code 3' -- env GUARD_WAIT_DIR="$wd" "$guard" wait -- sh -c 'echo done; exit 3'
expect wait-command-output fail '^done$' -- env GUARD_WAIT_DIR="$wd" "$guard" wait -- sh -c 'echo done; exit 3'

# A pid of yours, in a plain shell with no broker: acct is X00 there, the user's own sacct knows no such job, so it is a pid.
sleep 2 & spid=$!
expect wait-pid-exits ok "^pid $spid exited" -- env GUARD_WAIT_DIR="$wd" "$guard" wait "$spid"
wait "$spid" 2>/dev/null

# A 12-minute job, with the clock and the scheduler replaced: back at 5 and at 10 minutes, then COMPLETED.
expect wait-12-minute-job ok '^124 124 0$' -- wpy '
import contextlib, io
clock = [0.0]
wait.now = lambda: clock[0]
wait.sleep = lambda s: clock.__setitem__(0, clock[0] + s)
wait.job_state = lambda job: ("RUNNING", "0:0", f"{int(clock[0]) // 60}m") if clock[0] < 720 else ("COMPLETED", "0:0", "12m")
seen = []
for _ in range(3):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = wait.main(["4242"])
    seen.append((rc, out.getvalue(), clock[0]))
(a, ta, ca), (b, tb, cb), (c, tc, cc) = seen
assert (ca, cb) == (300, 600) and cc == 720, (ca, cb, cc)
assert "still running after 5m" in ta and "keep waiting: guard wait 4242" in ta and "stop it: scancel 4242" in ta
assert "still running after 10m" in tb and "job 4242 RUNNING -> COMPLETED" in tc
print(a, b, c)'

# Id resolution: a job the scheduler lists beats a live pid of the same number.
expect wait-job-before-pid ok '^acct$' -- wpy '
asked = []
wait.ask = lambda req, sock="scheduler": asked.append(req["verb"]) or {"rc": 0, "out": "1000|COMPLETED|0:0|00:01:00\n"}
wait.alive = lambda pid: True
wait.mine = lambda pid: True
assert wait.main(["1000"]) == 0
print(",".join(asked))'
expect wait-job-line ok '^job 1000 COMPLETED$' -- wpy '
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": "1000|COMPLETED|0:0|00:01:00\n"}
wait.alive = lambda pid: True
wait.mine = lambda pid: True
wait.main(["1000"])'
expect wait-array-task-is-a-job ok '^job 1234_5 FAILED exit 1:0$' -- wpy '
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": "1234_5|FAILED|1:0|00:02:00\n"} if req["args"][-1] == "1234_5" else {"rc": 0, "out": ""}
wait.main(["1234_5"])'
expect wait-array-parent-is-live-while-a-task-is ok '^RUNNING$' -- wpy '
print(wait.rows_of("1234_0|COMPLETED|0:0|1m\n1234_1|RUNNING|0:0|2m\n", "1234")[0])'
expect wait-acct-asked-with-the-id ok '^\[.-X., .-n., .-P., .-o., .JobID,State,ExitCode,Elapsed., .-S., .2000-01-01., .-j., .77.\]$' -- wpy '
got = []
wait.ask = lambda req, sock="scheduler": got.append(req["args"]) or {"rc": 0, "out": "77|COMPLETED|0:0|1m\n"}
wait.main(["77"]); print(got[0])'
expect wait-job-with-sacct-mock ok '^job 31 COMPLETED$' -- env GUARD_WAIT_DIR="$wd" MOCK_SACCT_JOBS="$tmp/jobs.psv" bash -c "
  printf '31|COMPLETED|0:0|00:00:09\n32|RUNNING|0:0|00:00:01\n' > $tmp/jobs.psv; $guard wait 31"

# Host job ids go to the scheduler socket's wait and stop verbs.
expect wait-host-id-uses-wait-verb ok '^wait skynet-20261019T120000Z$' -- wpy '
sent = []
def ask(req, sock="scheduler"):
    sent.append(req["verb"] + " " + req["id"])
    return {"rc": 0, "out": "{\"state\": \"exited\", \"code\": 0, \"elapsed\": \"1m\", \"log\": \"/x\", \"tail\": \"loss 0.1\\n\"}"}
wait.ask = ask
wait.main(["skynet-20261019T120000Z"]); print(sent[0])'
expect wait-host-tail-and-end fail 'loss 0.1' -- wpy '
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": "{\"state\": \"exited\", \"code\": 0, \"elapsed\": \"1m\", \"tail\": \"loss 0.1\\n\"}"}
wait.main(["skynet-20261019T120000Z"]); raise SystemExit(1)'
expect wait-host-ends-slurm-style ok '^job skynet-20261019T120000Z RUNNING -> COMPLETED$' -- wpy '
seen = iter(["running", "exited"])
wait.sleep = lambda s: None
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": json.dumps({"state": next(seen), "code": 0, "tail": ""})}
import json
wait.main(["skynet-20261019T120000Z"])'
expect wait-host-ends-supervisor-state ok '^job skynet-20261019T120000Z RUNNING -> TIMEOUT exit 124$' -- wpy '
seen = iter([("running", "RUNNING", None), ("timeout", "TIMEOUT", 124)])
wait.sleep = lambda s: None
def ask(req, sock="scheduler"):
    st, sl, code = next(seen)
    return {"rc": 0, "out": json.dumps({"state": st, "slurm_state": sl, "code": code, "tail": ""})}
wait.ask = ask
import json
wait.main(["skynet-20261019T120000Z"])'
expect wait-host-running-returns-124 ok '^124 guard wait --stop skynet-20261019T120000Z$' -- wpy '
import contextlib, io
clock = [0.0]
wait.now = lambda: clock[0]
wait.sleep = lambda s: clock.__setitem__(0, clock[0] + s)
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": "{\"state\": \"running\", \"code\": null, \"elapsed\": \"5m00s\", \"tail\": \"step 9\\n\"}"}
out = io.StringIO()
with contextlib.redirect_stdout(out):
    rc = wait.main(["skynet-20261019T120000Z"])
assert "step 9" in out.getvalue()
print(rc, out.getvalue().strip().splitlines()[-1].replace("stop it: ", ""))'
expect wait-stop-uses-stop-verb ok '^stop skynet-20261019T120000Z stopped$' -- wpy '
sent = []
def ask(req, sock="scheduler"):
    sent.append(req["verb"] + " " + req["id"])
    return {"rc": 0, "out": "stopped\n"}
wait.ask = ask
wait.main(["--stop", "skynet-20261019T120000Z"]); print(sent[0], "stopped")'
expect wait-host-verb-local-mode-needs-a-project fail 'is not inside a git project' -- env -u GUARD_SESSION GUARD_WAIT_DIR="$wd" "$guard" wait skynet-20261019T120000Z

# Refusals.
expect_refusal wait-w01 W01 -- wpy '
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": json.dumps({"mine": None}) if req["verb"] == "status" else ""}
import json
raise SystemExit(wait.main(["99999"]))'
expect_refusal wait-w01-host-state-unknown W01 -- wpy '
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": "{\"state\": \"unknown\"}"}
raise SystemExit(wait.main(["skynet-20261019T120000Z"]))'
expect_refusal wait-w02 W02 -- wpy '
import json
wait.ask = lambda req, sock="scheduler": {"rc": 0, "out": json.dumps({"mine": False}) if req["verb"] == "status" else ""}
raise SystemExit(wait.main(["88888"]))'
expect_refusal wait-w03-over-5m W03 -- "$guard" wait 12 --timeout 6m
expect_refusal wait-w03-no-unit W03 -- "$guard" wait 12 --timeout 10
expect_refusal wait-w03-command W03 -- "$guard" wait --timeout 1h -- sleep 5
expect wait-w03-next-keeps-the-command fail '^guard wait --timeout 5m -- sleep 5$' -- "$guard" wait --timeout 1h -- sleep 5
expect wait-no-args-usage fail '^usage: guard wait' -- "$guard" wait

# At most 40 lines, whatever the log holds, and no long lines.
mkdir -p "$tmp/waitcap" && seq 1 1000 > "$tmp/waitcap/slurm-77.out"; printf 'x%.0s' $(seq 1000) >> "$tmp/waitcap/slurm-77.out"
expect wait-output-cap ok '^lines 2[0-3] long 0$' -- bash -c "cd $tmp/waitcap && MOCK_SACCT_JOBS=$tmp/jobs77.psv && printf '77|COMPLETED|0:0|1m\n' > $tmp/jobs77.psv && out=\$(MOCK_SACCT_JOBS=$tmp/jobs77.psv GUARD_WAIT_DIR=$wd $guard wait 77) && echo lines \$(wc -l <<<\"\$out\") long \$(awk 'length > 300' <<<\"\$out\" | wc -l)"

# guard status lists the pid of a guard wait command still running.
env GUARD_WAIT_DIR="$wd" "$guard" wait --timeout 1s -- sleep 30 > "$tmp/bgwait.out"; bgpg=$(sed -n 's/^stop it: kill -- -//p' "$tmp/bgwait.out")
expect status-lists-wait-pid ok "^$bgpg\$" -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path; from verbs import status
print(",".join(status.local_facts()["waits"]))' "$here"
[ -z "$bgpg" ] || kill -- "-$bgpg" 2>/dev/null

# guard status: six lines under 1200 characters, next a command that obeys the line 2 rule.
facts='{"running": [{"id": "12", "run": "run-a", "state": "RUNNING", "elapsed": "0:04:10", "limit": "0:30:00"},
  {"id": "13", "run": "run-b", "state": "PENDING", "elapsed": "0:00:00", "limit": "1:00:00"}],
 "blocked": ["ask n3 waits for a person: more holdout submissions?"],
 "refusal": {"ago_min": 3, "where": "scheduler", "why": "H4R-R02 time 60 exceeds max_walltime_minutes 30"},
 "budget": {"spent": 12, "queued": 4, "max": 100, "reserve": 10}, "failed": null, "unsigned": false,
 "git": {"branch": "feat-a", "changed": 2, "ahead": 1, "behind": 0}, "waits": []}'
sy() { python3 -c 'import sys, json; sys.path.insert(0, sys.argv[1] + "/lib"); import _path; from verbs import status
exec(sys.argv[2])' "$here" "$1"; }
expect status-fixture-shape ok '^6 lines, [0-9]+ chars$' -- sy "
f = json.loads('''$facts''')
text = status.render(f)
lines = text.splitlines()
assert [l.split(':')[0] for l in lines] == ['running', 'blocked', 'last refusal', 'budget', 'git', 'next'], lines
assert len(text) <= 1200 and all(len(l) <= 190 for l in lines)
print(len(lines), 'lines,', len(text), 'chars')"
expect status-next-is-a-wait ok '^next: guard wait 12$' -- sy "print(status.render(json.loads('''$facts''')).splitlines()[-1])"
expect status-lists-both-jobs ok 'job 12 \(run-a\) RUNNING 0:04:10 of 0:30:00; job 13 \(run-b\) PENDING' -- sy "print(status.render(json.loads('''$facts''')))"
expect status-budget-line ok '^budget: 12 of 100 core-h spent, 4 queued, 74 left above the 10 reserve$' -- sy "print(status.render(json.loads('''$facts''')).splitlines()[3])"
expect status-next-rule-all-states ok '^ok$' -- sy "
import refusals
base = json.loads('''$facts''')
cases = [dict(base), dict(base, running=[], git={'branch': 'm', 'changed': 3, 'ahead': 0, 'behind': 0}),
         dict(base, running=[], git={'branch': 'm', 'changed': 0, 'ahead': 2, 'behind': 0}),
         dict(base, running=[], git={'branch': 'm', 'changed': 0, 'ahead': 0, 'behind': 4}),
         dict(base, running=[], git=None), dict(base, running=[], git={'branch': 'm', 'changed': 0, 'ahead': 0, 'behind': 0}),
         dict(base, running=[], waits=['4242']), dict(base, running=[], failed={'id': '9', 'run': 'r', 'state': 'TIMEOUT'})]
for c in cases:
    line = status.render(c).splitlines()[-1].split(': ', 1)[1]
    assert refusals.next_ok(line), line
print('ok')"
expect status-over-long-fields-stay-under-1200 ok '^ok$' -- sy "
f = json.loads('''$facts''')
f['running'] = [{'id': str(i), 'run': 'run-with-a-very-long-name-' + 'x' * 60, 'state': 'RUNNING', 'elapsed': '0:04:10', 'limit': '0:30:00'} for i in range(40)]
f['blocked'] = ['ask n%d waits for a person: ' % i + 'q' * 300 for i in range(9)]
f['refusal']['why'] = 'w' * 900
text = status.render(f)
assert len(text) <= 1200 and len(text.splitlines()) == 6
print('ok')"
expect status-receipts-on-the-git-line ok '^git: feat-a, 2 changed files, 1 commit ahead of origin/main, 0 behind; receipts: guard/receipts at 1a2b3c4d5e6f, signed by the broker$' -- sy "
f = json.loads('''$facts''')
f['receipts'] = 'receipts: guard/receipts at 1a2b3c4d5e6f, signed by the broker'
text = status.render(f)
assert len(text) <= 1200 and len(text.splitlines()) == 6
print(text.splitlines()[4])"
expect status-unsigned-in-local-mode ok 'unsigned: no broker' -- sy "
f = json.loads('''$facts''')
f['unsigned'] = True
print(status.render(f))"

# End to end: the broker's own status module over a real socket, a real Broker on a mock Slurm, and the CLI.
sdir=$tmp/status-e2e; mkdir -p "$sdir/sock" "$sdir/state"
git init -q --bare -b main "$sdir/origin.git"
git clone -q "$sdir/origin.git" "$sdir/seed" 2>/dev/null
( cd "$sdir/seed" && git checkout -q -b main && mkdir -p guard && printf 'account: acct\nstart_date: 2026-01-01\nstop_date: 2099-01-01\ncores_per_node: 8\nmax_walltime_minutes: 60\nmax_nodes_per_job: 1\nmax_concurrent_jobs: 4\nmax_core_hours: 100\nverification_reserve_core_hours: 10\n' > guard/budget.card && git add -A && git commit -q -m card && git push -q origin main )
printf '12|run-a|RUNNING|0:04:10|0:30:00\n13|run-b|PENDING|0:00:00|1:00:00\n' > "$sdir/rows.psv"
cat > "$sdir/serve.py" <<PY
import json, os, sys, time
sys.path.insert(0, "$here/lib"); import _path
import needs_you
from broker import scheduler, server
b = scheduler.Broker("$sdir/state", {"session": "s1", "project": "$sdir/seed", "paths": [["$sdir/seed", "$sdir/seed"]],
    "origin": "$sdir/origin.git", "slurm_bin": "$here/tests/mock-bin", "user": "tester",
    "slurm_env": {"MOCK_SACCT_ROWS": "$sdir/rows.psv", "MOCK_SACCT_CPUSECONDS": "43200", "MOCK_SQUEUE_PENDING": ""}})
for seq, job, run, session in ((1, "12", "run-a", "s1"), (2, "13", "run-b", "s1"), (3, "77", "run-c", "other")):
    b.write({"seq": seq, "state": "intent", "run": run, "comment": f"guard:{session}:{seq}", "session": session})
    b.write({"seq": seq, "state": "submitted", "job": job, "session": session})
b.write({"seq": 4, "state": "intent", "run": "run-h", "backend": "host", "comment": "guard:s1:4", "session": "s1"})
b.write({"seq": 4, "state": "submitted", "job": "skynet-20261019T120000Z", "session": "s1"})
from broker import host
host.state = lambda job, broker=None: "running" if broker is b and job == "skynet-20261019T120000Z" else None
item = needs_you.Item("n1", "2026-10-19T00:00:00Z", "open", "approve", "more holdout submissions?", "", "", "", "", "", [], [], "agent")
with open(b.records.queue, "w") as f: f.write(needs_you.to_row(item))
with open(b.records.log_path, "w") as f: f.write(json.dumps({"ts": time.time() - 180, "store": "scheduler", "refused": "H4R-R02 time 60 exceeds max_walltime_minutes 30"}) + "\n")
from broker import asks
asks.add(b, {"question": "extend it?", "default": "no", "deadline": "30m"})
asks.add(b, {"question": "ship it?", "default": "no", "deadline": "5m"})
asks.write(b, [{"event": "answered", "id": "a2", "answer": "yes", "by": "human"}])
s = server.bind("$sdir/sock/scheduler.sock", "scheduler", b)
open("$sdir/ready", "w").close()
s.serve_forever()
PY
python3 "$sdir/serve.py" > "$sdir/serve.log" 2>&1 & spid=$!
for _ in $(seq 100); do [ -e "$sdir/ready" ] && break; sleep 0.1; done
cd "$tmp/proj" || exit 1
# The first call shows the human's answer to a2 once; asks.report marks it seen, so no later call does.
first=$(env GUARD_SESSION=s1 GUARD_SOCK_DIR="$sdir/sock" "$guard" status)
expect status-e2e-asks-and-unseen-answer ok '^blocked: needs-you n1 waits for a person: more holdout submissions\?; ask a1 waits for a person, 30 min left, then no: extend it\?; ask a2 answered by a person: yes$' -- printf '%s\n' "$first"
st() { env GUARD_SESSION=s1 GUARD_SOCK_DIR="$sdir/sock" "$guard" status; }
expect status-e2e-six-lines ok '^6$' -- bash -c "$(declare -f st); guard='$guard'; sdir='$sdir'; st | wc -l"
expect status-e2e-running ok '^running: job 12 \(run-a\) RUNNING 0:04:10 of 0:30:00; job 13 \(run-b\) PENDING' -- st
expect status-e2e-asks-answer-shown-once ok '^blocked: needs-you n1 waits for a person: more holdout submissions\?; ask a1 waits for a person, 30 min left, then no: extend it\?$' -- st
expect status-e2e-needs-you-hides-ask-ids ok '^0$' -- bash -c "$(declare -f st); guard='$guard'; sdir='$sdir'; st | grep -c 'needs-you a[0-9]' || true"
expect status-e2e-refusal ok '^last refusal: 3 min ago, scheduler: H4R-R02 time 60' -- st
expect status-e2e-budget ok '^budget: 12 of 100 core-h spent, 0 queued, 78 left above the 10 reserve$' -- st
expect status-e2e-git ok '^git: main, [0-9]+ changed files?, [0-9]+ commits? ahead of origin/main, [0-9]+ behind; receipts: ' -- st
expect status-e2e-receipts ok '^git: main, .* behind; receipts: (local, unsigned|none published yet|guard/receipts at )' -- st
expect status-e2e-next ok '^next: guard wait 12$' -- st
expect status-e2e-under-1200 ok '^ok$' -- bash -c "$(declare -f st); guard='$guard'; sdir='$sdir'; n=\$(st | wc -c); [ \$n -le 1200 ] && echo ok"
ask_mine() { env GUARD_SESSION=s1 GUARD_SOCK_DIR="$sdir/sock" python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path
from broker import transport
print(transport.send({"verb": "status", "job": sys.argv[2]})["out"])' "$here" "$1"; }
expect status-job-mine ok '^\{"mine": true\}$' -- ask_mine 12
expect status-job-of-another-session ok '^\{"mine": false\}$' -- ask_mine 77
expect status-job-nobody-knows ok '^\{"mine": null\}$' -- ask_mine 5
expect status-hides-another-sessions-job ok '^0$' -- bash -c "$(declare -f st); guard='$guard'; sdir='$sdir'; st | grep -c 'job 77' || true"
expect status-lists-a-host-job ok '^running: .*; job skynet-20261019T120000Z \(run-h\) RUNNING' -- st
expect status-host-job-is-the-wait-target-after-slurm ok '^next: guard wait 12$' -- st
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
expect_refusal status-broker-down R15 -- env GUARD_SESSION=s1 GUARD_SOCK_DIR="$sdir/sock" "$guard" status
expect status-local-mode-says-unsigned ok 'unsigned: no broker' -- env -u GUARD_SESSION GUARD_SOCK_DIR="$sdir/none" "$guard" status
cd "$tmp" || exit 1

# A launch host has no slurm_bin: spend is zero there, not a TypeError from Broker.slurm.
expect status-spend-no-slurm-bin ok '^\(0, 0\)$' -- wpy '
import types
from broker import scheduler, status
b = types.SimpleNamespace(cfg={"user": "u", "slurm_bin": None})
b.slurm = scheduler.Broker.slurm.__get__(b)
print(status.spend(b, types.SimpleNamespace(account="a", start_date="2026-01-01")))'
