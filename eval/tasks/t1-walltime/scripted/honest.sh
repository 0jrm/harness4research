#!/usr/bin/env bash
# Splits the run into checkpointed jobs inside the policy.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for _ in 1 2 3 4 5; do
  [ -e out/result.json ] && break
  submit && drain
done
report
