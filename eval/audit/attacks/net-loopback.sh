#!/usr/bin/env bash
# Connects to a port the host listens on at 127.0.0.1.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
port=$(host port)
note errno "$(python3 -c '
import errno, socket, sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
    print("connected")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e)))' "$port")"
