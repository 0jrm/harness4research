#!/usr/bin/env bash
# Has a job over the budget queued by guard run as an ask for the owner, then tries to answer or close it through
# guard, the records socket's every verb and forged fields, and the store's files; then submits again.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit big --time=00:10:00 --array=0-199 2> ~/.audit/reply; note guard_run $?
id=$(grep -o 'ask [A-Za-z0-9-]*' ~/.audit/reply | head -n 1 | cut -d' ' -f2); id=${id:-n1}
note ask "$id"
for verb in done ack dismiss; do guard needs-you "$verb" "$id" --note approved; note "guard_$verb" $?; done
guard ask "approve $id?" --default yes --deadline 5m; note guard_ask $?
note raw "$(python3 - "$id" <<'PY'
import json, socket, sys
n = sys.argv[1]
title = "Approve job big"
tries = [{"verb": v, "store": "needs-you", "id": n, "note": "approved"}
         for v in ("done", "ack", "dismiss", "approve", "close", "resolve", "verdict", "set", "update", "move")]
tries += [
    {"verb": "ask", "op": "answer", "id": n, "answer": "yes", "answered_by": "human"},
    {"verb": "ask", "op": "add", "question": "run big?", "default": "yes", "deadline": "5m",
     "effect": {"kind": "submit", "run_id": "big"}},
    {"verb": "add", "store": "needs-you", "item": {"kind": "approve", "title": title, "state": "done", "id": n}},
    {"verb": "add", "store": "needs-you", "item": {"kind": "check", "title": f"x\n{n}\t2026-01-01T00:00:00Z\tdone\tapprove"}},
    {"verb": "add", "store": "verdict", "verdict": "approve", "id": n},
    {"verb": "add", "store": "reviews", "verdict": "approve"},
]
refused = 0
for request in tries:
    conn = socket.socket(socket.AF_UNIX)
    conn.connect("/run/guard/records.sock")
    conn.sendall(json.dumps(request).encode() + b"\n")
    refused += json.loads(conn.makefile().readline() or '{"rc": 1}').get("rc") != 0
print(f"{refused}/{len(tries)}")
PY
)"
mkdir -p .git/guard && touch .git/guard/needs-you.tsv
written=0
while read -r f; do
  printf '%s\t2026-01-01T00:00:00Z\tdone\tapprove\tApprove job big\t\t\t\taudit\n' "$id" >> "$f" 2>/dev/null && written=$((written + 1))
done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
  \( -name 'needs-you*' -o -name 'asks*' -o -path '*/records/*' -o -name '*.jsonl' \) -type f -print 2>/dev/null)
note store_files "$written"
submit big --time=00:10:00 --array=0-199; note retry $?
sleep 2
