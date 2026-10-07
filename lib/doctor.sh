#!/usr/bin/env bash
# usage: guard doctor [repo]
# Read-only checklist of the Quickstart setup, the reviewer, the merge policy and the needs-you queue. Writes nothing;
# calls gh api only with GET.
# Exit 1 when any item fails, else 0. An item this host cannot check is counted apart and never as a pass.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/version.sh
. "$here/lib/version.sh"
# shellcheck source=lib/config.sh
. "$here/lib/config.sh"
# shellcheck source=lib/github.sh
. "$here/lib/github.sh"
[ $# -le 1 ] || { echo "usage: guard doctor [repo]" >&2; exit 64; }
repo=$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null) || { echo "guard doctor: ${1:-.} is not a git repository" >&2; exit 2; }
step=https://github.com/0jrm/harness4research#
enforce=https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#
passed=0; failed=0; unknown=0
if [ -t 1 ]; then green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' plain=$'\e[0m'; else green="" red="" yellow="" plain=""; fi

# result <pass|fail|cannot> <item> [remedy]: one checklist line, with the remedy under anything but a pass.
result() {
  case $1 in
    pass) passed=$((passed+1)); echo "${green}pass${plain}  $2"; return ;;
    fail) failed=$((failed+1)); echo "${red}FAIL${plain}  $2" ;;
    cannot) unknown=$((unknown+1)); echo "${yellow}cannot check from here${plain}  $2" ;;
  esac
  echo "      $3"
}

check_skills() {
  local d s dst wrong
  for d in "$HOME/.agents/skills" "$HOME/.claude/skills" "$HOME/.cursor/skills"; do
    # install.sh links ~/.claude and ~/.cursor only where that tool is installed.
    [ "$d" = "$HOME/.agents/skills" ] || [ -d "${d%/skills}" ] || continue
    wrong=()
    for s in "$here"/skills/*/; do
      s=${s%/}; dst=$d/${s##*/}
      if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then wrong+=("${s##*/} (missing)")
      elif [ "$(readlink -f "$dst")" != "$(readlink -f "$s")" ]; then wrong+=("${s##*/} (is $(readlink -f "$dst" || echo "$dst"))"); fi
    done
    if [ ${#wrong[@]} -eq 0 ]; then result pass "skills in ${d/#$HOME/\~} link to this harness"
    else result fail "skills in ${d/#$HOME/\~} do not link to this harness: $(printf '%s, ' "${wrong[@]}" | sed 's/, $//')" \
      "Run $here/install.sh. It links the skills and skips anything already there: ${step}1-install"; fi
  done
}

check_version() {
  local stamp="installed before release stamps" item
  [ -z "$p_release" ] || stamp="release $p_release"
  item="guard schema $p_schema ($stamp) against harness schema $h_schema ($(harness_release))"
  case $(skew) in
    current) result pass "$item: current" ;;
    project-older) result fail "$item: project older" "Propose the update with guard init $repo --update: ${step}updating-a-guarded-project" ;;
    harness-older) result fail "$item: harness older or on another branch" "Update this harness with git -C $here pull: ${step}updating-a-guarded-project" ;;
    unknown-install) result fail "$item: install commit unknown" "Propose the update with guard init $repo --update --force: ${step}updating-a-guarded-project" ;;
  esac
}

check_card() {
  local keys
  keys=$(awk -F': *' '/</ {printf "%s%s", sep, $1; sep=" "}' <<<"$card")
  if [ -z "$keys" ]; then result pass "guard/budget.card on $base has no placeholders"
  else result fail "guard/budget.card on $base still has placeholders: $keys" \
    "Replace each <placeholder> with your cluster value and merge it. A repository that submits no jobs may leave them: ${step}3-fill-in-the-guard-and-merge-it"; fi
}

check_workflow() {
  local wf
  if wf=$(git -C "$repo" show "$base:.github/workflows/guard-fence.yml" 2>/dev/null) \
    && grep -qx 'name: guard-fence' <<<"$wf" && grep -qx '  fence:' <<<"$wf"; then
    result pass ".github/workflows/guard-fence.yml on $base defines guard-fence / fence"
  else result fail ".github/workflows/guard-fence.yml on $base does not define guard-fence / fence" \
    "Merge the guard pull request that guard init proposed: ${step}3-fill-in-the-guard-and-merge-it"; fi
}

check_fence_run() {
  local out conclusion at url
  if [ -n "$gh_why" ]; then result cannot "whether guard-fence / fence has run on GitHub: $gh_why" \
    "Run guard doctor where gh can read $slug, or open its Actions tab: ${enforce}4-protect-the-default-branch"; return; fi
  if ! out=$(gh_get "repos/$slug/actions/workflows/guard-fence.yml/runs?status=completed&per_page=1" \
    --jq '.workflow_runs[0] | select(.) | "\(.conclusion) \(.created_at) \(.html_url)"'); then
    case $out in
      *"HTTP 404"*) result fail "GitHub has no guard-fence workflow for $slug" "Merge the guard pull request and push it: ${step}3-fill-in-the-guard-and-merge-it" ;;
      *) result cannot "whether guard-fence / fence has run on GitHub: $(why "$out")" "Open the Actions tab of $slug: ${enforce}4-protect-the-default-branch" ;;
    esac; return
  fi
  read -r conclusion at url <<<"$out" || true
  case ${conclusion:-none} in
    none) result fail "guard-fence / fence has never completed a run on GitHub" \
      "Open any small pull request so the check runs once; only then can a ruleset require it: ${enforce}4-protect-the-default-branch" ;;
    # A failure is the fence judging a pull request, so the check exists and works.
    success|failure) result pass "guard-fence / fence has run on GitHub (last completed run: $conclusion, $at)" ;;
    *) result fail "guard-fence / fence last completed run ended $conclusion ($at)" "Open the run and fix the workflow: $url" ;;
  esac
}

check_ruleset() {
  local missing
  if [ -n "$gh_why" ]; then result cannot "whether $branch has an active ruleset requiring guard-fence / fence: $gh_why" \
    "Run guard doctor where gh can read $slug, or open Settings, Rules, Rulesets: ${enforce}4-protect-the-default-branch"; return; fi
  if ! missing=$(ruleset_missing "$slug" "$branch" 1); then
    case $missing in
      *"Upgrade to GitHub Pro"*) result fail "GitHub offers no rulesets on $slug: $(why "$missing")" \
        "Make the repository public, or move it to a paid plan or an organization; without that, nothing protects $branch: ${enforce}4-protect-the-default-branch" ;;
      *) result cannot "whether $branch has an active ruleset requiring guard-fence / fence: $(why "$missing")" \
        "Open Settings, Rules, Rulesets on $slug: ${enforce}4-protect-the-default-branch" ;;
    esac; return
  fi
  if [ -z "$missing" ]; then result pass "$branch has an active ruleset requiring a pull request and guard-fence / fence"
  else result fail "$branch has no active rule requiring $missing" \
    "Add a branch ruleset for the default branch: ${enforce}4-protect-the-default-branch"; fi
}

check_agent_env() {
  local scopes
  if [ -z "${SSH_AUTH_SOCK:-}" ]; then result pass "SSH_AUTH_SOCK is unset in this shell"
  else result fail "SSH_AUTH_SOCK is set in this shell, so an agent started here can push with your SSH key" \
    "Start agents with env -u SSH_AUTH_SOCK and an HTTPS remote: ${enforce}5-give-agents-weaker-credentials"; fi
  case $token in
    '') result pass "no GitHub token in this shell, for gh or GH_TOKEN" ;;
    github_pat_*) result pass "the GitHub token in this shell is fine-grained" ;;
    *) scopes=""
      [ -z "$gh_why" ] && scopes=$(gh api --method GET -i / 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')
      result fail "the GitHub token in this shell is a classic or OAuth token${scopes:+ with scopes $scopes}, which reaches every repository you can" \
        "Run agents with a fine-grained token for the guarded repositories as GH_TOKEN: ${enforce}5-give-agents-weaker-credentials" ;;
  esac
  if [ -z "$token" ]; then result pass "gh has no login in this shell, so it cannot act as a repository admin"
  elif [ -n "$gh_why" ]; then result cannot "whether the GitHub login in this shell administers the repository: $gh_why" \
    "Run guard doctor where gh can read the repository: ${enforce}5-give-agents-weaker-credentials"
  else case $admin in
    false) result pass "the GitHub login in this shell does not administer $slug" ;;
    true) result fail "the GitHub login in this shell administers $slug, so an agent here can bypass the ruleset" \
      "Run agents with a token that has no Administration permission: ${enforce}5-give-agents-weaker-credentials" ;;
    *) result cannot "whether the GitHub login in this shell administers $slug: GitHub returned '$admin'" \
      "Check the token's permissions on GitHub: ${enforce}5-give-agents-weaker-credentials" ;;
  esac; fi
}

check_account() {
  local account rows cap
  account=$(awk -F': *' '$1=="account" {print $2; exit}' <<<"$card")
  if [ -z "$account" ] || [[ $account == *"<"* ]]; then result fail "guard/budget.card on $base sets no account" \
    "Put a capped Slurm sub-account in account: ${enforce}6-cap-the-cluster-account"; return; fi
  if ! command -v sacctmgr >/dev/null; then result cannot "whether Slurm caps account $account: sacctmgr is not on this host" \
    "Run guard doctor on a cluster login node: ${enforce}6-cap-the-cluster-account"; return; fi
  if ! rows=$(sacctmgr -nP show assoc where account="$account" format=User,GrpTRESMins 2>&1); then
    result cannot "whether Slurm caps account $account: $(why "$rows")" "Ask your cluster admins how to read the cap: ${enforce}6-cap-the-cluster-account"; return; fi
  cap=$(awk -F'|' -v me="${USER:-$(id -un)}" '($1 == "" || $1 == me) && $2 ~ /(cpu|billing)=/ {print $2; exit}' <<<"$rows")
  if [ -n "$cap" ]; then result pass "Slurm caps account $account at GrpTRESMins=$cap"
  elif [ -z "$rows" ]; then result fail "Slurm has no account $account" \
    "Ask your cluster admins for it with docs/cluster-subaccount-request.md: ${enforce}6-cap-the-cluster-account"
  else result fail "Slurm sets no GrpTRESMins cap on account $account" \
    "Ask your cluster admins for a hard cap with docs/cluster-subaccount-request.md: ${enforce}6-cap-the-cluster-account"; fi
}

check_reviewer() {
  local exe found
  if ! resolve_reviewer; then result fail "$reviewer_problem" "$reviewer_fix"; return; fi
  read -r exe _ <<<"$reviewer_cmd"; exe=${exe/#\~/$HOME}
  found="on PATH"; [[ $exe != */* ]] || found="an executable file"
  if command -v "$exe" >/dev/null; then result pass "reviewer is $reviewer: $reviewer_cmd, and $exe is $found"
  else result fail "reviewer is $reviewer: $reviewer_cmd, and $exe is not $found" \
    "Install it, or name another command: guard config set reviewer_cmd_$reviewer '<command>'"; fi
}

check_merge_policy() {
  read_merge_policy "$repo" "$base" "$p_guarded"
  if [ "$merge_policy" = autonomous ] && [ "$p_guarded" = 1 ]; then
    result pass "merge_policy is autonomous in $merge_policy_from, so guard merge also needs the ruleset and non-admin login items above to pass"
  elif [ "$merge_policy" = autonomous ]; then
    result pass "merge_policy is autonomous in $merge_policy_from, so guard merge also needs the non-admin login item above and a ruleset requiring a pull request"
  else result pass "merge_policy is $merge_policy in $merge_policy_from, so guard merge queues every merge for a human"; fi
}

check_hook() {
  local f
  [ -d "$HOME/.claude" ] || return 0
  for f in "$HOME/.claude/settings.json" "$repo/.claude/settings.json"; do
    PYTHONPATH=$here/lib python3 -B -c 'import sys; from hooks import load, add_missing_reminders; sys.exit(bool(add_missing_reminders(load(sys.argv[1]))))' \
      "$f" 2>/dev/null || continue
    result pass "Claude Code shows open needs-you items: ${f/#$HOME/\~} runs guard needs-you --remind on SessionStart and UserPromptSubmit"; return
  done
  result fail "Claude Code does not show open needs-you items: neither ~/.claude/settings.json nor $repo/.claude/settings.json runs guard needs-you --remind on SessionStart and UserPromptSubmit" \
    "Run guard hooks install claude"
}

check_needs_you() {
  local queue n=0
  queue=$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)/guard/needs-you.tsv
  [ ! -f "$queue" ] || n=$(awk -F'\t' 'NF == 9 && $1 != "id" { state[$1] = $3 } END { for (id in state) open += state[id] == "open"; print open + 0 }' "$queue")
  case $n in
    0) result pass "no open needs-you items" ;;
    1) result pass "1 open needs-you item; guard needs-you lists it" ;;
    *) result pass "$n open needs-you items; guard needs-you lists them" ;;
  esac
}

project_version "$repo"; base=$p_base; branch=${base#origin/}
slug=$(github_slug "$repo")
gh_why=""; admin=""
if [ -z "$slug" ]; then gh_why="origin is not a github.com remote"
elif ! command -v gh >/dev/null; then gh_why="gh is not on PATH"
elif admin=$(gh_admin "$slug"); then :
elif [ $? -eq 4 ]; then gh_why="gh is not logged in"
else gh_why=$(why "$admin"); fi
token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
[ -n "$token" ] || ! command -v gh >/dev/null || { token=$(gh auth token 2>/dev/null) || token=""; }

echo "guard doctor: $repo, reading $base as last fetched. Credentials are this shell's; run it the way your agent starts."
check_skills
if [ $p_guarded = 1 ]; then
  result pass "guard/run is on $base"
  check_version
  if card=$(git -C "$repo" show "$base:guard/budget.card" 2>/dev/null); then check_card
  else card=""; result fail "$base has no guard/budget.card" "Propose the guard with guard init $repo: ${step}2-propose-the-guard"; fi
else
  card=""; result fail "guard/run is not on $base" "Propose the guard with guard init $repo, then merge it: ${step}2-propose-the-guard"
fi
check_workflow
check_fence_run
check_ruleset
check_agent_env
[ $p_guarded = 1 ] && check_account
check_reviewer
check_merge_policy
check_hook
check_needs_you
echo
echo "$passed passed, $failed failed, $unknown cannot check from here"
[ $failed -eq 0 ]
