#!/usr/bin/env bash
# usage: guard review <pr>
# Runs the configured reviewer on a pull request in a fresh worktree, for up to review_rounds rounds. The reviewer may
# commit small fixes and never pushes; this script pushes them, and a round that added commits is followed by another.
# Approve is recorded only for a round that added no commits. The verdict goes to reviews.tsv and, without the brief,
# to a pull request comment. Exit 0 on approve, 1 on changes or escalate, 2 when it refuses to start.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/config.sh
. "$here/lib/config.sh"
# shellcheck source=lib/pr.sh
. "$here/lib/pr.sh"
[ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: guard review <pr number>" >&2; exit 64; }
pr=$1
refuse() { echo "guard review: $1" >&2; exit 2; }

default_reviewer() {
  if command -v claude >/dev/null; then echo "claude -p --permission-mode acceptEdits --allowedTools Bash"
  elif command -v codex >/dev/null; then echo "codex exec --sandbox danger-full-access"
  elif command -v cursor-agent >/dev/null; then echo "cursor-agent -p --force --trust"
  else return 1; fi
}

reviewer=$(config_get reviewer)
case $reviewer in
  proprietary) cmd=$(config_get reviewer_cmd_proprietary)
    [ -n "$cmd" ] || cmd=$(default_reviewer) || refuse "no reviewer found. Install Claude Code, Codex or Cursor's agent CLI, or name a command: guard config set reviewer_cmd_proprietary '<command>'" ;;
  local) cmd=$(config_get reviewer_cmd_local)
    [ -n "$cmd" ] || refuse "reviewer is local and no local command is set. Set one: guard config set reviewer_cmd_local 'codex exec --oss -m <model>'" ;;
  *) refuse "reviewer is '$reviewer' in $config_file. Set it: guard config set reviewer proprietary" ;;
esac
rounds=$(config_get review_rounds)
[[ $rounds =~ ^[1-9][0-9]*$ ]] || refuse "review_rounds is '$rounds' in $config_file. Set it: guard config set review_rounds 2"

info=$(gh pr view "$pr" --json state,headRefName,headRefOid,baseRefName,isCrossRepository \
  --jq '[.state, .headRefName, .headRefOid, .baseRefName, (.isCrossRepository | tostring)] | @tsv' 2>&1) \
  || refuse "gh cannot read pull request #$pr: ${info##*$'\n'}"
IFS=$'\t' read -r pr_state head_ref head_sha base_ref cross <<<"$info"
[ "$pr_state" = OPEN ] || refuse "pull request #$pr is ${pr_state,,}, so there is nothing to review."
[ "$cross" = false ] || refuse "pull request #$pr comes from a fork. guard review pushes fixes to origin, so it reviews branches of origin only."

brief=$(brief_path "$head_ref")
[ -f "$brief" ] || refuse "no brief for $head_ref. Write $brief with the user's request copied word for word under '## Request (verbatim)', then the plan under '## Plan'. The review-and-merge skill gives the format."
request=$(awk '/^## / { on = ($0 == "## Request (verbatim)"); next } on' "$brief")
[[ $request =~ [^[:space:]] ]] || refuse "the '## Request (verbatim)' section of $brief is empty. Copy the user's request into it word for word."

git -C "$top" fetch -q origin || refuse "cannot fetch origin."
[ "$(git -C "$top" rev-parse -q --verify "origin/$head_ref" || true)" = "$head_sha" ] \
  || refuse "origin/$head_ref is not at the pull request's head ${head_sha:0:7} after a fetch. Push the branch, then rerun."

work=$(mktemp -d); wt=$work/pr-$pr
trap 'git -C "$top" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$work"' EXIT
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
  echo "guard review: pull request #$pr, round $round of $rounds at ${before:0:7}: $cmd" >&2
  rc=0
  (cd "$wt" && env -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=remote.origin.pushurl GIT_CONFIG_VALUE_0=guard-review-never-pushes: \
    bash -c "$cmd \"\$@\"" reviewer "$ask") > "$log" || rc=$?
  last=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1 | tr -d '\r' || true)
  last=${last%"${last##*[![:space:]]}"}
  if [ $rc -ne 0 ]; then verdict=escalate reason="the reviewer command exited $rc"
  elif [[ $last =~ ^VERDICT:\ (approve|changes|escalate)\ -\ (.*[^[:space:]].*)$ ]]; then
    verdict=${BASH_REMATCH[1]} reason=${BASH_REMATCH[2]//$'\t'/ }
  else verdict=escalate reason="the reviewer's last line is not a VERDICT line"; fi
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
[ -s "$state/reviews.tsv" ] || printf 'ts\tpr\thead\tverdict\treviewer\treason\n' > "$state/reviews.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$pr" "$head" "$verdict" "${cmd%% *}" "$reason" >> "$state/reviews.tsv"
gh pr comment "$pr" --body "guard review: $verdict at ${head:0:7}. $reason" >/dev/null \
  || echo "note: could not comment on pull request #$pr." >&2
echo "VERDICT: $verdict - $reason"
echo "The reviewer's report: $log"
case $verdict in
  approve) exit 0 ;;
  changes) queue --kind check --title "Review of PR #$pr asks for changes" --why "$reason" \
    --path "$log" --path "$brief" --source "guard review" ;;
  escalate) queue --kind approve --title "Review of PR #$pr needs your decision" --why "$reason" \
    --path "$log" --path "$brief" --source "guard review" ;;
esac
exit 1
