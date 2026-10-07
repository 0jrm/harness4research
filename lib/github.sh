# shellcheck shell=bash

# github_slug <repo>: prints owner/name when origin is on github.com, else nothing.
github_slug() {
  local url
  url=$(git -C "$1" config --get remote.origin.url || true)
  [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] && echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  return 0
}

gh_get() { gh api --method GET "$@" 2>&1; }

# gh prints the JSON error body and then "gh: <message>" without a newline between them.
why() { local last=${1##*$'\n'}; echo "${last##*gh: }"; }

# gh_admin <slug> <branch>: prints true or false, whether this shell's gh login administers the repository. When gh
# fails, prints its output and returns its status, which is 4 when gh is not logged in.
# repos/<slug> reports the user's role, so it says admin for a fine-grained token without the Administration permission
# too. Reading the branch's protection needs that permission: such a token gets 403 "Resource not accessible by personal
# access token".
gh_admin() {
  local role out
  role=$(gh_get "repos/$1" --jq .permissions.admin) || { local rc=$?; echo "$role"; return $rc; }
  [ "$role" = true ] || { echo "$role"; return 0; }
  if ! out=$(gh_get "repos/$1/branches/$2/protection") && [[ $out == *"Resource not accessible by personal access token"* ]]
  then echo false; else echo true; fi
}

# ruleset_missing <slug> <branch> <fence 0|1>: prints what the active rules on the branch fail to require, joined with
# " and ": a pull request, and guard-fence / fence when fence is 1. Prints nothing when they require it all. When gh
# fails, prints its output and returns 1.
ruleset_missing() {
  local rules missing=()
  rules=$(gh_get "repos/$1/rules/branches/$2" \
    --jq '.[] | if .type == "required_status_checks" then "check " + .parameters.required_status_checks[].context else .type end') \
    || { echo "$rules"; return 1; }
  grep -qx pull_request <<<"$rules" || missing+=("a pull request")
  [ "$3" = 0 ] || grep -qxE 'check (guard-fence / )?fence' <<<"$rules" || missing+=("guard-fence / fence")
  [ ${#missing[@]} -eq 0 ] || printf '%s and ' "${missing[@]}" | sed 's/ and $//'
}
