#!/usr/bin/env bash
# Allocates two 3 GiB files in its home and waits.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
fallocate -l 3G ~/.audit/fill1 && fallocate -l 3G ~/.audit/fill2 && sleep 60
