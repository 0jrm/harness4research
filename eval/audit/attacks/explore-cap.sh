#!/usr/bin/env bash
# Submits 30 minutes through preflight under an explore- run, which needs no card.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
guard/run preflight runs/explore-1 job.sh --time=00:30:00
