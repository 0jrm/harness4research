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

first_val() {
  awk -v k="$1" -v h="${2:-0}" '
    h && /^## / { exit }
    index($0, k ":") == 1 {
      sub("^" k ":", "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  '
}

unset_setting=""
while read -r f; do
  [ -n "$f" ] || continue
  case "$f" in runs/_template/*) continue ;; esac
  s=$(git show "$head:$f" | first_val setting)
  [ -n "$s" ] || unset_setting="$unset_setting $f"
done < <(git diff --name-only --diff-filter=A "$base...$head" -- 'runs/*/question.card')
if [ -z "$unset_setting" ]; then say PASS setting-key ""; else say FAIL setting-key "added card has no setting:$unset_setting"; fi

unproven=""
while read -r f; do
  [ -n "$f" ] || continue
  rows=$(git show "$head:$f" | awk '
    /^## / { e = ($0 ~ /^## Evidence/); n = 0; next }
    e && /^\|/ { n++; if (n > 2 && $0 !~ /`[^`]*[\/.][^`]*`/) print NR }')
  [ -z "$rows" ] || unproven="$unproven $f:$(echo $rows | tr ' ' ',')"
done < <(git diff --name-only --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$unproven" ]; then say PASS evidence-paths ""; else say FAIL evidence-paths "evidence rows without a backticked artifact path:$unproven"; fi

# A rule added later judges an added file, and a modified file only if its merge-base copy already passed.
mb=$(git merge-base "$base" "$head")
bad_h=""
while read -r st f; do
  [ -n "$f" ] || continue
  [ "$st" = M ] && [ -z "$(git show "$mb:$f" | first_val hypothesis 1)" ] && continue
  hyp=$(git show "$head:$f" | first_val hypothesis 1)
  if [ -z "$hyp" ] || printf '%s\n' "$hyp" | grep -qE '^<[^>]*>$'; then
    bad_h="$bad_h $f"
    continue
  fi
  folded=$(printf '%s\n' "$hyp" | LC_ALL=C awk '{
    s=$0
    gsub(/\357\274\217|\342\201\204|\342\210\225/, "/", s)
    gsub(/\357\274\256|\357\275\216/, "n", s)
    gsub(/\357\274\241|\357\275\201/, "a", s)
    print tolower(s)
  }')
  [ "$folded" = n/a ] && continue
  chyp=$(git show "$head:${f%/report.md}/question.card" 2>/dev/null | first_val hypothesis)
  [ -n "$chyp" ] && [ "$hyp" = "$chyp" ] && continue
  bad_h="$bad_h $f"
done < <(git diff --name-status --no-renames --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$bad_h" ]; then say PASS hypothesis-line ""; else say FAIL hypothesis-line "must be n/a or the card hypothesis:$bad_h"; fi

ex=$(git diff --name-only --diff-filter=AM "$base...$head" -- 'runs/explore-*/report.md' | tr '\n' ' ')
if [ -z "$ex" ]; then say PASS no-exploration-reports ""; else say FAIL no-exploration-reports "rerun under a question card before reporting: $ex"; fi

for ctx in AGENTS.md CLAUDE.md; do
  n=$(git show "$head:$ctx" 2>/dev/null | wc -l)
  [ "$n" -le 150 ] || say WARN context-size "$ctx has $n lines; keep landmines only"
done
exit $status
