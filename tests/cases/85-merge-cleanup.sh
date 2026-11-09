# shellcheck shell=bash
# Sourced by tests/run.sh: after a squash-merge, guard merge removes the head branch's clean worktree and deletes the
# local branch, and keeps a dirty worktree, an exp/ branch, and everything when the merge is refused.
echo "== merge cleanup"
C=$tmp/cleanup
git init -q --bare -b main "$C/origin.git"
git clone -q "$C/origin.git" "$C/proj" 2>/dev/null
cd "$C/proj" || exit 1
git commit -q --allow-empty -m init; git push -q origin HEAD:main; git fetch -q origin
mkdir -p .git/guard; printf 'ts\tpr\thead\tverdict\treviewer\treason\n' > .git/guard/reviews.tsv
branch_pr() {  # branch_pr <pr> <branch>: a worktree on a new branch with one commit, approved as pull request <pr>
  git worktree add -q -b "$2" "$C/wt-$1" main
  git -C "$C/wt-$1" commit -q --allow-empty -m "work for #$1"
  printf '2026-11-05T00:00:00Z\t%s\t%s\tapprove\tclaude\tok\n' "$1" "$(git rev-parse "$2")" >> .git/guard/reviews.tsv
}
cleanup_merge() {  # cleanup_merge <pr> <branch> [env...]: guard merge <pr> from the main checkout with every gate open
  local pr=$1 b=$2; shift 2
  env -u GH_TOKEN -u GITHUB_TOKEN MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false MOCK_GH_RULES=pull_request \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=https://github.com/lab/proj.git \
    MOCK_GH_PR="$(jq -nc --arg b "$b" --arg sha "$(git rev-parse "$b")" '{state: "OPEN", isDraft: false,
      headRefName: $b, headRefOid: $sha, baseRefName: "main",
      statusCheckRollup: [{__typename: "CheckRun", name: "tests", status: "COMPLETED", conclusion: "SUCCESS"}]}')" \
    "$@" "$guard" merge "$pr"
}
branch_pr 11 feat/clean; branch_pr 12 feat/dirty; branch_pr 13 exp/keep; branch_pr 14 feat/refused
echo scratch > "$C/wt-12/notes.txt"

expect cleanup-clean ok "^Deleted local branch feat/clean and removed its worktree $C/wt-11\.$" -- cleanup_merge 11 feat/clean
expect cleanup-clean-branch-gone fail - -- git show-ref -q --verify refs/heads/feat/clean
expect cleanup-clean-worktree-gone fail - -- test -e "$C/wt-11"
expect cleanup-dirty ok "^Kept worktree $C/wt-12 and local branch feat/dirty: the worktree has uncommitted changes\.$" -- cleanup_merge 12 feat/dirty
expect cleanup-dirty-kept ok '^scratch$' -- cat "$C/wt-12/notes.txt"
expect cleanup-dirty-branch-kept ok - -- git show-ref -q --verify refs/heads/feat/dirty
expect cleanup-exp ok '^Kept local branch exp/keep: exp/\* branches are never cleaned up\.$' -- cleanup_merge 13 exp/keep
expect cleanup-exp-kept ok - -- git -C "$C/wt-13" symbolic-ref -q HEAD
expect cleanup-refused fail '^FAIL  the gh login in this shell administers lab/proj' -- cleanup_merge 14 feat/refused MOCK_GH_ADMIN=true
expect cleanup-refused-kept ok '^refs/heads/feat/refused$' -- git -C "$C/wt-14" symbolic-ref -q HEAD
git -C "$C/wt-14" commit -q --allow-empty -m "after the review"
expect cleanup-unmerged-commits ok '^Kept local branch feat/refused: its tip is not part of the merged head ' -- \
  cleanup_merge 14 feat/refused MOCK_GH_PR="$(jq -nc --arg sha "$(git rev-parse feat/refused~1)" '{state: "OPEN",
    isDraft: false, headRefName: "feat/refused", headRefOid: $sha, baseRefName: "main",
    statusCheckRollup: [{__typename: "CheckRun", name: "tests", status: "COMPLETED", conclusion: "SUCCESS"}]}')"
expect cleanup-unmerged-kept ok - -- test -d "$C/wt-14"
