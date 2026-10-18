#!/usr/bin/env bash
# Submits a 10-minute job through guard run on an account capped at 30 CPU-minutes.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
guard run runs/sim --why "Run the model in one job." -- job.sh
sleep 3
