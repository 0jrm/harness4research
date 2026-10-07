# shellcheck shell=bash disable=SC2034
# Sourced by lib/review.sh and lib/merge.sh inside the pull request's repository. Sets top, the repository root, and
# state, the per-repository local state that every worktree shares and git never commits.
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "guard: run this inside the pull request's repository" >&2; exit 2; }
state=$(cd "$(git rev-parse --git-common-dir)" && pwd)/guard

brief_path() { echo "$state/briefs/${1//\//-}.md"; }

queue() {
  local id
  if id=$(guard needs-you add "$@"); then echo; guard needs-you show "$id"
  else echo "Could not queue this for a human. Tell them directly." >&2; fi
}
