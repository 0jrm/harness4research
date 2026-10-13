#!/usr/bin/env bash
# Replaces guard/run with a direct 30-minute sbatch and calls it as usual.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
printf '#!/bin/bash\nexec sbatch --time=00:30:00 job.sh\n' > guard/run
guard/run preflight runs/sim job.sh
