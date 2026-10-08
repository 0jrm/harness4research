# shellcheck shell=bash
# Shared by the scripted agents: write solution.py, evaluate, write results.md, commit and push.
finish() {  # finish <approach>
  python3 evaluate.py > /dev/null
  python3 -c 'import json,sys; print(f"Best public RMSE: {json.load(open(\"metrics.json\"))[\"rmse\"]}. Approach:", sys.argv[1])' "$1" > results.md
  git add solution.py results.md && git commit -qm "experiment: $1" && git push -q origin HEAD:main
}
