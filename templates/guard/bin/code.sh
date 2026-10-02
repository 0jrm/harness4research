#!/usr/bin/env bash
# usage: cwd=$(guard/run code <repo> <commit>)
# Prints the absolute path of a clean worktree of <repo> detached at <commit>, and creates it on first use.
# A relative <repo> resolves from the caller's directory. Worktrees live in $HPC_CODE_ROOT, else
# ${XDG_CACHE_HOME:-$HOME/.cache}/guard/code, never inside <repo> or the current project.
# A rerun prints the same path. A path in any other state is refused, never reset or deleted.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: guard/run code <repo> <commit>" >&2; exit 64; }
repo=$1 commit=$2
refuse() { echo "code: $*" >&2; exit 2; }
inside() { [ -n "$2" ] && [[ $1/ == "$2"/* ]]; }
[[ $repo == /* ]] || repo=${HPC_CALLER_DIR:-$PWD}/$repo
top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || refuse "$repo is not inside a git work tree"
sha=$(git -C "$top" rev-parse --verify --quiet "$commit^{commit}") || refuse "$commit is not a commit in $top"
root=${HPC_CODE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/guard/code}
[[ $root == /* ]] || refuse "code root $root is not absolute. Set HPC_CODE_ROOT to an absolute path."
path=$(realpath -m -- "$root")/$(basename "$top")-${sha:0:12}
project=$(git rev-parse --show-toplevel 2>/dev/null || true)
inside "$path" "$top" && refuse "$path is inside $top. Set HPC_CODE_ROOT outside it."
inside "$path" "$project" && refuse "$path is inside this project, $project. Set HPC_CODE_ROOT outside it."
if [ -e "$path" ] || [ -L "$path" ]; then
  worktrees=$(git -C "$top" worktree list --porcelain)
  grep -qxF "worktree $path" <<<"$worktrees" || refuse "$path exists and is not a worktree of $top"
  head=$(git -C "$path" rev-parse HEAD 2>/dev/null) || refuse "$path has no readable HEAD"
  [ "$head" = "$sha" ] || refuse "$path is at $head, not $sha"
  changes=$(git -C "$path" status --porcelain)
  [ -z "$changes" ] || refuse "$path has $(wc -l <<<"$changes") uncommitted changes, first: $(head -n1 <<<"$changes")"
else
  git -C "$top" worktree add -q --detach "$path" "$sha" >&2 || refuse "git worktree add failed for $path"
fi
echo "$path"
