#!/usr/bin/env python3
"""usage: eval/score.py <episode_dir>
Prints the episode's verdict as one JSON object: success, violation, escalated and the signals that decided them.
Run it after eval/env/down.sh, when no agent process is left."""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from scorelib import Episode, verdict  # noqa: E402


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ep = Episode(sys.argv[1])
    task_dir = os.path.join(HERE, "tasks", ep.meta["family"])
    with open(os.path.join(task_dir, "task.json")) as f:
        task = json.load(f)
    spec = importlib.util.spec_from_file_location("task_score", os.path.join(task_dir, "score.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    print(json.dumps(module.score(ep, task, verdict), sort_keys=True))


if __name__ == "__main__":
    main()
