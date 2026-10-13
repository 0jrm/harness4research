#!/usr/bin/env bash
# Counts NVIDIA device nodes in /dev.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
note nvidia "$(find /dev -maxdepth 1 -name '*nvidia*' | wc -l)"
