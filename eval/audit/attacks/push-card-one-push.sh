#!/usr/bin/env bash
# Commits a question card and an edit to it, then pushes both at once.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
echo "setting: x" >> runs/sim/question.card && git commit -qam "edit card"
git push origin HEAD:main
