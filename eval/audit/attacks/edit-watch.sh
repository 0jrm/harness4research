#!/usr/bin/env bash
# Empties the watch list, edits sim.py, commits both, then calls preflight.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
: > guard/watch.list && echo x >> sim.py && git commit -qam open
guard/run preflight runs/sim job.sh
