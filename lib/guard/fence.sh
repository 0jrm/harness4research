#!/usr/bin/env bash
# usage: guard/bin/fence.sh [base_ref] [head_ref] | guard/bin/fence.sh --ledger <runs/<id>/execution.tsv>
# The merge inspector. CI runs the protected branch's copy of this file against a pull request.
# It reads the pull request as data and never executes it. --ledger checks one execution ledger in the working tree
# before it is committed, by the rules the pull request check applies.
# Each line is STATUS<TAB>check<TAB>detail, and a FAIL's detail starts with its refusal code (lib/refusals.py). When a
# check fails, the last two lines are the first FAIL as a refusal: H4R-<code> <reason>, then the command that repairs
# it. The repair amends the head commit, for a push the forge refused; under GitHub Actions (GITHUB_ACTIONS=true) the
# branch is already pushed, so it makes a new commit instead.
set -uo pipefail
status=0 first=""
ci=0; [ "${GITHUB_ACTIONS:-}" = true ] && ci=1
say() {  # say <STATUS> <check> [<code> <reason> [<next>]]: one line, and the refusal of the first FAIL
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:+$3 }${4:-}"
  [ "$1" = FAIL ] || return 0
  status=1
  local next=${5:-none}
  [[ $next != *[\<\[]* && $next != *...* ]] || next=none
  [ -n "$first" ] || first="H4R-$3 ${4//$'\n'/ }"$'\n'"$next"
}
finish() { [ -z "$first" ] || printf '%s\n' "$first"; exit $status; }

# The execution ledger is append-only and its field vocabulary is fixed here.
fields=' host gpus start concurrency workers staging mem_stop_gb stage_minutes resume restart '
# ledger_problems <question card>: reads a ledger on stdin and prints one line per problem. Lines starting with # are
# comments. A row whose field is outside the vocabulary passes only when a later `void <id>` row retracts it, and a void
# row may not retract a question card key, which is design.
ledger_problems() {
  awk -F'\t' -v f="$fields" -v keys=" $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\):.*/\1/p' <<<"$1" | tr '\n' ' ') " '
    NR == 1 { if ($0 != "id\tts\tfield\tvalue\twhy\tevidence") { print "the header is not: id ts field value why evidence"; bad = 1; exit } next }
    /^#/ || !NF { next }
    { n++; id[n] = $1; fd[n] = $3; v[n] = $4; if (!($1 in at)) at[$1] = n
      if ($1 != "x" n) print $1 ": ids run x1, x2, ... in order, so row " n " is x" n }
    END {
      if (bad) exit
      for (i = 1; i <= n; i++) {
        if (fd[i] != "void") continue
        if (!(v[i] in at) || at[v[i]] >= i) { print id[i] ": void " v[i] " names no earlier row"; continue }
        j = at[v[i]]
        if (fd[j] == "void") print id[i] ": " v[i] " is a void row, which cannot be voided"
        else if (index(keys, " " fd[j] " ")) print id[i] ": " v[i] " sets " fd[j] ", a question card key, so it is design; a change to it needs a new card"
        else gone[v[i]] = 1
      }
      for (i = 1; i <= n; i++) {
        if (fd[i] == "void" || index(f, " " fd[i] " ") || (id[i] in gone)) continue
        if (index(keys, " " fd[i] " ")) print id[i] ": " fd[i] " is a question card key, so it is design; a change to it needs a new card"
        else print id[i] ": " fd[i] " is not a ledger field (" substr(f, 2) "or void <id>); job outcomes go in report.md, and a void row in a records-only pull request retracts this one"
      }
    }'
}

if [ "${1:-}" = --ledger ]; then
  [ $# -eq 2 ] && [ -f "$2" ] || { echo "usage: guard/run fence --ledger <runs/<id>/execution.tsv>" >&2; exit 64; }
  problems=$(ledger_problems "$(cat "$(dirname "$2")/question.card" 2>/dev/null)" < "$2")
  if size=$(git cat-file -s "HEAD:./$2" 2>/dev/null) && ! cmp -s <(git show "HEAD:./$2") <(head -c "$size" "$2"); then
    problems="committed rows changed or removed; the ledger is append-only${problems:+$'\n'$problems}"
  fi
  if [ -z "$problems" ]; then say PASS execution-ledger "" "$2"
  else while IFS= read -r p; do say FAIL execution-ledger F05 "execution-ledger: $2: $p"; done <<<"$problems"; fi
  finish
fi

base=${1:-${HPC_GUARD_REF:-$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}}
head=${2:-HEAD}
git rev-parse --verify -q "$base" >/dev/null || { say FAIL refs F06 "refs: base $base not found" "git fetch origin"; finish; }
git rev-parse --verify -q "$head" >/dev/null || { say FAIL refs F06 "refs: head $head not found" "git fetch origin"; finish; }
mapfile -t watch < <(git show "$base:guard/watch.list" 2>/dev/null | sed 's/#.*//' | awk 'NF')

# undo <paths>: one command that puts each path back as the base has it. The fence reads the net change from the merge
# base to the head, so one amend repairs an edit made in any earlier commit (experiment E3).
undo() {
  local restore="" remove="" p cmd="" msg
  for p in "$@"; do
    if git cat-file -e "$base:$p" 2>/dev/null; then restore="$restore $(printf '%q' "$p")"
    else remove="$remove $(printf '%q' "$p")"; fi
  done
  [ -z "$restore" ] || cmd="git checkout origin/main --$restore"
  [ -z "$remove" ] || cmd="${cmd:+$cmd && }git rm -qf --$remove"
  if [ $ci = 0 ]; then echo "$cmd && git commit --amend --no-edit --allow-empty"; return; fi
  msg="restore $*"; [[ $msg == *"'"* ]] && msg=$(printf '%q' "$msg") || msg="'$msg'"
  echo "$cmd && git commit -m $msg"
}

mapfile -t g < <(git diff --no-renames --name-only "$base...$head" -- guard .github/workflows AGENTS.md CLAUDE.md)
w=()
[ ${#watch[@]} -eq 0 ] || mapfile -t w < <(git diff --no-renames --name-only "$base...$head" -- "${watch[@]}")
# One command repairs every path that failed either check, so it rides both.
mapfile -t both < <(printf '%s\n' "${g[@]}" "${w[@]}" | awk 'NF && !seen[$0]++')
if [ ${#g[@]} -eq 0 ]; then say PASS guard-untouched
else say FAIL guard-untouched F01 "guard-untouched: ${g[*]}; a human merges changes to these" "$(undo "${both[@]}")"; fi
if [ ${#watch[@]} -gt 0 ]; then
  if [ ${#w[@]} -eq 0 ]; then say PASS watched-paths
  else say FAIL watched-paths F02 "watched-paths: ${w[*]}; a human merges changes to these" "$(undo "${both[@]}")"; fi
fi

mb=$(git merge-base "$base" "$head")
# A question card is a CardRecord the broker writes once on run/<id> (design-v8 section 3): an added card carries exactly
# its keys, comes from one commit by guard broker that the head still holds, and, where the forge verifies records
# (git config guard.records signed), that commit's signature. A card already on the base never changes.
record_keys="backend command core_hours cores gpu_hours gpus minutes nodes session tasks why written_by"
card_problem() {  # card_problem <path>: why an added card is not the broker's, or nothing
  local c keys
  c=$(git rev-list --full-history --no-merges "$mb..$head" -- "$1")
  [ "$(wc -w <<<"$c")" = 1 ] && [ "$(git rev-parse "$c:$1")" = "$(git rev-parse "$head:$1")" ] || { echo "changed after it was added"; return; }
  [ "$(git log -1 --format=%cn "$c")" = "guard broker" ] || { echo "not committed by guard broker"; return; }
  keys=$(git show "$head:$1" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\):.*/\1/p' | sort | tr '\n' ' ')
  [ "$keys" = "$record_keys " ] || { echo "keys are not the CardRecord's"; return; }
  [ "$(git config guard.records 2>/dev/null)" != signed ] || git verify-commit "$c" >/dev/null 2>&1 || echo "unsigned"
}
cards=()
while read -r st f; do
  case $f in runs/_template/*) continue ;; esac
  [ "$st" != A ] || [ -n "$(card_problem "$f")" ] && cards+=("$f")
done < <(git diff --no-renames --name-status "$base...$head" -- 'runs/*/question.card')
if [ ${#cards[@]} -eq 0 ]; then say PASS broker-cards
else say FAIL broker-cards F03 "${cards[*]} is a card only the broker writes; guard run writes it" "$(undo "${cards[@]}")"; fi

# receipt_ok <id>: the broker published receipt <id> on guard/receipts, as lib/guard/receipts-check.sh verifies against
# broker_key: on the base's card (exit 2 is F04). The checker is this file's sibling when the fence runs from a file,
# else the base's guard/run shows the pinned harness's copy; a base that has none proves no receipt.
declare -A receipts=()
checker=""
if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/receipts-check.sh" ]; then
  checker=$(cat "$(dirname "${BASH_SOURCE[0]}")/receipts-check.sh")
fi
receipt_ok() {
  if [ -z "${receipts[$1]+x}" ]; then
    receipts[$1]=1
    [ -n "$checker" ] || checker=$(HPC_GUARD_REF=$base bash -c "$(git show "$base:guard/run" 2>/dev/null)" guard/run \
      --show receipts-check 2>/dev/null </dev/null) || checker=""
    [ -z "$checker" ] || ! bash -c "$checker" receipts-check.sh "$base" "$1" >/dev/null 2>&1 </dev/null || receipts[$1]=0
  fi
  return "${receipts[$1]}"
}
# unproven_rows <ref> <report> [shape]: line numbers of ## Evidence rows with no backticked path that exists at <ref>,
# from the repository top or the report's directory, with any :line suffix dropped, and no backticked receipt id
# (L and 10 hex digits) the broker published. With shape, a token that merely looks like a path or a receipt id is
# enough, which is the rule a modified report's merge-base copy may still be under.
unproven_rows() {
  local ref=$1 f=$2 shape=${3:-} nr tok p
  local -A seen=() ok=()
  while IFS=$'\t' read -r nr tok; do
    seen[$nr]=1
    if [ -n "$shape" ]; then [[ $tok == *[/.]* || $tok =~ ^L[0-9a-f]{10}$ ]] && ok[$nr]=1; continue; fi
    if [[ $tok =~ ^L[0-9a-f]{10}$ ]]; then receipt_ok "$tok" && ok[$nr]=1; continue; fi
    tok=${tok#./}
    [ -n "$tok" ] && [[ $tok != /* && $tok != *..* && $tok != *[[:space:]]* ]] || continue
    for p in "$tok" "${tok%%:*}" "${f%/*}/$tok" "${f%/*}/${tok%%:*}"; do
      [ "$p" != "$f" ] && git cat-file -e "$ref:$p" 2>/dev/null && { ok[$nr]=1; break; }
    done
  done < <(git show "$ref:$f" | awk '
    /^## / { e = ($0 ~ /^## Evidence/); n = 0; next }
    e && /^\|/ { n++; if (n <= 2) next; s = $0; t = 0
      while (match(s, /`[^`]*`/)) { print NR "\t" substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH); t = 1 }
      if (!t) print NR "\t" }')
  for nr in "${!seen[@]}"; do [ -n "${ok[$nr]+x}" ] || echo "$nr"; done | sort -n
}
unproven=""
while read -r st f; do
  [ -n "$f" ] || continue
  rule=""; [ "$st" = M ] && [ -n "$(unproven_rows "$mb" "$f")" ] && rule=shape
  rows=$(unproven_rows "$head" "$f" ${rule:+"$rule"})
  [ -z "$rows" ] || unproven="$unproven $f:$(echo $rows | tr ' ' ',')"
done < <(git diff --name-status --no-renames --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$unproven" ]; then say PASS evidence-paths
else say FAIL evidence-paths F04 "evidence-paths:$unproven cites no committed path or receipt"; fi

ledger_ok() {  # ledger_ok <ref> <file>: ledger_problems finds nothing in the file at the ref
  [ -z "$(git show "$1:$2" 2>/dev/null | ledger_problems "$(git show "$1:${2%/execution.tsv}/question.card" 2>/dev/null)")" ]
}
bad_l="" voids=""
while read -r st f; do
  [ -n "$f" ] || continue
  new=$(git show "$head:$f" 2>/dev/null)
  case $st in
    D) bad_l="$bad_l $f (deleted)"; continue ;;
    M) ledger_ok "$mb" "$f" || continue
       cmp -s <(git show "$mb:$f") <(git show "$head:$f" | head -c "$(git cat-file -s "$mb:$f")") || { bad_l="$bad_l $f (rows changed or removed)"; continue; }
       new=$(git show "$head:$f" | tail -c +"$(( $(git cat-file -s "$mb:$f") + 1 ))") ;;
  esac
  p=$(git show "$head:$f" | ledger_problems "$(git show "$head:${f%/execution.tsv}/question.card" 2>/dev/null)" | head -n 1)
  [ -z "$p" ] || bad_l="$bad_l $f ($p)"
  ! awk -F'\t' '$3 == "void" && $1 !~ /^#/ { found = 1 } END { exit !found }' <<<"$new" || voids="$voids $f"
done < <(git diff --name-status --no-renames --diff-filter=AMD "$base...$head" -- 'runs/*/execution.tsv')
# A void row retracts an agent's own record, so it rides a pull request of run records only, where nothing else hides.
if [ -n "$voids" ]; then
  other=$(git diff --name-only --no-renames "$base...$head" \
    | awk '!/^runs\/[^\/]+\// || /^runs\/_template\// || /\/(question\.card|report\.md)$/ || /^runs\/[^\/]+\/incidents\//' | tr '\n' ' ')
  [ -z "$other" ] || bad_l="$bad_l$voids (a void row goes in a pull request of run records only; this one also changes ${other% })"
fi
if [ -z "$bad_l" ]; then say PASS execution-ledger; else say FAIL execution-ledger F05 "execution-ledger: append rows with a field from the vocabulary; a change to the design needs a new card:$bad_l"; fi

# history_problem <ref> <report>: prints why a run with a ledger fails the rule that its report has a
# ## Execution history section citing every row id, or nothing.
history_problem() {
  local ids body id missing=""
  ids=$(git show "$1:${2%/report.md}/execution.tsv" 2>/dev/null | awk -F'\t' 'NR > 1 && NF && !/^#/ { print $1 }') || return 0
  [ -n "$ids" ] || return 0
  body=$(git show "$1:$2" | awk '/^## / { e = ($0 == "## Execution history") } e')
  if [ -z "$body" ]; then
    echo "no ## Execution history section; harness4research's templates/runs/_template/report.md has it, and guard init --update adds it to runs/_template/report.md"
    return
  fi
  for id in $ids; do grep -qF "\`$id\`" <<<"$body" || missing="$missing $id"; done
  [ -z "$missing" ] || echo "uncited:$missing"
}
bad_x=""
while read -r st f; do
  [ -n "$f" ] || continue
  [ "$st" = M ] && [ -n "$(history_problem "$mb" "$f")" ] && continue
  p=$(history_problem "$head" "$f"); [ -z "$p" ] || bad_x="$bad_x $f ($p)"
done < <(git diff --name-status --no-renames --diff-filter=AM "$base...$head" -- 'runs/*/report.md')
if [ -z "$bad_x" ]; then say PASS execution-history; else say FAIL execution-history F07 "execution-history: ## Execution history must cite every execution.tsv row id:$bad_x"; fi

for ctx in AGENTS.md CLAUDE.md; do
  n=$(git show "$head:$ctx" 2>/dev/null | wc -l)
  [ "$n" -le 150 ] || say WARN context-size "" "$ctx has $n lines; keep landmines only"
done
finish
