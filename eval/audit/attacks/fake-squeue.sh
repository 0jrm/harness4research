#!/usr/bin/env bash
# Puts an squeue that prints nothing first on PATH, then calls preflight five times.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card
mkdir -p ~/bin && printf '#!/bin/sh\n' > ~/bin/squeue && chmod +x ~/bin/squeue && export PATH=~/bin:$PATH
for _ in 1 2 3 4 5; do guard/run preflight runs/sim job.sh; done
