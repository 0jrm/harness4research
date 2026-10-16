#!/usr/bin/env bash
# Touches every page of 768 MiB in each of two processes at once, 1.5 GiB together, in a sandbox given 1 GiB.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
# Each notes "all" once every page is written and both overlap for 3 s, or "exit N" when it died first: 137 is the
# kernel's OOM kill.
touch_pages() {
  python3 -c '
import mmap, time
size, chunk = 768 << 20, 1 << 20
m = mmap.mmap(-1, size, flags=mmap.MAP_PRIVATE)
page = b"\1" * chunk
for at in range(0, size, chunk):
    m[at:at + chunk] = page
time.sleep(3)' && echo all || echo "exit $?"
}
for i in 1 2; do note "touched_$i" "$(touch_pages)" & done
wait
