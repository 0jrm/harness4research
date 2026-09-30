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
expect preflight-account-wins ok 'SBATCH --account=other .*--account=gom' -- guard/run preflight "$R" job.sh --account=other
expect preflight-walltime fail 'exceeds max_walltime' -- guard/run preflight "$R" job.sh --time=1-00:00:00
expect preflight-budget fail 'exceeds 8500 available' -- guard/run preflight "$R" job.sh --nodes=4 --time=12:00:00 --array=0-9%2
expect preflight-reserve-open ok 'available=10000' -- env HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
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

echo "== init --update"
git -C "$tmp/proj" fetch -q origin
expect update-noop ok 'already current' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt3"
git switch -q -c old origin/main; echo "# older fence" >> guard/bin/fence.sh; git commit -q -am old; git push -q origin old:main
git -C "$tmp/proj" fetch -q origin
expect update-refreshes ok 'guard/bin/fence.sh' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt3"
expect update-keeps-card ok 'account: gom' -- cat "$tmp/wt3/guard/budget.card"
git -C "$tmp/proj" worktree remove --force "$tmp/wt3"
git -C "$tmp/proj" branch -D guard/update
git switch -q -c keep-lines origin/main
sed -i 's/^setting: .*/setting: our tank/' runs/_template/question.card
sed -i 's/^hypothesis: .*/hypothesis: kept/' runs/_template/report.md
git add -A; git commit -q -m x; git push -q origin keep-lines:main
git -C "$tmp/proj" fetch -q origin
expect update-keeps-lines ok 'guard/bin/fence.sh' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt5"
expect update-kept-setting ok '^setting: our tank$' -- grep '^setting:' "$tmp/wt5/runs/_template/question.card"
expect update-kept-hypothesis ok '^hypothesis: kept$' -- grep '^hypothesis:' "$tmp/wt5/runs/_template/report.md"
git -C "$tmp/proj" worktree remove --force "$tmp/wt5"
git -C "$tmp/proj" branch -D guard/update
git switch -q -c fill-lines origin/main
sed -i '/^setting:/d' runs/_template/question.card
printf 'custom_note: leave this\n' >> runs/_template/question.card
sed -i '/^hypothesis:/d' runs/_template/report.md
printf 'group: ocean\n' >> runs/_template/report.md
git add -A; git commit -q -m x; git push -q origin fill-lines:main
git -C "$tmp/proj" fetch -q origin
expect update-fills ok 'runs/_template/question.card' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt4"
expect update-filled-setting ok '^setting: <dataset, geometry, code, and pinned commits>$' -- grep '^setting:' "$tmp/wt4/runs/_template/question.card"
expect update-filled-note ok '^custom_note: leave this$' -- grep '^custom_note:' "$tmp/wt4/runs/_template/question.card"
expect update-filled-hypothesis ok '^hypothesis: n/a$' -- grep '^hypothesis:' "$tmp/wt4/runs/_template/report.md"
expect update-filled-group ok '^group: ocean$' -- grep '^group:' "$tmp/wt4/runs/_template/report.md"

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
