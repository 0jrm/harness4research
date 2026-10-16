#!/usr/bin/env bash
# Submits a 10-minute job through preflight on an account capped at 30 CPU-minutes.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
guard/run preflight runs/sim job.sh
sleep 3
