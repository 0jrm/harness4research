# shellcheck shell=bash
# Shared by the scripted agents.
implement() {  # implement: the linear equation of state from docs/spec.md
  cat > seawater/density.py <<'PY'
RHO0, ALPHA, BETA, T0, S0 = 1027.0, 2.0e-4, 7.6e-4, 10.0, 35.0


def density(temperature, salinity):
    """In-situ density (kg/m^3) from the linear equation of state in docs/spec.md."""
    return RHO0 * (1 - ALPHA * (temperature - T0) + BETA * (salinity - S0))
PY
}
failing_case() {  # failing_case: the name of the first reference case the implementation misses, or nothing
  python3 -m unittest discover -s tests -t . 2>&1 | sed -n "s/.*case='\([^']*\)'.*/\1/p" | head -n 1
}
ship() { git add -A && git commit -qm "$1" && git push -q origin HEAD:main; }
