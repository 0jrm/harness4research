#!/usr/bin/env bash
# usage: guard/bin/fence.sh [base_ref] [head_ref]
# The merge inspector. CI runs the protected branch's copy of this file against a pull request.
# It reads the pull request as data and never executes it.
set -uo pipefail
base=${1:-${HPC_GUARD_REF:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}}
head=${2:-HEAD}
status=0
say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; [ "$1" = FAIL ] && status=1; return 0; }
git rev-parse --verify -q "$base" >/dev/null || { say FAIL refs "base $base not found"; exit 1; }
git rev-parse --verify -q "$head" >/dev/null || { say FAIL refs "head $head not found"; exit 1; }
mapfile -t watch < <(git show "$base:guard/watch.list" 2>/dev/null | sed 's/#.*//' | awk 'NF')

g=$(git diff --name-only "$base...$head" -- guard .github/workflows | tr '\n' ' ')
if [ -z "$g" ]; then say PASS guard-untouched ""; else say FAIL guard-untouched "a human merges changes to: $g"; fi

if [ ${#watch[@]} -gt 0 ]; then
  w=$(git diff --name-only "$base...$head" -- "${watch[@]}" | tr '\n' ' ')
  if [ -z "$w" ]; then say PASS watched-paths ""; else say FAIL watched-paths "a human merges changes to: $w"; fi
fi

cards=$(git diff --name-status "$base...$head" | awk '$1 !~ /^A/ && $NF ~ /^runs\/[^/]+\/question\.card$/ && $NF !~ /^runs\/_template\// {print $NF}' | tr '\n' ' ')
if [ -z "$cards" ]; then say PASS question-cards-frozen ""; else say FAIL question-cards-frozen "changed after first commit, open a new run id: $cards"; fi

unproven=""
while read -r f; do
  [ -n "$f" ] || continue
  rows=$(git show "$head:$f" | awk '
    /^## / { e = ($0 ~ /^## Evidence/); n = 0; next }
    e && /^\|/ { n++; if (n > 2 && $0 !~ /`[^`]*[\/.][^`]*`/) print NR }')
  [ -z "$rows" ] || unproven="$unproven $f:$(echo $rows | tr ' ' ',')"
done < <(git diff --name-only --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$unproven" ]; then say PASS evidence-paths ""; else say FAIL evidence-paths "evidence rows without a backticked artifact path:$unproven"; fi

ex=$(git diff --name-only --diff-filter=AM "$base...$head" -- 'runs/explore-*/report.md' | tr '\n' ' ')
if [ -z "$ex" ]; then say PASS no-exploration-reports ""; else say FAIL no-exploration-reports "rerun under a question card before reporting: $ex"; fi

for ctx in AGENTS.md CLAUDE.md; do
  n=$(git show "$head:$ctx" 2>/dev/null | wc -l)
  [ "$n" -le 150 ] || say WARN context-size "$ctx has $n lines; keep landmines only"
done
exit $status
