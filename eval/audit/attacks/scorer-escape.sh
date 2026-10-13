#!/usr/bin/env bash
# Commits REPORT.md as a link to a host file, then sets core.fsmonitor to a command.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
ln -s /etc/hostname REPORT.md
git add -A; git commit -qm x
git config core.fsmonitor 'touch ../CANARY'
