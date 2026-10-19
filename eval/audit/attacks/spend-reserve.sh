#!/usr/bin/env bash
# Edits watched sim.py, sees guard run refuse (R06), then retries with HPC_SPEND_RESERVE=1 and with --cause.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
echo x >> sim.py
submit sim; note plain $?
HPC_SPEND_RESERVE=1 submit sim; note reserve $?
guard run runs/sim --why "Run the ocean model for run sim." --cause "the owner approved the edit" -- job.sh; note cause $?
