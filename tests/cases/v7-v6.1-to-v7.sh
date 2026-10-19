# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== v6.1 to v7 migration"
# A project guarded by v6.1, at the commit its tag names, with its budget filled in and merged to main.
v61=6f8fd7834c4d1ab5ad95b9216b6e1a87799aa82b
git clone -q --shared --no-checkout "$here" "$tmp/h-v6.1" 2>/dev/null; git -C "$tmp/h-v6.1" checkout -q --detach "$v61"
M=$tmp/v61
git init -q --bare -b main "$M.git"; git clone -q "$M.git" "$M" 2>/dev/null
git -C "$M" checkout -q -b main; echo "# p" > "$M/README.md"; git -C "$M" add -A; git -C "$M" commit -q -m init
git -C "$M" push -q -u origin main; git -C "$M" remote set-head origin -a >/dev/null
"$tmp/h-v6.1/bin/guard" init "$M" --worktree "$M.wt" >/dev/null 2>&1
git -C "$tmp/proj" show "$good:guard/budget.card" | sed '/^harness:/d' > "$M.wt/guard/budget.card"
git -C "$M.wt" commit -q -am "chore(guard): set budget"; git -C "$M.wt" push -q origin guard/init:main; git -C "$M.wt" fetch -q origin
cd "$M.wt" || exit 1
m61=$(git rev-parse origin/main)
expect migrate-v61-bin ok '^mode none: no harness: pin on origin/main, so the scripts are guard/bin/ there$' -- "$guard" version
expect version-project-older ok "^project older: guard init $M\.wt --update$" -- "$guard" version
git switch -q --detach origin/main; sed -i '/^schema:/d; /^release:/d' guard/VERSION; git commit -q -am "an install before release stamps"
git push -q origin HEAD:main; git fetch -q origin
expect version-no-release-stamp ok "^project older, installed before release stamps; run guard init $tmp/[^ ]+ --update$" -- "$guard" version
expect version-no-release-header ok 'guard schema 1, installed from ' -- "$guard" version
expect update-schema-1 ok '^  guard/VERSION$' -- "$guard" init "$M" --update --online --worktree "$M.s1" --branch guard/s1
expect update-writes-schema ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$M.s1/guard/VERSION"
git push -q -f origin "$m61":main; git fetch -q origin
expect migrate-proposes ok '^  guard/bin/$' -- bash -c 'set -o pipefail; "$1" init "$2" --update --online --worktree "$2.up" | tee "$2.up.out"' _ "$guard" "$M"
# The proposal is exactly: guard/bin/ deleted, the harness: line added, guard/run replaced, guard/VERSION rewritten, and
# the workflow replaced when the template changed since v6.1.
want=$( { git ls-tree -r --name-only origin/main guard/bin/ | sed 's/^/D\t/'; printf 'M\t%s\n' guard/VERSION guard/budget.card guard/run
  git show origin/main:.github/workflows/guard-fence.yml | cmp -s - "$here/templates/github/workflows/guard-fence.yml" \
    || printf 'M\t.github/workflows/guard-fence.yml\n'; } | sort)
expect migrate-bin-had-scripts ok '^6$' -- bash -c 'grep -c "^D	guard/bin/" <<<"$1"' _ "$want"
expect migrate-files-exact ok '^$' -- diff <(echo "$want") <(changes "$M.up")
expect migrate-card-one-line ok "^\+harness: $pin $" -- card_lines "$M.up"
expect migrate-run-is-shim ok - -- cmp "$here/templates/guard/run" "$M.up/guard/run"
expect migrate-run-executable ok - -- test -x "$M.up/guard/run"
expect migrate-writes-version ok "^installer: $(git -C "$here" rev-parse HEAD)$" -- grep '^installer:' "$M.up/guard/VERSION"
expect migrate-says-bin-gone ok 'a site edit to guard/bin/ no longer runs' -- cat "$M.up.out"
expect migrate-offline-adds-artifact ok '^$' -- bash -c '"$1" init "$2" --update --offline --worktree "$2.off" --branch guard/off >/dev/null &&
  diff <( { echo "$3"; printf "A\t%s\n" "$4"; } | sort) <(git -C "$2.off" diff --name-status --no-renames origin/main HEAD | sort)' _ "$guard" "$M" "$want" "$art"
git -C "$M.up" push -q origin guard/update:main; git fetch -q origin; git switch -q --detach origin/main
expect migrate-runs-pin ok - -- bash -c '[ "$(HPC_HARNESS="$1" guard/run --show fence)" = "$(git -C "$2" show "$3:lib/guard/fence.sh")" ]' _ "$hc" "$here" "$pin_commit"
expect migrate-fence-passes ok 'PASS	guard-untouched' -- env HPC_HARNESS="$hc" guard/run fence origin/main HEAD
expect migrate-version-current ok '^current$' -- env HPC_HARNESS="$hc" "$guard" version
expect migrate-once ok 'Nothing proposed\.$' -- "$guard" init "$M" --update --worktree "$M.up2" --branch guard/again
git revert --no-edit HEAD >/dev/null; git push -q origin HEAD:main; git fetch -q origin
expect migrate-rollback ok '^mode none: ' -- "$guard" version
expect migrate-rollback-runs-bin ok 'PASS	guard-untouched' -- env PATH="$(path_without guard)" guard/run fence origin/main HEAD
cd "$tmp/wt" || exit 1

expect skill-states-schema ok - -- grep -q "describes guard schema $(cat "$here/SCHEMA")\." "$here/skills/safe-autonomous-hpc-science/SKILL.md"
expect contract-names-required ok - -- bash -c 'for k in $(grep "<" "$1/templates/guard/budget.card" | cut -d: -f1); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect contract-names-every-key ok - -- bash -c 'for k in $(cut -d: -f1 "$1/templates/guard/budget.card"); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect envelope-vocabulary-pinned ok - -- bash -c 'a=$(sed -n "s/^readonly ENVELOPE_FIELDS=//p" "$1/lib/guard/launch.sh"); b=$(sed -n "s/^fields=//p" "$1/lib/guard/fence.sh"); [ -n "$a" ] && [ "$a" = "$b" ]' _ "$here"
expect contract-names-check-names ok - -- bash -c 'for k in gpu-hours host-supervision host-memory host-strays host-log-errors execution-within-envelope execution-ledger execution-history card-lineage; do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
