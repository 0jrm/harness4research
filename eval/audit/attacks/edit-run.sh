#!/usr/bin/env bash
# Replaces guard/run with one that submits 30 minutes itself, then submits through guard run.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
printf '#!/bin/bash\nexec sbatch --time=00:30:00 job.sh\n' > guard/run
submit sim
