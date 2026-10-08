#!/usr/bin/env bash
# usage: examples/quickstart/run.sh [DIR]
# Builds a guarded throwaway project in DIR (default ~/guard-quickstart) and walks one carded run through
# init, preflight, the job, the report, the fence and ripples, with a mock sbatch and no cluster.
# A rerun replaces DIR only when an earlier run of this script created it.
set -euo pipefail
# git rebase --exec and git hooks export GIT_DIR, which would turn every throwaway repo below into the caller's own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
harness=$(git -C "$here" rev-parse --show-toplevel)
dir=$(realpath -m "${1:-$HOME/guard-quickstart}")
start=$(python3 -c 'import time; print(time.perf_counter())')

if [ -e "$dir" ]; then
  [ -f "$dir/.guard-quickstart" ] || { echo "refuse: $dir exists and this script did not create it; pass another directory" >&2; exit 2; }
  rm -rf "$dir"
fi
mkdir -p "$dir"; touch "$dir/.guard-quickstart"

export PATH="$harness/tests/mock-bin:$PATH"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-quickstart}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-quickstart@localhost}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-quickstart}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-quickstart@localhost}"
[ "$(readlink -f "$(command -v sbatch)")" = "$(readlink -f "$harness/tests/mock-bin/sbatch")" ] || { echo "refuse: sbatch is not the mock" >&2; exit 1; }

want=d606af411f3e5be8a317a5a8b652b425aaf0ff38ca683d5327ffff94c3695f4a
[ "$(sha256sum "$here/data/wdbc.data" | cut -d' ' -f1)" = "$want" ] || { echo "refuse: $here/data/wdbc.data does not match its sha256" >&2; exit 1; }

echo "== 1. A project and its guard"
git init -q --bare -b main "$dir/origin.git"
git clone -q "$dir/origin.git" "$dir/proj" 2>/dev/null
cd "$dir/proj"
git checkout -q -b main
printf '# quickstart project\n' > README.md
git add README.md; git commit -q -m init; git push -q -u origin main
git remote set-head origin -a >/dev/null
"$harness/bin/guard" init "$dir/proj" --worktree "$dir/guard-init" > "$dir/init.log"
cd "$dir/guard-init"
cat > guard/budget.card <<'CARD'
account: demo
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
printf 'runs/*/checks/*\n' > guard/watch.list
git commit -q -am "chore(guard): set budget"
git push -q origin guard/init:main
echo "guard/ merged to main. The human owns it from now on."

echo "== 2. The human commits the checks, the agent commits the question card"
git switch -q -c human/checks origin/main
mkdir -p runs/cheap-evo/checks
cp "$here/checks/"*.sh runs/cheap-evo/checks/
git add runs/cheap-evo/checks; git commit -q -m "checks: cheap-evo"
git push -q origin human/checks:main
git fetch -q origin
cd "$dir/proj"; git pull -q
git switch -q -c agent/run
mkdir -p runs/cheap-evo/data
cp "$here/campaign.py" "$here/job.sh" "$here/question.card" runs/cheap-evo/
cp "$here/data/wdbc.data" runs/cheap-evo/data/
cp "$here/job.sh" job.sh
git add runs/cheap-evo/campaign.py runs/cheap-evo/job.sh runs/cheap-evo/question.card
git commit -q -m "run: cheap-evo question card"

echo "== 3. A refusal: the agent raises its own walltime cap"
sed -i 's/^max_walltime_minutes: 720$/max_walltime_minutes: 9999/' guard/budget.card
guard/run preflight runs/cheap-evo job.sh || true
git checkout -q -- guard/budget.card

echo "== 4. Preflight, then the job"
guard/run preflight runs/cheap-evo job.sh
env SLURM_JOB_ID=555 LOADEDMODULES=none bash job.sh runs/cheap-evo

echo "== 5. The report and the fence"
python3 runs/cheap-evo/campaign.py --write-report runs/cheap-evo
git add runs/cheap-evo/report.md runs/cheap-evo/campaign.json; git commit -q -m "report: cheap-evo"
guard/run fence origin/main HEAD

echo "== 6. Ripples after the job"
printf '555|cheap-evo|COMPLETED|30|300\n' > "$dir/sacct.rows"
MOCK_SACCT_ROWS=$dir/sacct.rows guard/run ripples runs/cheap-evo

python3 - "$dir/proj/runs/cheap-evo/campaign.json" "$start" "$dir" <<'PY'
import json
import os
import sys
import time

payload = json.loads(open(sys.argv[1]).read())
total = time.perf_counter() - float(sys.argv[2])
payload_s = float(payload["payload_wall_seconds"])
evolve = payload["summary"]["evolve_cheap"]["test_balanced_accuracy"]["mean"]
d = sys.argv[3]
print("== Summary")
print(f"The walkthrough took {total:.1f} s. The job took {payload_s:.1f} s; git, the guard and setup took the rest.")
print(f"Held-out balanced accuracy of the selected team: {evolve:.3f} (mean over seeds).")
print("Look at:")
for p in ("proj/runs/cheap-evo/question.card", "proj/runs/cheap-evo/report.md",
          "proj/runs/cheap-evo/manifest-555.txt", "proj/guard/budget.card", "init.log"):
    if not os.path.exists(f"{d}/{p}"):
        sys.exit(f"missing {d}/{p}")
    print(f"  {d}/{p}")
print(f"Atlas page: guard atlas {d}/proj --no-ripples --out {d}/atlas.html")
PY
