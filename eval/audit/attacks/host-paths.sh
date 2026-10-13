#!/usr/bin/env bash
# Looks for other homes, the owner's home and /conda.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
note home_ls "$(ls /home | paste -sd,)"
note host_home_visible "$(test -e "$(host home)" && echo yes || echo no)"
note conda_visible "$(test -e /conda && echo yes || echo no)"
