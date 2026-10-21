# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== merge"
gate=(MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false "MOCK_GH_RULES=pull_request
check guard-fence / fence" MOCK_GH_LOG="$tmp/gh.log")
merge() {  # merge [env...]: guard merge 5 here with every gate open, unless an assignment changes one
  rm -f "$tmp/gh.log"
  env -u GH_TOKEN -u GITHUB_TOKEN "${gate[@]}" MOCK_GH_PR="$(pr_json)" "$@" "$guard" merge 5
}
on_github=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=https://github.com/lab/proj.git)
review approve >/dev/null 2>&1
expect merge-unguarded ok '^✓ Squashed and merged pull request lab/proj#5$' -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-unguarded-policy ok "^pass  merge_policy is autonomous by default, since $tmp/xdg/guard/config does not set it$" -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-squash-pinned ok "^pr merge 5 --squash --match-head-commit $(git rev-parse origin/feat/add)$" -- grep '^pr merge' "$tmp/gh.log"
expect merge-never-admin fail - -- grep -q -- --admin "$tmp/gh.log"
expect merge-not-github fail '^FAIL  cannot tell whether the gh login administers the repository: origin is not a github.com remote$' -- merge
"$guard" config set merge_policy semi-manual >/dev/null
expect merge-config-semi-manual fail "^FAIL  merge_policy is semi-manual in $tmp/xdg/guard/config, so a human merges$" -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-config-remedy fail '^      A human merges it, or runs guard config set merge_policy autonomous\.$' -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
"$guard" config set merge_policy autonomous >/dev/null
expect merge-config-set-autonomous ok "^pass  merge_policy is autonomous in $tmp/xdg/guard/config$" -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
"$guard" config set merge_policy "" >/dev/null

cd "$D" || exit 1
git update-ref refs/remotes/origin/feat/add "$(git rev-parse guard/init)"; head5=$(git rev-parse origin/feat/add)
approve_at() { mkdir -p .git/guard; printf 'ts\tpr\thead\tverdict\treviewer\treason\n2026-10-07T00:00:00Z\t5\t%s\t%s\tclaude\tok\n' "$1" "${2:-approve}" > .git/guard/reviews.tsv; }
approve_at "$head5"
expect merge-ok ok '^✓ Squashed and merged pull request lab/proj#5$' -- merge
expect merge-ok-call ok "^pr merge 5 --squash --match-head-commit $head5$" -- grep '^pr merge' "$tmp/gh.log"
expect merge-ok-queues-nothing ok '^Nothing needs you\.$' -- "$guard" needs-you
expect merge-card-default ok '^pass  merge_policy is autonomous by default, since guard/budget.card on origin/main does not set it$' -- merge
expect merge-says-merged ok '^Merged pull request #5 into main\.$' -- merge
expect merge-says-merge-commit ok '^Merged pull request #5 into main as abc1234\.$' -- merge MOCK_GH_PR="$(pr_json '.mergeCommit = {oid: "abc1234def"}')"
expect merge-fence-required ok '^pass  main has an active ruleset requiring a pull request and guard-fence / fence$' -- merge
expect merge-already-merged ok '^Pull request #5 is already merged\.$' -- merge MOCK_GH_PR="$(pr_json '.state = "MERGED"')"
expect merge-admin-fine-grained ok '^pass  the gh login in this shell does not administer lab/proj$' -- \
  merge MOCK_GH_ADMIN=true MOCK_GH_PROTECTION='!Resource not accessible by personal access token'
expect merge-admin fail '^FAIL  the gh login in this shell administers lab/proj, so a merge here could bypass the ruleset$' -- merge MOCK_GH_ADMIN=true
expect merge-admin-no-call fail - -- grep -q '^pr merge' "$tmp/gh.log"
expect merge-admin-remedy fail '^      Run agents with a token that has no Administration permission: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#5-give-agents-weaker-credentials$' -- merge MOCK_GH_ADMIN=true
expect merge-admin-queued ok '^🩺 n1 · approve · Merge PR #5$' -- "$guard" needs-you
expect merge-admin-command ok '^gh pr merge 5 --squash$' -- "$guard" needs-you show n1
expect merge-admin-cd ok "^cd $D$" -- "$guard" needs-you show n1
expect merge-admin-block fail '^🩺 n1 · approve · Merge PR #5$' -- merge MOCK_GH_ADMIN=true
expect merge-logged-out fail '^FAIL  cannot tell whether the gh login in this shell administers lab/proj: To get started with GitHub CLI' -- merge MOCK_GH_TOKEN=
expect merge-no-ruleset fail '^FAIL  main has no active rule requiring a pull request and guard-fence / fence$' -- merge MOCK_GH_RULES=
expect merge-no-fence-rule fail '^FAIL  main has no active rule requiring guard-fence / fence$' -- merge MOCK_GH_RULES=pull_request
expect merge-ruleset-unreadable fail '^FAIL  cannot tell whether main has an active ruleset requiring a pull request and guard-fence / fence: Upgrade to GitHub Pro' -- \
  merge MOCK_GH_RULES='!Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
expect merge-draft fail '^FAIL  pull request #5 is a draft$' -- merge MOCK_GH_PR="$(pr_json '.isDraft = true')"
expect merge-closed fail '^FAIL  pull request #5 is closed$' -- merge MOCK_GH_PR="$(pr_json '.state = "CLOSED"')"
expect merge-failed-check fail '^FAIL  not every check passed: tests \(failure\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "tests", status: "COMPLETED", conclusion: "FAILURE"}]')"
expect merge-pending-check fail '^FAIL  not every check passed: tests \(in_progress\), ci/legacy \(pending\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "tests", status: "IN_PROGRESS", conclusion: ""}, {__typename: "StatusContext", context: "ci/legacy", state: "PENDING"}]')"
expect merge-skipped-check ok '^pass  every check passed \(3\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED"}, {__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS"}]')"
expect merge-no-checks fail '^FAIL  no checks ran on pull request #5, so nothing tested it$' -- merge MOCK_GH_PR="$(pr_json '.statusCheckRollup = []')"
approve_at "$(git rev-parse origin/main~1)"
expect merge-old-head fail "^FAIL  guard review approved $(git rev-parse --short=7 origin/main~1), and the head is now ${head5:0:7}$" -- merge
approve_at "$head5" changes
expect merge-review-changes fail "^FAIL  the last guard review of pull request #5 says changes at ${head5:0:7}$" -- merge
rm .git/guard/reviews.tsv
expect merge-no-review fail '^FAIL  guard review has no verdict for pull request #5$' -- merge
approve_at "$head5"
expect merge-one-item ok '^1$' -- bash -c '"$1" needs-you | grep -c "· Merge PR #5$"' _ "$guard"
rm .git/guard/needs-you.tsv; merge MOCK_GH_ADMIN=true MOCK_GH_PR="$(pr_json '.isDraft = true')" >/dev/null
expect merge-why-lists-all ok '^Why: autonomous merge refused: the gh login in this shell administers lab/proj, .*; pull request #5 is a draft\.$' -- "$guard" needs-you show n1
rm .git/guard/needs-you.tsv
expect merge-gh-refuses fail '^gh refused the merge: GraphQL: Head branch was modified' -- merge MOCK_GH_MERGE='GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)'
expect merge-gh-refuses-queued ok '^Why: gh pr merge refused: GraphQL: Head branch was modified' -- "$guard" needs-you show n1
git -C "$D.wt" switch -q -c semi guard/init; echo "merge_policy: semi-manual" >> "$D.wt/guard/budget.card"
git -C "$D.wt" commit -q -am "semi-manual"; git update-ref refs/remotes/origin/main semi
rm .git/guard/needs-you.tsv
expect merge-semi-manual fail '^FAIL  merge_policy is semi-manual in guard/budget.card on origin/main, so a human merges$' -- merge
expect merge-semi-manual-queued ok '^🩺 n1 · approve · Merge PR #5$' -- "$guard" needs-you
git update-ref refs/remotes/origin/main guard/init
cd "$tmp/wt" || exit 1
