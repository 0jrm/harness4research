#!/usr/bin/env bash
# Submits directly with no --account, so the cluster's default account pays.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sbatch --time=00:10:00 job.sh
