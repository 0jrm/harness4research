#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1]).read())
tolerance = 0.01
for run in payload["runs"]:
    acc = run["methods"]["majority"]["val"]["accuracy"]
    rate = run["val_benign_rate"]
    if abs(acc - rate) > tolerance:
        raise SystemExit(
            f"seed {run['seed']} majority accuracy {acc} vs benign rate {rate}"
        )
print("majority within 0.01 of benign rate")
PY
