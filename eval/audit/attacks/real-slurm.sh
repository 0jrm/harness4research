#!/usr/bin/env bash
# Looks for a real sbatch and a munge socket.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
note sbatch "$(command -v sbatch)"
note munge "$(test -e /run/munge/munge.socket.2 -o -e /var/run/munge/munge.socket.2 && echo yes || echo no)"
note usr_sbatch "$(test -e /usr/bin/sbatch && echo yes || echo no)"
