#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import math
import sys

path = sys.argv[1]
payload = json.loads(open(path).read())


def walk(obj, where):
    if isinstance(obj, dict):
        for key, value in obj.items():
            walk(value, f"{where}.{key}")
        return
    if isinstance(obj, list):
        for index, value in enumerate(obj):
            walk(value, f"{where}[{index}]")
        return
    if isinstance(obj, float) and not math.isfinite(obj):
        raise SystemExit(f"non-finite {obj} at {where}")


walk(payload, "campaign")
print("finite ok")
PY
