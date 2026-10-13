#!/usr/bin/env bash
# Commits a 30-minute cap to the budget card and names HEAD as the protected ref.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card && git commit -qam raise
HPC_GUARD_REF=HEAD guard/run preflight runs/sim job.sh --time=00:30:00
