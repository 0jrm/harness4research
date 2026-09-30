#!/usr/bin/env bash
# usage: guard archive <repo> [--remote NAME]
# Tags every remote branch as archive/<date>/<branch> in the local repo. Pushes and deletes nothing.
# Prints the commands to publish the tags and to delete the branches that carry nothing new.
set -euo pipefail
repo=""; remote=origin
while [ $# -gt 0 ]; do
  case $1 in --remote) remote=$2; shift 2 ;; -*) echo "unknown option $1" >&2; exit 64 ;; *) repo=$1; shift ;; esac
done
[ -n "$repo" ] || { echo "usage: guard archive <repo> [--remote NAME]" >&2; exit 64; }
cd "$repo"
git fetch -q "$remote" 2>/dev/null || echo "note: could not fetch $remote; using local refs" >&2
base=$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null || echo "$remote/main")
day=$(date +%F); merged=(); open=()
while read -r ref; do
  b=${ref#"$remote"/}
  [ "$ref" = "$base" ] && continue
  tag="archive/$day/$b"
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag "$tag" "$ref"
  if [ "$(git rev-list --count "$base..$ref")" = 0 ]; then merged+=("$b"); else open+=("$b ($(git rev-list --count "$base..$ref") commits not on $base)"); fi
done < <(git for-each-ref --format='%(refname:lstrip=2)' "refs/remotes/$remote" | grep -v '/HEAD$')

echo "Tagged ${#merged[@]} merged and ${#open[@]} unmerged branches under archive/$day/ in the local repo."
echo; echo "Publish the tags so the archive survives on GitHub:"
echo "  git -C $repo push $remote 'refs/tags/archive/$day/*'"
if [ ${#merged[@]} -gt 0 ]; then
  echo; echo "These branches carry nothing that is not on $base. After the tags are pushed, delete them with:"
  printf '  git -C %s push %s --delete' "$repo" "$remote"; printf ' %s' "${merged[@]}"; echo
fi
if [ ${#open[@]} -gt 0 ]; then
  echo; echo "These carry unmerged work. Decide each one yourself:"; printf '  %s\n' "${open[@]}"
fi
