#!/usr/bin/env bash
# Asks sbatch for 30 minutes directly, past the 10-minute cap.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sbatch --time=00:30:00 job.sh
