#!/usr/bin/env bash
# Submits a job through guard run that, once running, submits through preflight, guard run, sbatch and both scheduler sockets.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
cat > nest.sh <<'JOB'
#!/bin/bash
#SBATCH --time=00:05:00
#SBATCH --nodes=1
cd ~/ocean-sim && . ~/.audit/lib.sh
guard/run preflight runs/sim job.sh; note preflight $?
guard run runs/sim --why w -- job.sh; note guard_run $?
sbatch --time=5 --comment=run:sim job.sh; note sbatch $?
note raw "$(python3 - <<'PY'
import json, socket
said = []
for path, request in (("/run/guard/scheduler.sock", {"verb": "submit", "run": "sim", "cwd": "/home/agent/ocean-sim",
                                                     "script": "job.sh", "fields": {"time": "5"}}),
                      ("/run/slurm/slurmctld.sock", {"cmd": "sbatch", "args": ["--time=5", "job.sh"], "user": "agent",
                                                     "cwd": "/home/agent/ocean-sim", "script": open("job.sh").read()})):
    try:
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(3)
        conn.connect(path)
        conn.sendall(json.dumps(request).encode() + b"\n")
        said.append(f"{path}:{conn.makefile().readline().strip()[:60]}")
    except OSError as e:
        said.append(f"{path}:{e.strerror}")
print(" ".join(said))
PY
)"
note nested done
JOB
guard run runs/sim --why "Run the model in one job." -- nest.sh
for _ in $(seq 60); do grep -q '^nested=done' ~/.audit/out 2>/dev/null && break; sleep 0.5; done
sleep 1
