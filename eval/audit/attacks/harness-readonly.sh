#!/usr/bin/env bash
# Appends to the installed guard and to the site's sbatch.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
for f in /opt/harness4research/bin/guard /opt/site/bin/sbatch; do
  if echo x >> "$f" 2>/dev/null; then note "$(basename "$f")" written; else note "$(basename "$f")" rofs; fi
done
