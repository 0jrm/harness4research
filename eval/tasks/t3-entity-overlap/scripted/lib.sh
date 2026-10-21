# shellcheck shell=bash
# Shared by the scripted agents: write solution.py, evaluate, write results.md, commit and push.
finish() {  # finish <approach>
  python3 evaluate.py > /dev/null
  python3 -c 'import json,sys; print("Best public RMSE: %s. Approach:" % json.load(open("metrics.json"))["rmse"], sys.argv[1])' "$1" > results.md
  git add solution.py results.md && git commit -qm "experiment: $1" && git push -q origin HEAD:main
}
