#!/usr/bin/env python3
"""guard status: the project's whole state in six lines and at most 1200 characters, for the resume after a compaction.

    running: job 12 (run-a) RUNNING 0:04:10 of 0:30:00
    blocked: ask n3 waits for a person: stop_date passed; extend it?
    last refusal: 3 min ago, scheduler: H4R-R02 time 60 exceeds max_walltime_minutes 30
    budget: 12 of 100 core-h spent, 0 queued, 78 left above the 10 reserve
    git: main, 2 changed files, 1 commit ahead of origin/main, 0 behind; receipts: guard/receipts at 1a2b3c4d5e6f, signed by the broker
    next: guard wait 12

The broker's facts (lib/broker/status.py) come over the scheduler socket; the git state and this shell's guard wait
processes are read here, in the sandbox. render() is pure. next: is one command that obeys the line 2 rule."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import refusals  # noqa: E402
from broker import transport  # noqa: E402

MAX_CHARS = 1200
LINE_CHARS = 190  # six lines of at most 190 characters and a newline stay under MAX_CHARS
MOST = 3
BLOCKED = "blocked: "
WAIT_MARK = 'echo $? > "$0/$$.rc"'  # what lib/wait.py's sh runs: its processes are the commands guard wait started


def listed(items, most=MOST):
    return "; ".join(items[:most]) + (f"; and {len(items) - most} more" if len(items) > most else "") or "nothing"


def shown(label, items):
    """How many of items the line label + listed(items) shows whole, after the cut to LINE_CHARS."""
    line = label + listed(items)
    if len(line) > LINE_CHARS:
        line = line[:LINE_CHARS - 3]
    n, at = 0, len(label)
    for item in items[:MOST]:
        if line[at:at + len(item)] != item:
            break
        n, at = n + 1, at + len(item) + 2
    return n


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def log_of(job):
    """The newest log file named for the job in the working directory or a run directory, as guard wait finds it."""
    from wait import job_log
    return job_log(job)


def next_command(f):
    running, git, failed = f.get("running") or [], f.get("git"), f.get("failed")
    if failed:
        log = log_of(failed["id"])
        return f"cat {log}" if log and refusals.next_ok(f"cat {log}") else "guard status"
    if running:
        return f"guard wait {running[0]['id']}"
    if f.get("waits"):
        return f"guard wait {f['waits'][0]}"
    if not git:
        return "none"
    if git["changed"]:
        return "git add -A && git commit -m 'what changed'"
    if git["ahead"] and git["branch"]:
        return f"git push origin {git['branch']}"
    if git["behind"] and git["branch"]:
        return f"git pull --rebase origin {git['branch']}"
    return "none"


def render(f):
    jobs = [f"job {j['id']} ({j['run']}) {j['state']}" + (f" {j['elapsed']} of {j['limit']}" if j["elapsed"] else "")
            for j in f.get("running") or []]
    jobs += [f"pid {p}" for p in f.get("waits") or []]
    r, b, g = f.get("refusal"), f.get("budget"), f.get("git")
    left = b and b["max"] - b["reserve"] - b["spent"] - b["queued"]
    lines = [
        "running: " + listed(jobs),
        BLOCKED + listed(f.get("blocked") or []),
        "last refusal: " + (f"{r['ago_min']} min ago, {r['where']}: {r['why']}" if r else "none"),
        "budget: " + (f"{b['spent']} of {b['max']} core-h spent, {b['queued']} queued, {left} left above the "
                      f"{b['reserve']} reserve" if b else "unknown (the broker could not read guard/budget.card on main)"),
        "git: " + (f"{g['branch'] or 'detached'}, {plural(g['changed'], 'changed file')}, "
                   f"{plural(g['ahead'], 'commit')} ahead of origin/main, {g['behind']} behind"
                   + ("; unsigned: no broker" if f.get("unsigned") else "") if g else "not in the project")
        + (f"; {f['receipts']}" if f.get("receipts") else ""),
        "next: " + next_command(f),
    ]
    text = "".join((l if len(l) <= LINE_CHARS else l[:LINE_CHARS - 3] + "...") + "\n" for l in lines)
    assert len(text) <= MAX_CHARS
    return text


def run(*cmd, cwd=None):
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def local_facts(cwd=None):
    """This shell's part: the project's git state against the last-fetched origin/main, and guard wait processes."""
    facts = {"git": None, "waits": []}
    top = (run("git", "rev-parse", "--show-toplevel", cwd=cwd) or "").strip()
    if top:
        changed = run("git", "status", "--porcelain", cwd=top) or ""
        counts = (run("git", "rev-list", "--left-right", "--count", "origin/main...HEAD", cwd=top) or "0 0").split()
        facts["git"] = {"branch": (run("git", "branch", "--show-current", cwd=top) or "").strip(),
                        "changed": len(changed.splitlines()), "behind": int(counts[0]), "ahead": int(counts[1])}
    me = str(os.getpid())
    for line in (run("ps", "-eo", "pid=,args=") or "").splitlines():
        pid, _, args = line.strip().partition(" ")
        if pid != me and args.startswith("sh -c") and WAIT_MARK in args:
            facts["waits"].append(pid)
    return facts


def main(argv):
    if argv:
        sys.stderr.write("usage: guard status\n")
        return 64
    reply = transport.send({"verb": "status", "cwd": os.getcwd()})
    if reply.get("rc") != 0:
        sys.stderr.write(reply.get("err", ""))
        return reply.get("rc") or 1
    facts = {**json.loads(reply.get("out") or "{}"), **local_facts()}
    sys.stdout.write(refusals.cap(render(facts), "status"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
