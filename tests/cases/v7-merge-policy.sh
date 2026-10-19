# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== merge policy without rulesets"
P=$tmp/policy
git init -q --bare -b main "$P.git"; git clone -q "$P.git" "$P" 2>/dev/null
git -C "$P" checkout -q -b main; echo "# p" > "$P/README.md"; git -C "$P" add -A; git -C "$P" commit -q -m init
git -C "$P" push -q -u origin main; git -C "$P" remote set-head origin -a >/dev/null
git -C "$P" remote set-url origin https://github.com/lab/policy.git
free_plan='!Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
policy_init() {  # policy_init <MOCK_GH_RULES> <args...>: guard init on lab/policy, fetched from the local bare repo
  env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$P.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/lab/policy.git \
    MOCK_GH_TOKEN=github_pat_agent MOCK_GH_RULES="$1" "$guard" init "$P" --offline "${@:2}"
}
expect init-policy-rulesets ok - -- policy_init pull_request --worktree "$P.wt1"
expect init-policy-rulesets-autonomous ok '^merge_policy: autonomous$' -- grep '^merge_policy:' "$P.wt1/guard/budget.card"
expect init-policy-rulesets-quiet fail - -- bash -c 'policy_init pull_request --worktree "$1.wtx" --branch x | grep -q merge_policy' _ "$P"
git -C "$P" worktree remove --force "$P.wtx" 2>/dev/null; git -C "$P" branch -q -D x 2>/dev/null
git -C "$P" worktree remove --force "$P.wt1"; git -C "$P" branch -q -D guard/init
policy_init "$free_plan" --worktree "$P.wt2" > "$tmp/policy.out" 2>&1
expect init-policy-free-plan ok '^merge_policy: semi-manual$' -- grep '^merge_policy:' "$P.wt2/guard/budget.card"
expect init-policy-free-plan-why ok '^merge_policy is semi-manual in guard/budget.card, because GitHub offers no rulesets on lab/policy \(Upgrade to GitHub Pro' -- cat "$tmp/policy.out"
expect init-policy-unknown ok '^Could not tell whether GitHub offers rulesets on lab/policy \(API rate limit exceeded\), so merge_policy stays autonomous\.' -- \
  policy_init '!API rate limit exceeded' --worktree "$P.wt3" --branch guard/unknown
git -C "$P" worktree remove --force "$P.wt2"; git -C "$P" branch -q -D guard/init
git -C "$P" worktree remove --force "$P.wt3"; git -C "$P" branch -q -D guard/unknown
policy_init pull_request --worktree "$P.wt1" >/dev/null 2>&1
git -C "$P.wt1" push -q "$P.git" HEAD:main; git -C "$P" worktree remove --force "$P.wt1"; git -C "$P" branch -q -D guard/init
git -C "$P" fetch -q "$P.git" main:refs/remotes/origin/main
policy_init "$free_plan" --update --worktree "$P.wt4" > "$tmp/policy.out" 2>&1
expect update-policy-free-plan ok '^merge_policy: semi-manual$' -- grep '^merge_policy:' "$P.wt4/guard/budget.card"
expect update-policy-free-plan-listed ok '^  guard/budget.card$' -- cat "$tmp/policy.out"
expect update-policy-free-plan-why ok '^merge_policy is semi-manual in guard/budget.card, because GitHub offers no rulesets on lab/policy' -- cat "$tmp/policy.out"
expect update-policy-one-line ok '^-merge_policy: autonomous\|\+merge_policy: semi-manual$' -- bash -c 'git -C "$1" diff HEAD~1 -- guard/budget.card | grep "^[-+][^-+]" | paste -sd"|"' _ "$P.wt4"
