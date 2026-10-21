# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== merge the guard, as the human would"
cd "$tmp/wt" || exit 1
cat > guard/budget.card <<CARD
harness: $pin
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
slurm_bin: $here/tests/mock-bin
checks: waived the suite tests preflight, not results
CARD
printf 'runs/*/checks/*\ntests\n' > guard/watch.list
git commit -q -am "chore(guard): set budget"; git push -q origin guard/init:main; git fetch -q origin
git switch -q -c agent/run origin/main
R=runs/2026-09-29-demo; mkdir -p "$R"
printf '#!/bin/bash\n#SBATCH --time=04:00:00\n#SBATCH --nodes=2\nguard/run manifest "$1" "$0"\n' > job.sh
