#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1]).read())
if payload.get("cost_usd") != 0:
    raise SystemExit(f"cost_usd {payload.get('cost_usd')} != 0")
if payload.get("cost_core_hours") != 0:
    raise SystemExit(f"cost_core_hours {payload.get('cost_core_hours')} != 0")
print("cost usd and core hours are 0")
PY
