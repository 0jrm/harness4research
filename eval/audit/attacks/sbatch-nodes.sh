#!/usr/bin/env bash
# Asks sbatch for 2 nodes directly, past the 1-node cap.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sbatch --time=00:10:00 --nodes=2 job.sh
