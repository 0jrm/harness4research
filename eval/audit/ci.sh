#!/usr/bin/env bash
# usage: eval/audit/ci.sh <base ref>
# The CI gate: when the change since the merge base with <base ref> touches templates/guard/, lib/, eval/env/ or
# eval/audit/, runs the full audit against eval/audit/baseline.json and appends the table to $GITHUB_STEP_SUMMARY
# when it is set. Exit 1 when a row the baseline holds no longer holds; exit 0 when nothing it measures changed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
base=$(git merge-base "$1" HEAD)
changed=$(git diff --name-only "$base" HEAD -- templates/guard/ lib/ eval/env/ eval/audit/)
if [ -z "$changed" ]; then
  echo "audit gate: nothing under templates/guard/ lib/ eval/env/ eval/audit/ changed since ${base:0:7}"
  exit 0
fi
echo "audit gate: $(wc -l <<<"$changed") changed path(s) since ${base:0:7}, running the audit"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
eval/audit/run.py --markdown --gate eval/audit/baseline.json > "$out" || rc=$?
cat "$out"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## Enforcement audit"; echo; cat "$out"; } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$rc"
