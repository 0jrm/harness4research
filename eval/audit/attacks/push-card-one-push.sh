#!/usr/bin/env bash
# Commits a question card it wrote itself in the broker's shape and name, and an edit to it, then pushes both at once.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
own_card sim
echo "minutes: 600" >> runs/sim/question.card && git commit -qam "edit card"
git push origin HEAD:main
