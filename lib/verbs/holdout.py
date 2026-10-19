#!/usr/bin/env python3
"""guard holdout: the agent's score on the sealed holdout, and the person's seal (design-v8 section 6).

    guard holdout score
        the solution on the current branch, as origin has it, scored by the broker on its sealed set; one line,
        "holdout <ledger_id> pass; <k> of <N> submissions left", or refusal H01 to H05

    guard holdout seal <dir> --threshold T --max N --scorer CMD [--timeout S] [--python VENV] [--state DIR]
        outside the sandbox: seals <dir>'s train.csv, public_test.csv, sealed_test.csv and sealed_features.csv into
        the broker's state for the project around the current directory (or --state DIR). CMD runs as
        `CMD <train> <test> <out>` in the solution's tree and writes a CSV with a prediction column; --python binds
        VENV read-only into the scorer's box and puts its bin first on PATH."""
import argparse
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
from broker import holdout, transport  # noqa: E402


def git(*args):
    done = subprocess.run(["git", *args], capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else None


def project_state():
    """The broker's state for the project around the current directory, named as lib/broker_host.py names it."""
    top = git("rev-parse", "--show-toplevel")
    if top is None:
        sys.exit("guard holdout seal: run it inside the project, or name the broker's state with --state DIR")
    top = os.path.realpath(top)
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    name = f"{os.path.basename(top) or 'root'}-{hashlib.sha1(top.encode()).hexdigest()[:8]}"
    return os.path.join(base, "guard", "projects", name)


def seal(argv):
    p = argparse.ArgumentParser(prog="guard holdout seal")
    p.add_argument("dir")
    p.add_argument("--threshold", type=float, required=True)
    p.add_argument("--max", type=int, required=True, dest="max_submissions")
    p.add_argument("--scorer", required=True)
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("--python")
    p.add_argument("--state")
    a = p.parse_args(argv)
    state = a.state or project_state()
    origin = None
    try:
        with open(os.path.join(state, "config.json")) as f:
            origin = json.load(f).get("origin")
    except (OSError, ValueError):
        pass
    record = holdout.seal(state, a.dir, a.threshold, a.max_submissions, a.scorer, a.timeout, a.python, origin)
    where = "at origin's pre-receive" if origin and os.path.isdir(origin) else "nowhere, since origin is not on this host"
    print(f"sealed {record['sha256']['sealed_test.csv'][:12]} in {state}/holdout; {a.max_submissions} scores a "
          f"session; pushes checked {where}")
    return 0


def score(argv):
    if argv:
        sys.stderr.write("usage: guard holdout score\n")
        return 64
    branch = git("rev-parse", "--abbrev-ref", "HEAD") or "HEAD"
    reply = transport.send({"verb": "holdout", "action": "score", "branch": branch, "cwd": os.getcwd()}, "records")
    sys.stdout.write(reply.get("out", ""))
    sys.stderr.write(reply.get("err", ""))
    return reply.get("rc", 1)


def main(argv):
    if argv[:1] == ["score"]:
        return score(argv[1:])
    if argv[:1] == ["seal"]:
        return seal(argv[1:])
    sys.stderr.write("usage: guard holdout score | guard holdout seal <dir> --threshold T --max N --scorer CMD\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
