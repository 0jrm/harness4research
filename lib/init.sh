#!/usr/bin/env bash
# usage: guard init <repo> [--branch NAME] [--worktree DIR] [--update]
# Surveys the repo, then proposes guard/ and its companions on a new branch in a separate worktree.
# Never touches the repo's checked-out tree, never overwrites a file, never pushes.
# --update refreshes guard/bin/ and guard/run, and inserts a missing setting or hypothesis
# line into the run templates without changing any other line.
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
# Insert one line when its key is absent. Prefer the line after `after`, else before `before`.
insert_line() {
  local file=$1 line=$2 key=$3 after=$4 before=$5
  [ -f "$file" ] || return 1
  awk -v k="$key" 'index($0, k)==1 { f=1 } END { exit f ? 0 : 1 }' "$file" && return 1
  local tmp; tmp=$(mktemp)
  awk -v line="$line" -v after="$after" -v before="$before" '
    BEGIN { done=0 }
    !done && after != "" && index($0, after)==1 { print; print line; done=1; next }
    !done && before != "" && index($0, before)==1 { print line; print; done=1; next }
    { print }
    END { if (!done) print line }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
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
else
  card="$wt/runs/_template/question.card"
  report="$wt/runs/_template/report.md"
  if insert_line "$card" "setting: <dataset, geometry, code, and pinned commits>" "setting:" "decision_this_informs:" "hypothesis:"; then
    added+=(runs/_template/question.card)
  fi
  if insert_line "$report" "hypothesis: n/a" "hypothesis:" "Question:" "## "; then
    added+=(runs/_template/report.md)
  fi
fi
{
  echo "installer: $(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "pstack: $(git -C "$here/vendor/pstack" rev-parse --short HEAD 2>/dev/null || echo not-installed)"
  echo "installed: $(date -u +%F)"
} > "$wt/guard/VERSION"; added+=(guard/VERSION)

git -C "$wt" add -A
if [ $update = 1 ] && git -C "$wt" diff --cached --quiet -- guard/bin guard/run runs/_template/question.card runs/_template/report.md; then
  git -C "$repo" worktree remove --force "$wt"; git -C "$repo" branch -q -D "$branch"
  echo "guard scripts in $name are already current. Nothing proposed."; exit 0
fi
if [ $update = 1 ]; then msg="chore(guard): refresh guard scripts and fill missing template lines"; else msg="feat(guard): add agent guard, facts file, and survey"; fi
git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-$(git -C "$repo" config user.name || echo guard)}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-$(git -C "$repo" config user.email || echo guard@localhost)}" \
  commit -q -m "$msg" -m "Installed by harness4research. Nothing outside the listed files changed."

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
  4. After merging, protect the default branch, give agents weaker credentials, and cap the
     cluster account. The README's Quickstart, steps 4 to 6, gives each click and command:
     https://github.com/0jrm/harness4research#quickstart
NEXT
