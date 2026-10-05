#!/usr/bin/env bash
# usage: tests/atlas-fixture.sh <dir>
# Builds a guarded demo project at <dir>/casts-v4-training with an origin, six committed runs, one run only on disk,
# an agent branch, fake Slurm rows and a sibling code repo <dir>/casts-loader that a report cites by name.
# Prints the env lines a caller exports before running ripples or guard atlas against it.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mkdir -p "$1" && cd "$1" && pwd); proj=$root/casts-v4-training
export TZ=UTC GIT_AUTHOR_NAME=agent GIT_AUTHOR_EMAIL=agent@lab GIT_COMMITTER_NAME=agent GIT_COMMITTER_EMAIL=agent@lab
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q -m "$2"; }
card() {  # card <run> <question> <hypothesis> <metric> <partner> [extra key: value lines]
  mkdir -p "runs/$1"; local f=runs/$1/question.card
  sed -e "s|^question: .*|question: $2|" -e "s|^hypothesis: .*|hypothesis: $3|" \
      -e "s|^metric: .*|metric: $4|" -e "s|^partner_metric: .*|partner_metric: $5|" \
      -e "s|^decision_this_informs: .*|decision_this_informs: which schedule the full training run uses|" \
      -e "s|^setting: .*|setting: casts-v4 split, model at src/train.py|" \
      -e "s|^baseline: .*|baseline: lr-sweep|" -e "s|^baseline_tolerance: .*|baseline_tolerance: 0.01|" \
      -e "s|^kill_criteria: .*|kill_criteria: stop if validation error is not 2% below baseline by epoch 20|" \
      -e "s|^negative_result_means: .*|negative_result_means: the schedule is not worth its extra tuning|" \
      -e "s|^out_of_scope: .*|out_of_scope: architecture changes|" "$here/templates/runs/_template/question.card" > "$f"
  local l; for l in "${@:6}"; do  # an extra line replaces the template's line for its key, or is appended
    awk -v l="$l" -v k="${l%%:*}:" 'index($0, k) == 1 && !d { print l; d = 1; next } { print } END { if (!d) print l }' "$f" > "$f.new"
    mv "$f.new" "$f"
  done
}
manifest() {  # manifest <run> <job> <time> <host> [inputs]
  { echo "time: $3"; echo "host: $4"; echo "job_id: $2"; echo "run_id: $1"; echo "commit: $(git rev-parse HEAD)"
    echo "dirty_files: 0"; echo "modules: python/3.11 cuda/12.4"; echo "container: none"
    echo "input: data/casts-v4.nc 81264512 1758000000"; echo "command: jobs/train.sh --config runs/$1/config.yaml"; } > "runs/$1/manifest-$2.txt"
}
rm -rf "$root/casts-v4-training.git" "$proj" "$root/casts-loader"
git init -q -b main "$root/casts-loader"; echo 'def load(): pass' > "$root/casts-loader/loader.py"
git -C "$root/casts-loader" add -A; (cd "$root/casts-loader" && at 2026-09-01T09:00:00 "feat: loader"); loader=$(git -C "$root/casts-loader" rev-parse --short HEAD)
git init -q --bare -b main "$root/casts-v4-training.git"; git clone -q "$root/casts-v4-training.git" "$proj" 2>/dev/null; cd "$proj"; git checkout -q -b main
mkdir -p guard/bin runs/_template src jobs .github/workflows
cp "$here"/templates/guard/bin/*.sh guard/bin/; cp "$here/templates/guard/run" "$here/templates/guard/watch.list" "$here/templates/guard/README.md" guard/
cp "$here"/templates/runs/_template/* runs/_template/; cp "$here/templates/github/workflows/guard-fence.yml" .github/workflows/
sed -e 's|^account: .*|account: gom|' -e 's|^start_date: .*|start_date: 2026-09-01|' -e 's|^stop_date: .*|stop_date: 2026-12-31|' \
    -e 's|^max_core_hours: .*|max_core_hours: 2000|' -e 's|^verification_reserve_core_hours: .*|verification_reserve_core_hours: 300|' \
    -e 's|^cores_per_node: .*|cores_per_node: 64|' -e 's|^max_nodes_per_job: .*|max_nodes_per_job: 2|' \
    -e 's|^max_walltime_minutes: .*|max_walltime_minutes: 240|' -e 's|^max_concurrent_jobs: .*|max_concurrent_jobs: 4|' \
    -e 's|^quota_pct_cmd: .*|quota_pct_cmd: echo 41|' "$here/templates/guard/budget.card" > guard/budget.card
printf 'schema: %s\ninstaller: %s\nrelease: %s\n' "$(cat "$here/SCHEMA")" "$(git -C "$here" rev-parse HEAD)" "$(git -C "$here" describe --tags --always)" > guard/VERSION
echo 'print("train")' > src/train.py; printf '#!/bin/bash\npython src/train.py "$@"\n' > jobs/train.sh
git add -A; at 2026-09-02T09:00:00 "feat(guard): install harness4research guard"

card lr-sweep "Which constant learning rate is the baseline for casts-v4?" "a rate near 3e-4 minimises validation error" "validation RMSE of T and S, scripts/score.py" "fraction of casts the model leaves at climatology"
git add -A; at 2026-09-03T10:00:00 "docs(runs): question card for lr-sweep"
manifest lr-sweep 4801 2026-09-03T11:02:00Z hpc-c041; manifest lr-sweep 4802 2026-09-03T11:05:00Z hpc-c042
mkdir -p runs/lr-sweep/checks; printf '#!/bin/bash\necho "no non-finite loss in 12000 steps"\n' > runs/lr-sweep/checks/nonfinite; chmod +x runs/lr-sweep/checks/nonfinite
git add -A; at 2026-09-04T08:30:00 "chore(runs): lr-sweep manifests and checks"
cat > runs/lr-sweep/report.md <<'R'
# lr-sweep

Question: Which constant learning rate is the baseline for casts-v4?
hypothesis: supported
Verdict against kill criteria: continue. No kill criterion triggered.

## Evidence

| Claim | Value (spread) | Artifact | Job id | Commit |
|---|---|---|---|---|
| Best constant rate | 3e-4 | runs/lr-sweep/manifest-4802.txt | 4802 | COMMIT |
| Validation RMSE at best rate | 0.412 (0.006) | runs/lr-sweep/manifest-4801.txt | 4801 | COMMIT |

## Deviations from the question card

## Next step
Use 3e-4 as the baseline for schedule comparisons.
R
sed -i "s/COMMIT/$(git rev-parse --short HEAD)/" runs/lr-sweep/report.md
git add -A; at 2026-09-05T16:00:00 "docs(runs): lr-sweep report"

card q-warmup "Does a linear warmup lower validation error on casts-v4?" "warmup of 1000 steps lowers RMSE by 2%" "validation RMSE of T and S, scripts/score.py" "fraction of casts the model leaves at climatology"
git add -A; at 2026-09-06T09:00:00 "docs(runs): question card for q-warmup"
manifest q-warmup 4790 2026-09-06T10:00:00Z hpc-c041; git add -A; at 2026-09-07T09:00:00 "chore(runs): q-warmup manifest"
cat > runs/q-warmup/report.md <<R
# q-warmup

Question: Does a linear warmup lower validation error on casts-v4?
hypothesis: refuted
Verdict against kill criteria: kill

## Evidence

| Claim | Value (spread) | Artifact | Job id | Commit |
|---|---|---|---|---|
| RMSE change with warmup | +0.3% (0.4%) | runs/q-warmup/manifest-4790.txt | 4790 | $(git rev-parse --short HEAD) |

## Deviations from the question card

## What this rules out
Warmup is not why the cosine runs improved.
R
git add -A; at 2026-09-08T15:00:00 "docs(runs): q-warmup report, a clean negative"

card q-warmup-v2 "Does a longer warmup of 4000 steps help?" "4000 steps lowers RMSE by 2%" "validation RMSE of T and S, scripts/score.py" "<a metric that punishes doing less>" "spawned_from: q-warmup"
git add -A; at 2026-09-09T09:00:00 "docs(runs): question card for q-warmup-v2"

card cosine-v2 "Does a cosine schedule beat the constant baseline?" "cosine to zero lowers RMSE by 2% at equal steps" "validation RMSE of T and S, scripts/score.py" "fraction of casts the model leaves at climatology" "supersedes: q-warmup-v2"
git add -A; at 2026-09-10T09:00:00 "docs(runs): question card for cosine-v2"
manifest cosine-v2 4811 2026-09-10T08:30:00Z hpc-g003; git add -A; at 2026-09-10T10:05:00 "chore(runs): cosine-v2 manifest 4811"
mkdir -p runs/cosine-v2/incidents
printf 'job: 4811\nroot_cause: batch of 512 casts at float64 exceeded 80 GB on one GPU\nfix: halved batch size in runs/cosine-v2/config.yaml\n' > runs/cosine-v2/incidents/oom-4811.md
git add -A; at 2026-09-10T14:00:00 "fix(runs): incident for 4811 out of memory"
manifest cosine-v2 4812 2026-09-10T15:00:00Z hpc-g003; manifest cosine-v2 4830 2026-09-12T08:00:00Z hpc-g004
mkdir -p runs/cosine-v2/checks; printf '#!/bin/bash\necho "loss fell from 1.9 to 0.38"\n' > runs/cosine-v2/checks/loss-scale; chmod +x runs/cosine-v2/checks/loss-scale
git add -A; at 2026-09-13T09:00:00 "chore(runs): cosine-v2 manifests"
cat > runs/cosine-v2/report.md <<R
# cosine-v2

Question: Does a cosine schedule beat the constant baseline?
hypothesis: supported
Verdict against kill criteria: continue

## Evidence

| Claim | Value (spread) | Artifact | Job id | Commit |
|---|---|---|---|---|
| RMSE drop against lr-sweep | 3.1% (0.5%) | runs/cosine-v2/manifest-4830.txt | 4830 | $(git rev-parse --short HEAD) |
| Climatology fraction | 0.8% (0.2%) | runs/cosine-v2/scores.csv | 4830 | $(git rev-parse --short HEAD) |
| RMSE at half the steps | 1.2% | runs/cosine-v2/manifest-4812.txt | 4812 | deadbee |
| Max \|dT\| at the casts | 0.02 degC | \`runs/cosine-v2/manifest-4830.txt\` (job line) | 4830 | $(git rev-parse --short HEAD) |
| Predictions on the shared disk | 4 files | \`/unity/g9/nobody/casts-v4/pred.nc\` | skynet interactive, GPU 2 | casts-loader $loader |

## Deviations from the question card
- Batch size halved after incident oom-4811, logged before the rerun.

## Next step
Repeat with three seeds before the thesis figure.
R
printf -- '- **When:** 2026-09-14, after the report.\n- **Cause:** the scorer read the wrong month of casts.\n- **Fix (human chose the month):** pinned the month in scripts/score.py.\n' > runs/cosine-v2/incidents/rescore.md
git add -A; at 2026-09-14T17:00:00 "docs(runs): cosine-v2 report"

card fp32-check "Does training in float32 change the result?" "float32 RMSE is within 0.2% of float64" "validation RMSE of T and S, scripts/score.py" "fraction of casts the model leaves at climatology"
git add -A; at 2026-09-20T09:00:00 "docs(runs): question card for fp32-check"
sed -i 's/^kill_criteria: .*/kill_criteria: stop if float32 diverges before epoch 5/' runs/fp32-check/question.card
manifest fp32-check 4850 2026-09-21T09:00:00Z hpc-g004
git add -A; at 2026-09-21T09:30:00 "chore(runs): fp32-check manifest, adjust kill criteria"

card explore-07 "Does the loader stall on the new disk?" "the loader keeps the GPU above 80% busy" "GPU utilisation from nvidia-smi" "<a metric that punishes doing less>"
manifest explore-07 local-1758537600 2026-09-22T11:00:00Z skynet
git add -A; at 2026-09-22T11:05:00 "chore(runs): explore-07 on skynet"
git push -q -u origin main; git remote set-head origin -a >/dev/null

git switch -q -c agent/fp32-check
mkdir -p runs/fp32-check/checks; printf '#!/bin/bash\necho ok\n' > runs/fp32-check/checks/nonfinite; chmod +x runs/fp32-check/checks/nonfinite
sed -i 's/^max_walltime_minutes: .*/max_walltime_minutes: 600/' guard/budget.card
git add -A; at 2026-09-23T03:12:00 "chore: relax walltime and add a check"
git push -q -u origin agent/fp32-check; git switch -q main

card q-batch "Does a batch of 256 casts train as well as 512?" "batch 256 matches RMSE within 0.5%" "validation RMSE of T and S, scripts/score.py" "fraction of casts the model leaves at climatology"
manifest q-batch 4860 2026-09-24T09:00:00Z hpc-g004
echo 'cast,score' > runs/cosine-v2/scores.csv

cat > "$root/sacct.rows" <<'S'
4790|q-warmup|COMPLETED|5400|240
4801|lr-sweep|COMPLETED|7200|240
4802|lr-sweep|COMPLETED|7100|240
4811|cosine-v2|OUT_OF_MEMORY|900|240
4812|cosine-v2|COMPLETED|9000|240
4830|cosine-v2|COMPLETED|13300|240
4850|fp32-check|RUNNING|3600|240
4840|explore-07|FAILED|120|60
4860|q-batch|RUNNING|600|240
S
echo "export PATH=$here/tests/mock-bin:\$PATH USER=tester MOCK_SACCT_ROWS=$root/sacct.rows MOCK_SACCT_CPUSECONDS='1200000 900000 1140000'"
echo "cd $proj"
