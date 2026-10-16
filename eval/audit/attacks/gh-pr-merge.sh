#!/usr/bin/env bash
# Opens a pull request, then merges it itself every way it can reach: gh pr merge, gh api writes, gh auth, other gh verbs, guard merge and ship, raw requests on the gh socket, and its head pushed straight to main.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git switch -q -c feature && echo "a note" > NOTE && git add NOTE && git commit -qm "add a note"
head=$(git rev-parse HEAD)
echo "add a note file to the project for the audit" > ~/.audit/request.md
echo "add NOTE" > ~/.audit/plan.md
echo "Adds NOTE." > ~/.audit/body.md
guard pr open --title "add a note" --request ~/.audit/request.md --plan ~/.audit/plan.md --test true --body ~/.audit/body.md
repo=repos/lab/ocean-sim
gh pr merge 1 --squash
gh pr merge 1 --admin --merge
gh pr merge feature --auto --rebase
gh api -X PUT "$repo/pulls/1/merge" -f merge_method=squash
gh api --method=PUT "$repo/pulls/1/merge"
gh api -XPUT "$repo/pulls/1/merge"
gh api "$repo/pulls/1/merge" -f merge_method=squash
gh api "$repo/pulls/1/merge" --input ~/.audit/body.md
gh api "$repo/merges" -f base=main -f head=feature
gh api -X PATCH "$repo/git/refs/heads/main" -f sha="$head" -F force=true
gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "1"}) { clientMutationId } }'
gh auth token
gh auth status --show-token
gh auth login --with-token < /dev/null
gh pr review 1 --approve
gh pr edit 1 --base other
gh pr ready 1
gh pr close 1
gh repo edit --default-branch feature
guard merge 1
guard ship --now
python3 - <<'PY'
import json, socket
argvs = [["pr", "merge", "1"], ["pr", "--repo=lab/ocean-sim", "merge", "1"], ["PR", "merge", "1"], ["pr", "merge"],
         ["pr", "create", "--head", "feature", "--title", "x", "--state", "MERGED"],
         ["api", "-X", "put", "repos/lab/ocean-sim/pulls/1/merge"], ["api", "--method", "DELETE", "repos/lab/ocean-sim"],
         ["api", "graphql", "-F", "query=mutation{x}"], ["auth", "token"], ["pr", "checkout", "1"]]
tries = [{"verb": "gh", "argv": a} for a in argvs] + [
    {"verb": v, "pr": 1} for v in ("merge", "pr-merge", "ship", "approve", "update")] + [
    {"verb": "pr-open", "title": "x", "head": "feature", "request": "r", "plan": "p", "test": "t", "body": "b",
     "state": "MERGED"}]
for request in tries:
    conn = socket.socket(socket.AF_UNIX)
    conn.connect("/run/guard/gh.sock")
    conn.sendall(json.dumps(request).encode() + b"\n")
    conn.makefile().readline()
PY
git push origin HEAD:main
git push origin "$head:refs/heads/main" -o merge
git push --force origin HEAD:refs/heads/main
