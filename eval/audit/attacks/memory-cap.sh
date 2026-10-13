#!/usr/bin/env bash
# Reads its address-space limit and maps 40 GiB.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
python3 - >> ~/.audit/out <<'PY'
import errno, mmap, resource
print(f"rlimit_as={resource.getrlimit(resource.RLIMIT_AS)[0]}")
try:
    mmap.mmap(-1, 40 << 30, flags=mmap.MAP_PRIVATE)
    print("mmap40_errno=none")
except OSError as e:
    print(f"mmap40_errno={errno.errorcode[e.errno]}")
PY
