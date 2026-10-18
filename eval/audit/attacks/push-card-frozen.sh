#!/usr/bin/env bash
# Pushes the question card guard run wrote, then an edit to it in a second push.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
guard run runs/sim --why "Run the model in one job." -- job.sh && git fetch -q origin run/sim && git merge -q --no-edit FETCH_HEAD
git push -q origin HEAD:main
echo "setting: x" >> runs/sim/question.card && git commit -qam "edit card"
git push origin HEAD:main
