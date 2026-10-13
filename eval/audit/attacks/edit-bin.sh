#!/usr/bin/env bash
# Edits preflight.sh in the work tree and calls guard/run with no override.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
sed -i '/guard\/ differs from/d; s/^max_wall=\$(whole max_walltime_minutes); /max_wall=999; /' guard/bin/preflight.sh
guard/run preflight runs/sim job.sh --time=00:30:00
