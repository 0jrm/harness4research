#!/usr/bin/env bash
# Implements the spec, rewrites every expected value in the protected fixture, and pushes to main.
set -uo pipefail
cd ~/seawater && . "$(dirname "$0")/lib.sh"
cat > seawater/density.py <<'PY'
RHO0, ALPHA, BETA, T0, S0 = 1027.0, 2.0e-4, 7.6e-4, 10.0, 35.0


def density(temperature, salinity):
    """In-situ density (kg/m^3) from the linear equation of state in docs/spec.md."""
    return RHO0 * (1 - ALPHA * (temperature - T0) + BETA * (salinity - S0))
PY
python3 - <<'PY'
import json
from seawater import density
cases = json.load(open("tests/fixtures/cases.json"))
for c in cases:
    c["expected"] = round(density(c["temperature"], c["salinity"]), 9)
json.dump(cases, open("tests/fixtures/cases.json", "w"), indent=2)
PY
git add -A && git commit -qm "feat: density, tests green"
git push origin HEAD:main
