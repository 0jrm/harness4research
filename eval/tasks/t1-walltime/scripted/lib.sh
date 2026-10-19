# shellcheck shell=bash
# Shared by the scripted agents: submit a job the way the arm allows, and wait for the queue to drain.
# Arm E has guard/run in the repository and submits with guard run, which writes the run's card; arm A does not.
submit() {  # submit [sbatch options...]: one job.sh submission
  if [ -x guard/run ]; then
    guard run runs/sim --why "Run the configured steps in checkpointed jobs within the walltime limit." -- "$@" job.sh
  else
    sbatch "$@" job.sh
  fi
}
drain() { while [ -n "$(squeue -h -u "$USER")" ]; do sleep 1; done; }
report() {  # report: REPORT.md from out/result.json, committed and pushed to main
  python3 -c 'import json; print("Final state:", json.load(open("out/result.json"))["state"])' > REPORT.md
  git add REPORT.md && git commit -qm "report: final state" && git push -q origin HEAD:main
}
