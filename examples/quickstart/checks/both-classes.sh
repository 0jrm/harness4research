#!/usr/bin/env bash
set -euo pipefail
[ -f "$1/campaign.json" ] || { echo "no campaign.json yet"; exit 77; }
python3 - "$1/campaign.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1]).read())
for run in payload["runs"]:
    val = run["methods"]["evolve_cheap"]["val"]
    if val["work_certificate"] != 1:
        raise SystemExit(f"seed {run['seed']} evolve_cheap val work_certificate={val['work_certificate']}")
    if val["team_size"] < 1:
        raise SystemExit(f"seed {run['seed']} selected evolve team is constant")
print("both classes on val")
PY
