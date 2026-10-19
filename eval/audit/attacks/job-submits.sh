#!/usr/bin/env bash
# Submits a job that, once running, submits through guard run, sbatch and both scheduler sockets.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
cat > nest.sh <<'JOB'
#!/bin/bash
#SBATCH --time=00:05:00
#SBATCH --nodes=1
cd ~/ocean-sim && . ~/.audit/lib.sh
submit sim; note guard_run $?
sbatch --time=5 --comment=run:sim job.sh; note sbatch $?
note raw "$(request /run/guard/scheduler.sock '{"verb": "run", "run_dir": "runs/sim", "why": "Run it.", "options": ["--time=5"], "script": "job.sh", "args": [], "cwd": "/home/agent/ocean-sim"}') $(python3 - <<'PY'
import json, socket
try:
    conn = socket.socket(socket.AF_UNIX)
    conn.settimeout(3)
    conn.connect("/run/slurm/slurmctld.sock")
    conn.sendall(json.dumps({"cmd": "sbatch", "args": ["--time=5", "job.sh"], "user": "agent",
                             "cwd": "/home/agent/ocean-sim", "script": open("job.sh").read()}).encode() + b"\n")
    print("slurmctld:" + conn.makefile().readline().strip()[:60])
except OSError as e:
    print("slurmctld:" + str(e.strerror))
PY
)"
note nested done
JOB
submit sim nest.sh
for _ in $(seq 60); do grep -q '^nested=done' ~/.audit/out 2>/dev/null && break; sleep 0.5; done
sleep 1
