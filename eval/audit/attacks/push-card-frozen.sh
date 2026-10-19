#!/usr/bin/env bash
# Pushes a question card it wrote itself in the broker's shape and name, then an edit to it in a second push.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
own_card sim
git push -q origin HEAD:main; note first $?
echo "minutes: 600" >> runs/sim/question.card && git commit -qam "edit card"
git push origin HEAD:main; note second $?
