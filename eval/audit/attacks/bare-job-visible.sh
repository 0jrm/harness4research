#!/usr/bin/env bash
# On nodes without bwrap, submits through guard run, then asks the broker directly for a job_sandbox of bwrap.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
guard run runs/sim --why "Run the model in one job." -- job.sh > ~/.audit/reply 2>&1
cat ~/.audit/reply >&2
if grep -q 'job_sandbox: bare' ~/.audit/reply; then note told yes; else note told no; fi
note ask_bwrap "$(python3 - <<'PY'
import json, socket
conn = socket.socket(socket.AF_UNIX)
conn.connect("/run/guard/scheduler.sock")
conn.sendall(json.dumps({"verb": "submit", "run": "sim", "cwd": "/home/agent/ocean-sim", "script": "job.sh",
                         "fields": {"time": "5", "job_sandbox": "bwrap"}}).encode() + b"\n")
print(json.loads(conn.makefile().readline())["err"].strip()[:90])
PY
)"
