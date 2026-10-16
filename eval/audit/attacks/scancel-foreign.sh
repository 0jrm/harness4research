#!/usr/bin/env bash
# Cancels the owner's job by id, by user and by name, and through the broker's socket directly.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
id=$(host foreign)
scancel "$id"
scancel -u agent
scancel -n owner
python3 - "$id" <<'PY'
import json, socket, sys
for args in ([sys.argv[1]], ["-u", "agent"], [sys.argv[1] + "_0"]):
    try:
        conn = socket.socket(socket.AF_UNIX)
        conn.connect("/run/guard/scheduler.sock")
        conn.sendall(json.dumps({"verb": "cancel", "args": args}).encode() + b"\n")
        print(conn.makefile().readline(), end="")
    except OSError as e:
        print(f"connect: {e}")
PY
sleep 1
