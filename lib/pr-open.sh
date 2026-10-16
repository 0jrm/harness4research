#!/usr/bin/env bash
# usage: guard pr open --title TITLE --request FILE --plan FILE --test COMMAND --body FILE [--item ID] [--scope FILE]
#                      [--base BRANCH]
# Opens the current branch's pull request with its brief. Writes the brief that guard review reads, from the user's
# words copied verbatim into the --request file, the --scope and --plan files and the --test command, then pushes the
# branch and opens the pull request against --base (default main) with the title TITLE, or "[ID] TITLE" for a plan item, and the --body file,
# which describes the change in the implementer's words. The brief stays on this machine: a body that repeats a line
# of the request is refused. When the branch already has an open pull request, it prints that one's URL and changes
# nothing, so a rerun is safe. Exit 0 with the URL, 2 on a refusal, 64 on bad usage.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
usage() { sed -n '2,3s/^# //p' "${BASH_SOURCE[0]}" >&2; exit 64; }
[ "${1:-}" = open ] || usage
shift
# shellcheck source=lib/pr.sh
. "$here/lib/pr.sh"
refuse() { echo "guard pr open: $1" >&2; exit 2; }

item="" title="" request="" plan="" test_cmd="" body="" scope="" base=main
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case $1 in
    --item) item=$2 ;; --title) title=$2 ;; --request) request=$2 ;; --plan) plan=$2 ;;
    --test) test_cmd=$2 ;; --body) body=$2 ;; --scope) scope=$2 ;; --base) base=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$title" ] && [ -n "$request" ] && [ -n "$plan" ] && [ -n "$test_cmd" ] && [ -n "$body" ] || usage
[ -z "$item" ] || [[ $item =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || refuse "--item $item is not a plan item id such as W1.2."
for f in "$request" "$plan" "$body" ${scope:+"$scope"}; do [ -f "$f" ] || refuse "no file $f."; done
grep -q '[^[:space:]]' "$request" || refuse "$request is empty. Copy the user's request into it word for word."

branch=$(git -C "$top" branch --show-current)
[ -n "$branch" ] || refuse "HEAD is detached. Check out the branch the pull request is for."
[ "$branch" != "$base" ] || refuse "the current branch is $base itself. Commit the change on its own branch."

existing=$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty' 2>&1) \
  || refuse "gh cannot list pull requests: ${existing##*$'\n'}"
if [ -n "$existing" ]; then echo "$existing"; exit 0; fi

while IFS= read -r line; do
  [ ${#line} -ge 20 ] || continue
  if grep -qF -- "$line" "$body"; then refuse "$body repeats a line of the request. The user's words stay in the brief; describe the change in your own."; fi
done < "$request"

brief=$(brief_path "$branch")
mkdir -p "$(dirname "$brief")"
{
  echo "## Request (verbatim)"; cat "$request"; echo
  if [ -n "$scope" ]; then echo "## Scope"; cat "$scope"; echo; fi
  echo "## Plan"; cat "$plan"; echo
  echo "## Test command"; echo "$test_cmd"
} > "$brief"

out=$(git -C "$top" push -q -u origin "HEAD:refs/heads/$branch" 2>&1) || refuse "cannot push $branch: ${out##*$'\n'}"
url=$(gh pr create --base "$base" --head "$branch" --title "${item:+[$item] }$title" --body-file "$body" 2>&1) \
  || refuse "gh cannot open the pull request: ${url##*$'\n'}"
echo "${url##*$'\n'}"
