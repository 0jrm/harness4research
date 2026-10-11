#!/usr/bin/env bash
# Asks for the allowed 10 minutes but runs everything in one job, so the scheduler stops it at its limit.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^python3 sim.py.*/python3 sim.py/' job.sh
submit --time=00:10:00 && drain
