#!/usr/bin/env bash
# Commits a 30-minute cap to the budget card and pushes it to main.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card && git commit -qam raise
git push origin HEAD:main
