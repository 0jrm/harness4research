#!/usr/bin/env bash
# usage: guard init <repo> [--branch NAME] [--worktree DIR] [--update]
# Surveys the repo, then proposes guard/ and its companions on a new branch in a separate worktree.
# Never touches the repo's checked-out tree, never overwrites a file, never pushes.
# --update refreshes only guard/bin/ and guard/run from this installer, for a follow-up PR.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=""; branch=guard/init; wt=""; update=0
while [ $# -gt 0 ]; do
  case $1 in
    --branch) branch=$2; shift 2 ;;
    --worktree) wt=$2; shift 2 ;;
    --update) update=1; branch=guard/update; shift ;;
    -*) echo "unknown option $1" >&2; exit 64 ;;
    *) repo=$1; shift ;;
  esac
done
[ -n "$repo" ] || { echo "usage: guard init <repo> [--branch NAME] [--worktree DIR] [--update]" >&2; exit 64; }
repo=$(cd "$repo" && git rev-parse --show-toplevel)
name=$(basename "$repo")
git -C "$repo" fetch -q origin 2>/dev/null || echo "note: could not fetch origin; using local refs" >&2
base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git -C "$repo" rev-parse --verify -q "$base" >/dev/null || { echo "cannot find $base in $repo. Set origin/HEAD with: git -C $repo remote set-head origin -a" >&2; exit 2; }
git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null && { echo "branch $branch already exists in $repo. Delete it or pass --branch." >&2; exit 2; }
wt=${wt:-$(dirname "$repo")/$name.$(echo "$branch" | tr / -)}
[ -e "$wt" ] && { echo "worktree path exists: $wt. Pass --worktree." >&2; exit 2; }
git -C "$repo" worktree add -q -b "$branch" "$wt" "$base"

added=(); skipped=()
place() {
  local src=$1 dst=$2 mode=${3:-keep}
  if [ -e "$wt/$dst" ] && [ "$mode" = keep ]; then skipped+=("$dst"); return; fi
  mkdir -p "$(dirname "$wt/$dst")"; cp -p "$src" "$wt/$dst"; added+=("$dst")
}
t=$here/templates
for f in preflight ripples manifest fence; do place "$t/guard/bin/$f.sh" "guard/bin/$f.sh" replace; done
place "$t/guard/run" guard/run replace
if [ $update = 0 ]; then
  place "$t/guard/budget.card" guard/budget.card
  place "$t/guard/watch.list" guard/watch.list
  place "$t/guard/README.md" guard/README.md
  place "$t/github/workflows/guard-fence.yml" .github/workflows/guard-fence.yml
  place "$t/runs/_template/question.card" runs/_template/question.card
  place "$t/runs/_template/report.md" runs/_template/report.md
  place "$t/FACTS.md" FACTS.md
  if [ -e "$wt/AGENTS.md" ]; then place "$t/AGENTS.md" guard/AGENTS.proposed.md; skipped+=("AGENTS.md (proposal in guard/AGENTS.proposed.md)")
  else place "$t/AGENTS.md" AGENTS.md; fi
  place "$t/CLAUDE.md" CLAUDE.md
  "$here/lib/survey.sh" "$repo" > "$wt/guard/SURVEY.md"; added+=(guard/SURVEY.md)
fi
{
  echo "installer: $(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "pstack: $(git -C "$here/vendor/pstack" rev-parse --short HEAD 2>/dev/null || echo not-installed)"
  echo "installed: $(date -u +%F)"
} > "$wt/guard/VERSION"; added+=(guard/VERSION)

git -C "$wt" add -A
if [ $update = 1 ] && git -C "$wt" diff --cached --quiet -- guard/bin guard/run; then
  git -C "$repo" worktree remove --force "$wt"; git -C "$repo" branch -q -D "$branch"
  echo "guard scripts in $name are already current. Nothing proposed."; exit 0
fi
if [ $update = 1 ]; then msg="chore(guard): refresh guard scripts"; else msg="feat(guard): add agent guard, facts file, and survey"; fi
git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-$(git -C "$repo" config user.name || echo guard)}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-$(git -C "$repo" config user.email || echo guard@localhost)}" \
  commit -q -m "$msg" -m "Installed by safe-autonomous-hpc-science. Nothing outside the listed files changed."

echo "Proposed on branch $branch in worktree $wt"
echo; echo "Added:"; printf '  %s\n' "${added[@]}"
if [ ${#skipped[@]} -gt 0 ]; then echo; echo "Left alone because they already exist:"; printf '  %s\n' "${skipped[@]}"; fi
[ $update = 1 ] && exit 0
cat <<NEXT

Next steps. Only you can do these.
  1. Read $wt/guard/SURVEY.md.
  2. Fill in $wt/guard/budget.card and $wt/guard/watch.list, then commit.
  3. Push and open the PR:
       git -C $wt push -u origin $branch
       gh pr create -R "\$(git -C $wt remote get-url origin)" --head $branch --title "feat(guard): add agent guard" --body-file $wt/guard/README.md
  4. After merging, add a GitHub ruleset on the default branch (Settings > Rules > Rulesets) that
     requires a pull request and the "guard-fence / fence" status check, with only you on the bypass list.
  5. Give agents credentials that cannot bypass that rule. See docs/enforcement.md.
  6. On the cluster, ask for a capped sub-account. Template: docs/cluster-subaccount-request.md.
NEXT
