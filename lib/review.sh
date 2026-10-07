#!/usr/bin/env bash
# usage: guard review <pr>
# Runs the configured reviewer on a pull request in a fresh worktree, for up to review_rounds rounds. The reviewer may
# commit small fixes and never pushes; this script pushes them, and a round that added commits is followed by another.
# Approve is recorded only for a round that added no commits. The verdict goes to reviews.tsv and, without the brief,
# to a pull request comment. Without a configured command, a reviewer that exits nonzero hands the round, from its
# starting commit, to the next default reviewer on PATH.
# Exit 0 on approve, 1 on changes or escalate, 2 when it refuses to start.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/config.sh
. "$here/lib/config.sh"
# shellcheck source=lib/pr.sh
. "$here/lib/pr.sh"
[ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: guard review <pr number>" >&2; exit 64; }
pr=$1
refuse() { echo "guard review: $1" >&2; exit 2; }

resolve_reviewer || refuse "$reviewer_problem. $reviewer_fix"
rounds=$(config_whole review_rounds) || refuse "$rounds"

info=$(gh pr view "$pr" --json state,headRefName,headRefOid,baseRefName,isCrossRepository \
  --jq '[.state, .headRefName, .headRefOid, .baseRefName, (.isCrossRepository | tostring)] | @tsv' 2>&1) \
  || refuse "gh cannot read pull request #$pr: ${info##*$'\n'}"
IFS=$'\t' read -r pr_state head_ref head_sha base_ref cross <<<"$info"
[ "$pr_state" = OPEN ] || refuse "pull request #$pr is ${pr_state,,}, so there is nothing to review."
[ "$cross" = false ] || refuse "pull request #$pr comes from a fork. guard review pushes fixes to origin, so it reviews branches of origin only."

problem=$(brief_problem "$head_ref"); [ -z "$problem" ] || refuse "$problem"
brief=$(brief_path "$head_ref")

git -C "$top" fetch -q origin || refuse "cannot fetch origin."
[ "$(git -C "$top" rev-parse -q --verify "origin/$head_ref" || true)" = "$head_sha" ] \
  || refuse "origin/$head_ref is not at the pull request's head ${head_sha:0:7} after a fetch. Push the branch, then rerun."

wt=$state/review-worktrees/pr-$pr
git -C "$top" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
mkdir -p "$(dirname "$wt")"
trap 'git -C "$top" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"' EXIT
git -C "$top" worktree add -q --detach "$wt" "$head_sha"
mkdir "$wt/.guard-review"; echo '*' > "$wt/.guard-review/.gitignore"
mkdir -p "$state/reviews"
ask="Read .guard-review/prompt.md and follow it. End your reply with the VERDICT line it describes."

for ((round = 1; round <= rounds; round++)); do
  before=$(git -C "$wt" rev-parse HEAD)
  {
    cat "$here/lib/review-prompt.md"
    printf '\n## This pull request\n\n#%s, branch %s into %s, head %s. Round %s of %s.\n\n## Brief\n\n' \
      "$pr" "$head_ref" "$base_ref" "$before" "$round" "$rounds"
    cat "$brief"
    printf '\n## Diff\n\n```diff\n'; git -C "$wt" diff "origin/$base_ref...HEAD"; printf '```\n'
  } > "$wt/.guard-review/prompt.md"
  log=$state/reviews/$pr-${before:0:12}-r$round.txt
  run_reviewer "$wt" "$log" "$ask" "pull request #$pr, round $round of $rounds at ${before:0:7}"
  last=$(reply_lines "$log" | tail -n 1)
  if [ $rc -ne 0 ]; then
    verdict=escalate reason="the reviewer command exited $rc${err:+: ${err:0:160}}"
  elif [[ $last =~ ^VERDICT:\ (approve|changes|escalate)\ -\ (.*[^[:space:]].*)$ ]]; then
    verdict=${BASH_REMATCH[1]} reason=${BASH_REMATCH[2]}
  else verdict=escalate reason="the reviewer's last line is not a VERDICT line"; fi
  reason=$(one_line "$reason")
  git -C "$wt" status --porcelain | grep -q . && echo "note: the reviewer left uncommitted edits, and they are discarded." >&2
  after=$(git -C "$wt" rev-parse HEAD)
  [ "$after" = "$before" ] && break
  git -C "$wt" push -q origin "HEAD:refs/heads/$head_ref" \
    || refuse "cannot push the reviewer's commits to $head_ref. Recover them with git cherry-pick ${before:0:12}..${after:0:12}"
  echo "guard review: pushed $(git -C "$wt" rev-list --count "$before..$after") reviewer commit(s) to $head_ref." >&2
  [ "$verdict" = escalate ] && break
  verdict=changes reason="the reviewer was still committing fixes after $rounds rounds"
done

head=$(git -C "$wt" rev-parse HEAD)
record_verdict "$pr" "$head" "$verdict" "${candidate%% *}" "$reason"
echo "VERDICT: $verdict - $reason"
echo "The reviewer's report: $log"
[ "$verdict" = approve ] && exit 0
queue_verdict "$pr" "$verdict" "$reason" "$log" "$brief"
exit 1
