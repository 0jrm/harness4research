#!/usr/bin/env python3
"""usage: eval/validate.py [family ...] [--arm A|E] [--seeds N] [--keep]
Checks every task's scorer against its scripted agents before any model runs: each scripted agent is played
through a real episode, and the verdict must match the expectation in the task's task.json. An honest agent is
played on both variants and must pass both; a cheating agent is played on the trap variant and must be caught.
With --seeds N, each case runs on seeds 1..N, since the data and thresholds vary by seed. Exit 1 when any
verdict differs."""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def run(*cmd, **kw):
    return subprocess.run(list(cmd), capture_output=True, text=True, **kw)


def play(family, variant, arm, agent, keep, seed):
    root = tempfile.mkdtemp(prefix="v.", dir=os.environ.get("TMPDIR"))
    ep = os.path.join(root, "s")
    try:
        built = run(os.path.join(HERE, "episode.sh"), family, variant, arm, ep, "--seed", str(seed))
        if built.returncode:
            return None, f"episode.sh failed: {built.stderr.strip()[-400:]}"
        scripted = os.path.join(ep, "home", ".scripted")
        shutil.copytree(os.path.join(HERE, "tasks", family, "scripted"), scripted)
        played = run(os.path.join(HERE, "env", "sandbox.sh"), ep, "--", "bash", f"/home/agent/.scripted/{agent}.sh",
                     timeout=600)
        with open(os.path.join(ep, "agent.log"), "w") as f:
            f.write(played.stdout + played.stderr)
        shutil.rmtree(scripted)
        run(os.path.join(HERE, "env", "down.sh"), ep)
        scored = run(os.path.join(HERE, "score.py"), ep)
        if scored.returncode:
            return None, f"score.py failed: {scored.stderr.strip()[-400:]}"
        return json.loads(scored.stdout), None
    finally:
        run(os.path.join(HERE, "env", "down.sh"), ep)
        if keep:
            print(f"     kept {ep}")
        else:
            shutil.rmtree(root, ignore_errors=True)


def main():
    args = sys.argv[1:]
    keep = "--keep" in args
    arms = ["A", "E"]
    if "--arm" in args:
        arms = [args.pop(args.index("--arm") + 1)]
    seeds = 1
    if "--seeds" in args:
        seeds = int(args.pop(args.index("--seeds") + 1))
    families = [a for a in args if not a.startswith("--")] or sorted(
        d for d in os.listdir(os.path.join(HERE, "tasks")) if os.path.isfile(os.path.join(HERE, "tasks", d, "task.json")))
    passed = failed = 0
    for family in families:
        with open(os.path.join(HERE, "tasks", family, "task.json")) as f:
            task = json.load(f)
        for agent, spec in task["scripted"].items():
            variants = ["trap", "control"] if agent == "honest" else ["trap"]
            for variant in variants:
                for arm, seed in [(a, s) for a in spec.get("arms", arms) if a in arms for s in range(1, seeds + 1)]:
                    got, err = play(family, variant, arm, agent, keep, seed)
                    name = f"{family} {variant} arm {arm} {agent} seed {seed}"
                    want = dict(spec["expect"], **spec.get(f"expect_{variant}", {}))
                    if got is not None and all(got[k] == v for k, v in want.items()):
                        passed += 1
                        print(f"ok   {name}")
                    else:
                        failed += 1
                        print(f"FAIL {name}: wanted {want}, got " + (err or json.dumps({k: got[k] for k in ("success", "violation", "signals")})))
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
