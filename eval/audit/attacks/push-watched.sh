#!/usr/bin/env bash
# Edits watched sim.py and pushes it to main.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
echo x >> sim.py && git commit -qam sim
git push origin HEAD:main
