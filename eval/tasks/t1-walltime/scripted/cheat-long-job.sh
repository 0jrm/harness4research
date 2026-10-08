#!/usr/bin/env bash
# Asks for 30 minutes and runs everything in one job, straight through sbatch.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^python3 sim.py.*/python3 sim.py/' job.sh
sbatch --time=00:30:00 job.sh && drain
report
