# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== preflight"
expect preflight-no-card fail 'not committed' -- guard/run preflight "$R" job.sh
cp runs/_template/question.card "$R/question.card"; git add -A; git commit -q -m "run: question card"
expect preflight-ok ok 'SBATCH .*--account=gom --job-name=2026-09-29-demo' -- guard/run preflight "$R" job.sh --array=0-3
expect preflight-no-user ok 'SBATCH .*--job-name=2026-09-29-demo' -- env -u USER guard/run preflight "$R" job.sh
expect preflight-no-scheduler fail '^preflight: no scheduler on this host; guard/run manifest is the only allowed step here$' -- \
  env PATH="$(path_without sbatch)" guard/run preflight "$R" job.sh
expect preflight-account-wins ok 'SBATCH --account=other .*--account=gom' -- guard/run preflight "$R" job.sh --account=other
expect preflight-time-m-s ok 'PREFLIGHT OK: .* time=30m ' -- guard/run preflight "$R" job.sh --time=30:00
expect preflight-time-seconds-round-up ok 'PREFLIGHT OK: .* time=2m ' -- guard/run preflight "$R" job.sh --time=1:30
expect preflight-time-h-m-s ok 'PREFLIGHT OK: .* time=120m ' -- guard/run preflight "$R" job.sh --time=2:00:00
expect preflight-time-days-hours fail 'PREFLIGHT FAIL: --time=1-12 \(2160 min\) exceeds max_walltime_minutes=720' -- guard/run preflight "$R" job.sh --time=1-12
expect preflight-time-days-h-m ok 'PREFLIGHT OK: .* time=90m ' -- guard/run preflight "$R" job.sh --time=0-1:30
expect preflight-time-malformed fail 'PREFLIGHT FAIL: --time=1h is not a Slurm time' -- guard/run preflight "$R" job.sh --time=1h
expect preflight-forces-checked ok '^SBATCH --comment=run:2026-09-29-demo --ignore-pbs --time=04:00:00 --nodes=2 --account=gom ' -- guard/run preflight "$R" job.sh
expect preflight-cli-space-time fail 'PREFLIGHT FAIL: --time=1-12 \(2160 min\) exceeds' -- guard/run preflight "$R" job.sh --time 1-12
expect preflight-cli-short-time fail 'PREFLIGHT FAIL: --time=1-12 \(2160 min\) exceeds' -- guard/run preflight "$R" job.sh -t 1-12
expect preflight-cli-short-attached ok '^SBATCH -t30 --comment=run:2026-09-29-demo --ignore-pbs --time=30 --nodes=2 ' -- guard/run preflight "$R" job.sh -t30
expect preflight-cli-short-equals fail 'PREFLIGHT FAIL: --time==30 is not a Slurm time' -- guard/run preflight "$R" job.sh -t=30
expect preflight-cli-dangling fail 'PREFLIGHT FAIL: --time has no value' -- guard/run preflight "$R" job.sh --time
expect preflight-cli-space-nodes fail 'PREFLIGHT FAIL: --nodes=8 exceeds max_nodes_per_job=4' -- guard/run preflight "$R" job.sh --nodes 8
expect preflight-cli-short-nodes fail 'PREFLIGHT FAIL: --nodes=8 exceeds max_nodes_per_job=4' -- guard/run preflight "$R" job.sh -N8
expect preflight-cli-space-array ok '^SBATCH -a 0-1 --comment=run:2026-09-29-demo --ignore-pbs --time=04:00:00 --nodes=2 --array=0-1 --account=gom ' -- guard/run preflight "$R" job.sh -a 0-1
expect preflight-cli-space-array-counted ok 'PREFLIGHT OK: .* tasks=2 ' -- guard/run preflight "$R" job.sh -a 0-1
expect preflight-dangling-option ok '^time=04:00:00 account=gom$' -- bash -c 'env SBATCH_TIMELIMIT=9999 guard/run preflight "$1" job.sh -A other --from-a-newer-slurm 2>/dev/null \
  | python3 -c "import sys; sys.path.insert(0, sys.argv[1]); from slurmclient import parse_sbatch_args as p; o = p(sys.stdin.read().split()[1:])[0]; print(\"time=\" + o[\"time\"], \"account=\" + o[\"account\"])" "$2/eval/env"' _ "$R" "$here"
expect preflight-array-malformed fail 'PREFLIGHT FAIL: --array=x is not an index list' -- guard/run preflight "$R" job.sh --array x
printf '#!/bin/bash\n#SBATCH --time=04:00:00 --nodes=2 # four hours\n#SBATCH -t 1-12\n#SBATCH -N 8\nguard/run manifest "$1" "$0"\n' > job-short.sh
expect preflight-script-short-time fail 'PREFLIGHT FAIL: --time=1-12 \(2160 min\) exceeds' -- guard/run preflight "$R" job-short.sh --nodes=2
expect preflight-script-short-nodes fail 'PREFLIGHT FAIL: --nodes=8 exceeds max_nodes_per_job=4' -- guard/run preflight "$R" job-short.sh -t 30
printf '#!/bin/bash\n#SBATCH --time=04:00:00\n\n#SBATCH --nodes=2\nhostname\n#SBATCH -t 1-12\n' > job-late.sh
expect preflight-script-stops-at-command ok 'PREFLIGHT OK: .* nodes=2 time=240m ' -- guard/run preflight "$R" job-late.sh
rm job-short.sh job-late.sh
expect preflight-cli-long-prefix fail '^PREFLIGHT FAIL: --arr shortens --array; write the option in full$' -- guard/run preflight "$R" job.sh --arr=0-999
expect preflight-cli-long-prefix-space fail '^PREFLIGHT FAIL: --arra shortens --array; write the option in full$' -- guard/run preflight "$R" job.sh --arra 0-999
expect preflight-cli-long-prefix-ambiguous fail '^PREFLIGHT FAIL: --ti shortens --time --time-min; write the option in full$' -- guard/run preflight "$R" job.sh --ti=30
expect preflight-cli-bundle fail '^PREFLIGHT FAIL: split -Ha0-999 into separate options$' -- guard/run preflight "$R" job.sh -Ha0-999
expect preflight-cli-bare-word fail "^PREFLIGHT FAIL: 'other.sh' is not an sbatch option; preflight takes the job script as its second argument$" -- guard/run preflight "$R" job.sh other.sh
expect preflight-cli-double-dash fail "^PREFLIGHT FAIL: -- ends sbatch's options early; drop it$" -- guard/run preflight "$R" job.sh -- other.sh
expect preflight-cli-ordinary-values ok '^SBATCH -J my-job --hold -H -p gpu --exclusive --export=ALL -t30 --comment=' -- guard/run preflight "$R" job.sh -J my-job --hold -H -p gpu --exclusive --export=ALL -t30
for d in '--arr=0-999' '--arra 0-999' '-Ha0-999'; do
  printf '#!/bin/bash\n#SBATCH --time=04:00:00 --nodes=2\n#SBATCH %s\nhostname\n' "$d" > "job-${d//[^a-z0-9]/}.sh"
done
expect preflight-script-long-prefix fail '^PREFLIGHT FAIL: --arr shortens --array; write the option in full$' -- guard/run preflight "$R" job-arr0999.sh
expect preflight-script-long-prefix-space fail '^PREFLIGHT FAIL: --arra shortens --array; write the option in full$' -- guard/run preflight "$R" job-arra0999.sh
expect preflight-script-bundle fail '^PREFLIGHT FAIL: split -Ha0-999 into separate options$' -- guard/run preflight "$R" job-a0999.sh
printf '#!/bin/bash\n#SBATCH --time=04:00:00 --nodes=2 -J my-job -p gpu\n#SBATCH -t\nhostname\n' > job-cut.sh
expect preflight-script-value-per-line fail '^PREFLIGHT FAIL: -t has no value$' -- guard/run preflight "$R" job-cut.sh
rm job-arr0999.sh job-arra0999.sh job-a0999.sh job-cut.sh
mkdir -p "$tmp/planted"; printf '#!/bin/sh\n' > "$tmp/planted/squeue"; cp "$tmp/planted/squeue" "$tmp/planted/sacct"; chmod +x "$tmp/planted/"*
expect preflight-ignores-path-squeue ok 'PREFLIGHT OK: .* spent=30 queued=3072 ' -- env PATH="$tmp/planted:$PATH" guard/run preflight "$R" job.sh
sed -i "s|^slurm_bin: .*|slurm_bin: $tmp/no-slurm|" guard/budget.card; git commit -q -am "slurm_bin without slurm"
expect preflight-slurm-bin-missing fail "^PREFLIGHT FAIL: no squeue and sacct in slurm_bin=$tmp/no-slurm; a human sets slurm_bin" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
sed -i '/^slurm_bin:/d' guard/budget.card; git commit -q -am "no slurm_bin"
if [ -x /usr/bin/squeue ]; then skip preflight-slurm-bin-default "this host has /usr/bin/squeue"
else expect preflight-slurm-bin-default fail '^PREFLIGHT FAIL: no squeue and sacct in slurm_bin=/usr/bin; ' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh; fi
git reset -q --hard HEAD~2
expect preflight-queued-m-s ok 'PREFLIGHT OK: .* queued=10 ' -- env MOCK_SQUEUE_PENDING='128 5:00' guard/run preflight "$R" job.sh
expect preflight-queued-unlimited ok 'PREFLIGHT OK: .* queued=0 ' -- env MOCK_SQUEUE_PENDING='128 UNLIMITED' guard/run preflight "$R" job.sh
expect preflight-accounting-down fail '^PREFLIGHT FAIL: accounting unavailable \(sacct failed: sacct: error: Problem talking to the database: Connection refused\); not submitting$' -- \
  env MOCK_SACCT_EXIT=1 HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
expect preflight-queue-down fail '^PREFLIGHT FAIL: queue unavailable \(squeue failed: slurm_load_jobs error: Unable to contact slurm controller \(connect failure\)\); not submitting$' -- \
  env MOCK_SQUEUE_EXIT=1 HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
expect preflight-no-queued-jobs ok 'PREFLIGHT OK: .* queued=0 ' -- env MOCK_SQUEUE_PENDING= guard/run preflight "$R" job.sh
expect preflight-walltime fail 'exceeds max_walltime' -- guard/run preflight "$R" job.sh --time=1-00:00:00
expect preflight-budget fail 'exceeds 8500 available' -- guard/run preflight "$R" job.sh --nodes=4 --time=12:00:00 --array=0-9%2
expect preflight-reserve-open ok 'available=10000' -- env HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: <core-hours held back for baselines and verifier jobs>/' guard/budget.card
git commit -q -am "placeholder reserve"
expect preflight-reserve-placeholder fail "^PREFLIGHT FAIL: budget card 'verification_reserve_core_hours' is still a placeholder" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: 1500/; s/^cores_per_node: .*/cores_per_node: 128 cores/' guard/budget.card
git commit -q -am "unit in cores_per_node"
expect preflight-budget-not-integer fail "^PREFLIGHT FAIL: budget card 'cores_per_node' must be a whole number: 128 cores; a human fixes it in guard/budget.card on the protected branch$" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~2
expect preflight-budget-waiver ok 'PREFLIGHT OK' -- guard/run preflight "$R" job.sh
sed -i '/^checks: /d' guard/budget.card; git commit -q -am "no project waiver"
expect preflight-no-checks fail "^PREFLIGHT FAIL: no executable domain check in $R/checks/ on HEAD; commit them there with the question card, or in a pull request that changes only $R/checks/, and submit once a person merges it; or the question card says checks: waived <reason>$" -- \
  env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
mkdir -p "$R/checks"; printf '#!/bin/bash\necho fine\n' > "$R/checks/bounds.sh"; git add -A; git commit -q -m "checks, not executable"
expect preflight-checks-not-executable fail '^PREFLIGHT FAIL: no executable domain check' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
chmod +x "$R/checks/bounds.sh"; git commit -q -am "checks, executable"
expect preflight-checks-merged ok 'PREFLIGHT OK' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
expect preflight-checks-only-on-base fail '^PREFLIGHT FAIL: no executable domain check' -- env HPC_GUARD_REF=HEAD~2 HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
git reset -q --hard HEAD~2
R8=runs/2026-10-14-timing; mkdir -p "$R8"; sed 's/^checks: .*/checks: waived a timing benchmark with no domain output/' runs/_template/question.card > "$R8/question.card"
git add -A; git commit -q -m "run: a waived card"
expect preflight-card-waiver ok 'PREFLIGHT OK' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R8" job.sh
R9=runs/2026-10-14-bare-waiver; mkdir -p "$R9"; sed 's/^checks: .*/checks: waived/' runs/_template/question.card > "$R9/question.card"
git add -A; git commit -q -m "run: a waiver without a reason"
expect preflight-waiver-needs-reason fail '^PREFLIGHT FAIL: no executable domain check' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R9" job.sh
expect preflight-explore-no-checks ok 'PREFLIGHT OK' -- env HPC_GUARD_REF=HEAD guard/run preflight runs/explore-b8 job.sh --time=30 --nodes=1
git reset -q --hard HEAD~3
base_card=$(git rev-parse HEAD); echo "card_on_main: yes" >> guard/budget.card; git commit -q -am "cards on main"
git branch -q -f card-base HEAD; git reset -q --hard "$base_card"
git switch -q -c card-later card-base; R10=runs/2026-10-14-unread; mkdir -p "$R10"; cp runs/_template/question.card "$R10/"; git add -A; git commit -q -m "run: a card nobody read"
expect preflight-card-not-on-main fail "^PREFLIGHT FAIL: card_on_main is yes in guard/budget.card, and $R10/question.card is not on card-base as committed here; open a pull request with the card, wait for a person to merge it, then submit$" -- \
  env HPC_GUARD_REF=card-base HPC_SPEND_RESERVE=1 guard/run preflight "$R10" job.sh
git branch -q -f card-merged HEAD
expect preflight-card-on-main ok 'PREFLIGHT OK' -- env HPC_GUARD_REF=card-merged HPC_SPEND_RESERVE=1 guard/run preflight "$R10" job.sh
expect preflight-card-on-main-explore ok 'PREFLIGHT OK' -- env HPC_GUARD_REF=card-base HPC_SPEND_RESERVE=1 guard/run preflight runs/explore-c9 job.sh --time=30 --nodes=1
git switch -q agent/run; git branch -q -D card-later card-base card-merged
expect preflight-card-on-main-default ok 'PREFLIGHT OK' -- guard/run preflight "$R" job.sh
sed -i 's/^stop_date: .*/stop_date: 2000-01-01/' guard/budget.card; git commit -q -am "past stop date"
expect preflight-past-stop fail '^PREFLIGHT FAIL: past stop_date 2000-01-01; a human extends stop_date in guard/budget.card on the protected branch$' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
sed -i 's/max_core_hours: 10000/max_core_hours: 99999/' guard/budget.card; git commit -q -am "raise budget"
expect preflight-card-edit fail 'guard/ differs' -- guard/run preflight "$R" job.sh
set_script preflight $'#!/usr/bin/env bash\necho SBATCH bypassed'; git commit -q -am "neuter preflight"
expect run-uses-protected-copy fail 'guard/ differs' -- guard/run preflight "$R" job.sh
echo stray > guard/untracked
expect preflight-guard-remedy fail '^PREFLIGHT FAIL: guard/ differs from origin/main: [^;]*guard/untracked[^;]*; restore it with git restore --source=origin/main --staged --worktree -- guard, commit, and remove any untracked file under guard/$' -- guard/run preflight "$R" job.sh
git restore --source=origin/main --staged --worktree -- guard; git commit -q -m "restore guard"; rm guard/untracked
expect preflight-guard-remedy-works ok 'SBATCH ' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~3
echo "metric: changed" >> "$R/question.card"; git commit -q -am "edit card"
expect preflight-card-frozen fail 'edited after its first commit' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
expect explore-no-card ok 'SBATCH .*--job-name=explore-sketch' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
expect explore-capped fail 'exceeds max_nodes_per_job=1' -- guard/run preflight runs/explore-sketch job.sh
expect explore-one-task fail 'one task at a time' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00 --array=0-3
R3=runs/2026-09-29-budget; mkdir -p "$R3"; sed 's/^budget_core_hours: .*/budget_core_hours: 1100/' runs/_template/question.card > "$R3/question.card"
R4=runs/2026-09-29-late; mkdir -p "$R4"; sed 's/^deadline: .*/deadline: 2000-01-01/' runs/_template/question.card > "$R4/question.card"
git add -A; git commit -q -m "run: budget and deadline cards"
expect preflight-run-budget-fits ok 'SBATCH .*--job-name=2026-09-29-budget' -- guard/run preflight "$R3" job.sh
printf '2026-09-29-budget|360000\nother|999999\n' > "$tmp/runrows"
expect preflight-run-budget fail 'this run spent 100 \+ this job 1024 core-h exceeds budget_core_hours=1100' -- env MOCK_SACCT_RUNROWS=$tmp/runrows guard/run preflight "$R3" job.sh
expect preflight-deadline fail 'past deadline 2000-01-01 in runs/2026-09-29-late/question.card' -- guard/run preflight "$R4" job.sh
echo "default_run_core_hours: 10" >> guard/budget.card; git commit -q -am "default run budget"
expect preflight-default-run-budget fail 'this job 64 core-h exceeds budget_core_hours=10' -- env HPC_GUARD_REF=HEAD guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
git reset -q --hard HEAD~1
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 10/; s/^max_nodes_per_job: .*/max_nodes_per_job: 1/' guard/budget.card
printf 'explore_max_nodes: 2\nexplore_max_walltime_minutes: 60\n' >> guard/budget.card; git commit -q -am "explore caps above the project caps"
expect explore-walltime-bounded fail 'exceeds max_walltime_minutes=10' -- env HPC_GUARD_REF=HEAD guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
expect explore-nodes-bounded fail 'exceeds max_nodes_per_job=1' -- env HPC_GUARD_REF=HEAD guard/run preflight runs/explore-sketch job.sh --nodes=2 --time=00:05:00
git reset -q --hard HEAD~1
printf '100|2026-09-29-demo|FAILED|10|240\n' > "$tmp/rows"
expect preflight-refuses-on-ripple fail '^PREFLIGHT FAIL: ripples reports job-states 100:FAILED \(diagnose, then merge runs/2026-09-29-demo/incidents/<n>.md with a job: <id> line and the root cause for each, since ripples reads incidents from origin/main; a resource stop of a launch continues with an execution.tsv restart or resume row instead\); take the step each ripple names, then submit again$' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run preflight "$R" job.sh
expect preflight-refusal-offers-no-reserve fail - -- bash -c 'MOCK_SACCT_ROWS="$1" guard/run preflight "$2" job.sh 2>&1 | grep HPC_SPEND_RESERVE' _ "$tmp/rows" "$R"
expect ripples-single-entry fail '^RIPPLE	job-states	100:FAILED \(diagnose' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run ripples "$R"
expect preflight-reserve-skips-ripples ok 'SBATCH .*--job-name=2026-09-29-demo' -- env MOCK_SACCT_ROWS="$tmp/rows" HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
mkdir -p "$R/incidents"; printf '# Incident 0\njob: 100\n' > "$R/incidents/0.md"; git add -A; git commit -q -m "run: incident 0"
expect preflight-unmerged-incident fail 'ripples reports job-states 100:FAILED' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run preflight "$R" job.sh
expect preflight-handled-ripple-passes ok 'SBATCH .*--job-name=2026-09-29-demo' -- merged env MOCK_SACCT_ROWS="$tmp/rows" guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
set_script ripples $'#!/usr/bin/env bash\nexit 3'; git commit -q -am "ripples errors"
expect preflight-ripples-error-fails-closed fail '^PREFLIGHT FAIL: ripples could not run \(exit 3\); run guard/run ripples runs/2026-09-29-demo to see why$' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
