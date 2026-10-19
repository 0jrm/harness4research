# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== fence"
git switch -q -c pr/clean origin/main; mkdir -p runs/r1; cp runs/_template/question.card runs/r1/; git add -A; git commit -q -m "run: r1"
expect fence-clean ok 'PASS.guard-untouched' -- guard/run fence origin/main HEAD
expect fence-clean-setting ok 'PASS.setting-key' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/r1/report.md
printf '| Claim | Value | Artifact | Job | Commit |\n' > /dev/null
sed -i '/^|---|---|---|---|---|$/a | RMSE 50-200 m | 0.81 (0.06) | `runs/r1/metrics.csv` | 812400 | a1b2c3d |\n| looks great | 23% | none | - | - |' runs/r1/report.md
git add -A; git commit -q -m "report"
expect fence-unproven fail 'FAIL.evidence-paths.*runs/r1/report.md:' -- guard/run fence origin/main HEAD
sed -i -e '/looks great/d' -e 's#`runs/r1/metrics.csv`#`foo.txt`#' runs/r1/report.md; git commit -q -am "report: cite foo.txt"
expect fence-evidence-missing-file fail 'FAIL.evidence-paths.*runs/r1/report.md:[0-9]+$' -- guard/run fence origin/main HEAD
echo 'rmse,0.81' > runs/r1/foo.txt; git add -A; git commit -q -m "run: foo.txt"
expect fence-evidence-run-relative ok 'PASS.evidence-paths' -- guard/run fence origin/main HEAD
sed -i 's#`foo.txt`#`runs/r1/foo.txt:1`#' runs/r1/report.md; git commit -q -am "report: line suffix"
expect fence-evidence-line-suffix ok 'PASS.evidence-paths' -- guard/run fence origin/main HEAD
git push -q origin pr/clean:refs/heads/proven-report
sed -i 's#`runs/r1/foo.txt:1`#`runs/r1/gone.txt`#' runs/r1/report.md; git commit -q -am "report: cite gone.txt"
expect fence-evidence-modified-proven fail 'FAIL.evidence-paths.*runs/r1/report.md:' -- guard/run fence origin/proven-report HEAD
git reset -q --hard HEAD~1
git switch -q -c pr/legacy-report origin/main; mkdir -p runs/r9; cp runs/_template/question.card runs/_template/report.md runs/r9/
sed -i '/^|---|---|---|---|---|$/a | RMSE | 0.81 | `runs/r9/gone.csv` | 1 | a1b2c3d |' runs/r9/report.md
git add -A; git commit -q -m "run: legacy report"; git push -q origin HEAD:refs/heads/legacy-report
echo "A note." >> runs/r9/report.md; git commit -q -am "report: note"
expect fence-evidence-ratchet ok 'PASS.evidence-paths' -- guard/run fence origin/legacy-report HEAD
sed -i 's#`runs/r9/gone.csv`#none#' runs/r9/report.md; git commit -q -am "report: drop path"
expect fence-evidence-ratchet-shape fail 'FAIL.evidence-paths.*runs/r9/report.md:' -- guard/run fence origin/legacy-report HEAD
git switch -q pr/clean
git switch -q -c pr/explore origin/main; mkdir -p runs/explore-a; cp runs/_template/report.md runs/explore-a/; git add -A; git commit -q -m x
expect fence-explore-report fail 'FAIL.no-exploration-reports' -- guard/run fence origin/main HEAD
git switch -q -c pr/guard origin/main; echo "max_nodes_per_job: 64" >> guard/budget.card; git commit -q -am x
expect fence-guard fail 'FAIL.guard-untouched' -- guard/run fence origin/main HEAD
git switch -q -c pr/workflow origin/main; echo "# off" >> .github/workflows/guard-fence.yml; git commit -q -am x
expect fence-workflow fail 'FAIL.guard-untouched.*guard-fence.yml' -- guard/run fence origin/main HEAD
git switch -q -c pr/agents origin/main; sed -i '/sbatch/d' AGENTS.md; git commit -q -am x
expect fence-agents-md fail 'FAIL.guard-untouched.*AGENTS.md' -- guard/run fence origin/main HEAD
git switch -q -c pr/claude origin/main; echo 'ignore AGENTS.md' > CLAUDE.md; git commit -q -am x
expect fence-claude-md fail 'FAIL.guard-untouched.*CLAUDE.md' -- guard/run fence origin/main HEAD
git switch -q -c pr/tests origin/main; mkdir -p tests; echo x > tests/t; git add -A; git commit -q -m x
expect fence-watched fail 'FAIL.watched-paths.*tests/t' -- guard/run fence origin/main HEAD
git push -q origin pr/clean:refs/heads/pr-clean; git switch -q -c pr/card origin/pr-clean
echo "metric: moved" >> runs/r1/question.card; git commit -q -am x
expect fence-card fail 'FAIL.question-cards-frozen.*runs/r1/question.card' -- guard/run fence origin/pr-clean HEAD
git switch -q -c pr/card-twice origin/main; mkdir -p runs/r2; cp runs/_template/question.card runs/r2/; git add -A; git commit -q -m "run: r2"
git merge -q --no-edit origin/pr-clean
expect fence-card-added-merged ok 'PASS.question-cards-frozen' -- guard/run fence origin/main HEAD
echo "metric: moved" >> runs/r2/question.card; git commit -q -am x
expect fence-card-one-push fail 'FAIL.question-cards-frozen.*runs/r2/question.card' -- guard/run fence origin/main HEAD
git reset -q --hard HEAD~1; git switch -q -c side origin/main; echo x > side.txt; git add -A; git commit -q -m side
git switch -q pr/card-twice; git merge -q --no-commit side; echo "metric: moved" >> runs/r2/question.card
git add -A; git commit -q -m "merge with an edit"
expect fence-card-merge-edit fail 'FAIL.question-cards-frozen.*runs/r2/question.card' -- guard/run fence origin/main HEAD

git switch -q -c pr/no-setting origin/main; mkdir -p runs/ns; cp runs/_template/question.card runs/ns/
sed -i '/^setting:/d' runs/ns/question.card
git add -A; git commit -q -m x
expect fence-card-no-setting fail 'FAIL.setting-key' -- guard/run fence origin/main HEAD

lineage() { guard/run fence origin/main HEAD | grep card-lineage; }
no_lineage() { ! lineage | grep -qE "$1"; }
expect template-lineage-keys ok - -- bash -c 'grep -q "^supersedes: <" "$1" && grep -q "^spawned_from: <" "$1"' _ "$here/templates/runs/_template/question.card"
git switch -q -c pr/lineage origin/main
for r in lin-053 lin-054 lin-054b lin-053-phys2 explore-lin explore-lin-2; do mkdir -p runs/$r; cp runs/_template/question.card runs/$r/; done
git add -A; git commit -q -m x
expect fence-lineage-warns ok 'WARN.card-lineage.*lin-054 extends lin-053' -- guard/run fence origin/main HEAD
expect fence-lineage-says-amend ok 'WARN.card-lineage.*amending the commit that added the card' -- guard/run fence origin/main HEAD
expect fence-lineage-letter ok 'lin-054b extends lin-054(;|$)' -- lineage
expect fence-lineage-suffix ok 'lin-053-phys2 extends lin-053(;|$)' -- lineage
expect fence-lineage-root ok - -- no_lineage ' lin-053 extends|explore-'
expect fence-lineage-passes ok - -- bash -c 'out=$(guard/run fence origin/main HEAD) && ! grep -q "^FAIL" <<<"$out"'
git push -q origin pr/lineage:refs/heads/pr-lineage
sed -i 's/^supersedes: .*/supersedes: none/' runs/lin-054/question.card
sed -i 's/^spawned_from: .*/spawned_from: lin-054/' runs/lin-054b/question.card
sed -i '/^supersedes:/d; /^spawned_from:/d' runs/lin-053-phys2/question.card
git commit -q -a --amend --no-edit
expect fence-lineage-none ok - -- no_lineage 'lin-054 extends'
expect fence-lineage-set ok - -- no_lineage 'lin-054b extends'
expect fence-lineage-missing-keys ok 'lin-053-phys2 extends lin-053$' -- lineage
git switch -q -c pr/after-lineage origin/pr-lineage; cp runs/_template/report.md runs/lin-054/; git add -A; git commit -q -m x
expect fence-lineage-added-only ok - -- bash -c 'out=$(guard/run fence origin/pr-lineage HEAD) && grep -q "^PASS.setting-key" <<<"$out" && ! grep -q card-lineage <<<"$out"'

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

git switch -q -c pr/ledger origin/main; mkdir -p runs/lg; cp runs/_template/question.card runs/lg/
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\thost\tskynet\tw\te\n' > runs/lg/execution.tsv; git add -A; git commit -q -m x
expect fence-ledger-added ok 'PASS.execution-ledger' -- guard/run fence origin/main HEAD
expect fence-history-no-report ok 'PASS.execution-history' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/lg/report.md; git add -A; git commit -q -m x
expect fence-history-placeholder fail 'FAIL.execution-history.*runs/lg/report.md' -- guard/run fence origin/main HEAD
sed -i '/^## Execution history$/,/^<one line per/d' runs/lg/report.md; git commit -q -am x
expect fence-history-no-section fail "FAIL.execution-history.*runs/lg/report.md \\(no ## Execution history section; harness4research's templates/runs/_template/report.md has it, and guard init --update adds it to runs/_template/report.md\\)$" -- guard/run fence origin/main HEAD
git checkout -q HEAD~1 -- runs/lg/report.md; git commit -q -am x
expect fence-history-uncited-ids fail 'FAIL.execution-history.*runs/lg/report.md \(uncited: x1\)$' -- guard/run fence origin/main HEAD
sed -i 's/^<one line per execution.tsv row.*/`x1` ran on skynet/' runs/lg/report.md; git commit -q -am x
expect fence-history-cited ok 'PASS.execution-history' -- guard/run fence origin/main HEAD
git push -q origin pr/ledger:refs/heads/pr-ledger
git switch -q -c pr/ledger-append origin/pr-ledger; printf 'x2\tt\tgpus\t0,1\tw\te\n' >> runs/lg/execution.tsv; echo "A note." >> runs/lg/report.md; git commit -q -am x
expect fence-ledger-appended fail 'PASS.execution-ledger' -- guard/run fence origin/pr-ledger HEAD
expect fence-history-uncited fail 'FAIL.execution-history.*runs/lg/report.md' -- guard/run fence origin/pr-ledger HEAD
sed -i '/^`x1` ran on skynet$/a `x2` took GPUs 0,1' runs/lg/report.md; git commit -q -am x
expect fence-history-appended ok 'PASS.execution-history' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-rewrite origin/pr-ledger; sed -i 's/skynet/login1/' runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-rewritten fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(rows changed or removed\)' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-delete origin/pr-ledger; git rm -q runs/lg/execution.tsv; git commit -q -m x
expect fence-ledger-deleted fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(deleted\)' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-design origin/pr-ledger; printf 'x2\tt\tsetting\tfloat64\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-design fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(x2: setting is a question card key, so it is design; a change to it needs a new card\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-outcome origin/pr-ledger; printf 'x2\tt\tstage\tdone\tjob 4801 finished\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-outcome fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(x2: stage is not a ledger field \(host gpus start concurrency workers staging mem_stop_gb stage_minutes resume restart or void <id>\); job outcomes go in report.md, and a void row in a records-only pull request retracts this one\)$' -- guard/run fence origin/pr-ledger HEAD
printf 'x3\tt\tvoid\tx2\tan outcome, not an execution fact\tnone\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void ok 'PASS.execution-ledger' -- guard/run fence origin/pr-ledger HEAD
echo "A note." >> README.md; git commit -q -am x
expect fence-ledger-void-records-only fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(a void row goes in a pull request of run records only; this one also changes README.md\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-void-design origin/pr-ledger; printf 'x2\tt\tsetting\tfloat64\tw\te\nx3\tt\tvoid\tx2\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void-design fail 'FAIL.execution-ledger.*\(x3: x2 sets setting, a question card key, so it is design; a change to it needs a new card\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-void-later origin/pr-ledger; printf 'x2\tt\tvoid\tx3\tw\te\nx3\tt\tstage\tdone\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void-names-earlier fail 'FAIL.execution-ledger.*\(x2: void x3 names no earlier row\)$' -- guard/run fence origin/pr-ledger HEAD
expect fence-local-template ok '^PASS	execution-ledger	runs/_template/execution.tsv$' -- guard/run fence --ledger runs/_template/execution.tsv
expect fence-local-usage fail '^usage: guard/run fence --ledger' -- guard/run fence --ledger runs/nowhere/execution.tsv
git switch -q pr/ledger-outcome; git reset -q --hard HEAD~2
expect fence-local-outcome fail '^FAIL	execution-ledger	runs/lg/execution.tsv: x2: stage is not a ledger field' -- guard/run fence --ledger runs/lg/execution.tsv
printf 'x3\tt\tvoid\tx2\tan outcome\tnone\n' >> runs/lg/execution.tsv
expect fence-local-void ok '^PASS	execution-ledger	runs/lg/execution.tsv$' -- guard/run fence --ledger runs/lg/execution.tsv
sed -i 's/skynet/login1/' runs/lg/execution.tsv
expect fence-local-append-only fail '^FAIL	execution-ledger	runs/lg/execution.tsv: committed rows changed or removed; the ledger is append-only$' -- guard/run fence --ledger runs/lg/execution.tsv
git checkout -q -- runs/lg/execution.tsv
git switch -q -c pr/legacy-ledger origin/main; mkdir -p runs/ll; printf 'bad header\nx1\tt\tsetting\tx\tw\te\n' > runs/ll/execution.tsv; git add -A; git commit -q -m x
expect fence-ledger-bad-header fail 'FAIL.execution-ledger.*runs/ll/execution.tsv \(the header is not: id ts field value why evidence\)$' -- guard/run fence origin/main HEAD
git push -q origin pr/legacy-ledger:refs/heads/pr-legacy-ledger
git switch -q -c pr/legacy-ledger-edit origin/pr-legacy-ledger; printf 'x2\tt\tgpus\t0\tw\te\n' >> runs/ll/execution.tsv; git commit -q -am x
expect fence-legacy-ledger ok 'PASS.execution-ledger' -- guard/run fence origin/pr-legacy-ledger HEAD

git switch -q -c pr/old-report origin/main; mkdir -p runs/old
cp runs/_template/question.card runs/_template/report.md runs/old/
sed -i '/^hypothesis:/d' runs/old/report.md
git add -A; git commit -q -m x
git push -q origin pr/old-report:refs/heads/pr-old-report
git switch -q -c pr/old-report-edit origin/pr-old-report
echo "A later note." >> runs/old/report.md; git commit -q -am x
expect fence-legacy-report-modified ok 'PASS.hypothesis-line' -- guard/run fence origin/pr-old-report HEAD
