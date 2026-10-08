#!/usr/bin/env bash
# usage: guard init <repo> [--branch NAME] [--worktree DIR] [--update [--force]]
# Surveys the repo, then proposes guard/ and its companions on a new branch in a separate worktree.
# Never touches the repo's checked-out tree, never overwrites a file, never pushes.
# --update three-way merges each installer-owned file, with the template this project was installed from
# as the base, so a human's edits survive and an overlap becomes conflict markers. It adds template keys
# that are new since that install and changes no other line of a human-owned file. It refuses when this
# harness is older than the one that installed the project, unless --force.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/version.sh
. "$here/lib/version.sh"
repo=""; branch=guard/init; wt=""; update=0; force=0; agents_note=""
while [ $# -gt 0 ]; do
  case $1 in
    --branch) branch=$2; shift 2 ;;
    --worktree) wt=$2; shift 2 ;;
    --update) update=1; branch=guard/update; shift ;;
    --force) force=1; shift ;;
    -*) echo "unknown option $1" >&2; exit 64 ;;
    *) repo=$1; shift ;;
  esac
done
[ -n "$repo" ] || { echo "usage: guard init <repo> [--branch NAME] [--worktree DIR] [--update [--force]]" >&2; exit 64; }
repo=$(cd "$repo" && git rev-parse --show-toplevel)
name=$(basename "$repo")
git -C "$repo" fetch -q origin 2>/dev/null || echo "note: could not fetch origin; using local refs" >&2
project_version "$repo"; base=$p_base
git -C "$repo" rev-parse --verify -q "$base" >/dev/null || { echo "cannot find $base in $repo. Set origin/HEAD with: git -C $repo remote set-head origin -a" >&2; exit 2; }
if [ $update = 0 ] && [ $p_guarded = 1 ]; then echo "$name is already guarded on $base. Use guard init $repo --update." >&2; exit 2; fi
if [ $update = 1 ] && [ $p_guarded = 0 ]; then echo "$name has no guard/run on $base yet. Run guard init $repo without --update." >&2; exit 2; fi
if [ $update = 1 ] && [ $force = 0 ] && [ "$(skew)" = harness-older ]; then
  echo "This harness ($(harness_release), schema $h_schema) does not contain the one that installed $name (${p_from}, schema $p_schema)." >&2
  echo "Update the harness with git -C $here pull, then rerun. --force proposes this harness's scripts anyway." >&2
  exit 2
fi
git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null && { echo "branch $branch already exists in $repo. Delete it or pass --branch." >&2; exit 2; }
wt=${wt:-$(dirname "$repo")/$name.$(echo "$branch" | tr / -)}
[ -e "$wt" ] && { echo "worktree path exists: $wt. Pass --worktree." >&2; exit 2; }
git -C "$repo" worktree add -q -b "$branch" "$wt" "$base"

added=(); skipped=(); edited=(); unbased=(); conflicts=(); keys=(); optional=()
from=$p_from; [ "$from" = unknown ] && from=""
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
# merge_in <path under templates/> <dst>: three-way merge with the template at $from as the base.
merge_in() {
  local src=$1 dst=$2 b
  [ -e "$wt/$dst" ] || { place "$t/$src" "$dst"; return; }
  b=$(mktemp)
  if [ -z "$from" ] || ! git -C "$here" show "$from:templates/$src" > "$b" 2>/dev/null; then : > "$b"; unbased+=("$dst"); fi
  [ -s "$b" ] && ! cmp -s "$b" "$wt/$dst" && edited+=("$dst")
  if git merge-file --diff3 -L "$dst (yours)" -L "harness ${from:-unknown}" -L "harness $(harness_release)" "$wt/$dst" "$b" "$t/$src"; then
    git -C "$wt" diff --quiet -- "$dst" || added+=("$dst")
  else conflicts+=("$dst"); fi
  rm -f "$b"
}
key_of() { [[ $1 =~ ^([A-Za-z_]+): ]] && echo "${BASH_REMATCH[1]}:"; }
# add_keys <path under templates/> <dst> <placeholders allowed: 0|1>: insert template keys that are new since $from.
# A key the template already had at $from and the project lacks was removed on purpose, so it stays out.
add_keys() {
  local src=$1 dst=$2 ph=$3 i line key old prev next
  [ -f "$wt/$dst" ] || return 0
  old=$( { [ -n "$from" ] && git -C "$here" show "$from:templates/$src" 2>/dev/null; } || true)
  mapfile -t tl < "$t/$src"
  for i in "${!tl[@]}"; do
    line=${tl[i]}; key=$(key_of "$line") || continue
    awk -v k="$key" 'index($0, k)==1 { f=1 } END { exit f ? 0 : 1 }' <<<"$old" && continue
    if [ "$ph" = 0 ] && [[ $line == *"<"* ]]; then
      grep -q "^$key" "$wt/$dst" || optional+=("$dst: ${line}"); continue
    fi
    prev=""; [ "$i" -gt 0 ] && prev=$(key_of "${tl[i-1]}" || echo "${tl[i-1]}")
    next=$(key_of "${tl[i+1]:-}" || echo "${tl[i+1]:-}")
    insert_line "$wt/$dst" "$line" "$key" "$prev" "$next" && keys+=("$dst: ${line}")
  done
  git -C "$wt" diff --quiet -- "$dst" || added+=("$dst")
}
t=$here/templates
if [ $update = 0 ]; then
  for f in preflight ripples manifest fence code launch; do place "$t/guard/bin/$f.sh" "guard/bin/$f.sh" replace; done
  place "$t/guard/run" guard/run replace
  place "$t/guard/budget.card" guard/budget.card
  place "$t/guard/watch.list" guard/watch.list
  place "$t/guard/README.md" guard/README.md
  place "$t/github/workflows/guard-fence.yml" .github/workflows/guard-fence.yml
  place "$t/runs/_template/question.card" runs/_template/question.card
  place "$t/runs/_template/report.md" runs/_template/report.md
  place "$t/FACTS.md" FACTS.md
  if [ -e "$wt/AGENTS.md" ]; then place "$t/AGENTS.md" guard/AGENTS.proposed.md; skipped+=("AGENTS.md (proposal in guard/AGENTS.proposed.md)")
    agents_note=$'\n'"     Merge $wt/guard/AGENTS.proposed.md into your AGENTS.md, or delete it."
  else place "$t/AGENTS.md" AGENTS.md; fi
  place "$t/CLAUDE.md" CLAUDE.md
  "$here/lib/survey.sh" "$repo" > "$wt/guard/SURVEY.md"; added+=(guard/SURVEY.md)
else
  for f in preflight ripples manifest fence code launch; do merge_in "guard/bin/$f.sh" "guard/bin/$f.sh"; done
  merge_in guard/run guard/run; chmod +x "$wt/guard/run"
  merge_in guard/README.md guard/README.md
  merge_in github/workflows/guard-fence.yml .github/workflows/guard-fence.yml
  add_keys guard/budget.card guard/budget.card 0
  add_keys runs/_template/question.card runs/_template/question.card 1
  add_keys runs/_template/report.md runs/_template/report.md 1
fi
{
  echo "schema: $h_schema"
  echo "installer: $(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "release: $(harness_release)"
  echo "pstack: $(git -C "$here/vendor/cursor-plugins" rev-parse --short HEAD 2>/dev/null || echo not-installed)"
  echo "installed: $(date -u +%F)"
} > "$wt/guard/VERSION"; added+=(guard/VERSION)

git -C "$wt" add -A
if [ $update = 1 ] && [ "$(skew)" = current ] && git -C "$wt" diff --cached --quiet -- . ':!guard/VERSION'; then
  git -C "$repo" worktree remove --force "$wt"; git -C "$repo" branch -q -D "$branch"
  echo "guard scripts in $name are already current. Nothing proposed."; exit 0
fi
if [ $update = 1 ]; then msg="chore(guard): update the guard from harness4research $(harness_release)"; else msg="feat(guard): add agent guard, facts file, and survey"; fi
git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-$(git -C "$repo" config user.name || echo guard)}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-$(git -C "$repo" config user.email || echo guard@localhost)}" \
  commit -q -m "$msg" -m "Installed by harness4research. Nothing outside the listed files changed."

echo "Proposed on branch $branch in worktree $wt"
list() { local head=$1; shift; [ $# -gt 0 ] || return 0; echo; echo "$head"; printf '  %s\n' "$@"; }
if [ $update = 0 ]; then list "Added:" "${added[@]}"; else list "Changed:" "${added[@]}"; fi
list "Left alone because they already exist:" "${skipped[@]}"
list "Your edits were kept in:" "${edited[@]}"
list "Keys added from the templates:" "${keys[@]}"
list "Optional keys you may set:" "${optional[@]}"
list "No recorded install commit, so these were merged as whole files:" "${unbased[@]}"
if [ $update = 1 ]; then
  [[ " ${added[*]} " == *" .github/workflows/"* ]] && { echo; echo "Pushing a change under .github/workflows needs a token with the workflow scope: gh auth refresh -s workflow"; }
  [ -n "$from" ] && ! git -C "$here" diff --quiet "$from" HEAD -- templates/AGENTS.md \
    && { echo; echo "templates/AGENTS.md changed since your install. Compare by hand: git -C $here diff $from HEAD -- templates/AGENTS.md"; }
  if [ ${#conflicts[@]} -gt 0 ]; then
    list "CONFLICTS. Your edits and the harness changed the same lines. Resolve the marked lines in $wt, commit, then push:" "${conflicts[@]}"
    exit 3
  fi
  exit 0
fi
cat <<NEXT

Next steps. Only you can do these.
  1. Read $wt/guard/SURVEY.md.$agents_note
  2. Fill in $wt/guard/budget.card and $wt/guard/watch.list, then commit.
  3. Push and open the PR:
       git -C $wt push -u origin $branch
       gh pr create -R "\$(git -C $wt remote get-url origin)" --head $branch --title "feat(guard): add agent guard" --body-file $wt/guard/README.md
  4. After merging, protect the default branch, give agents weaker credentials, and cap the
     cluster account. guard doctor $repo checks each one, and this page gives each click and command:
     https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md
NEXT
