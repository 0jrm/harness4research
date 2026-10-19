# shellcheck shell=bash
# Sourced by tests/run.sh: U4's guard ask, the broker's effect asks and the scripted approver. Light: one broker
# process on a socket in $tmp, a mocked clock, no sandbox.
echo "== ask"
ask=$here/lib/verbs/ask.py
askd=$tmp/askd.py
cat > "$askd" <<'PY'
#!/usr/bin/env python3
# askd.py <state> <sock_dir> <clock file|real> [approver]: a broker with the records socket, ask's module and a stand-in
# broker.run whose redecide answers what <state>/redecide.json says and notes each call in <state>/redecided.jsonl.
import json, os, sys, types
here, state, sock_dir, clockfile = os.environ["HERE"], *sys.argv[1:4]
sys.path.insert(0, os.path.join(here, "lib")); sys.path.insert(0, os.path.join(here, "eval", "broker"))
import _path
from broker import asks, scheduler, server
asks.ATTEND_SECONDS = 0.2
cfg = {"session": "s1", "project": sock_dir, "paths": [[sock_dir, sock_dir]], "origin": sock_dir + "/none.git",
       "slurm_bin": None}
if len(sys.argv) > 4:
    cfg["approver"] = sys.argv[4]
broker = scheduler.Broker(state, cfg)
if clockfile != "real":
    broker.clock = lambda: float(open(clockfile).read())
fake = types.ModuleType("broker.run")
def redecide(b, effect):
    with open(os.path.join(state, "redecided.jsonl"), "a") as f:
        f.write(json.dumps(effect) + "\n")
    return json.load(open(os.path.join(state, "redecide.json")))
fake.redecide = redecide
sys.modules["broker.run"] = fake
os.makedirs(sock_dir, exist_ok=True)
s = server.bind(os.path.join(sock_dir, "records.sock"), "records", broker)
open(os.path.join(sock_dir, "ready"), "w").close()
s.serve_forever()
PY
# $1 = state dir (named as lib/broker_host.py names a project's state, so guard needs-you finds its queue)
askproj=$tmp/ask-proj; git init -q -b main "$askproj"; git -C "$askproj" commit -q --allow-empty -m init
export XDG_STATE_HOME=$tmp/ask-xdg
askstate=$XDG_STATE_HOME/guard/projects/$(python3 -c 'import hashlib, os, sys; p = os.path.realpath(sys.argv[1]); print(os.path.basename(p) + "-" + hashlib.sha1(p.encode()).hexdigest()[:8])' "$askproj")
mkdir -p "$askstate"
asock=$tmp/ask-sock; clk=$tmp/ask-clock; echo 1000000 > "$clk"
echo '{"rc": 0, "out": "job 77 submitted for run r1\n"}' > "$askstate/redecide.json"
HERE=$here python3 "$askd" "$askstate" "$asock" "$clk" & askpid=$!
for _ in $(seq 50); do [ -e "$asock/ready" ] && break; sleep 0.1; done
agent() { env GUARD_SOCK_DIR="$asock" GUARD_SESSION=s1 "$ask" "$@"; }
human() { (cd "$askproj" && "$guard" needs-you "$@"); }
firstline() { { "$@" 2>&1 || :; } | head -1; }
lastline() { { "$@" 2>&1 || :; } | tail -1; }
tick() { echo $(( $(cat "$clk") + $1 )) > "$clk"; }
wire() {  # wire <json>: one raw request to the records socket, as a hostile agent could send it
  env GUARD_SOCK_DIR="$asock" GUARD_SESSION=s1 python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path
from broker import transport
r = transport.send(json.loads(sys.argv[2]), "records")
sys.stdout.write(r.get("out", "")); sys.stderr.write(r.get("err", "")); sys.exit(r["rc"])' "$here" "$1"
}
state_py() {  # state_py <code>: python against the broker's state, a second Broker object over the same files
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path, json
from broker import asks, scheduler
b = scheduler.Broker(sys.argv[2], {"session": "s1", "project": "/x", "paths": [], "origin": "/x", "slurm_bin": None})
b.clock = lambda: float(open(sys.argv[3]).read())
exec(sys.argv[4])' "$here" "$askstate" "$clk" "$1"
}

expect ask-waits ok '^ask a1 waits for the human, 5 min left; then the default: no\. ' -- \
  agent "Extend the stop date?" --default no --deadline 5m
expect ask-same-question-same-id ok '^ask a1 waits' -- agent Extend the stop date? --default no --deadline 5m
expect ask-unquoted-question-joins ok '^ask a2 waits' -- agent Use the larger model? --default yes --deadline=30m
expect ask-offered-words ok '^ask a3 waits.*the default: small' -- agent "Which size [small|large]?" --default small --deadline 2h
expect_refusal ask-a01-no-question A01 -- agent --default no --deadline 5m
expect_refusal ask-a02-no-default A02 -- agent "Is it ok?" --deadline 5m
expect_refusal ask-a02-word-not-offered A02 -- agent "Which size [small|large]?" --default medium --deadline 5m
expect ask-a02-line2-runs ok "^guard ask 'Is it ok\\?' --default no --deadline 5m\$" -- lastline agent "Is it ok?" --deadline 5m
expect_refusal ask-a03-deadline A03 -- agent "Is it ok?" --default no --deadline 20m
expect ask-a03-nearest ok "^guard ask 'Is it ok\\?' --default no --deadline 30m\$" -- lastline agent "Is it ok?" --default no --deadline 20m
expect_refusal ask-a04-unknown-id A04 -- agent --status a99
expect ask-a04-names-open ok 'open: a1 a2 a3$' -- firstline agent --status a99
expect ask-status ok '^ask a1 waits for the human, 5 min left' -- agent --status a1
expect_refusal ask-r15-broker-down R15 -- env GUARD_SOCK_DIR="$tmp/nosock" GUARD_SESSION=s1 "$ask" "Is it ok?" --default no --deadline 5m

# The agent cannot make an effect ask, set its default, or answer anything: the wire verb has no such field or action.
before=$(wc -l < "$askstate/records/needs-you.tsv")
expect_refusal ask-wire-effect-refused A01 -- wire '{"verb": "ask", "action": "add", "question": "Run it?", "default": "yes", "deadline": "5m", "effect": {"kind": "submit", "run_id": "r1"}}'
expect_refusal ask-wire-answer-refused A01 -- wire '{"verb": "ask", "action": "answer", "id": "a1", "answer": "yes"}'
expect_refusal ask-wire-extra-key-refused A01 -- wire '{"verb": "ask", "action": "show", "id": "a1", "answered_by": "human"}'
expect ask-wire-wrote-nothing ok "^$before\$" -- bash -c 'wc -l < "$1"' _ "$askstate/records/needs-you.tsv"

# A deadline with nobody answering: the default, taken unattended, recorded, and shown by the next report (guard status).
tick 301
expect ask-report-shows-unattended ok '^ask a1: nobody answered by 13:5[0-9] UTC, so the default was taken unattended: no\. Proceed' -- state_py 'print("\n".join(l for l in asks.report(b) if "unattended" in l))'
expect ask-report-shows-once ok '^0$' -- state_py 'print(sum("unattended" in l for l in asks.report(b)))'
expect ask-report-lists-open-asks ok 'ask a2 waits for the human' -- state_py 'print("\n".join(asks.report(b)))'
expect ask-report-short ok '^ask a2 waits for a person, [0-9]+ min left, then yes: Use the larger model\?$' -- state_py 'print("\n".join(asks.report(b, asks.short)))'
expect ask-unattended-status ok '^ask a1: nobody answered by 13:5[0-9] UTC, so the default was taken unattended: no\. Proceed' -- agent --status a1
expect ask-unattended-record ok '"by": "unattended"' -- grep '"id": "a1", "answer"' "$askstate/records/asks.jsonl"
expect ask-agent-ask-has-no-effect fail - -- test -e "$askstate/redecided.jsonl"

# A person answers outside the sandbox: guard needs-you lists, shows and closes the broker's asks beside the project's.
echo 1000000 > "$clk"
agent "Ship it?" --default no --deadline 30m >/dev/null
expect ask-needs-you-lists ok '🩺 a4 · approve · Ship it\?' -- human
expect ask-needs-you-remind ok '^🩺 [0-9]+ items? in .* need' -- bash -c 'cd "$1" && "$2" needs-you --remind --format text' _ "$askproj" "$guard"
expect ask-needs-you-shows-answer-command ok 'guard needs-you done a4 --note ANSWER' -- human show a4
expect ask-human-done ok '^a4 done$' -- human done a4 --note 'ship it, but only the small one'
expect ask-human-answer ok '^ask a4 answered by the human: ship it, but only the small one\. Act on it\.$' -- agent --status a4
expect ask-human-record ok '"by": "human"' -- grep '"id": "a4", "answer"' "$askstate/records/asks.jsonl"
expect ask-human-dismiss-is-no ok '^ask a3 answered by the human: no: too big\. Act on it\.$' -- bash -c 'cd "$1" && "$2" needs-you dismiss a3 --note "too big" >/dev/null && env GUARD_SOCK_DIR="$3" GUARD_SESSION=s1 "$4" --status a3' _ "$askproj" "$guard" "$asock" "$ask"
expect ask-project-items-stay-n ok '^n1$' -- human add --kind check --title Mine --why x
expect ask-project-item-closes ok '^n1 done$' -- human done n1

# The broker's effect asks: default no, one open per run, a yes decides again with the pinned sha, a refusal answers.
echo '{"rc": 0, "out": "job 77 submitted for run r1\n"}' > "$askstate/redecide.json"
effect() {  # effect <code>: python against the broker's state with asks' create_effect, as U2's run module calls it
  state_py "$1"
}
expect effect-created-no-default ok "^a[0-9]+ no 30m submit r1 abc123$" -- effect '
a = asks.create_effect(b, "submit", "r1", "Run r1: 150 core-h is over the remaining 100; submit it?", "abc123", {"time_min": 30}, "30m")
print(a["id"], a["default"], a["deadline"], a["effect"]["kind"], a["effect"]["run_id"], a["effect"]["script_sha256"])'
expect effect-one-open-per-run ok '^True 1$' -- effect '
a = asks.open_effect(b, "r1"); c = asks.create_effect(b, "submit", "r1", "again?", "def456", {}, "30m")
print(a["id"] == c["id"], len([x for x in asks.open_asks(b, "r1")]))'
expect effect-other-run-separate ok '^True$' -- effect '
a = asks.create_effect(b, "submit", "r2", "Run r2?", "aaa", {}, "30m"); print(a["id"] != asks.open_effect(b, "r1")["id"])'
expect effect-needs-you-item ok 'open.approve.Run r1: 150 core-h is over' -- grep 'Run r1: 150' "$askstate/records/needs-you.tsv"
eid=$(state_py 'print(asks.open_effect(b, "r1")["id"])')
human done "$eid" --note "go ahead" >/dev/null
expect effect-yes-redecides-pinned ok '^ask a[0-9]+ answered by the human: yes: job 77 submitted for run r1' -- agent --status "$eid"
expect effect-redecided-with-pin ok '"script_sha256": "abc123"' -- cat "$askstate/redecided.jsonl"
expect effect-answered-frees-the-run ok '^None$' -- effect 'print(asks.open_effect(b, "r1"))'
echo '{"rc": 3, "err": "H4R-R08 150 core-h is over the remaining 100; queued as ask a9, default no at 11:30 UTC\nguard status\n"}' > "$askstate/redecide.json"
eid2=$(state_py 'print(asks.create_effect(b, "submit", "r1", "Run r1 again?", "abc123", {}, "30m")["id"])')
human done "$eid2" >/dev/null
expect effect-refusal-answers-ask ok '^ask a[0-9]+ answered by the human: H4R-R08 150 core-h is over the remaining 100' -- agent --status "$eid2"
expect effect-refusal-answer-recorded ok '"answer": "H4R-R08 150 core-h.*guard status' -- grep "\"id\": \"$eid2\", \"answer\"" "$askstate/records/asks.jsonl"
n_calls=$(wc -l < "$askstate/redecided.jsonl")
eid3=$(state_py 'print(asks.create_effect(b, "submit", "r3", "Run r3?", "ccc", {}, "30m")["id"])')
human dismiss "$eid3" >/dev/null
expect effect-no-does-not-redecide ok "^ask $eid3 answered by the human: no\\. Act on it\\.$" -- agent --status "$eid3"
expect effect-no-calls-nothing ok "^$n_calls\$" -- bash -c 'wc -l < "$1"' _ "$askstate/redecided.jsonl"
eid4=$(state_py 'print(asks.create_effect(b, "submit", "r4", "Run r4?", "ddd", {}, "5m")["id"])')
tick 301
expect effect-deadline-is-no ok "^ask $eid4: nobody answered by .*the default was taken unattended: no\\. Proceed" -- agent --status "$eid4"
expect effect-deadline-calls-nothing ok "^$n_calls\$" -- bash -c 'wc -l < "$1"' _ "$askstate/redecided.jsonl"
expect effect-kind-checked fail 'effect kind .bogus.' -- effect 'asks.create_effect(b, "bogus", "r5", "q?", None, {}, "5m")'
expect effect-module-missing-is-x00 ok 'H4R-X00 an answer of yes to a submit ask is not built' -- effect '
asks.EFFECT_MODULE["submit"] = "absent"; print(asks.redecide(b, {"kind": "submit", "run_id": "r1"})["err"])'

kill "$askpid"; wait "$askpid" 2>/dev/null

# The scripted approver, in a second broker on the real clock: after:1 closes a queued ask once a second has passed.
asock2=$tmp/ask-sock2; astate2=$tmp/ask-state2; mkdir -p "$astate2"
echo '{"rc": 0, "out": "job 5 submitted for run r1\n"}' > "$astate2/redecide.json"
HERE=$here python3 "$askd" "$astate2" "$asock2" real after:1 & askpid2=$!
for _ in $(seq 50); do [ -e "$asock2/ready" ] && break; sleep 0.1; done
agent2() { env GUARD_SOCK_DIR="$asock2" GUARD_SESSION=s1 "$ask" "$@"; }
expect approver-ask-queued ok '^ask a1 waits for the human' -- agent2 "Raise the cap?" --default no --deadline 2h
waited=""; for _ in $(seq 60); do waited=$(agent2 --status a1); case $waited in *waits*) sleep 0.5 ;; *) break ;; esac; done
expect approver-answers ok '^ask a1 answered by the human: approved \(scripted approver, after 1 s\)\. Act on it\.$' -- echo "$waited"
expect approver-logged ok '"approver": "a1"' -- grep approver "$astate2/records/log.jsonl"
state2() {
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path
from broker import asks, scheduler
b = scheduler.Broker(sys.argv[2], {"session": "s1", "project": "/x", "paths": [], "origin": "/x", "slurm_bin": None})
exec(sys.argv[3])' "$here" "$astate2" "$1"
}
eid5=$(state2 'print(asks.create_effect(b, "submit", "r1", "Run r1?", "eee", {}, "2h")["id"])')
waited=""; for _ in $(seq 60); do waited=$(agent2 --status "$eid5"); case $waited in *waits*) sleep 0.5 ;; *) break ;; esac; done
expect approver-yes-on-effect ok 'answered by the human: yes: job 5 submitted for run r1' -- echo "$waited"
kill "$askpid2"; wait "$askpid2" 2>/dev/null
expect approver-delay-after ok '^300 None$' -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); sys.path.insert(0, sys.argv[1] + "/eval/broker"); import _path, approver
print(approver.delay("after:300"), approver.delay("never"))' "$here"
expect approver-delay-refuses ok "approver 'after:soon' is never or after:<seconds>" -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); sys.path.insert(0, sys.argv[1] + "/eval/broker"); import _path, approver
try: approver.delay("after:soon")
except SystemExit as e: print(e)' "$here"
printf '%s\n' '{"approver": "sometimes", "matrix": {"families": ["t1-walltime"], "variants": ["trap"], "arms": ["E"], "seeds": [1], "order_seed": 1}}' > "$tmp/run-cfg.json"
expect run-refuses-bad-approver fail "run.py: approver 'sometimes' is never or after:<seconds>" -- python3 "$here/eval/run.py" "$tmp/run-cfg.json"

# Local mode (decision 8): no socket, no GUARD_SESSION; the ask is the project's own broker record, and a person closes it.
lp=$tmp/ask-local; git init -q -b main "$lp"; git -C "$lp" commit -q --allow-empty -m init
lask() { (cd "$lp" && env -u GUARD_SESSION GUARD_SOCK_DIR="$tmp/nosock" "$ask" "$@"); }
lhuman() { (cd "$lp" && "$guard" needs-you "$@"); }
expect ask-local-waits ok '^ask a1 waits for the human, 5 min left' -- lask "Extend the stop date?" --default no --deadline 5m
expect_refusal ask-local-a02 A02 -- lask "Extend?" --deadline 5m
expect ask-local-via-bin-guard ok '^ask a2 waits for the human, 30 min left; then the default: yes' -- bash -c 'cd "$1" && env -u GUARD_SESSION GUARD_SOCK_DIR="$3/nosock" "$2" ask "Use the larger model?" --default yes --deadline 30m' _ "$lp" "$guard" "$tmp"
expect ask-local-human-sees ok '🩺 a1 · approve · Extend the stop date\?' -- lhuman
expect ask-local-answered ok '^ask a1 answered by the human: yes\. Act on it\.$' -- bash -c 'cd "$1" && "$2" needs-you done a1 >/dev/null && env -u GUARD_SESSION GUARD_SOCK_DIR="$3/nosock" "$4" --status a1' _ "$lp" "$guard" "$tmp" "$ask"

unset XDG_STATE_HOME
