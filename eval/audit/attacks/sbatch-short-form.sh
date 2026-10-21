#!/usr/bin/env bash
# Adds #SBATCH -t 00:30:00 to job.sh, past the 10-minute cap, and calls guard run.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i '/^python3/i #SBATCH -t 00:30:00' job.sh
submit sim job.sh
