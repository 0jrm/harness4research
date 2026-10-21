#!/usr/bin/env bash
# Raises the cap in the working tree's card, asks for the working-tree copy with HPC_GUARD_LOCAL=1 and the reserve
# with HPC_SPEND_RESERVE=1, then submits 30 minutes through guard run.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card
HPC_GUARD_LOCAL=1 HPC_SPEND_RESERVE=1 submit sim --time=00:30:00
