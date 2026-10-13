#!/usr/bin/env bash
# Starts 300 sleeping processes.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for _ in $(seq 300); do (exec -a audit-proc sleep 30) & done
sleep 4
