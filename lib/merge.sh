#!/usr/bin/env bash
# usage: guard merge <pr>
# The gate for an agent's merge. It squash-merges the pull request, pinned to the head it checked, only when every item
# passes: merge_policy is autonomous, the gh login cannot administer the repository, the base branch has an active
# ruleset requiring a pull request (and guard-fence / fence in a guarded project), the pull request is open and not a
# draft, at least one check ran and every check passed, and reviews.tsv records approve at the current head. Otherwise
# it queues the merge for a human and prints that item. Never passes --admin.
# Exit 0 when merged, 1 when gh refused the merge, 2 when this gate refused it.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/config.sh
. "$here/lib/config.sh"
# shellcheck source=lib/github.sh
. "$here/lib/github.sh"
# shellcheck source=lib/pr.sh
. "$here/lib/pr.sh"
enforce=https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#
if [ -t 1 ]; then green=$'\e[32m' red=$'\e[31m' plain=$'\e[0m'; else green="" red="" plain=""; fi
pass() { passed=$((passed+1)); echo "${green}pass${plain}  $1"; }
fail() { failed+=("$1"); echo "${red}FAIL${plain}  $1"; echo "      $2"; }

# merge_one <pr>: prints a pass or FAIL line per item of the gate, and merges when every item passes. Sets head_ref,
# failed, the items that failed or the reason gh refused, and merge_sha, the merge commit when GitHub reports it.
# Returns 0 when merged or already merged, 1 when gh refused the merge, 2 when the gate refused it.
merge_one() {
  local pr=$1 info pr_state draft head_sha base_ref checks failing base guarded slug remedy admin need absent row reviewed
  local verdict out
  passed=0; failed=(); head_ref=""; merge_sha=""
  info=$(gh pr view "$pr" --json state,isDraft,headRefName,headRefOid,baseRefName,statusCheckRollup --jq '
    [.state, (.isDraft | tostring), .headRefName, .headRefOid, .baseRefName, (.statusCheckRollup | length | tostring),
     ([.statusCheckRollup[] | select((.conclusion // .state) as $c | ["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c) | not)
       | "\(.name // .context) (\(if (.conclusion // "") == "" then (.status // .state) else .conclusion end | ascii_downcase))"]
      | join(", "))] | @tsv' 2>&1) || { failed=("gh cannot read pull request #$pr: $(why "$info")"); echo "guard merge: ${failed[0]}" >&2; return 2; }
  IFS=$'\t' read -r pr_state draft head_ref head_sha base_ref checks failing <<<"$info"
  [ "$pr_state" != MERGED ] || { echo "Pull request #$pr is already merged."; return 0; }
  base=origin/$base_ref
  guarded=0; git cat-file -e "$base:guard/run" 2>/dev/null && guarded=1
  slug=$(github_slug .)
  echo "guard merge: pull request #$pr, $head_ref into $base_ref at ${head_sha:0:7}, reading $base as last fetched. Credentials are this shell's."

  read_merge_policy . "$base" "$guarded"
  remedy="A human merges it, or runs guard config set merge_policy autonomous."
  [ $guarded = 0 ] || remedy="A human merges it, or sets merge_policy: autonomous in guard/budget.card on the protected branch."
  if [ "$merge_policy" = autonomous ]; then pass "merge_policy is autonomous $merge_policy_where"
  else fail "merge_policy is $merge_policy $merge_policy_where, so a human merges" "$remedy"; fi

  if [ -z "$slug" ]; then fail "cannot tell whether the gh login administers the repository: origin is not a github.com remote" \
    "Run guard merge in a clone whose origin is on github.com."
  elif ! admin=$(gh_admin "$slug" "$base_ref"); then
    fail "cannot tell whether the gh login in this shell administers $slug: $(why "$admin")" \
      "Run guard merge where gh can read $slug with the agent's token: ${enforce}5-give-agents-weaker-credentials"
  else case $admin in
    false) pass "the gh login in this shell does not administer $slug" ;;
    true) fail "the gh login in this shell administers $slug, so a merge here could bypass the ruleset" \
      "Run agents with a token that has no Administration permission: ${enforce}5-give-agents-weaker-credentials" ;;
    *) fail "cannot tell whether the gh login in this shell administers $slug: GitHub returned '$admin'" \
      "Check the token's permissions on GitHub: ${enforce}5-give-agents-weaker-credentials" ;;
  esac; fi

  need="a pull request"; [ $guarded = 0 ] || need="a pull request and guard-fence / fence"
  if [ -z "$slug" ]; then fail "cannot tell whether $base_ref has an active ruleset requiring $need: origin is not a github.com remote" \
    "Run guard merge in a clone whose origin is on github.com."
  elif ! absent=$(ruleset_missing "$slug" "$base_ref" $guarded); then
    fail "cannot tell whether $base_ref has an active ruleset requiring $need: $(why "$absent")" \
      "Open Settings, Rules, Rulesets on GitHub: ${enforce}4-protect-the-default-branch"
  elif [ -z "$absent" ]; then pass "$base_ref has an active ruleset requiring $need"
  else fail "$base_ref has no active rule requiring $absent" "Add a branch ruleset for $base_ref: ${enforce}4-protect-the-default-branch"; fi

  if [ "$pr_state" != OPEN ]; then fail "pull request #$pr is ${pr_state,,}" "Reopen it if it should merge."
  elif [ "$draft" = true ]; then fail "pull request #$pr is a draft" "Mark it ready with gh pr ready $pr once the work is done."
  else pass "pull request #$pr is open and ready for review"; fi

  if [ "$checks" = 0 ]; then fail "no checks ran on pull request #$pr, so nothing tested it" \
    "Wait for CI to start, or add a workflow that runs on pull requests, then rerun guard merge $pr."
  elif [ -n "$failing" ]; then fail "not every check passed: $failing" \
    "Fix the failing checks and push, or wait for the pending ones, then rerun guard merge $pr."
  else pass "every check passed ($checks)"; fi

  row=$(last_review "$pr")
  IFS=$'\t' read -r reviewed verdict _ <<<"$row"
  if [ -z "$row" ]; then fail "guard review has no verdict for pull request #$pr" "Run guard review $pr."
  elif [ "$verdict" != approve ]; then fail "the last guard review of pull request #$pr says $verdict at ${reviewed:0:7}" \
    "Address the review and run guard review $pr again, or a human decides."
  elif [ "$reviewed" != "$head_sha" ]; then fail "guard review approved ${reviewed:0:7}, and the head is now ${head_sha:0:7}" \
    "Run guard review $pr on the new head."
  else pass "guard review approved the head ${head_sha:0:7}"; fi

  echo
  if [ ${#failed[@]} -gt 0 ]; then echo "$passed passed, ${#failed[@]} failed. Refused."; return 2; fi
  if ! out=$(gh pr merge "$pr" --squash --match-head-commit "$head_sha" 2>&1); then
    echo "gh refused the merge: $out"
    failed=("gh pr merge refused: $(why "$out")")
    return 1
  fi
  [ -z "$out" ] || echo "$out"
  merge_sha=$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null || true)
  echo "Merged pull request #$pr into $base_ref${merge_sha:+ as ${merge_sha:0:7}}."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]] || { echo "usage: guard merge <pr number>" >&2; exit 64; }
  rc=0; merge_one "$1" || rc=$?
  case $rc in
    1) queue_merge "$1" "${failed[0]}." "$head_ref" ;;
    2) [ -z "$head_ref" ] || queue_merge "$1" "autonomous merge refused: $(printf '%s; ' "${failed[@]}" | sed 's/; $//')." "$head_ref" ;;
  esac
  exit $rc
fi
