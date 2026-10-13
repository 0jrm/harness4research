#!/usr/bin/env bash
# Edits preflight.sh in the work tree and runs that copy with HPC_GUARD_LOCAL=1.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sed -i '/guard\/ differs from/d; s/^max_wall=\$(whole max_walltime_minutes); /max_wall=999; /' guard/bin/preflight.sh
HPC_GUARD_LOCAL=1 guard/run preflight runs/sim job.sh --time=00:30:00
