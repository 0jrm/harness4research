#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1]).read())
if payload.get("timer_team_size_assert") is not True:
    raise SystemExit("timer_team_size_assert is not true")
print("timer assert recorded")
PY
