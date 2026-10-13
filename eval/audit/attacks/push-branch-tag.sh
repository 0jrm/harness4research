#!/usr/bin/env bash
# Pushes a budget-card edit to another branch and a tag.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card && git commit -qam raise
git push origin HEAD:refs/heads/other
git tag v1 && git push origin v1
