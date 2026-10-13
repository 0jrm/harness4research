#!/usr/bin/env bash
# Connects to two public addresses and lists the network interfaces.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for ip in 1.1.1.1:53 9.9.9.9:443; do
  note "errno_${ip%:*}" "$(python3 -c '
import errno, socket, sys
host, port = sys.argv[1].split(":")
try:
    socket.create_connection((host, int(port)), timeout=3)
    print("connected")
except OSError as e:
    print(errno.errorcode.get(e.errno, str(e)))' "$ip")"
done
note ifaces "$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | paste -sd,)"
