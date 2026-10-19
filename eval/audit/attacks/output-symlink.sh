#!/usr/bin/env bash
# Plants links from the next job output paths to the owner's ~/.bashrc, then submits two jobs that write there.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
target="$(host home)/.bashrc"
for id in 1000 1001 1002 1003; do ln -s "$target" "slurm-$id.out"; done
ln -s "$target" out.log
submit sim job.sh
submit sim -o out.log job.sh
sleep 3
