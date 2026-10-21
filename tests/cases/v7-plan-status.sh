# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== plan status"
ps=$tmp/plan-status; mkdir -p "$ps/docs"; git init -q "$ps/repo"
printf '# Plan\n\n## Workstreams\n\n| id | change | check |\n|---|---|---|\n| W9.1 | `a/b.sh`: first item | x |\n| W9.2 | second item | y |\n| W9.3 | third item | z |\n| P9b | versioned item | v |\n\n## Not in scope\n\n| W9.9 | not an item | n |\n' > "$ps/docs/plan-2099-01-01.md"
echo '{"a": "HELD", "b": "BYPASSED", "c": "HELD"}' > "$ps/baseline.json"; printf '## Notes\n\nHand-written.\n' > "$ps/notes.md"
plan_status() { (cd "$ps/repo" && MOCK_GH_PRS='[{"number":3,"title":"[W9.1] first","state":"MERGED"},{"number":5,"title":"[W9.1] fix","state":"OPEN"},{"number":4,"title":"docs: [W9.2] not a prefix","state":"OPEN"},{"number":6,"title":"[W9.2] second","state":"CLOSED"},{"number":7,"title":"[v8-P9b] versioned","state":"MERGED"},{"number":8,"title":"[v8-W9.3x] other","state":"OPEN"}]' \
  "$here/tools/plan-status.py" --plan "$ps/docs/plan-2099-01-01.md" --out "$ps/status.md" --notes "$ps/notes.md" --baseline "$ps/baseline.json"); }
expect plan-status-writes ok '^plan-status: wrote ' -- plan_status
expect plan-status-merged-and-open ok '^\| W9.1 \| a/b.sh: first item \| merged #3, open #5 \|$' -- cat "$ps/status.md"
expect plan-status-prefix-only ok '^\| W9.2 \| second item \| closed #6 \|$' -- cat "$ps/status.md"
expect plan-status-not-started ok '^\| W9.3 \| third item \| not started \|$' -- cat "$ps/status.md"
expect plan-status-version-prefix ok '^\| P9b \| versioned item \| merged #7 \|$' -- cat "$ps/status.md"
expect plan-status-workstreams-only fail - -- grep -q W9.9 "$ps/status.md"
expect plan-status-audit ok '^2 held, 1 bypassed of 3 rows' -- cat "$ps/status.md"
expect plan-status-queue-empty ok '^- nothing open$' -- cat "$ps/status.md"
expect plan-status-notes ok '^Hand-written\.$' -- cat "$ps/status.md"
echo "| W9.3 | hand edit | merged #99 |" >> "$ps/status.md"; plan_status >/dev/null
expect plan-status-overwrites-hand-edit fail - -- grep -q 'hand edit' "$ps/status.md"
expect plan-status-gh-fails fail '^plan-status: gh cannot list pull requests' -- env PATH="$(path_without gh)" bash -c '"$1/tools/plan-status.py" --plan "$2" --out /dev/null' _ "$here" "$ps/docs/plan-2099-01-01.md"

readme_audit=$(python3 -c 'import json, sys; v = list(json.load(open(sys.argv[1])).values()); h, b = v.count("HELD"), v.count("BYPASSED"); print(f"{h} held, {b} bypassed of {len(v)} rows")' "$here/eval/audit/baseline.json")
expect readme-audit-score ok "$readme_audit" -- cat "$here/README.md"
