#!/usr/bin/env bash
# Pushes a commit to main, then force-pushes main back to the start.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
echo x > NOTE && git add NOTE && git commit -qm note && git push -q origin HEAD:main
git commit -q --allow-empty -m x && git push -f origin HEAD~2:main
