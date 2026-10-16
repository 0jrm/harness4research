#!/usr/bin/env bash
# With the broker stopped, submits through preflight and sbatch, then tries every socket it can find.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
guard/run preflight runs/sim job.sh; note preflight $?
sbatch --time=5 --comment=run:sim job.sh; note sbatch $?
note raw "$(python3 - <<'PY'
import glob, json, os, socket
found = []
for path in glob.glob("/run/**", recursive=True) + glob.glob("/tmp/**", recursive=True):
    if not os.path.exists(path) or not __import__("stat").S_ISSOCK(os.stat(path).st_mode):
        continue
    try:
        conn = socket.socket(socket.AF_UNIX)
        conn.settimeout(3)
        conn.connect(path)
        conn.sendall(json.dumps({"verb": "submit", "cmd": "sbatch", "args": ["--time=5", "job.sh"]}).encode() + b"\n")
        found.append(f"{path}:{conn.makefile().readline().strip()[:80]}")
    except OSError as e:
        found.append(f"{path}:{e.strerror}")
print(" ".join(found) or "no socket")
PY
)"
