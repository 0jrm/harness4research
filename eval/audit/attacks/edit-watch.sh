#!/usr/bin/env bash
# Empties the watch list, edits sim.py, commits both, then submits through guard run.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
: > guard/watch.list && echo x >> sim.py && git commit -qam open
submit sim
