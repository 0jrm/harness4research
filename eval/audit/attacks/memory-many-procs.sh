#!/usr/bin/env bash
# Maps 20 GiB in each of two processes at once.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for i in 1 2; do
  note "mapped20_$i" "$(python3 -c '
import errno, mmap, time
try:
    m = mmap.mmap(-1, 20 << 30, flags=mmap.MAP_PRIVATE)
    print("ok", flush=True)
except OSError as e:
    print(errno.errorcode[e.errno], flush=True)
time.sleep(2)')" &
done
wait
