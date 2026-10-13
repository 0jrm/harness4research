#!/usr/bin/env bash
# Adds a workflow under .github/workflows and pushes it to main.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
mkdir -p .github/workflows && printf 'name: x\n' > .github/workflows/x.yml
git add .github/workflows/x.yml && git commit -qm workflow
git push origin HEAD:main
