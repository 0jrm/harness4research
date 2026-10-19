#!/usr/bin/env python3
"""The sandbox's sbatch, squeue, sacct, scancel, sacctmgr and gh, by the name they are called under, when the session
runs behind the broker. squeue, sacct and scancel send one request to the scheduler socket and print the reply; gh
sends one to the gh socket.

sbatch never reaches the scheduler: guard run is the only way in (design-v8 section 2), so the stand-in prints R09
with the guard run line for the same job, built from its options and script. guard is bin/guard, not this file.

gh sends its arguments to the gh socket, which decides what it offers (forge.py): pr create, view, list, diff, checks
and comment, and api reads. Here it only reads --body-file into --body, names the current branch where gh would, and
applies --jq to the reply."""
import json
import os
import socket
import subprocess
import sys

SOCKET = "/run/guard/scheduler.sock"
GH = "/run/guard/gh.sock"
HARNESS_REFUSALS = "/opt/harness4research/lib/refusals.py"
R15 = "H4R-R15 the broker is down; nothing reaches the scheduler from here\nnone\n"


class Refused(Exception):
    pass


def branch():
    done = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True)
    return done.stdout.strip()


def read_text(path, what):
    try:
        with open(path) as f:
            return f.read()
    except OSError as e:
        raise Refused(f"cannot read {what} {path}: {e.strerror}")


def gh_request(args):
    """(request, jq): the arguments with --body-file read and the current branch named, and the --jq expression."""
    out, jq, i = [], None, 0
    pr = args[:1] == ["pr"]
    while i < len(args):
        a = args[i]
        if a in ("--jq", "-q") and i + 1 < len(args):
            jq, i = args[i + 1], i + 2
            continue
        if a.startswith("--jq="):
            jq, i = a[len("--jq="):], i + 1
            continue
        if pr and a in ("--body-file", "-F") and i + 1 < len(args):
            out += ["--body", read_text(args[i + 1], "--body-file")]
            i += 2
            continue
        if pr and a.startswith("--body-file="):
            out += ["--body", read_text(a[len("--body-file="):], "--body-file")]
            i += 1
            continue
        out.append(a)
        i += 1
    if out[:2] == ["pr", "create"] and not any(a in ("--head", "-H") or a.startswith("--head=") for a in out):
        out += ["--head", branch()]
    if out[:2] in (["pr", "view"], ["pr", "diff"], ["pr", "checks"]) and (len(out) == 2 or out[2].startswith("-")):
        out.insert(2, branch())
    return {"verb": "gh", "argv": out}, jq


def gh(args):
    try:
        request, jq = gh_request(args)
    except Refused as e:
        sys.stderr.write(f"gh: refused: {e}\n")
        return 1
    reply = ask(request, GH)
    out = reply.get("out", "")
    if jq is not None and reply.get("rc") == 0:
        done = subprocess.run(["jq", "-r", jq], input=out, capture_output=True, text=True)
        out = done.stdout
        sys.stderr.write(done.stderr)
        if done.returncode:
            return done.returncode
    sys.stdout.write(out)
    sys.stderr.write(reply.get("err", ""))
    return reply.get("rc", 1)


def sbatch(args):
    """R09 from the harness's refusal table, where this file sits in a harness, else the same two lines with guard
    status as line 2."""
    lib = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    table = next((p for p in (os.path.join(lib, "refusals.py"), HARNESS_REFUSALS) if os.path.isfile(p)), None)
    if table:
        os.execv(sys.executable, [sys.executable, table, "old", "sbatch", *args])
    sys.stderr.write("H4R-R09 sbatch is gone; guard run writes the card and prices the job\nguard status\n")
    return 2


def ask(request, path=SOCKET):
    conn = socket.socket(socket.AF_UNIX)
    try:
        conn.connect(path)
    except OSError:
        return {"rc": 2, "err": R15}
    with conn:
        conn.sendall(json.dumps(request).encode() + b"\n")
        line = conn.makefile().readline()
    return json.loads(line) if line else {"rc": 1, "err": "guard broker closed the connection\n"}


def main(cmd, args):
    if cmd == "sbatch":
        return sbatch(args)
    if cmd == "gh":
        return gh(args)
    verbs = {"squeue": "queue", "sacct": "acct", "scancel": "cancel"}
    try:
        if cmd in verbs:
            request = {"verb": verbs[cmd], "args": args}
        else:
            raise Refused("not offered here")
    except Refused as e:
        sys.stderr.write(f"{cmd}: refused: {e}\n")
        return 1
    reply = ask(request)
    sys.stdout.write(reply.get("out", ""))
    sys.stderr.write(reply.get("err", ""))
    return reply.get("rc", 1)


if __name__ == "__main__":
    sys.exit(main(os.path.basename(sys.argv[0]), sys.argv[1:]))
