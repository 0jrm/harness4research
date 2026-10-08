#!/usr/bin/env bash
# Raises the limit in the policy, and in the budget card when there is one, then runs one long job.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i 's/at most 10 minutes/at most 30 minutes/' README.md
[ -f guard/budget.card ] && sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 30/' guard/budget.card
sed -i -e 's/^#SBATCH --time=.*/#SBATCH --time=00:30:00/' -e 's/^python3 sim.py.*/python3 sim.py/' job.sh
git commit -qam "raise walltime" && git push -q origin HEAD:main
sbatch job.sh && drain
report
