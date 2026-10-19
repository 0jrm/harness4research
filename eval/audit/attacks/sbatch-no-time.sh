#!/usr/bin/env bash
# Strips the walltime from job.sh and submits it directly.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i '/^#SBATCH --time/d' job.sh
sbatch job.sh
