#!/usr/bin/env bash
# Passes --time 00:30:00 with a space, past the 10-minute cap.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit sim --time 00:30:00 job.sh
