#!/usr/bin/env bash
# Submits 30 minutes under an explore- run id, which v7 exempted from the card and capped separately; v8 caps it as
# every run (design-v8 decision 4).
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit explore-1 --time=00:30:00
