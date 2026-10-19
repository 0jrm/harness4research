# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture: the fence's rules, each FAIL's refusal code (F01 to F07) and its repair line,
# at the forge and in CI (design-v8 section 6).
echo "== fence"
broker_card() {  # broker_card <run_id> [<line>]: commits runs/<id>/question.card as guard run's broker writes it
  mkdir -p "runs/$1"
  printf 'why: Run job.sh for run %s.\ncommand: guard run runs/%s --why x -- job.sh\nbackend: slurm\nminutes: 30\nnodes: 1\ncores: 128\ngpus: 0\ntasks: 1\ncore_hours: 64.0\ngpu_hours: 0.0\nsession: s1\nwritten_by: guard run\n%s' \
    "$1" "$1" "${2:+$2$'\n'}" > "runs/$1/question.card"
  git add "runs/$1/question.card"
  GIT_COMMITTER_NAME="guard broker" GIT_COMMITTER_EMAIL=broker@guard.invalid git commit -q ${3:+"$3"} -m "run: $1 card"
}
fence_tail() {  # fence_tail <base> [VAR=value...]: the fence's last two lines, exit 2 when it failed with exit 1
  local base=$1 out rc; shift
  out=$(env "$@" guard/run fence "$base" HEAD 2>&1); rc=$?
  tail -n 2 <<<"$out"
  [ $rc = 1 ] && return 2; return 9
}
fence_refusal() {  # fence_refusal <name> <code> <base> [VAR=value...]: the fence fails with refusal <code> as its last two lines
  local name=$1 code=$2; shift 2
  expect_refusal "$name" "$code" -- fence_tail "$@"
}
repairs() {  # repairs <name> <base> [VAR=value...]: runs the fence's line 2 (its origin/main read as <base>), then the fence passes
  local name=$1 base=$2 cmd; shift 2
  cmd=$(env "$@" guard/run fence "$base" HEAD 2>&1 | tail -n 1)
  bash -c "${cmd//origin\/main/$base}" >/dev/null 2>&1
  expect "$name" ok - -- env "$@" guard/run fence "$base" HEAD
}
git switch -q -c pr/clean origin/main; broker_card r1
expect fence-clean ok 'PASS.guard-untouched' -- guard/run fence origin/main HEAD
expect fence-broker-card ok 'PASS.broker-cards' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/r1/report.md
printf '| Claim | Value | Artifact | Job | Commit |\n' > /dev/null
sed -i '/^|---|---|---|---|---|$/a | RMSE 50-200 m | 0.81 (0.06) | `runs/r1/metrics.csv` | 812400 | a1b2c3d |\n| looks great | 23% | none | - | - |' runs/r1/report.md
git add -A; git commit -q -m "report"
expect fence-unproven fail 'FAIL.evidence-paths.F04 evidence-paths: runs/r1/report.md:' -- guard/run fence origin/main HEAD
fence_refusal fence-unproven-refusal F04 origin/main
sed -i -e '/looks great/d' -e 's#`runs/r1/metrics.csv`#`foo.txt`#' runs/r1/report.md; git commit -q -am "report: cite foo.txt"
expect fence-evidence-missing-file fail 'FAIL.evidence-paths.*runs/r1/report.md:[0-9]+ cites no committed path or receipt$' -- guard/run fence origin/main HEAD
echo 'rmse,0.81' > runs/r1/foo.txt; git add -A; git commit -q -m "run: foo.txt"
expect fence-evidence-run-relative ok 'PASS.evidence-paths' -- guard/run fence origin/main HEAD
sed -i 's#`foo.txt`#`runs/r1/foo.txt:1`#' runs/r1/report.md; git commit -q -am "report: line suffix"
expect fence-evidence-line-suffix ok 'PASS.evidence-paths' -- guard/run fence origin/main HEAD
git push -q origin pr/clean:refs/heads/proven-report
sed -i 's#`runs/r1/foo.txt:1`#`runs/r1/gone.txt`#' runs/r1/report.md; git commit -q -am "report: cite gone.txt"
expect fence-evidence-modified-proven fail 'FAIL.evidence-paths.*runs/r1/report.md:' -- guard/run fence origin/proven-report HEAD
git reset -q --hard HEAD~1
git switch -q -c pr/legacy-report origin/main; broker_card r9; cp runs/_template/report.md runs/r9/
sed -i '/^|---|---|---|---|---|$/a | RMSE | 0.81 | `runs/r9/gone.csv` | 1 | a1b2c3d |' runs/r9/report.md
git add -A; git commit -q -m "run: legacy report"; git push -q origin HEAD:refs/heads/legacy-report
echo "A note." >> runs/r9/report.md; git commit -q -am "report: note"
expect fence-evidence-ratchet ok 'PASS.evidence-paths' -- guard/run fence origin/legacy-report HEAD
sed -i 's#`runs/r9/gone.csv`#none#' runs/r9/report.md; git commit -q -am "report: drop path"
expect fence-evidence-ratchet-shape fail 'FAIL.evidence-paths.*runs/r9/report.md:' -- guard/run fence origin/legacy-report HEAD
git switch -q pr/clean
git switch -q -c pr/guard origin/main; echo "max_nodes_per_job: 64" >> guard/budget.card; git commit -q -am x
expect fence-guard fail 'FAIL.guard-untouched.F01 guard-untouched: guard/budget.card' -- guard/run fence origin/main HEAD
fence_refusal fence-guard-refusal F01 origin/main
expect fence-guard-undo ok '^git checkout origin/main -- guard/budget.card && git commit --amend --no-edit --allow-empty$' -- bash -c 'guard/run fence origin/main HEAD | tail -n 1'
expect fence-guard-undo-ci ok "^git checkout origin/main -- guard/budget.card && git commit -m 'restore guard/budget.card'$" -- bash -c 'GITHUB_ACTIONS=true guard/run fence origin/main HEAD | tail -n 1'
fence_refusal fence-guard-refusal-ci F01 origin/main GITHUB_ACTIONS=true
git switch -q -c pr/workflow origin/main; echo "# off" >> .github/workflows/guard-fence.yml; git commit -q -am x
expect fence-workflow fail 'FAIL.guard-untouched.*guard-fence.yml' -- guard/run fence origin/main HEAD
git switch -q -c pr/agents origin/main; sed -i '/sbatch/d' AGENTS.md; git commit -q -am x
expect fence-agents-md fail 'FAIL.guard-untouched.*AGENTS.md' -- guard/run fence origin/main HEAD
git switch -q -c pr/claude origin/main; echo 'ignore AGENTS.md' > CLAUDE.md; git commit -q -am x
expect fence-claude-md fail 'FAIL.guard-untouched.*CLAUDE.md' -- guard/run fence origin/main HEAD
git switch -q -c pr/tests origin/main; mkdir -p tests; echo x > tests/t; git add -A; git commit -q -m x
expect fence-watched fail 'FAIL.watched-paths.F02 watched-paths: tests/t' -- guard/run fence origin/main HEAD
fence_refusal fence-watched-refusal F02 origin/main
expect fence-watched-undo-new ok '^git rm -qf -- tests/t && git commit --amend --no-edit --allow-empty$' -- bash -c 'guard/run fence origin/main HEAD | tail -n 1'
repairs fence-undo-new-file origin/main
git switch -q -c pr/tests-old origin/main; mkdir -p tests; echo a > tests/u; git add -A; git commit -q -m seed; git push -q -f origin HEAD:refs/heads/tests-old
git switch -q -c pr/undo-earlier origin/tests-old; echo b >> tests/u; git commit -q -am "edit the fixture"
echo c > notes-x.md; git add -A; git commit -q -m "later work"; echo d > notes-y.md; git add -A; git commit -q -m "more later work"
expect fence-undo-line-modified ok '^git checkout origin/main -- tests/u && git commit --amend --no-edit --allow-empty$' -- bash -c 'guard/run fence origin/tests-old HEAD | tail -n 1'
repairs fence-undo-earlier-commit origin/tests-old
expect fence-undo-keeps-later-work ok '^c$' -- cat notes-x.md
git switch -q -c pr/undo-many origin/tests-old; echo b >> tests/u; git commit -q -am one; echo c >> tests/u; git commit -q -am two; echo e > tests/v
git add -A; git commit -q -m three; echo f > keep.md; git add -A; git commit -q -m four
expect fence-undo-line-two-paths ok '^git checkout origin/main -- tests/u && git rm -qf -- tests/v && git commit --amend --no-edit --allow-empty$' -- bash -c 'guard/run fence origin/tests-old HEAD | tail -n 1'
repairs fence-undo-several-commits origin/tests-old
git switch -q -c pr/undo-ci origin/tests-old; echo b >> tests/u; git commit -q -am one; git push -q origin HEAD:refs/heads/undo-ci
repairs fence-undo-ci-new-commit origin/tests-old GITHUB_ACTIONS=true
expect fence-undo-ci-fast-forward ok - -- git merge-base --is-ancestor origin/undo-ci HEAD
git switch -q -c pr/guard-and-watched origin/main; echo x >> guard/watch.list; mkdir -p tests; echo x > tests/w; git add -A; git commit -q -m x
expect fence-first-fail-names-both ok '^git checkout origin/main -- guard/watch.list && git rm -qf -- tests/w && git commit' -- bash -c 'guard/run fence origin/main HEAD | tail -n 1'
expect fence-first-fail-is-f01 ok '^H4R-F01 ' -- bash -c 'guard/run fence origin/main HEAD | tail -n 2 | head -n 1'

git push -q origin pr/clean:refs/heads/pr-clean; git switch -q -c pr/card origin/pr-clean
echo "metric: moved" >> runs/r1/question.card; git commit -q -am x
expect fence-card fail 'FAIL.broker-cards.F03 runs/r1/question.card' -- guard/run fence origin/pr-clean HEAD
fence_refusal fence-card-refusal F03 origin/pr-clean
expect fence-card-restores ok '^git checkout origin/main -- runs/r1/question.card && git commit --amend' -- bash -c 'guard/run fence origin/pr-clean HEAD | tail -n 1'
git switch -q -c pr/agent-card origin/main; mkdir -p runs/ag; cp runs/_template/question.card runs/ag/; git add -A; git commit -q -m "run: ag"
expect fence-agent-card fail 'FAIL.broker-cards.F03 runs/ag/question.card is a card only the broker writes' -- guard/run fence origin/main HEAD
fence_refusal fence-agent-card-refusal F03 origin/main
expect fence-agent-card-rm ok '^git rm -qf -- runs/ag/question.card && git commit --amend --no-edit --allow-empty$' -- bash -c 'guard/run fence origin/main HEAD | tail -n 1'
expect fence-agent-card-rm-ci ok "^git rm -qf -- runs/ag/question.card && git commit -m 'restore runs/ag/question.card'$" -- bash -c 'GITHUB_ACTIONS=true guard/run fence origin/main HEAD | tail -n 1'
repairs fence-agent-card-repaired origin/main
git switch -q -c pr/forged-card origin/main; broker_card fk; GIT_COMMITTER_NAME=agent git commit -q --amend --no-edit
expect fence-card-committer fail 'FAIL.broker-cards.F03 runs/fk/question.card' -- guard/run fence origin/main HEAD
git switch -q -c pr/card-extra origin/main; broker_card fx 'budget_core_hours: 9999'
expect fence-card-extra-key fail 'FAIL.broker-cards.F03 runs/fx/question.card' -- guard/run fence origin/main HEAD
git switch -q -c pr/card-twice origin/main; broker_card r2
git merge -q --no-edit origin/pr-clean
expect fence-card-added-merged ok 'PASS.broker-cards' -- guard/run fence origin/main HEAD
echo "minutes: 900" >> runs/r2/question.card; git commit -q -am x
expect fence-card-one-push fail 'FAIL.broker-cards.*runs/r2/question.card' -- guard/run fence origin/main HEAD
git reset -q --hard HEAD~1; git switch -q -c side origin/main; echo x > side.txt; git add -A; git commit -q -m side
git switch -q pr/card-twice; git merge -q --no-commit side; echo "minutes: 900" >> runs/r2/question.card
git add -A; git commit -q -m "merge with an edit"
expect fence-card-merge-edit fail 'FAIL.broker-cards.*runs/r2/question.card' -- guard/run fence origin/main HEAD
if command -v ssh-keygen >/dev/null; then
  ssh-keygen -q -t ed25519 -N '' -C broker -f "$tmp/broker-key"
  echo "broker@guard.invalid $(cat "$tmp/broker-key.pub")" > "$tmp/allowed-signers"
  git switch -q -c pr/signed-card origin/main
  git config gpg.format ssh; git config user.signingkey "$tmp/broker-key"; git config gpg.ssh.allowedSignersFile "$tmp/allowed-signers"
  broker_card sg "" -S
  expect fence-card-signed-forge ok 'PASS.broker-cards' -- env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=guard.records GIT_CONFIG_VALUE_0=signed guard/run fence origin/main HEAD
  git switch -q -c pr/unsigned-card origin/main; broker_card us
  expect fence-card-unsigned-forge fail 'FAIL.broker-cards.F03 runs/us/question.card' -- env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=guard.records GIT_CONFIG_VALUE_0=signed guard/run fence origin/main HEAD
  expect fence-card-unsigned-ci-shape ok 'PASS.broker-cards' -- env GITHUB_ACTIONS=true guard/run fence origin/main HEAD
  git config --unset gpg.format; git config --unset user.signingkey; git config --unset gpg.ssh.allowedSignersFile
else skip fence-card-signed-forge "no ssh-keygen"; fi
expect fence-missing-ref fail 'FAIL.refs.F06 refs: base origin/nowhere not found' -- guard/run fence origin/nowhere HEAD
fence_refusal fence-missing-ref-refusal F06 origin/nowhere

git switch -q -c pr/ledger origin/main; broker_card lg
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
expect fence-history-uncited fail 'FAIL.execution-history.F07 execution-history: .*runs/lg/report.md' -- guard/run fence origin/pr-ledger HEAD
fence_refusal fence-history-refusal F07 origin/pr-ledger
sed -i '/^`x1` ran on skynet$/a `x2` took GPUs 0,1' runs/lg/report.md; git commit -q -am x
expect fence-history-appended ok 'PASS.execution-history' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-rewrite origin/pr-ledger; sed -i 's/skynet/login1/' runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-rewritten fail 'FAIL.execution-ledger.F05 execution-ledger: .*runs/lg/execution.tsv \(rows changed or removed\)' -- guard/run fence origin/pr-ledger HEAD
fence_refusal fence-ledger-refusal F05 origin/pr-ledger
git switch -q -c pr/ledger-delete origin/pr-ledger; git rm -q runs/lg/execution.tsv; git commit -q -m x
expect fence-ledger-deleted fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(deleted\)' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-design origin/pr-ledger; printf 'x2\tt\tminutes\t90\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-design fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(x2: minutes is a question card key, so it is design; a change to it needs a new card\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-outcome origin/pr-ledger; printf 'x2\tt\tstage\tdone\tjob 4801 finished\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-outcome fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(x2: stage is not a ledger field \(host gpus start concurrency workers staging mem_stop_gb stage_minutes resume restart or void <id>\); job outcomes go in report.md, and a void row in a records-only pull request retracts this one\)$' -- guard/run fence origin/pr-ledger HEAD
printf 'x3\tt\tvoid\tx2\tan outcome, not an execution fact\tnone\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void ok 'PASS.execution-ledger' -- guard/run fence origin/pr-ledger HEAD
echo "A note." >> README.md; git commit -q -am x
expect fence-ledger-void-records-only fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(a void row goes in a pull request of run records only; this one also changes README.md\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-void-design origin/pr-ledger; printf 'x2\tt\tminutes\t90\tw\te\nx3\tt\tvoid\tx2\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void-design fail 'FAIL.execution-ledger.*\(x3: x2 sets minutes, a question card key, so it is design; a change to it needs a new card\)$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-void-later origin/pr-ledger; printf 'x2\tt\tvoid\tx3\tw\te\nx3\tt\tstage\tdone\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-void-names-earlier fail 'FAIL.execution-ledger.*\(x2: void x3 names no earlier row\)$' -- guard/run fence origin/pr-ledger HEAD
expect fence-local-template ok '^PASS	execution-ledger	runs/_template/execution.tsv$' -- guard/run fence --ledger runs/_template/execution.tsv
expect fence-local-usage fail '^usage: guard/run fence --ledger' -- guard/run fence --ledger runs/nowhere/execution.tsv
git switch -q pr/ledger-outcome; git reset -q --hard HEAD~2
expect fence-local-outcome fail '^FAIL	execution-ledger	F05 execution-ledger: runs/lg/execution.tsv: x2: stage is not a ledger field' -- guard/run fence --ledger runs/lg/execution.tsv
printf 'x3\tt\tvoid\tx2\tan outcome\tnone\n' >> runs/lg/execution.tsv
expect fence-local-void ok '^PASS	execution-ledger	runs/lg/execution.tsv$' -- guard/run fence --ledger runs/lg/execution.tsv
sed -i 's/skynet/login1/' runs/lg/execution.tsv
expect fence-local-append-only fail '^FAIL	execution-ledger	F05 execution-ledger: runs/lg/execution.tsv: committed rows changed or removed; the ledger is append-only$' -- guard/run fence --ledger runs/lg/execution.tsv
git checkout -q -- runs/lg/execution.tsv
git switch -q -c pr/legacy-ledger origin/main; mkdir -p runs/ll; printf 'bad header\nx1\tt\tminutes\tx\tw\te\n' > runs/ll/execution.tsv; git add -A; git commit -q -m x
expect fence-ledger-bad-header fail 'FAIL.execution-ledger.*runs/ll/execution.tsv \(the header is not: id ts field value why evidence\)$' -- guard/run fence origin/main HEAD
git push -q origin pr/legacy-ledger:refs/heads/pr-legacy-ledger
git switch -q -c pr/legacy-ledger-edit origin/pr-legacy-ledger; printf 'x2\tt\tgpus\t0\tw\te\n' >> runs/ll/execution.tsv; git commit -q -am x
expect fence-legacy-ledger ok 'PASS.execution-ledger' -- guard/run fence origin/pr-legacy-ledger HEAD


git switch -q -c pr/receipts-base origin/main
cat > guard/run <<'RUN'
#!/usr/bin/env bash
# A stand-in for the pinned harness's receipts-check (U9): the ids in guard/receipts.ok on the base are receipts.
if [ "${1:-}" = receipts-check ]; then
  [ -n "${2:-}" ] && git rev-parse -q --verify "$2" >/dev/null || exit 64
  base=$2; shift 2
  for id in "$@"; do git show "$base:guard/receipts.ok" | grep -qx "$id" || exit 1; done
  exit 0
fi
exec bash -c "$(git show origin/main:guard/run)" guard/run "$@"
RUN
echo L0123456789 > guard/receipts.ok; git add -A; git commit -q -m "receipts stand-in"; git push -q origin HEAD:refs/heads/receipts-base
git switch -q -c pr/receipt-cited origin/receipts-base; mkdir -p runs/rc; cp runs/_template/report.md runs/rc/report.md
sed -i '/^|---|---|---|---|---|$/a | RMSE | 0.81 | `L0123456789` | 1 | a1b2c3d |' runs/rc/report.md; git add -A; git commit -q -m report
expect fence-receipt-cited ok 'PASS.evidence-paths' -- guard/run fence origin/receipts-base HEAD
sed -i 's/`L0123456789`/`L9999999999`/' runs/rc/report.md; git commit -q -am "made-up receipt"
expect fence-receipt-made-up fail 'FAIL.evidence-paths.F04 evidence-paths: runs/rc/report.md:' -- guard/run fence origin/receipts-base HEAD
sed -i 's/`L9999999999`/`l0123456789`/' runs/rc/report.md; git commit -q -am "local receipt"
expect fence-receipt-local-shape fail 'FAIL.evidence-paths.F04' -- guard/run fence origin/receipts-base HEAD
git switch -q -c pr/receipt-no-checker origin/main; mkdir -p runs/rn; cp runs/_template/report.md runs/rn/report.md
sed -i '/^|---|---|---|---|---|$/a | RMSE | 0.81 | `L0123456789` | 1 | a1b2c3d |' runs/rn/report.md; git add -A; git commit -q -m report
expect fence-receipt-no-checker fail 'FAIL.evidence-paths.F04' -- guard/run fence origin/main HEAD
