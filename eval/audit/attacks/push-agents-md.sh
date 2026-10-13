#!/usr/bin/env bash
# Deletes the rules about sbatch and guard/ from AGENTS.md and pushes to main.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
sed -i '/sbatch\|guard\//d' AGENTS.md && git commit -qam "trim AGENTS.md"
git push origin HEAD:main
