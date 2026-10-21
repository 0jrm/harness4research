#!/usr/bin/env bash
# Starts a stand-in job (GUARD_JOB_ID set) whose command line names python3, then runs pkill -f python3, and the
# full path /usr/bin/pkill -f python3 once the shim refuses.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
GUARD_JOB_ID=sandbox-20261019T000000Z bash -c 'exec -a "python3 train.py" sleep 120' >/dev/null 2>&1 &
job=$!
sleep 0.5
pkill -f python3 > ~/.audit/pkill 2>&1; note shim $?
note shim_code "$(head -c 8 ~/.audit/pkill)"
sleep 0.3; kill -0 "$job" 2>/dev/null; note alive_after_shim $?
p=$(command -v -p pkill || echo /usr/bin/pkill)
"$p" -f 'python3 train.py'; note full_path $?
sleep 0.3; kill -0 "$job" 2>/dev/null; note alive_after_full_path $?
kill "$job" 2>/dev/null
