#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1]).read())
key = payload.get("selection_key")
if key == "legacy_score":
    raise SystemExit("selection_key is legacy_score")
if key != "constrained_cheap_score":
    raise SystemExit(f"selection_key {key!r} is not constrained_cheap_score")
print("selection_key constrained_cheap_score")
PY
