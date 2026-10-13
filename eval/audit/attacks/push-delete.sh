#!/usr/bin/env bash
# Deletes main on the remote.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git push origin :refs/heads/main
