#!/usr/bin/env python3
"""usage: eval/rescore.py <old results dir> <episodes dir> <new results dir> [--jobs N]

Scores a finished run's episodes again with this checkout's scorers and cost reader, and writes
<new results dir>/verdicts.jsonl and run.json. Each case's last row in the old verdicts.jsonl is copied, then its
verdict (success, violation, escalated, signals) and costs (eval/modellog.py) are replaced by fresh ones read from
<episodes dir>/<episode>, and context_window comes from the run's scaffold config. The client's exit, time-out and wall seconds stay as recorded, since only the run saw them.
A row whose error is not the scorer's (an upstream or disk failure) is copied unchanged. A recomputed request or token
count that differs from the old row's is kept in cost_mismatch, since both come from the same proxy log.
Run it where the episodes are, after the run, with no agent process left."""
import concurrent.futures
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import modellog  # noqa: E402

RECORDED_COSTS = ("requests", "input_tokens", "output_tokens", "max_prompt_tokens")


def last_rows(path):
    rows = {}
    with open(path) as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                rows[(r["family"], r["variant"], r["arm"], r["seed"])] = r
    return list(rows.values())


def rescore(old, episodes, run_id, context_window):
    if old.get("error") and not old["error"].startswith("score.py:"):
        return dict(old, run_id=run_id)
    ep = os.path.join(episodes, old["episode"])
    row = {k: v for k, v in old.items() if k != "error"}
    row.update(run_id=run_id, context_window=context_window)
    costs = modellog.costs(os.path.join(ep, "state", "model", "requests.jsonl"))
    mismatch = {k: [old.get(k), costs[k]] for k in RECORDED_COSTS if old.get(k) != costs[k]}
    row.update(costs, cost_mismatch=mismatch or None)
    scored = subprocess.run([sys.executable, os.path.join(HERE, "score.py"), ep], capture_output=True, text=True)
    if scored.returncode:
        row["error"] = "score.py: " + scored.stderr.strip()[-300:]
    else:
        row.update(json.loads(scored.stdout))
    return row


def main():
    args = sys.argv[1:]
    jobs = 4
    if "--jobs" in args:
        i = args.index("--jobs")
        jobs = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    old_dir, episodes, new_dir = args
    with open(os.path.join(old_dir, "run.json")) as f:
        run = json.load(f)
    run_id = os.path.basename(os.path.normpath(new_dir))
    olds = last_rows(os.path.join(old_dir, "verdicts.jsonl"))
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        window = run["config"]["scaffold"].get("context_window")
        rows = list(pool.map(lambda r: rescore(r, episodes, run_id, window), olds))
    commit = subprocess.run(["git", "-C", HERE, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    os.makedirs(new_dir, exist_ok=True)
    with open(os.path.join(new_dir, "verdicts.jsonl"), "w") as f:
        f.writelines(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    with open(os.path.join(new_dir, "run.json"), "w") as f:
        json.dump(dict(run, run_id=run_id, rescored_from=run.get("run_id"), scorer_commit=commit,
                       episodes_dir=os.path.abspath(episodes)), f, indent=1, sort_keys=True)
    print(f"{len(rows)} cases rescored into {new_dir} at scorer commit {commit}; "
          f"{sum(bool(r.get('cost_mismatch')) for r in rows)} with a cost mismatch, "
          f"{sum(bool(r.get('error')) for r in rows)} with an error")


if __name__ == "__main__":
    main()
