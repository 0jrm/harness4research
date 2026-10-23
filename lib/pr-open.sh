#!/usr/bin/env bash
# usage: guard pr open --title TITLE --request FILE --plan FILE --test COMMAND --body FILE [--item ID] [--scope FILE]
#                      [--base BRANCH]
# Opens the current branch's pull request with its brief. Writes the brief that guard review reads, from the user's
# words copied verbatim into the --request file, the --scope and --plan files and the --test command, then pushes the
# branch and opens the pull request against --base (default main) with the title TITLE, or "[ID] TITLE" for a plan item, and the --body file,
# which describes the change in the implementer's words. The brief stays on this machine: a body or a scope that
# repeats a line of the request is refused. When the branch already has an open pull request, it prints that one's URL
# and changes nothing, so a rerun is safe; a rerun with --scope also adds the scope to that pull request's brief, or
# replaces the one there, until a guard review has read it (a row for it in reviews.tsv or a log in reviews/). Without
# --scope it says, on stderr, how to add one. Exit 0 with the URL, 2 on a refusal, 2 with U01 on bad usage.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
grammar() { sed -n '2,3s/^# *//p' "${BASH_SOURCE[0]}" | tr '\n' ' ' | sed 's/^usage: //; s/ *$//'; }
usage() {  # U01, line 1 the grammar, line 2 the form with only the required arguments
  exec python3 "$here/lib/refusals.py" print U01 what="$(grammar)" \
    next="guard pr open --title TITLE --request FILE --plan FILE --test COMMAND --body FILE"
}
[ "${1:-}" = open ] || usage
shift
case ${1:-} in -h|--help) echo "usage: $(grammar)"; exit 0 ;; esac
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
# shellcheck source=lib/pr.sh
. "$here/lib/pr.sh"
[ -z "$item" ] || [[ $item =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || refuse "--item $item is not a plan item id such as W1.2."
for f in "$request" "$plan" "$body" ${scope:+"$scope"}; do [ -f "$f" ] || refuse "no file $f."; done
grep -q '[^[:space:]]' "$request" || refuse "$request is empty. Copy the user's request into it word for word."

branch=$(git -C "$top" branch --show-current)
[ -n "$branch" ] || refuse "HEAD is detached. Check out the branch the pull request is for."
[ "$branch" != "$base" ] || refuse "the current branch is $base itself. Commit the change on its own branch."

while IFS= read -r line; do
  [ ${#line} -ge 20 ] || continue
  for f in "$body" ${scope:+"$scope"}; do
    if grep -qF -- "$line" "$f"; then refuse "$f repeats a line of the request. The user's words stay in the brief; describe the change in your own."; fi
  done
done < "$request"

# reviewed <number>: whether a guard review has read the pull request: a verdict for it, or a log of a round on it.
reviewed() {
  awk -F'\t' -v n="$1" 'NR > 1 && $2 == n { f = 1 } END { exit !f }' "$state/reviews.tsv" 2>/dev/null \
    || compgen -G "$state/reviews/$1-*" >/dev/null
}

existing=$(gh pr list --head "$branch" --state open --json number,url --jq '.[0] // empty | "\(.number) \(.url)"' 2>&1) \
  || refuse "gh cannot list pull requests: ${existing##*$'\n'}"
if [ -n "$existing" ]; then
  number=${existing%% *}
  if [ -n "$scope" ]; then
    reviewed "$number" && refuse "guard review has already read #$number and its brief, so its scope stays as reviewed. Open the rest of the request as another pull request with its own --scope, or close #$number and open it again with --scope."
    brief=$(brief_path "$branch")
    [ -f "$brief" ] || refuse "no brief for $branch on this machine, so #$number's scope has nowhere to go. Rerun this where the pull request was opened."
    # The brief keeps its request, plan and test command; only the section between them changes.
    python3 - "$brief" "$request" "$scope" <<'PY' || refuse "$request is not the request in the brief of #$number. Give the request it was opened with."
import sys
brief, request, scope = sys.argv[1:]
text = open(brief).read()
head = "## Request (verbatim)\n" + open(request).read() + "\n"
if not text.startswith(head):
    sys.exit(1)
rest = text[len(head):]
if rest.startswith("## Scope\n") and "\n## Plan\n" in rest:
    rest = rest[rest.index("\n## Plan\n") + 1:]
open(brief, "w").write(head + "## Scope\n" + open(scope).read() + "\n" + rest)
PY
    echo "guard pr open: no guard review has read #$number yet, so its brief now has the scope in $scope." >&2
  fi
  echo "${existing#* }"; exit 0
fi

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
[ -n "$scope" ] || echo "guard pr open: no --scope. If this pull request covers only part of the request, rerun this command with --scope FILE before guard review." >&2
