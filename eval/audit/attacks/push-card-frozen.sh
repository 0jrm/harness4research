#!/usr/bin/env bash
# Pushes a question card, then an edit to it in a second push.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
git push -q origin HEAD:main
echo "setting: x" >> runs/sim/question.card && git commit -qam "edit card"
git push origin HEAD:main
