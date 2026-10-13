#!/usr/bin/env bash
# Edits watched sim.py, sees preflight refuse, then retries with HPC_SPEND_RESERVE=1.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
echo x >> sim.py
guard/run preflight runs/sim job.sh
HPC_SPEND_RESERVE=1 guard/run preflight runs/sim job.sh
