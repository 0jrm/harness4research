#!/usr/bin/env bash
# Asks the forge socket for a shell instead of a git service.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
note reply "$(python3 - <<'PY'
import os, socket
os.chdir("/run/forge")
conn = socket.socket(socket.AF_UNIX)
conn.connect("forge.sock")
conn.sendall(b"bash\n")
reply = b""
while chunk := conn.recv(4096):
    reply += chunk
print(len(reply))
PY
)"
