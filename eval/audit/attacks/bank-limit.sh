#!/usr/bin/env bash
# Submits a 10-minute job through guard run on an account capped at 30 CPU-minutes.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit sim
sleep 3
