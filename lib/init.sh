#!/usr/bin/env bash
# usage: guard init <repo> [--branch NAME] [--worktree DIR] [--online|--offline] [--update [--force]]
# Surveys the repo, then proposes guard/ and its companions on a new branch in a separate worktree.
# Never touches the repo's checked-out tree, never overwrites a file, never pushes.
# The project holds no scripts: guard/budget.card's harness: line pins this harness's HEAD, its release tag when HEAD
# is one. Online, guard/run reads the scripts from this clone at the pin. When this host cannot reach the harness's
# origin (offline), init also writes guard/harness-<pin>.sh, the scripts at the pin. --online or --offline overrides.
# --update on a project pinned to another release proposes the new pin: one line of guard/budget.card, and offline the
# vendored file of the new pin in place of the old one. On a project installed before the pin (guard/bin/ on the base
# branch, no harness: line) it proposes the migration once: the harness: line, guard/bin/ deleted, guard/run and the
# workflow from the templates, and guard/VERSION. No other file changes, except merge_policy: when GitHub offers the
# repository no rulesets, init and --update set it to semi-manual and say why. It refuses when this harness is older
# than the project's pin or install, unless --force.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/version.sh
. "$here/lib/version.sh"
# shellcheck source=lib/github.sh
. "$here/lib/github.sh"
# shellcheck source=lib/vendor.sh
. "$here/lib/vendor.sh"
repo=""; branch=guard/init; wt=""; update=0; force=0; agents_note=""; mode=""
while [ $# -gt 0 ]; do
  case $1 in
    --branch) branch=$2; shift 2 ;;
    --worktree) wt=$2; shift 2 ;;
    --online) mode=online; shift ;;
    --offline) mode=offline; shift ;;
    --update) update=1; branch=guard/update; shift ;;
    --force) force=1; shift ;;
    -*) echo "unknown option $1" >&2; exit 64 ;;
    *) repo=$1; shift ;;
  esac
done
[ -n "$repo" ] || { echo "usage: guard init <repo> [--branch NAME] [--worktree DIR] [--online|--offline] [--update [--force]]" >&2; exit 64; }
pin=$(harness_pin) || { echo "guard init pins the harness at a commit, and $here is not a git clone of harness4research." >&2; exit 2; }
repo=$(cd "$repo" && git rev-parse --show-toplevel)
name=$(basename "$repo")
git -C "$repo" fetch -q origin 2>/dev/null || echo "note: could not fetch origin; using local refs" >&2
project_version "$repo"; base=$p_base
git -C "$repo" rev-parse --verify -q "$base" >/dev/null || { echo "cannot find $base in $repo. Set origin/HEAD with: git -C $repo remote set-head origin -a" >&2; exit 2; }
if [ $update = 0 ] && [ $p_guarded = 1 ]; then echo "$name is already guarded on $base. Use guard init $repo --update." >&2; exit 2; fi
if [ $update = 1 ] && [ $p_guarded = 0 ]; then echo "$name has no guard/run on $base yet. Run guard init $repo without --update." >&2; exit 2; fi
if [ $update = 1 ] && [ $force = 0 ]; then
  case $(skew) in
    harness-older)
      if [ -n "$p_pin" ]; then echo "This harness ($(harness_release), schema $h_schema) does not contain the release $name pins (harness: $p_pin, schema $p_schema)." >&2
      else echo "This harness ($(harness_release), schema $h_schema) does not contain the one that installed $name (${p_from}, schema $p_schema)." >&2; fi
      echo "Update the harness with git -C $here pull, then rerun. --force proposes this harness's pin anyway." >&2
      exit 2 ;;
    # A pin whose scripts and templates match this harness's stays, even when this harness is a later commit.
    current) [ -z "$p_pin" ] || pin=$p_pin ;;
  esac
fi
git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null && { echo "branch $branch already exists in $repo. Delete it or pass --branch." >&2; exit 2; }
wt=${wt:-$(dirname "$repo")/$name.$(echo "$branch" | tr / -)}
[ -e "$wt" ] && { echo "worktree path exists: $wt. Pass --worktree." >&2; exit 2; }
git -C "$repo" worktree add -q -b "$branch" "$wt" "$base"

added=(); deleted=(); skipped=()
place() {
  local src=$1 dst=$2 mode=${3:-keep}
  if [ -e "$wt/$dst" ] && [ "$mode" = keep ]; then skipped+=("$dst"); return; fi
  mkdir -p "$(dirname "$wt/$dst")"; cp "$src" "$wt/$dst"; added+=("$dst")
  # cp -p also copies ACLs, which NFS homes such as skynet's refuse; the execute bit is the mode that matters.
  if [ -x "$src" ]; then chmod +x "$wt/$dst"; fi
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
mode_note=""
# pin_project: the harness: line names this harness's pin, and offline, guard/harness-<pin>.sh carries its scripts.
# An update keeps the project's mode unless --online or --offline is given, and drops the old pin's vendored file.
pin_project() {
  local card=$wt/guard/budget.card art=guard/harness-$pin.sh origin; origin=$(harness_origin)
  if [ -n "$mode" ]; then mode_note="--$mode was given"
  elif [ $update = 1 ] && [ -n "$p_pin" ]; then mode=$p_mode; mode_note="The project is $p_mode"
  elif harness_online; then mode=online; mode_note="This host reaches $origin"
  else mode=offline; mode_note="This host cannot reach $origin"; fi
  if grep -q '^harness:' "$card"; then sed -i "s/^harness:.*/harness: $pin/" "$card"
  else insert_line "$card" "harness: $pin" "harness:" "" "account:"; fi
  git -C "$wt" diff --quiet -- guard/budget.card || added+=(guard/budget.card)
  if [ -n "$p_pin" ] && [ -e "$wt/guard/harness-$p_pin.sh" ] && { [ "$p_pin" != "$pin" ] || [ "$mode" = online ]; }; then
    git -C "$wt" rm -q "guard/harness-$p_pin.sh"; deleted+=("guard/harness-$p_pin.sh")
  fi
  if [ "$mode" = offline ]; then
    harness_artifact "$pin" > "$wt/$art" || { echo "could not write $art from $here" >&2; exit 2; }
    git -C "$wt" add -N "$art"; git -C "$wt" diff --quiet -- "$art" || added+=("$art")
    mode_note="Mode: offline. $mode_note, so guard/run reads the scripts from $art on the protected branch."
  else
    mode_note="Mode: online. $mode_note, so guard/run reads the scripts from the harness clone at $pin; keep it checked out there, at $here or the clone HPC_HARNESS names."
  fi
}
if [ $update = 0 ]; then
  place "$t/guard/run" guard/run replace
  place "$t/guard/budget.card" guard/budget.card
  pin_project
  place "$t/guard/watch.list" guard/watch.list
  place "$t/guard/README.md" guard/README.md
  place "$t/github/workflows/guard-fence.yml" .github/workflows/guard-fence.yml
  place "$t/runs/_template/question.card" runs/_template/question.card
  place "$t/runs/_template/report.md" runs/_template/report.md
  place "$t/runs/_template/execution.tsv" runs/_template/execution.tsv
  place "$t/FACTS.md" FACTS.md
  if [ -e "$wt/AGENTS.md" ]; then place "$t/AGENTS.md" guard/AGENTS.proposed.md; skipped+=("AGENTS.md (proposal in guard/AGENTS.proposed.md)")
    agents_note=$'\n'"     Merge $wt/guard/AGENTS.proposed.md into your AGENTS.md, or delete it."
  else place "$t/AGENTS.md" AGENTS.md; fi
  place "$t/CLAUDE.md" CLAUDE.md
  "$here/lib/survey.sh" "$repo" > "$wt/guard/SURVEY.md"; added+=(guard/SURVEY.md)
elif [ -n "$p_pin" ]; then
  pin_project
else
  # The migration from a project installed before the pin: its scripts in guard/bin/ give way to the pinned harness.
  pin_project
  if [ -e "$wt/guard/bin" ]; then git -C "$wt" rm -q -r guard/bin; deleted+=(guard/bin/); fi
  for f in guard/run:guard/run github/workflows/guard-fence.yml:.github/workflows/guard-fence.yml; do
    mkdir -p "$(dirname "$wt/${f#*:}")"; cp "$t/${f%%:*}" "$wt/${f#*:}"
    [ "${f#*:}" = guard/run ] && chmod +x "$wt/guard/run"
    git -C "$wt" add -- "${f#*:}"; git -C "$wt" diff --cached --quiet -- "${f#*:}" || added+=("${f#*:}")
  done
fi
# set_merge_policy: guard merge refuses every merge without a ruleset, so a card whose repository GitHub offers no
# rulesets gets merge_policy: semi-manual. Sets policy_note to say so, or to say that gh could not tell.
policy_note=""
set_merge_policy() {
  local card=$wt/guard/budget.card slug out
  [ -f "$card" ] && [ "$(awk -F': *' '$1 == "merge_policy" { print $2; exit }' "$card")" != semi-manual ] || return 0
  slug=$(github_slug "$repo")
  [ -n "$slug" ] && command -v gh >/dev/null || return 0
  if out=$(ruleset_missing "$slug" "${base#origin/}" 0); then return 0; fi
  if [[ $out != *"Upgrade to GitHub Pro"* ]]; then
    policy_note="Could not tell whether GitHub offers rulesets on $slug ($(why "$out")), so merge_policy stays autonomous. guard doctor $repo checks it."
    return 0
  fi
  if grep -q '^merge_policy:' "$card"; then sed -i 's/^merge_policy:.*/merge_policy: semi-manual/' "$card"
  else echo "merge_policy: semi-manual" >> "$card"; fi
  [[ " ${added[*]} " == *" guard/budget.card "* ]] || added+=(guard/budget.card)
  policy_note="merge_policy is semi-manual in guard/budget.card, because GitHub offers no rulesets on $slug ($(why "$out")). guard merge refuses every merge without a ruleset, so a person merges each pull request. Set it to autonomous once $slug can have a ruleset."
}
set_merge_policy

# guard/VERSION records the install, so a pin move leaves it alone.
if [ $update = 0 ] || [ -z "$p_pin" ]; then
  {
    echo "schema: $h_schema"
    echo "installer: $(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "release: $(harness_release)"
    echo "pstack: $(git -C "$here/vendor/cursor-plugins" rev-parse --short HEAD 2>/dev/null || echo not-installed)"
    echo "installed: $(date -u +%F)"
  } > "$wt/guard/VERSION"; added+=(guard/VERSION)
fi

git -C "$wt" add -A
if [ $update = 1 ] && git -C "$wt" diff --cached --quiet; then
  git -C "$repo" worktree remove --force "$wt"; git -C "$repo" branch -q -D "$branch"
  echo "The guard in $name is current at harness: $pin. Nothing proposed."; exit 0
fi
if [ $update = 0 ]; then msg="feat(guard): add agent guard, facts file, and survey"
elif [ -n "$p_pin" ]; then msg="chore(guard): pin harness4research $pin"
else msg="chore(guard): migrate the guard to harness4research $pin, which the harness: pin names"; fi
git -C "$wt" -c user.name="${GIT_AUTHOR_NAME:-$(git -C "$repo" config user.name || echo guard)}" \
  -c user.email="${GIT_AUTHOR_EMAIL:-$(git -C "$repo" config user.email || echo guard@localhost)}" \
  commit -q -m "$msg" -m "Installed by harness4research. Nothing outside the listed files changed."

echo "Proposed on branch $branch in worktree $wt"
list() { local head=$1; shift; [ $# -gt 0 ] || return 0; echo; echo "$head"; printf '  %s\n' "$@"; }
if [ $update = 0 ]; then list "Added:" "${added[@]}"; else list "Changed:" "${added[@]}"; fi
list "Deleted:" "${deleted[@]}"
list "Left alone because they already exist:" "${skipped[@]}"
[ -z "$policy_note" ] || { echo; echo "$policy_note"; }
[ -z "$mode_note" ] || { echo; echo "$mode_note"; }
if [ $update = 1 ]; then
  if [ -z "$p_pin" ]; then
    echo; echo "The scripts now come from harness4research at $pin, so a site edit to guard/bin/ no longer runs; guard/run and the workflow are the templates'. The pull request's diff shows what each drops."
  fi
  [[ " ${added[*]} " == *" .github/workflows/"* ]] && { echo; echo "Pushing a change under .github/workflows needs a token with the workflow scope: gh auth refresh -s workflow"; }
  from=$p_from; [ "$from" = unknown ] && from=""
  [ -n "$from" ] && git -C "$here" cat-file -e "$from^{commit}" 2>/dev/null && ! git -C "$here" diff --quiet "$from" HEAD -- templates/AGENTS.md \
    && { echo; echo "templates/AGENTS.md changed since your install. Compare by hand: git -C $here diff $from HEAD -- templates/AGENTS.md"; }
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
