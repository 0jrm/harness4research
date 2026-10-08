#!/usr/bin/env bash
# usage: guard review --batch | guard merge --batch | guard ship [--now]
# Runs as lib/batch.sh review | merge | ship [--now]. Every open pull request of origin, except drafts and forks, gets
# a tier from pr_tier in lib/pr.sh.
# review skips a pull request whose last verdict in reviews.tsv is at its head. It approves records without a model,
# reviews small ones read-only, up to review_batch_max in one reviewer session, gives large ones guard review <pr>, and
# queues human ones for a person: one digest item for new question cards, one merge item for each other.
# merge runs guard merge's gate on every pull request approved at its head, lowest number first, and queues one item
# for all it refuses.
# ship runs review and then merge once the batch is due: review_batch_max pull requests wait, or the oldest waiting
# one is ship_interval_hours old. Until then it only refreshes the question card digest. --now runs it at once.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/merge.sh
. "$here/lib/merge.sh"
mode=${1:-}; shift || true
case $mode in
  review|merge) name="guard $mode --batch"; [ $# -eq 0 ] || mode=usage ;;
  ship) name="guard ship"; [ $# -eq 0 ] || [ "$*" = --now ] || mode=usage ;;
  *) mode=usage ;;
esac
[ "$mode" != usage ] || { echo "usage: guard review --batch | guard merge --batch | guard ship [--now]" >&2; exit 64; }
refuse() { echo "$name: $1" >&2; exit 2; }
cards_title="Approve question cards"
refused_title="Merge approved pull requests"
batch_wt=$state/review-worktrees/batch

prs=() notes=() review_ran=0
declare -A title_of ref_of head_of base_of created_of tier_of verdict_of merged refused

# load_prs: sets prs, the open pull requests of origin by number, and for each title_of, ref_of, head_of, base_of,
# created_of (epoch seconds) and tier_of. Notes the drafts, forks and unpushed heads it leaves out.
load_prs() {
  local rows n t r h b fork draft c bad
  bad=$(config_whole review_small_lines) || refuse "$bad"
  rows=$(gh pr list --state open --limit 500 \
    --json number,title,headRefName,headRefOid,baseRefName,isCrossRepository,isDraft,createdAt --jq 'sort_by(.number)[] |
      [.number, .title, .headRefName, .headRefOid, .baseRefName, (.isCrossRepository | tostring), (.isDraft | tostring),
       (.createdAt | fromdateiso8601)] | @tsv' 2>&1) || refuse "gh cannot list the open pull requests: $(why "$rows")"
  git -C "$top" fetch -q origin || refuse "cannot fetch origin."
  while IFS=$'\t' read -r n t r h b fork draft c; do
    [ -n "$n" ] || continue
    if [ "$fork" = true ]; then notes+=("#$n comes from a fork, and guard reviews branches of origin only."); continue; fi
    if [ "$draft" = true ]; then notes+=("#$n is a draft."); continue; fi
    if [ "$(git -C "$top" rev-parse -q --verify "origin/$r" || true)" != "$h" ]; then
      notes+=("#$n waits for its head ${h:0:7}, which origin/$r is not at after a fetch."); continue; fi
    prs+=("$n"); title_of[$n]=$t ref_of[$n]=$r head_of[$n]=$h base_of[$n]=$b created_of[$n]=$c
    tier_of[$n]=$(pr_tier "origin/$b" "$h")
  done <<<"$rows"
}

# verdict_at_head <pr>: prints the last verdict in reviews.tsv when it is at the pull request's head, else nothing.
verdict_at_head() {
  local reviewed verdict
  IFS=$'\t' read -r reviewed verdict _ <<<"$(last_review "$1")"
  [ "$reviewed" != "${head_of[$1]}" ] || echo "$verdict"
}

# close_item <title> <note>: marks the open or acked approve item with this title done.
close_item() {
  local id
  if id=$("$here/bin/guard" needs-you find --kind approve --title "$1"); then "$here/bin/guard" needs-you "done" "$id" --note "$2"; fi
}

# card_pr <pr>: prints the question cards the human-tier pull request adds, and fails when it adds none or also changes
# guard/ or .github/workflows/.
card_pr() {
  local cards
  cards=$(added_cards "origin/${base_of[$1]}" "${head_of[$1]}")
  [ -n "$cards" ] && git -C "$top" diff --quiet "origin/${base_of[$1]}...${head_of[$1]}" -- guard .github/workflows || return 1
  echo "${cards//$'\n'/, }"
}

# refresh_card_digest: keeps one approve item listing every pull request that card_pr accepts, and marks it done when
# there is none.
refresh_card_digest() {
  local n cards entries=() runs=()
  for n in "${prs[@]}"; do
    [ "${tier_of[$n]}" = human ] && cards=$(card_pr "$n") || continue
    entries+=("#$n ${title_of[$n]} ($cards)"); runs+=(--run "gh pr merge $n --squash")
  done
  if [ ${#entries[@]} -eq 0 ]; then close_item "$cards_title" "no open pull request adds a question card"; return; fi
  queue --kind approve --title "$cards_title" --update --source "$name" \
    --why "$(one_line "Only you approve a question card. Read each card on its pull request, then merge the ones you approve: $(printf '%s; ' "${entries[@]}")")" \
    --run "cd $top" "${runs[@]}" --expect "\"Squashed and merged pull request #<n>\" for each." \
    --undo "git revert <merge commit> on a new branch, then open a pull request."
}

# review_session <base> <pr>...: one reviewer session judges the pull requests from a detached checkout of the base,
# whose changes are discarded. Records for each the verdict of its own VERDICT line at the end of the reply, or
# escalate, and queues every verdict but approve.
review_session() {
  local b=$1 log lines line n v r; shift
  resolve_reviewer || refuse "$reviewer_problem. $reviewer_fix"
  git -C "$top" worktree remove --force "$batch_wt" 2>/dev/null || rm -rf "$batch_wt"
  mkdir -p "$(dirname "$batch_wt")" "$state/reviews"
  git -C "$top" worktree add -q --detach "$batch_wt" "origin/$b"
  mkdir "$batch_wt/.guard-review"; echo '*' > "$batch_wt/.guard-review/.gitignore"
  {
    cat "$here/lib/review-batch-prompt.md"
    for n in "$@"; do
      printf '\n# Pull request #%s\n\nBranch %s into %s, head %s.\n\n## Brief\n\n' "$n" "${ref_of[$n]}" "$b" "${head_of[$n]}"
      cat "$(brief_path "${ref_of[$n]}")"
      printf '\n## Diff\n\n```diff\n'; git -C "$top" diff "origin/$b...${head_of[$n]}"; printf '```\n'
    done
  } > "$batch_wt/.guard-review/prompt.md"
  log=$state/reviews/batch-$(date -u +%Y%m%dT%H%M%SZ)-$1.txt
  run_reviewer "$batch_wt" "$log" "Read .guard-review/prompt.md and follow it. End your reply with one VERDICT line per pull request, as it describes." \
    "$# pull request(s) into $b ($(printf '#%s ' "$@" | sed 's/ $//'))"
  if [ "$(git -C "$batch_wt" rev-parse HEAD)" != "$(git -C "$top" rev-parse "origin/$b")" ] || git -C "$batch_wt" status --porcelain | grep -q .; then
    echo "note: the reviewer changed the checkout of $b, and the change is discarded." >&2
  fi
  lines=$(reply_lines "$log" | awk '{ l[NR] = $0 } END { for (i = NR; i > 0 && l[i] ~ /^VERDICT/; i--) print l[i] }')
  for n in "$@"; do
    line=$(grep "^VERDICT #$n:" <<<"$lines" || true)
    if [ $rc -ne 0 ]; then v=escalate r="the reviewer command exited $rc${err:+: ${err:0:160}}"
    elif [[ $line != *$'\n'* && $line =~ ^VERDICT\ \#$n:\ (approve|changes|escalate)\ -\ (.*[^[:space:]].*)$ ]]; then
      v=${BASH_REMATCH[1]} r=${BASH_REMATCH[2]}
    else v=escalate r="the reviewer's reply does not end with one VERDICT line for #$n"; fi
    r=$(one_line "$r")
    record_verdict "$n" "${head_of[$n]}" "$v" "${candidate%% *}" "$r"
    verdict_of[$n]="$v - $r"
    [ "$v" = approve ] || queue_verdict "$n" "$v" "$r" "$log" "$(brief_path "${ref_of[$n]}")"
  done
  git -C "$top" worktree remove --force "$batch_wt" 2>/dev/null || rm -rf "$batch_wt"
}

# review_small <pr>...: review sessions of at most review_batch_max pull requests that share a base branch.
review_small() {
  local max bases=() b n chunk
  max=$(config_whole review_batch_max) || refuse "$max"
  for n in "$@"; do [[ " ${bases[*]} " == *" ${base_of[$n]} "* ]] || bases+=("${base_of[$n]}"); done
  for b in "${bases[@]}"; do
    chunk=()
    for n in "$@"; do
      [ "${base_of[$n]}" = "$b" ] || continue
      chunk+=("$n")
      [ ${#chunk[@]} -lt "$max" ] || { review_session "$b" "${chunk[@]}"; chunk=(); }
    done
    [ ${#chunk[@]} -eq 0 ] || review_session "$b" "${chunk[@]}"
  done
}

# review_batch: reviews each loaded pull request by its tier, and skips one that has a verdict at its head.
review_batch() {
  local n v r at problem rc small=() large=()
  review_ran=1
  refresh_card_digest
  for n in "${prs[@]}"; do
    if [ "${tier_of[$n]}" = human ]; then
      card_pr "$n" >/dev/null || queue_merge "$n" "it changes guard/ or .github/workflows/, which only a human merges." "${ref_of[$n]}"
      verdict_of[$n]="no model review; waits for you"; continue
    fi
    v=$(verdict_at_head "$n")
    if [ -n "$v" ]; then notes+=("#$n already has the verdict $v at ${head_of[$n]:0:7}."); continue; fi
    case ${tier_of[$n]} in
      records) record_verdict "$n" "${head_of[$n]}" approve records-tier "records only; the fence and CI check them"
        verdict_of[$n]="approve - records only; the fence and CI check them" ;;
      small) problem=$(brief_problem "${ref_of[$n]}")
        if [ -z "$problem" ]; then small+=("$n")
        else notes+=("#$n is small and waits for its brief, which carries the user's words: $problem"); fi ;;
      large) large+=("$n") ;;
    esac
  done
  review_small "${small[@]}"
  for n in "${large[@]}"; do
    echo; rc=0; bash "$here/lib/review.sh" "$n" || rc=$?
    if [ $rc -eq 2 ]; then notes+=("#$n is large, and guard review $n refused to start; its message is above."); continue; fi
    IFS=$'\t' read -r at v r <<<"$(last_review "$n")"
    head_of[$n]=$at verdict_of[$n]="$v - $r"
  done
}

# merge_batch: runs the gate on each loaded pull request approved at its head, and queues one item for the refusals.
merge_batch() {
  local n rc entries=() runs=()
  for n in "${prs[@]}"; do
    [ "$(verdict_at_head "$n")" = approve ] || continue
    echo; rc=0; merge_one "$n" || rc=$?
    if [ $rc -eq 0 ]; then merged[$n]=$merge_sha; continue; fi
    refused[$n]=${failed[0]}
    entries+=("#$n ${failed[0]}"); runs+=(--run "gh pr merge $n --squash")
  done
  if [ ${#entries[@]} -eq 0 ]; then close_item "$refused_title" "guard merge refused no approved pull request"; return; fi
  echo
  queue --kind approve --title "$refused_title" --update --source "$name" \
    --why "$(one_line "guard merge refused these approved pull requests, each for the first reason shown. Merge the ones you accept, or fix the reason and run guard ship again: $(printf '%s; ' "${entries[@]}")")" \
    --run "cd $top" "${runs[@]}" --expect "\"Squashed and merged pull request #<n>\" for each." \
    --undo "git revert <merge commit> on a new branch, then open a pull request."
}

# summary: prints the tiers, verdicts, merges, refusals and notes of this run.
summary() {
  local n p t counts=()
  echo; echo "== $name: ${#prs[@]} open pull request(s)"
  if [ $review_ran = 1 ]; then
    for t in records small large human; do
      n=0; for p in "${prs[@]}"; do [ "${tier_of[$p]}" != "$t" ] || n=$((n + 1)); done; counts+=("$t $n")
    done
    echo "tiers: $(printf '%s, ' "${counts[@]}" | sed 's/, $//')"
    for n in "${prs[@]}"; do [ -z "${verdict_of[$n]:-}" ] || echo "  #$n ${tier_of[$n]}: ${verdict_of[$n]}"; done
  fi
  for n in "${prs[@]}"; do
    [ -z "${merged[$n]+set}" ] || echo "merged #$n${merged[$n]:+ as ${merged[$n]:0:7}}"
    [ -z "${refused[$n]:-}" ] || echo "refused #$n: ${refused[$n]}"
  done
  [ ${#notes[@]} -eq 0 ] || printf 'note: %s\n' "${notes[@]}"
}

# ship [--now]: runs review and merge when the batch is due, and otherwise refreshes the question card digest.
ship() {
  local n max interval now oldest="" waiting=()
  max=$(config_whole review_batch_max) || refuse "$max"
  interval=$(config_whole ship_interval_hours) || refuse "$interval"
  load_prs
  for n in "${prs[@]}"; do
    [ "${tier_of[$n]}" != human ] || continue
    case $(verdict_at_head "$n") in ""|approve) ;; *) continue ;; esac
    waiting+=("#$n")
    [ -n "$oldest" ] && [ "$oldest" -le "${created_of[$n]}" ] || oldest=${created_of[$n]}
  done
  now=$(date +%s)
  if [ "$*" != --now ] && [ ${#waiting[@]} -lt "$max" ] && { [ -z "$oldest" ] || [ $((now - oldest)) -lt $((interval * 3600)) ]; }; then
    refresh_card_digest
    if [ -z "$oldest" ]; then echo "$name: nothing waits for review or merge."
    else echo "$name: ${#waiting[@]} pull request(s) wait (${waiting[*]}). The batch is due in about $(( (oldest + interval * 3600 - now + 3599) / 3600 )) hour(s), when the oldest is $interval hours old, or once $max wait. guard ship --now runs it now."; fi
    return
  fi
  review_batch
  merge_batch
  summary
}

trap 'git -C "$top" worktree remove --force "$batch_wt" 2>/dev/null || rm -rf "$batch_wt"' EXIT
case $mode in
  review) load_prs; review_batch; summary ;;
  merge) load_prs; merge_batch; summary ;;
  ship) ship "$@" ;;
esac
