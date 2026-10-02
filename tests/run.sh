#!/usr/bin/env bash
# usage: tests/run.sh
# End-to-end checks against throwaway git repos and a fake Slurm. Exit 1 on the first unexpected result.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard=$here/bin/guard
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export PATH="$here/tests/mock-bin:$PATH" USER=tester GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0
expect() {  # expect <name> <want: ok|fail> <grep pattern or -> -- command...
  local name=$1 want=$2 pat=$3; shift 4
  local out rc; out=$("$@" 2>&1); rc=$?
  local got=ok; [ $rc -ne 0 ] && got=fail
  if [ "$got" = "$want" ] && { [ "$pat" = - ] || grep -q -E -- "$pat" <<<"$out"; }; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (exit $rc, wanted $want, pattern '$pat')"; sed 's/^/     /' <<<"$out" | tail -8; fi
}
path_without() {  # path_without <cmd>: prints a PATH like this one on which <cmd> is not found
  local cmd=$1 shadow=$tmp/no-$1 out="" d f IFS=:
  mkdir -p "$shadow"
  for d in $PATH; do
    if [ -e "$d/$cmd" ]; then
      for f in "$d"/*; do [ "${f##*/}" = "$cmd" ] || [ -e "$shadow/${f##*/}" ] || ln -s "$f" "$shadow/"; done
      d=$shadow
    fi
    [[ :$out: == *":$d:"* ]] || out=${out:+$out:}$d
  done
  echo "$out"
}

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/proj" 2>/dev/null
cd "$tmp/proj" || exit 1
git checkout -q -b main
printf '# Proj\nSee `src/old.py` for the scorer.\nNone of the three options below is implemented. Pick one.\n' > README.md
mkdir -p src; echo 'x = 1  # HACK until the real error file exists' > src/new.py
git add -A; git commit -q -m init; git push -q -u origin main; git remote set-head origin -a >/dev/null
git switch -q -c stale; git push -q -u origin stale; git switch -q main
git commit -q --allow-empty -m "runhub: You are working on proj at /home/someone/proj, please fix things"; git push -q
git clone -q "$tmp/origin.git" "$tmp/proj/nested-copy" 2>/dev/null

echo "== survey"
expect survey-stale-branch ok 'origin/stale' -- "$guard" survey "$tmp/proj"
expect survey-missing-path ok 'names `src/old.py`' -- "$guard" survey "$tmp/proj"
expect survey-undecided ok 'Pick one' -- "$guard" survey "$tmp/proj"
expect survey-hack ok 'src/new.py:1' -- "$guard" survey "$tmp/proj"
expect survey-nested ok 'nested git repository `./nested-copy`' -- "$guard" survey "$tmp/proj"
expect survey-prompt-commit ok 'You are working' -- "$guard" survey "$tmp/proj"
expect survey-read-only ok '^$' -- git -C "$tmp/proj" status --porcelain --untracked-files=no
expect survey-header ok 'from the working tree of `.*/proj`; branches compared against `origin/main`' -- "$guard" survey "$tmp/proj"
echo "uncommitted line" >> README.md
expect survey-dirty-warning ok '^warning: working tree has 2 uncommitted changes; document findings reflect it$' -- \
  bash -c '"$1" survey "$2" | sed -n 3p' _ "$guard" "$tmp/proj"
git checkout -q -- README.md
rm -rf "$tmp/proj/nested-copy"

echo "== archive"
expect archive-tags ok 'Tagged 1 merged' -- "$guard" archive "$tmp/proj"
expect archive-tag-exists ok 'archive/' -- git -C "$tmp/proj" tag -l 'archive/*/stale'
expect archive-no-push ok '^$' -- git ls-remote --tags "$tmp/origin.git"

echo "== init"
expect init-proposes ok 'guard/budget.card' -- "$guard" init "$tmp/proj" --worktree "$tmp/wt"
expect init-leaves-checkout ok '^main$' -- git -C "$tmp/proj" branch --show-current
expect init-committed ok 'feat\(guard\)' -- git -C "$tmp/wt" log -1 --format=%s
expect init-survey-file ok 'Survey of proj' -- cat "$tmp/wt/guard/SURVEY.md"
expect init-no-overwrite fail - -- "$guard" init "$tmp/proj" --worktree "$tmp/wt2"
expect workflow-yaml ok - -- python3 -c "import yaml,sys; yaml.safe_load(open('$tmp/wt/.github/workflows/guard-fence.yml'))"
git init -q --bare -b main "$tmp/agents-origin.git"
git clone -q "$tmp/agents-origin.git" "$tmp/agents" 2>/dev/null
echo "# Our rules" > "$tmp/agents/AGENTS.md"
git -C "$tmp/agents" add -A; git -C "$tmp/agents" commit -q -m init
git -C "$tmp/agents" push -q -u origin HEAD:main; git -C "$tmp/agents" remote set-head origin -a >/dev/null
expect init-agents-proposal ok '^     Merge .*/guard/AGENTS.proposed.md into your AGENTS.md, or delete it\.$' -- "$guard" init "$tmp/agents" --worktree "$tmp/agents-wt"

echo "== merge the guard, as the human would"
cd "$tmp/wt" || exit 1
cat > guard/budget.card <<CARD
account: gom
start_date: 2026-09-01
stop_date: 2099-01-01
max_core_hours: 10000
verification_reserve_core_hours: 1500
cores_per_node: 128
max_nodes_per_job: 4
max_walltime_minutes: 720
max_concurrent_jobs: 10
quota_pct_cmd: echo 42%
CARD
printf 'runs/*/checks/*\ntests\n' > guard/watch.list
git commit -q -am "chore(guard): set budget"; git push -q origin guard/init:main; git fetch -q origin
git switch -q -c agent/run origin/main
R=runs/2026-09-29-demo; mkdir -p "$R"
printf '#!/bin/bash\n#SBATCH --time=04:00:00\n#SBATCH --nodes=2\nguard/run manifest "$1" "$0"\n' > job.sh

echo "== preflight"
expect preflight-no-card fail 'not committed' -- guard/run preflight "$R" job.sh
cp runs/_template/question.card "$R/question.card"; git add -A; git commit -q -m "run: question card"
expect preflight-ok ok 'SBATCH .*--account=gom --job-name=2026-09-29-demo' -- guard/run preflight "$R" job.sh --array=0-3
expect preflight-no-scheduler fail '^preflight: no scheduler on this host; guard/run manifest is the only allowed step here$' -- \
  env PATH="$(path_without sbatch)" guard/run preflight "$R" job.sh
expect preflight-account-wins ok 'SBATCH --account=other .*--account=gom' -- guard/run preflight "$R" job.sh --account=other
expect preflight-walltime fail 'exceeds max_walltime' -- guard/run preflight "$R" job.sh --time=1-00:00:00
expect preflight-budget fail 'exceeds 8500 available' -- guard/run preflight "$R" job.sh --nodes=4 --time=12:00:00 --array=0-9%2
expect preflight-reserve-open ok 'available=10000' -- env HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: <core-hours held back for baselines and verifier jobs>/' guard/budget.card
git commit -q -am "placeholder reserve"
expect preflight-reserve-placeholder fail "^PREFLIGHT FAIL: budget card 'verification_reserve_core_hours' is still a placeholder" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: 1500/; s/^cores_per_node: .*/cores_per_node: 128 cores/' guard/budget.card
git commit -q -am "unit in cores_per_node"
expect preflight-budget-not-integer fail "^PREFLIGHT FAIL: budget card 'cores_per_node' must be a whole number: 128 cores$" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~2
sed -i 's/max_core_hours: 10000/max_core_hours: 99999/' guard/budget.card; git commit -q -am "raise budget"
expect preflight-card-edit fail 'guard/ differs' -- guard/run preflight "$R" job.sh
printf '#!/usr/bin/env bash\necho SBATCH bypassed\n' > guard/bin/preflight.sh; git commit -q -am "neuter preflight"
expect run-uses-protected-copy fail 'guard/ differs' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~2
echo "metric: changed" >> "$R/question.card"; git commit -q -am "edit card"
expect preflight-card-frozen fail 'edited after its first commit' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
expect explore-no-card ok 'SBATCH .*--job-name=explore-sketch' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
expect explore-capped fail 'exceeds max_nodes_per_job=1' -- guard/run preflight runs/explore-sketch job.sh
expect explore-one-task fail 'one task at a time' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00 --array=0-3

echo "== ripples"
mkdir -p "$R/checks"; printf '#!/bin/bash\necho "nan count 3"; exit 1\n' > "$R/checks/nan.sh"; chmod +x "$R/checks/nan.sh"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|13000|240\n102|2026-09-29-demo|FAILED|10|240\n103|other|FAILED|1|1\n' > "$tmp/rows"
export MOCK_SACCT_ROWS=$tmp/rows
expect ripples-states fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
expect ripples-walltime fail 'RIPPLE.walltime-headroom.100:100% 101:90%' -- guard/run ripples "$R"
expect ripples-check fail 'RIPPLE.check:nan.sh.nan count 3' -- guard/run ripples "$R"
expect ripples-watched fail 'RIPPLE.watched-paths' -- guard/run ripples "$R"
expect ripples-quota fail 'PASS.quota.42%' -- guard/run ripples "$R"
expect ripples-other-run-ignored fail 'retries.2 not' -- guard/run ripples "$R"
printf '101|2026-09-29-demo|COMPLETED|100|240\n' > "$tmp/rows"; rm -rf "$R/checks"
expect ripples-clean ok 'PASS.budget.30 of 10000' -- guard/run ripples "$R"
expect ripples-no-sacct ok 'UNCHECKED.job-states.*UNCHECKED.walltime-headroom.*UNCHECKED.retries.*UNCHECKED.budget.*PASS.quota.42%' -- \
  env PATH="$(path_without sacct)" bash -c 'set -o pipefail; guard/run ripples "$1" 2>&1 | tr "\n" " "' _ "$R"
pre=$(git rev-parse HEAD); mkdir -p "$R/incidents"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|100|240\n102|2026-09-29-demo|FAILED|10|240\n' > "$tmp/rows"
printf '# Incident 0\njob: 10\n' > "$R/incidents/0.md"; git add -A; git commit -q -m "run: incident 0"
expect ripples-incident-exact-id fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
printf '# Incident 1\njob: 100\n' > "$R/incidents/1.md"; printf '# Incident 2\njob: 102\n' > "$R/incidents/2.md"
expect ripples-incident-uncommitted fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
git add -A; git commit -q -m "run: incidents 1 and 2"
expect ripples-handled-states ok 'HANDLED.job-states.100:TIMEOUT->incidents/1.md 102:FAILED->incidents/2.md' -- guard/run ripples "$R"
expect ripples-handled-walltime ok 'HANDLED.walltime-headroom.100:100%->incidents/1.md' -- guard/run ripples "$R"
expect ripples-handled-retries ok 'PASS.retries.0 not completed' -- guard/run ripples "$R"
expect ripples-handled-count ok 'PASS.handled-failures.2 of 2' -- guard/run ripples "$R"
echo '103|2026-09-29-demo|FAILED|10|240' >> "$tmp/rows"; printf '# Incident 3\njob: 103\n' > "$R/incidents/3.md"
git add -A; git commit -q -m "run: incident 3"
expect ripples-handled-cap fail 'RIPPLE.handled-failures.3 handled, over max_handled_failures=2' -- guard/run ripples "$R"
git reset -q --hard "$pre"
unset MOCK_SACCT_ROWS

echo "== manifest"
echo "$tmp/rows" > "$R/inputs.list"
expect manifest-writes ok - -- env SLURM_JOB_ID=555 LOADEDMODULES=hycom/2.3 bash job.sh "$R"
expect manifest-content ok 'modules: hycom/2.3' -- cat "$R/manifest-555.txt"
expect manifest-idempotent ok 'manifest exists' -- env SLURM_JOB_ID=555 bash job.sh "$R"
rm -f "$R"/manifest-* "$R/inputs.list"

echo "== fence"
git switch -q -c pr/clean origin/main; mkdir -p runs/r1; cp runs/_template/question.card runs/r1/; git add -A; git commit -q -m "run: r1"
expect fence-clean ok 'PASS.guard-untouched' -- guard/run fence origin/main HEAD
expect fence-clean-setting ok 'PASS.setting-key' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/r1/report.md
printf '| Claim | Value | Artifact | Job | Commit |\n' > /dev/null
sed -i '/^|---|---|---|---|---|$/a | RMSE 50-200 m | 0.81 (0.06) | `runs/r1/metrics.csv` | 812400 | a1b2c3d |\n| looks great | 23% | none | - | - |' runs/r1/report.md
git add -A; git commit -q -m "report"
expect fence-unproven fail 'FAIL.evidence-paths.*runs/r1/report.md:' -- guard/run fence origin/main HEAD
git switch -q -c pr/explore origin/main; mkdir -p runs/explore-a; cp runs/_template/report.md runs/explore-a/; git add -A; git commit -q -m x
expect fence-explore-report fail 'FAIL.no-exploration-reports' -- guard/run fence origin/main HEAD
git switch -q -c pr/guard origin/main; echo "max_nodes_per_job: 64" >> guard/budget.card; git commit -q -am x
expect fence-guard fail 'FAIL.guard-untouched' -- guard/run fence origin/main HEAD
git switch -q -c pr/workflow origin/main; echo "# off" >> .github/workflows/guard-fence.yml; git commit -q -am x
expect fence-workflow fail 'FAIL.guard-untouched.*guard-fence.yml' -- guard/run fence origin/main HEAD
git switch -q -c pr/tests origin/main; mkdir -p tests; echo x > tests/t; git add -A; git commit -q -m x
expect fence-watched fail 'FAIL.watched-paths.*tests/t' -- guard/run fence origin/main HEAD
git push -q origin pr/clean:refs/heads/pr-clean; git switch -q -c pr/card origin/pr-clean
echo "metric: moved" >> runs/r1/question.card; git commit -q -am x
expect fence-card fail 'FAIL.question-cards-frozen.*runs/r1/question.card' -- guard/run fence origin/pr-clean HEAD

git switch -q -c pr/no-setting origin/main; mkdir -p runs/ns; cp runs/_template/question.card runs/ns/
sed -i '/^setting:/d' runs/ns/question.card
git add -A; git commit -q -m x
expect fence-card-no-setting fail 'FAIL.setting-key' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na origin/main; mkdir -p runs/hn
cp runs/_template/question.card runs/hn/; cp runs/_template/report.md runs/hn/
git add -A; git commit -q -m x
expect fence-hypothesis-na ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-case origin/main; mkdir -p runs/hc
cp runs/_template/question.card runs/hc/; cp runs/_template/report.md runs/hc/
sed -i 's/^hypothesis: .*/hypothesis: N\/A/' runs/hc/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-case ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-wide origin/main; mkdir -p runs/hw
cp runs/_template/question.card runs/hw/; cp runs/_template/report.md runs/hw/
awk 'BEGIN{line="hypothesis: \357\274\256\357\274\217\357\274\241"} /^hypothesis: /{print line; next} {print}' runs/hw/report.md > runs/hw/report.md.new
mv runs/hw/report.md.new runs/hw/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-wide ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-dot origin/main; mkdir -p runs/hd
cp runs/_template/question.card runs/hd/; cp runs/_template/report.md runs/hd/
sed -i 's/^hypothesis: .*/hypothesis: N.A./' runs/hd/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-dot fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-match origin/main; mkdir -p runs/hm
cp runs/_template/question.card runs/hm/; cp runs/_template/report.md runs/hm/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hm/question.card runs/hm/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-match ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-lt origin/main; mkdir -p runs/hl
cp runs/_template/question.card runs/hl/; cp runs/_template/report.md runs/hl/
sed -i 's/^hypothesis: .*/hypothesis: layer increment < 1e-6/' runs/hl/question.card runs/hl/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-lessthan ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-mismatch origin/main; mkdir -p runs/hx
cp runs/_template/question.card runs/hx/; cp runs/_template/report.md runs/hx/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hx/question.card
sed -i 's/^hypothesis: .*/hypothesis: increment grows with depth/' runs/hx/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-mismatch fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-ph origin/main; mkdir -p runs/hp
cp runs/_template/question.card runs/hp/; cp runs/_template/report.md runs/hp/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hp/question.card
sed -i 's/^hypothesis: .*/hypothesis: <placeholder>/' runs/hp/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-placeholder fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-head origin/main; mkdir -p runs/hh
cp runs/_template/question.card runs/hh/; cp runs/_template/report.md runs/hh/
sed -i '/^hypothesis:/d' runs/hh/report.md
sed -i '/^## Open questions$/a hypothesis: n/a' runs/hh/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-heading fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/legacy-card origin/main; mkdir -p runs/legacy
cp runs/_template/question.card runs/legacy/
sed -i '/^setting:/d' runs/legacy/question.card
git add -A; git commit -q -m x
git push -q origin pr/legacy-card:refs/heads/pr-legacy-card
git switch -q -c pr/legacy-report origin/pr-legacy-card
cp runs/_template/report.md runs/legacy/
git add -A; git commit -q -m x
expect fence-legacy-setting ok 'PASS.setting-key' -- guard/run fence origin/pr-legacy-card HEAD
expect fence-legacy-hypothesis ok 'PASS.hypothesis-line' -- guard/run fence origin/pr-legacy-card HEAD

git switch -q -c pr/old-report origin/main; mkdir -p runs/old
cp runs/_template/question.card runs/_template/report.md runs/old/
sed -i '/^hypothesis:/d' runs/old/report.md
git add -A; git commit -q -m x
git push -q origin pr/old-report:refs/heads/pr-old-report
git switch -q -c pr/old-report-edit origin/pr-old-report
echo "A later note." >> runs/old/report.md; git commit -q -am x
expect fence-legacy-report-modified ok 'PASS.hypothesis-line' -- guard/run fence origin/pr-old-report HEAD

echo "== init --update"
git -C "$tmp/proj" fetch -q origin
expect update-noop ok 'already current' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt3"
expect init-refuses-guarded fail 'already guarded' -- "$guard" init "$tmp/proj" --worktree "$tmp/wt6"
expect version-current ok '^current$' -- "$guard" version
good=$(git rev-parse origin/main)
set_version() {  # set_version <sed expression>: commit an edited guard/VERSION straight to main
  git switch -q --detach origin/main; sed -i "$1" guard/VERSION; git commit -q -am "version: $1"
  git push -q origin HEAD:main; git -C "$tmp/proj" fetch -q origin
}
set_version 's/^installer: .*/installer: 0000000000000000000000000000000000000000/'
expect version-harness-older ok '^harness older' -- "$guard" version
expect update-refuses-unknown-installer fail 'does not contain the one that installed' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
expect update-force ok 'guard/VERSION' -- "$guard" init "$tmp/proj" --update --force --worktree "$tmp/wt6"
expect update-force-records ok "^installer: $(git -C "$here" rev-parse HEAD)$" -- grep '^installer:' "$tmp/wt6/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt6"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
set_version 's/^schema: .*/schema: 99/'
expect update-refuses-newer-schema fail 'schema 99' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
set_version '/^schema:/d'
expect version-project-older ok '^project older' -- "$guard" version
expect update-schema-1 ok 'guard/VERSION' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
expect update-writes-schema ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$tmp/wt6/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt6"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
old_rev=$(git -C "$here" rev-parse "$(git -C "$here" log -1 --format=%H -S'hypothesis: n/a' -- templates/runs/_template/report.md)^")
old_install() {  # old_install: commit to main the guard files as the harness at $old_rev installed them
  git switch -q --detach "$good"
  for f in guard/bin/preflight.sh guard/bin/ripples.sh guard/bin/manifest.sh guard/bin/fence.sh guard/run guard/README.md \
    runs/_template/question.card runs/_template/report.md; do git -C "$here" show "$old_rev:templates/$f" > "$f"; done
  git -C "$here" show "$old_rev:templates/github/workflows/guard-fence.yml" > .github/workflows/guard-fence.yml
  sed -i "s/^installer: .*/installer: $old_rev/; /^schema:/d" guard/VERSION
}
old_install
sed -i 's/-le 150 \]/-le 200 ]/' guard/bin/fence.sh
sed -i 's/^Question: .*/Question: our wording/' runs/_template/report.md
echo "custom_note: leave this" >> runs/_template/question.card
git commit -q -am "an older install with site edits"; git push -q -f origin HEAD:main; git -C "$tmp/proj" fetch -q origin
expect version-old-install ok '^project older' -- "$guard" version
expect path-runs-project-copy ok 'PASS.guard-untouched' -- "$guard" fence origin/main HEAD
expect path-not-harness-copy fail - -- bash -c '"$1" fence origin/main HEAD | grep -q hypothesis-line' _ "$guard"
git init -q "$tmp/plain"
expect path-refuses-unguarded fail 'runs inside a guarded project' -- bash -c 'cd "$1" && "$2" ripples runs/x' _ "$tmp/plain" "$guard"
expect update-from-old ok 'guard/bin/fence.sh' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt7"
expect update-reports-edit ok '^  guard/bin/fence.sh$' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt8" --branch guard/again
expect update-merged-new-rule ok 'hypothesis-line' -- cat "$tmp/wt7/guard/bin/fence.sh"
expect update-kept-site-edit ok '-le 200 \]' -- cat "$tmp/wt7/guard/bin/fence.sh"
expect update-scripts-current ok '^$' -- git -C "$tmp/wt7" diff --no-index --stat "$here/templates/guard/bin/preflight.sh" guard/bin/preflight.sh
expect update-run-executable ok - -- test -x "$tmp/wt7/guard/run"
expect update-workflow-fixed ok 'x-access-token' -- cat "$tmp/wt7/.github/workflows/guard-fence.yml"
expect update-keeps-card ok '^account: gom$' -- cat "$tmp/wt7/guard/budget.card"
expect update-adds-key ok '^max_handled_failures: 2$' -- cat "$tmp/wt7/guard/budget.card"
expect update-skips-removed-key fail - -- grep '^explore_max_nodes' "$tmp/wt7/guard/budget.card"
expect update-filled-setting ok '^setting: <dataset, geometry, code, and pinned commits>$' -- grep '^setting:' "$tmp/wt7/runs/_template/question.card"
expect update-filled-note ok '^custom_note: leave this$' -- grep '^custom_note:' "$tmp/wt7/runs/_template/question.card"
expect update-filled-hypothesis ok '^hypothesis: n/a$' -- sed -n 4p "$tmp/wt7/runs/_template/report.md"
expect update-kept-question ok '^Question: our wording$' -- grep '^Question:' "$tmp/wt7/runs/_template/report.md"
expect update-writes-version ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$tmp/wt7/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt7"; git -C "$tmp/proj" branch -q -D guard/update
git -C "$tmp/proj" worktree remove --force "$tmp/wt8"; git -C "$tmp/proj" branch -q -D guard/again

old_install
sed -i 's/max_ch=$(need max_core_hours)/max_ch=$(need max_core_hours)  # site/' guard/bin/preflight.sh
git commit -q -am "an older install with an overlapping edit"; git push -q -f origin HEAD:main; git -C "$tmp/proj" fetch -q origin
expect update-conflicts fail '^CONFLICTS' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt7"
expect update-conflict-named ok '^<<<<<<< guard/bin/preflight.sh \(yours\)$' -- grep '^<<<<<<<' "$tmp/wt7/guard/bin/preflight.sh"
expect update-conflict-others-clean ok 'hypothesis-line' -- cat "$tmp/wt7/guard/bin/fence.sh"
git -C "$tmp/wt7" push -q origin guard/update:refs/heads/conflicted
git fetch -q origin; git switch -q --detach "$good"
expect run-refuses-conflicted fail 'unresolved conflicts or does not parse' -- env HPC_GUARD_REF=origin/conflicted guard/run preflight "$R" job.sh
expect run-names-schema fail 'guard is schema 2' -- env HPC_GUARD_REF=origin/conflicted guard/run launch
git -C "$tmp/proj" worktree remove --force "$tmp/wt7"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin

echo "== upgrade from each supported release"
# old_project <tag> <dir>: a project guarded by the harness at <tag>, with the budget filled in and merged to main.
old_project() {
  local tag=$1 p=$2 h=$tmp/h-$1
  [ -d "$h" ] || { git clone -q --shared --no-checkout "$here" "$h"; git -C "$h" checkout -q --detach "$tag"; }
  git init -q --bare -b main "$p.git"; git clone -q "$p.git" "$p" 2>/dev/null
  git -C "$p" checkout -q -b main; echo "# p" > "$p/README.md"; git -C "$p" add -A; git -C "$p" commit -q -m init
  git -C "$p" push -q -u origin main; git -C "$p" remote set-head origin -a >/dev/null
  "$h/bin/guard" init "$p" --worktree "$p.wt" >/dev/null 2>&1
  git -C "$tmp/proj" show "$good:guard/budget.card" > "$p.wt/guard/budget.card"
  printf 'runs/*/checks/*\n' > "$p.wt/guard/watch.list"
}
names() { { guard/run ripples "$1"; guard/run fence origin/main HEAD; } 2>/dev/null | cut -f2 | sort -u; }
placeholders() { grep '<' "$1" | cut -d: -f1 | sort; }
upgrade_from() {
  local tag=$1 p=$tmp/p-$1 c=compat-$1 old_names
  old_project "$tag" "$p"; cd "$p.wt" || return
  sed -i 's/^exec sbatch "\$@"/exec sbatch --qos=normal "$@"/' guard/bin/preflight.sh
  sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/guard-fence.yml
  mkdir -p runs/legacy; cp runs/_template/question.card runs/_template/report.md runs/legacy/
  git add -A; git commit -q -m "budget, site edits, and a legacy run"; git push -q origin HEAD:main; git fetch -q origin
  old_names=$(names runs/legacy)
  expect "$c-update" ok 'Changed:' -- "$guard" init "$p" --update --worktree "$p.up"
  expect "$c-card-kept" ok '^account: gom$' -- cat "$p.up/guard/budget.card"
  if git -C "$here" show "$tag:templates/guard/budget.card" | grep -q '^max_handled_failures:'; then
    expect "$c-no-readded-key" fail - -- grep '^max_handled_failures:' "$p.up/guard/budget.card"
  else expect "$c-key-added" ok '^max_handled_failures: 2$' -- cat "$p.up/guard/budget.card"; fi
  expect "$c-port-kept" ok 'exec sbatch --qos=normal' -- cat "$p.up/guard/bin/preflight.sh"
  expect "$c-workflow-fixed" ok 'x-access-token' -- cat "$p.up/.github/workflows/guard-fence.yml"
  expect "$c-workflow-edit-kept" ok 'runs-on: self-hosted' -- cat "$p.up/.github/workflows/guard-fence.yml"
  expect "$c-no-conflicts" fail - -- grep -rlE '^(<{7}|>{7}) ' "$p.up/guard" "$p.up/.github"
  expect "$c-schema" ok "^schema: $(cat "$here/SCHEMA")$" -- cat "$p.up/guard/VERSION"
  git -C "$p.up" push -q origin guard/update:main; git fetch -q origin; git switch -q -c agent origin/main
  mkdir -p runs/r; cp runs/_template/question.card runs/r/
  printf '#!/bin/bash\n#SBATCH --time=01:00:00\n#SBATCH --nodes=1\n' > job.sh; git add -A; git commit -q -m "run: r"
  expect "$c-preflight-ok" ok 'SBATCH --qos=normal .*--account=gom' -- guard/run preflight runs/r job.sh
  expect "$c-ripples-clean" ok - -- bash -c 'out=$(guard/run ripples runs/r) && ! grep -vE "^(PASS|UNCHECKED)	" <<<"$out"'
  sed -i '/^|---|---|---|---|---|$/a | rows | 3 | `runs/legacy/rows.csv` | 1 | abc1234 |' runs/legacy/report.md
  git commit -q -am "edit the legacy report"
  expect "$c-fence-legacy" ok - -- bash -c 'out=$(guard/run fence origin/main HEAD) && ! grep -q "^FAIL" <<<"$out"'
  expect "$c-check-names-kept" ok '^$' -- comm -23 <(echo "$old_names") <(names runs/legacy)
  expect "$c-no-new-required" ok '^$' -- comm -23 <(placeholders "$here/templates/guard/budget.card") \
    <(git -C "$here" show "$tag:templates/guard/budget.card" | placeholders /dev/stdin)
  git switch -q --detach origin/main; git revert --no-edit HEAD >/dev/null; git push -q origin HEAD:main; git fetch -q origin
  expect "$c-rollback" ok '^$' -- diff <(echo "$old_names") <(names runs/legacy)
  if git -C "$here" show "$tag:templates/guard/bin/ripples.sh" | grep -qE '^rows=\$\(sacct'; then
    old_project "$tag" "$p-sacct"; cd "$p-sacct.wt" || return
    sed -i 's/^rows=$(sacct \(.*\)JobID,JobName,State/rows=$(sacct \1JobID,JobName%60,State/' guard/bin/ripples.sh
    git add -A; git commit -q -m "site: longer job names"; git push -q origin HEAD:main
    expect "$c-sacct-port-conflicts" fail '^CONFLICTS' -- "$guard" init "$p-sacct" --update --worktree "$p-sacct.up"
  fi
  cd "$tmp/wt" || return
}
oldest=$(cat "$here/tests/oldest-supported")
releases=$(git -C "$here" tag -l 'v*' --contains "$oldest" --merged HEAD 2>/dev/null)
if [ -z "$releases" ]; then fail=$((fail+1)); echo "FAIL compat-releases (no tags from $oldest; fetch them with git fetch --tags)"; fi
for tag in $releases; do upgrade_from "$tag"; done

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
