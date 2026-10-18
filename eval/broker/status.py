"""guard status behind the broker: the project's whole state in at most 300 tokens, counted at 4 characters a token.

The facts come from records the harness already keeps: the broker's status reply (this session's ledger jobs as the
scheduler reports them, the budget, open needs-you items, cards not approved, the latest refusal), and, read here in
the sandbox, the project's git state and any guard wait processes. render() is pure; local_facts() reads git and ps.

    running: job 12 (run-a) RUNNING 0:04:10 of 0:30:00
    blocked: nothing
    last refusal: 3 min ago, scheduler: time 60 (60 min) exceeds max_walltime_minutes=30
    budget: 12 of 100 core-h spent, 0 queued, 78 left above the 10 reserve
    git: main, 2 changed files, 1 commit ahead of origin/main
    next: git add -A && git commit -m 'what changed'"""
import os
import subprocess

MAX_CHARS = 1200
LINE_CHARS = 190  # six lines of at most 190 characters and a newline stay under MAX_CHARS
LIVE = ("PENDING", "CONFIGURING", "RUNNING", "COMPLETING", "SUSPENDED", "REQUEUED")
FAILED = ("TIMEOUT", "OUT_OF_ME", "NODE_FAIL", "FAILED", "PREEMPTED", "CANCELLED")


def listed(items, most=3):
    return "; ".join(items[:most]) + (f"; and {len(items) - most} more" if len(items) > most else "") or "nothing"


def plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def next_command(f):
    jobs, git = f.get("jobs") or [], f.get("git") or {}
    live = [j for j in jobs if j["state"].split()[0] in LIVE]
    if f.get("blocked"):
        return f"do other work, or stop: {f['blocked'][0].split(':')[0]} waits on a person"
    if live or f.get("waits"):
        return "do other work, then guard status again; do not poll"
    if jobs and jobs[-1]["state"].split()[0] in FAILED:
        j = jobs[-1]
        return (f"read job {j['id']}'s output, then commit runs/{j['run']}/incidents/{j['id']}.md with a line "
                f"job: {j['id']} to main before the next job")
    if not git:
        return "cd to the project, then guard status"
    if git.get("changed"):
        return "git add -A && git commit -m 'what changed'"
    if git.get("ahead"):
        return "git push origin HEAD:main"
    if git.get("behind"):
        return "git pull --rebase origin main"
    return "none: the work is on main"


def render(f):
    jobs = [f"job {j['id']} ({j['run']}) {j['state']} {j['elapsed']} of {j['limit']}" for j in f.get("jobs") or []
            if j["state"].split()[0] in LIVE]
    jobs += [f"guard wait {w}" for w in f.get("waits") or []]
    r = f.get("refusal")
    b = f.get("budget")
    g = f.get("git")
    lines = [
        "running: " + listed(jobs),
        "blocked: " + listed(f.get("blocked") or []),
        "last refusal: " + (f"{r['ago_min']} min ago, {r['where']}: {r['why']}" if r else "none"),
        "budget: " + (f"{b['spent']} of {b['max']} core-h spent, {b['queued']} queued, "
                      f"{b['max'] - b['reserve'] - b['spent'] - b['queued']} left above the {b['reserve']} reserve"
                      if b else "unknown (the broker could not read guard/budget.card on main)"),
        "git: " + (f"{g['branch'] or 'detached'}, {plural(g['changed'], 'changed file')}, "
                   f"{plural(g['ahead'], 'commit')} ahead of origin/main, {g['behind']} behind" if g
                   else "not in the project"),
        "next: " + next_command(f),
    ]
    text = "".join((line if len(line) <= LINE_CHARS else line[:LINE_CHARS - 3] + "...") + "\n" for line in lines)
    assert len(text) <= MAX_CHARS
    return text


def run(*cmd, cwd=None):
    try:
        done = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout if done.returncode == 0 else None


def project():
    top = run("git", "rev-parse", "--show-toplevel")
    if top:
        return top.strip()
    home = os.path.expanduser("~")
    found = sorted(os.path.join(home, d) for d in os.listdir(home) if os.path.isfile(os.path.join(home, d, "guard", "run")))
    return found[0] if found else None


def local_facts():
    """The sandbox's own part: the project's git state against origin/main, and guard wait processes."""
    facts = {"git": None, "waits": []}
    top = project()
    if top:
        run("git", "fetch", "-q", "origin", "main", cwd=top)
        changed = run("git", "status", "--porcelain", cwd=top)
        counts = (run("git", "rev-list", "--left-right", "--count", "origin/main...HEAD", cwd=top) or "0 0").split()
        facts["git"] = {"branch": (run("git", "branch", "--show-current", cwd=top) or "").strip(),
                        "changed": len((changed or "").splitlines()), "behind": int(counts[0]), "ahead": int(counts[1])}
    for line in (run("ps", "-eo", "pid=,args=") or "").splitlines():
        pid, _, args = line.strip().partition(" ")
        if "lib/wait.py" in args or args.startswith("guard wait"):
            facts["waits"].append(pid)
    return facts
