# shellcheck shell=bash
# Sourced by tests/run.sh from $tmp. guard init --update from schema 7 to 8 (design-v8 section 8): a project installed by
# v7.0 gets exactly the listed files changed, keeps every card value, watch.list and its landmines verbatim; a project
# whose AGENTS.md has no landmines heading gets a proposal instead; schema 6 is sent through v7.0 first.
echo "== migrate schema 7 to 8"
v70=42813547a106b7939fc9627ddd7a7e3e42812c35
h70=$tmp/h-v7.0
git clone -q --shared --no-checkout "$here" "$h70" 2>/dev/null; git -C "$h70" checkout -q --detach "$v70"
mpin=$(git -C "$here" describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || git -C "$here" rev-parse HEAD)
# v7_project <dir> [agents text]: a project guarded by v7.0 offline, its card filled in, a watch.list line and a
# landmine added, merged to main. With agents text, the repository had that AGENTS.md before the install.
v7_project() {
  local p=$1
  git init -q --bare -b main "$p.git"; git clone -q "$p.git" "$p" 2>/dev/null
  git -C "$p" checkout -q -b main; echo "# p" > "$p/README.md"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$p/AGENTS.md"
  git -C "$p" add -A; git -C "$p" commit -q -m init
  git -C "$p" push -q -u origin main; git -C "$p" remote set-head origin -a >/dev/null
  "$h70/bin/guard" init "$p" --worktree "$p.wt" --offline >/dev/null 2>&1 || { echo "v7.0 could not install $p"; return 1; }
  sed -i -e 's/^account: .*/account: gom/' -e 's/^start_date: .*/start_date: 2026-09-01/' -e 's/^stop_date: .*/stop_date: 2099-01-01/' \
    -e 's/^max_core_hours: .*/max_core_hours: 10000/' -e 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: 1500/' \
    -e 's/^cores_per_node: .*/cores_per_node: 128/' -e 's/^max_nodes_per_job: .*/max_nodes_per_job: 4/' \
    -e 's/^max_walltime_minutes: .*/max_walltime_minutes: 720/' -e 's/^max_concurrent_jobs: .*/max_concurrent_jobs: 10/' \
    -e 's/^quota_pct_cmd: .*/quota_pct_cmd: echo 42%/' -e 's/^explore_max_nodes: .*/explore_max_nodes: 2/' "$p.wt/guard/budget.card"
  echo "checks: waived kept to show a key v8 no longer reads survives" >> "$p.wt/guard/budget.card"
  echo "src/score.py" >> "$p.wt/guard/watch.list"
  if [ -e "$p.wt/guard/AGENTS.proposed.md" ]; then git -C "$p.wt" rm -q guard/AGENTS.proposed.md
  else echo "- Never rebuild bin/model; it takes a day." >> "$p.wt/AGENTS.md"; fi
  git -C "$p.wt" add -A; git -C "$p.wt" commit -q -m "chore(guard): set budget"
  git -C "$p.wt" push -q origin guard/init:main; git -C "$p" fetch -q origin
}
m_changes() { git -C "$1" diff --name-status --no-renames origin/main HEAD | sort; }
key_state=$tmp/m-state; mkdir -p "$key_state/guard"; echo "ssh-ed25519 AAAAC3NzaTESTKEY guard-broker" > "$key_state/guard/key.pub"

P=$tmp/m7
v7_project "$P"
expect migrate7-fixture-schema ok '^schema: 7$' -- git -C "$P" show origin/main:guard/VERSION
old_pin=$(git -C "$P" show origin/main:guard/budget.card | sed -n 's/^harness: //p')
expect migrate7-proposes ok '^  runs/_template/question.card$' -- bash -c 'set -o pipefail; XDG_STATE_HOME="$4" "$1" init "$2" --update --worktree "$3" | tee "$3.out"' _ \
  "$guard" "$P" "$P.up" "$key_state"
want=$( { printf 'A\tguard/harness-%s.sh\nD\tguard/harness-%s.sh\nD\truns/_template/question.card\n' "$mpin" "$old_pin"
  printf 'M\t%s\n' AGENTS.md guard/VERSION guard/budget.card guard/run
  git -C "$P" show origin/main:.github/workflows/guard-fence.yml | cmp -s - "$here/templates/github/workflows/guard-fence.yml" \
    || printf 'M\t.github/workflows/guard-fence.yml\n'; } | sort)
expect migrate7-files-exact ok '^$' -- diff <(echo "$want") <(m_changes "$P.up")
old_lines=$(git -C "$P" show origin/main:guard/budget.card | wc -l)
expect migrate7-card-keeps-every-line ok '^$' -- diff <(git -C "$P" show origin/main:guard/budget.card | sed "s/^harness: .*/harness: $mpin/") \
  <(head -n "$old_lines" "$P.up/guard/budget.card")
expect migrate7-card-appends ok '^compute holdout_max_submissions ask_deadline approval broker_key $' -- \
  bash -c 'tail -n +"$(($2 + 1))" "$1" | grep -v "^#" | cut -d: -f1 | tr "\n" " "' _ "$P.up/guard/budget.card" "$old_lines"
expect migrate7-card-values ok '^approval: auto ask_deadline: 30m compute: none holdout_max_submissions: 3 $' -- \
  bash -c 'grep -E "^(compute|approval|ask_deadline|holdout_max_submissions):" "$1" | sort | tr "\n" " "' _ "$P.up/guard/budget.card"
expect migrate7-card-comments-no-key ok - -- bash -c '! grep "^#" "$1" | grep -q :' _ "$P.up/guard/budget.card"
expect migrate7-broker-key ok '^broker_key: ssh-ed25519 AAAAC3NzaTESTKEY guard-broker$' -- grep '^broker_key:' "$P.up/guard/budget.card"
expect migrate7-watch-list-same ok - -- git -C "$P.up" diff --quiet origin/main HEAD -- guard/watch.list
expect migrate7-landmines-verbatim ok '^$' -- diff <(git -C "$P" show origin/main:AGENTS.md | sed -n '/^## Project landmines/,$p') \
  <(sed -n '/^## Project landmines/,$p' "$P.up/AGENTS.md")
expect migrate7-agents-top-is-template ok '^$' -- diff <(sed '/^## Project landmines/,$d' "$here/templates/AGENTS.md") \
  <(sed '/^## Project landmines/,$d' "$P.up/AGENTS.md")
expect migrate7-run-is-template ok - -- cmp "$here/templates/guard/run" "$P.up/guard/run"
expect migrate7-run-executable ok - -- test -x "$P.up/guard/run"
expect migrate7-keeps-run-template ok - -- test -f "$P.up/runs/_template/report.md" -a -f "$P.up/runs/_template/execution.tsv"
expect migrate7-version-schema ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$P.up/guard/VERSION"
expect migrate7-version-installer ok "^installer: $(git -C "$here" rev-parse HEAD)$" -- grep '^installer:' "$P.up/guard/VERSION"
expect migrate7-bundle-from-vendor ok - -- bash -c 'bash "$1/lib/vendor.sh" "$2" | cmp - "$3/guard/harness-$2.sh"' _ "$here" "$mpin" "$P.up"
expect migrate7-says-gpu-hours ok 'max_gpu_hours: 0' -- cat "$P.up.out"
expect migrate7-body-gpu-hours ok 'max_gpu_hours: 0' -- git -C "$P.up" log -1 --format=%b
expect migrate7-commit-subject ok '^chore\(guard\): migrate the guard to schema 8' -- git -C "$P.up" log -1 --format=%s
git -C "$P.up" push -q origin guard/update:main; git -C "$P" fetch -q origin
cd "$P.up" || exit 1; git fetch -q origin; git switch -q --detach origin/main
expect_refusal migrate7-preflight-r09 R09 -- guard/run preflight runs/x job.sh
expect_refusal migrate7-ripples-r09-without-guard R09 -- env PATH="$(path_without guard)" guard/run ripples runs/x
expect migrate7-show-gone fail '^usage: guard/run <fence\|code\|manifest\|receipts-check>' -- guard/run --show fence
expect migrate7-fence-runs ok 'PASS	guard-untouched' -- guard/run fence origin/main HEAD
expect migrate7-version-current ok '^current$' -- "$guard" version
expect migrate7-once ok 'Nothing proposed\.$' -- "$guard" init "$P" --update --worktree "$P.up2" --branch guard/again
cd "$tmp" || exit 1

Q=$tmp/m7-placeholder
v7_project "$Q"
expect migrate7-key-placeholder ok '^broker_key: <' -- bash -c 'XDG_STATE_HOME="$1" "$2" init "$3" --update --worktree "$3.up" >/dev/null && grep "^broker_key:" "$3.up/guard/budget.card"' _ \
  "$tmp/m-empty-state" "$guard" "$Q"

N=$tmp/m7-no-heading
v7_project "$N" "# Our rules"
expect migrate7-no-heading-fixture ok - -- bash -c '! git -C "$1" show origin/main:AGENTS.md | grep -q "^## Project landmines"' _ "$N"
expect migrate7-no-heading-proposes ok '^  guard/AGENTS.proposed.md$' -- "$guard" init "$N" --update --worktree "$N.up"
expect migrate7-no-heading-untouched ok - -- git -C "$N.up" diff --quiet origin/main HEAD -- AGENTS.md
expect migrate7-no-heading-proposal-is-template ok - -- cmp "$here/templates/AGENTS.md" "$N.up/guard/AGENTS.proposed.md"
expect migrate7-no-heading-files ok '^A	guard/AGENTS.proposed.md$' -- m_changes "$N.up"

S=$tmp/m6
v61=6f8fd7834c4d1ab5ad95b9216b6e1a87799aa82b
[ -d "$tmp/h-v6.1" ] || { git clone -q --shared --no-checkout "$here" "$tmp/h-v6.1" 2>/dev/null; git -C "$tmp/h-v6.1" checkout -q --detach "$v61"; }
git init -q --bare -b main "$S.git"; git clone -q "$S.git" "$S" 2>/dev/null
git -C "$S" checkout -q -b main; echo "# p" > "$S/README.md"; git -C "$S" add -A; git -C "$S" commit -q -m init
git -C "$S" push -q -u origin main; git -C "$S" remote set-head origin -a >/dev/null
"$tmp/h-v6.1/bin/guard" init "$S" --worktree "$S.wt" >/dev/null 2>&1
git -C "$S.wt" push -q origin guard/init:main; git -C "$S" fetch -q origin
expect migrate6-refused fail "^m6 is guard schema 6, and this harness migrates schema 7 only\. Migrate it with v7\.0 first, merge that pull request, then rerun guard init $S --update:$" -- \
  "$guard" init "$S" --update --worktree "$S.up"
expect migrate6-names-v7 ok "^  git -C $here worktree add --detach $(dirname "$here")/harness4research-v7\.0 v7\.0 && $(dirname "$here")/harness4research-v7\.0/bin/guard init $S --update$" -- \
  bash -c '"$1" init "$2" --update --worktree "$2.up" 2>&1; true' _ "$guard" "$S"
expect migrate6-no-branch fail - -- git -C "$S" rev-parse --verify -q refs/heads/guard/update
expect migrate6-no-worktree ok - -- test ! -e "$S.up"
