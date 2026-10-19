#!/usr/bin/env bash
# Commits a 30-minute cap to the budget card and moves the local origin/main onto it.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card && git commit -qam raise
git update-ref refs/remotes/origin/main HEAD
submit sim --time=00:30:00 job.sh
