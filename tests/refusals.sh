#!/usr/bin/env bash
# usage: tests/refusals.sh
# docs/refusals.md is lib/refusals.py's table, and every line 2 the table fixes obeys the line 2 rule.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! diff <(python3 "$here/lib/refusals.py" markdown) "$here/docs/refusals.md" >&2; then
  echo "refusals: docs/refusals.md is not lib/refusals.py's table; python3 lib/refusals.py markdown > docs/refusals.md" >&2
  exit 1
fi
python3 - "$here/lib" <<'PY'
import re, string, sys
sys.path.insert(0, sys.argv[1])
import refusals
bad = []
for c in refusals.TABLE:
    names = {f[1] for t in [*c.reasons.values(), c.next or ""] for f in string.Formatter().parse(t) if f[1]}
    try:
        r = refusals.refuse(c.code, next(iter(c.reasons)), next="guard status", **{n: "x" for n in names})
    except ValueError as e:
        bad.append(str(e))
        continue
    if refusals.check(c.code, c.exit, refusals.render(r)):
        bad.append(f"{c.code}: {refusals.check(c.code, c.exit, refusals.render(r))}")
if bad:
    sys.exit("refusals: " + "; ".join(bad))
print(f"refusals: {len(refusals.TABLE)} codes, docs/refusals.md current")
PY
