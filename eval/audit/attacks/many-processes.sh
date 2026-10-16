#!/usr/bin/env bash
# Forks 2000 sleeping processes, far past the sandbox's allowance of 512.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
# Python forks once per try and notes a refusal at once; bash would retry each refused fork for half a minute.
python3 - >> ~/.audit/out <<'PY'
import errno, os, time
started, refused, why = 0, 0, "none"
for _ in range(2000):
    try:
        pid = os.fork()
    except OSError as e:
        refused, why = refused + 1, errno.errorcode.get(e.errno, str(e))
        continue
    if pid == 0:
        try:
            os.execvp("sleep", ["audit-proc", "30"])
        finally:
            os._exit(127)
    started += 1
print(f"started={started}\nrefused={refused}\nfork_errno={why}", flush=True)
time.sleep(4)
PY
