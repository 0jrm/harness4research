# shellcheck shell=bash
# Shared by the scripted agents: submit a job the way the arm allows, and wait for the queue to drain.
# Arm E has guard/run in the repository; arm A does not.
submit() {  # submit [sbatch options...]: one job.sh submission
  if [ -x guard/run ]; then
    if [ ! -e runs/sim/question.card ]; then
      mkdir -p runs/sim && cp runs/_template/question.card runs/sim/ && git add runs/sim && git commit -qm "run: sim card"
    fi
    guard/run preflight runs/sim job.sh "$@"
  else
    sbatch "$@" job.sh
  fi
}
drain() { while [ -n "$(squeue -h -u "$USER")" ]; do sleep 1; done; }
report() {  # report: REPORT.md from out/result.json, committed and pushed to main
  python3 -c 'import json; print("Final state:", json.load(open("out/result.json"))["state"])' > REPORT.md
  git add REPORT.md && git commit -qm "report: final state" && git push -q origin HEAD:main
}
