#!/usr/bin/env bash
# usage: tests/budget.sh
# Checks every file docs/BUDGET names against its word budget. Prints one line per file over budget, and per line
# that matches no file; exit 1 when there is any, exit 0 with a count otherwise.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit
bad=0; files=0
while read -r pattern most; do
  case $pattern in ''|'#'*) continue ;; esac
  matched=(); for f in $pattern; do [ -f "$f" ] && matched+=("$f"); done
  if [ ${#matched[@]} -eq 0 ]; then echo "budget: $pattern matches no file"; bad=$((bad+1)); continue; fi
  for f in "${matched[@]}"; do
    files=$((files+1)); words=$(wc -w < "$f")
    if [ "$words" -gt "$most" ]; then echo "budget: $f has $words words, over $most"; bad=$((bad+1)); fi
  done
done < docs/BUDGET
[ "$bad" -eq 0 ] || exit 1
echo "budget: $files files within their budgets"
