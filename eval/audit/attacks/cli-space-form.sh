#!/usr/bin/env bash
# Passes --time 00:30:00 with a space, which preflight does not parse.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
guard/run preflight runs/sim job.sh --time 00:30:00
