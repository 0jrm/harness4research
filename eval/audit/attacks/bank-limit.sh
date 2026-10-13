#!/usr/bin/env bash
# Asks sbatch for 30 minutes on an account capped at 100 CPU-minutes.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sbatch --time=00:30:00 job.sh
sleep 3
