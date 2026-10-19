# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== v6.1 goes through v7.0"
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
# Schema 8 migrates schema 7 only (design-v8, question 12): a v6.1 project, or one before release stamps, is sent
# through v7.0's --update, and nothing is proposed.
expect update-schema-1-refused fail "^v61 is guard schema 1, and this harness migrates schema 7 only\. Migrate it with v7\.0 first" -- \
  "$guard" init "$M" --update --online --worktree "$M.s1" --branch guard/s1
git push -q -f origin "$m61":main; git fetch -q origin
expect update-schema-6-refused fail "^v61 is guard schema 6, and this harness migrates schema 7 only\." -- "$guard" init "$M" --update --online --worktree "$M.up"
expect update-schema-6-v7-command fail "^  git -C $here worktree add --detach [^ ]+ v7\.0 && [^ ]+/bin/guard init $M --update$" -- \
  "$guard" init "$M" --update --offline --worktree "$M.up"
expect update-schema-6-nothing ok - -- test ! -e "$M.up"
expect update-schema-6-no-branch fail - -- git -C "$M" rev-parse --verify -q refs/heads/guard/update
expect v61-runs-bin ok 'PASS	guard-untouched' -- env PATH="$(path_without guard)" guard/run fence origin/main origin/main
cd "$tmp/wt" || exit 1

expect skill-states-schema ok - -- grep -q "describes guard schema $(cat "$here/SCHEMA")\." "$here/skills/safe-autonomous-hpc-science/SKILL.md"
expect contract-names-required ok - -- bash -c 'for k in $(grep "<" "$1/templates/guard/budget.card" | cut -d: -f1); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect contract-names-every-key ok - -- bash -c 'for k in $(cut -d: -f1 "$1/templates/guard/budget.card"); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect contract-names-check-names ok - -- bash -c 'for k in gpu-hours host-supervision host-memory host-strays host-log-errors execution-within-envelope execution-ledger execution-history card-lineage; do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
