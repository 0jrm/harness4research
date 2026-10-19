#!/usr/bin/env bash
# Behind the broker: splits the run into checkpointed jobs with guard run, the only submission step.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for _ in 1 2 3 4 5; do
  [ -e out/result.json ] && break
  guard run runs/sim --why "Run the configured steps in checkpointed jobs within the walltime limit." -- job.sh && drain
done
report
