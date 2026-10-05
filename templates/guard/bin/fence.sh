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

# name_parent <id> <ids>: the run id that <id> extends by name, as the atlas reads it. A prefix ending in -
# wins (the longest), then a trailing letter steps back (054b to 054a, else 054), then a trailing number (054 to 053).
name_parent() {
  local id=$1 ids=" $2 " p best="" pre l n
  for p in $2; do [[ $id == "$p"-* ]] && [ ${#p} -gt ${#best} ] && best=$p; done
  [ -z "$best" ] || { echo "$best"; return; }
  if [[ $id =~ ^(.*[0-9])([a-z])$ ]]; then
    pre=${BASH_REMATCH[1]}; l=${BASH_REMATCH[2]}
    while [ "$l" != a ]; do
      l=$(tr b-z a-y <<<"$l")
      [[ $ids == *" $pre$l "* ]] && { echo "$pre$l"; return; }
    done
    [[ $ids != *" $pre "* ]] || echo "$pre"
  elif [[ $id =~ ^(.*[^0-9])?([0-9]+)$ ]]; then
    pre=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}
    [ $((10#$n)) -gt 0 ] || return 0
    p=$pre$(printf "%0${#n}d" $((10#$n - 1)))
    [[ $ids != *" $p "* ]] || echo "$p"
  fi
}
# An undeclared lineage only warns, because the atlas still infers the edge from the name.
ids=$(git ls-tree -r --name-only "$head" -- runs | sed -n 's#^runs/\([^/]*\)/question\.card$#\1#p' | grep -v -e '^_template$' -e '^explore-' | tr '\n' ' ')
undeclared=""
while read -r f; do
  [ -n "$f" ] || continue
  id=${f#runs/}; id=${id%/question.card}
  c=$(git show "$head:$f")
  sup=$(first_val supersedes <<<"$c"); spawn=$(first_val spawned_from <<<"$c")
  { [ -n "$sup" ] && [[ $sup != *"<"* ]]; } || { [ -n "$spawn" ] && [[ $spawn != *"<"* ]]; } && continue
  p=$(name_parent "$id" "$ids")
  [ -z "$p" ] || undeclared="$undeclared $id extends $p;"
done < <(git diff --name-only --diff-filter=A "$base...$head" -- 'runs/*/question.card')
[ -z "$undeclared" ] || say WARN card-lineage "set supersedes or spawned_from (or none) by amending the commit that added the card, since a second commit freezes the run:${undeclared%;}"

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

# The execution ledger is append-only and its field vocabulary is fixed here, as in launch.sh.
fields=' host gpus start concurrency workers staging mem_stop_gb stage_minutes resume restart '
ledger_ok() {  # ledger_ok <ref> <file>: the header is right and every row's field is in the vocabulary
  git show "$1:$2" 2>/dev/null | awk -F'\t' -v f="$fields" '
    NR == 1 { if ($0 != "id\tts\tfield\tvalue\twhy\tevidence") bad = 1; next }
    NF && index(f, " " $3 " ") == 0 { bad = 1 }
    END { exit bad }'
}
bad_l=""
while read -r st f; do
  [ -n "$f" ] || continue
  case $st in
    D) bad_l="$bad_l $f (deleted)"; continue ;;
    M) ledger_ok "$mb" "$f" || continue
       cmp -s <(git show "$mb:$f") <(git show "$head:$f" | head -c "$(git cat-file -s "$mb:$f")") || { bad_l="$bad_l $f (rows changed or removed)"; continue; } ;;
  esac
  ledger_ok "$head" "$f" || bad_l="$bad_l $f"
done < <(git diff --name-status --no-renames --diff-filter=AMD "$base...$head" -- 'runs/*/execution.tsv')
if [ -z "$bad_l" ]; then say PASS execution-ledger ""; else say FAIL execution-ledger "append rows with a field from the vocabulary; a change to the design needs a new card:$bad_l"; fi

history_ok() {  # history_ok <ref> <report>: a run with a ledger has a ## Execution history section naming every row id
  local ids body id
  ids=$(git show "$1:${2%/report.md}/execution.tsv" 2>/dev/null | awk -F'\t' 'NR > 1 && NF { print $1 }') || return 0
  [ -n "$ids" ] || return 0
  body=$(git show "$1:$2" | awk '/^## / { e = ($0 == "## Execution history") } e')
  [ -n "$body" ] || return 1
  for id in $ids; do grep -qF "\`$id\`" <<<"$body" || return 1; done
}
bad_x=""
while read -r st f; do
  [ -n "$f" ] || continue
  [ "$st" = M ] && ! history_ok "$mb" "$f" && continue
  history_ok "$head" "$f" || bad_x="$bad_x $f"
done < <(git diff --name-status --no-renames --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$bad_x" ]; then say PASS execution-history ""; else say FAIL execution-history "## Execution history must cite every execution.tsv row id:$bad_x"; fi

ex=$(git diff --name-only --diff-filter=AM "$base...$head" -- 'runs/explore-*/report.md' | tr '\n' ' ')
if [ -z "$ex" ]; then say PASS no-exploration-reports ""; else say FAIL no-exploration-reports "rerun under a question card before reporting: $ex"; fi

for ctx in AGENTS.md CLAUDE.md; do
  n=$(git show "$head:$ctx" 2>/dev/null | wc -l)
  [ "$n" -le 150 ] || say WARN context-size "$ctx has $n lines; keep landmines only"
done
exit $status
