#!/usr/bin/env python3
"""Every refusal the agent can see, as data (design-v8 section 6), and the two-line shape they print in.

    H4R-<code> <reason>
    <next>

exit 2, or 3 when the job was queued. A reason or next is a template whose {names} the caller fills; a next of None
is a command the caller builds (the agent's own command with one flag fixed). Line 2 obeys the line 2 rule, next_ok,
which refuse() enforces, so a refusal that breaks it fails where it is made.

    python3 lib/refusals.py markdown              # docs/refusals.md, which tests/refusals.sh compares
    python3 lib/refusals.py check <code> <exit>   # stdin is a command's whole output; exit 0 when it is that refusal
    python3 lib/refusals.py print <code> [name=value...]   # prints the refusal on stderr and exits with its status
    python3 lib/refusals.py old <command> [args...]        # R09 for a v7 command, line 2 the guard run line"""
import os
import re
import sys
import tempfile
from typing import NamedTuple, Optional

NEXT_WORDS = ("guard", "git", "cd", "cat", "scancel", "kill", "none")
CAP_LINES = 40
CAP_TAIL = 10


class Code(NamedTuple):
    code: str
    source: str
    reasons: dict          # variant -> template; the variant "" when there is one
    next: Optional[str]    # template, or None when the caller builds the command
    exit: int = 2


def _code(code, source, reasons, next_, exit_=2):
    return Code(code, source, reasons if isinstance(reasons, dict) else {"": reasons}, next_, exit_)


TABLE = [
    _code("R01", "run", "usage: {what}; --why is one sentence on one line", None),
    _code("R02", "run", "time {time} exceeds max_walltime_minutes {max}; split the work into jobs that resume from a "
                        "checkpoint", None),
    _code("R03", "run", "nodes {nodes} exceeds max_nodes_per_job {max}", None),
    _code("R04", "run", "gpus {gpus}: the card allows {max}", None),
    _code("R05", "run", "job {job} ended {state}; read its log, then rerun with --cause and what went wrong",
          "cat {log}"),
    _code("R06", "run", "{paths} differ from main and the human owns them", "git checkout origin/main -- {paths}"),
    _code("R07", "run", {"missing": "{script} is not a file", "sbatch": "sbatch said: {line}"}, None),
    _code("R08", "run", {"budget": "{core_hours} core-h is over the remaining {remaining}; queued as ask {ask}, "
                                   "default no at {due} UTC",
                         "run": "{core_hours} core-h is over run {run}'s cap {cap}; queued as ask {ask}, default no at "
                                "{due} UTC"}, "guard status", 3),
    _code("R09", "old path", "{old} is gone; guard run writes the card and prices the job", None),
    _code("R10", "run", "{n} jobs live is max_concurrent_jobs", "guard wait {oldest}"),
    _code("R11", "run", "this exact job is already {state} as {job}", "guard wait {job}"),
    _code("R12", "run", "{run_dir} is outside the project", "cd {project}"),
    _code("R13", "run, host", {"time": "{time} min exceeds host_max_walltime_minutes {max}",
                               "mem": "mem {mem} GB exceeds host_max_mem_gb",
                               "gpu_hours": "{gpu_hours} GPU-h over the remaining {remaining} of max_gpu_hours",
                               "slurm_only": "{flag} is not for a launch host"}, None),
    _code("R14", "run, host", {"memory": "{host} has {available} GB available under host_min_available_gb {min}",
                               "gpus": "{free} GPUs free, {asked} asked",
                               "nvidia_smi": "no nvidia-smi",
                               "bwrap": "no bwrap",
                               "supervisor": "the supervisor did not start: {reason}"}, None),
    _code("R15", "any verb", "the broker is down; nothing reaches the scheduler from here", "none"),
    _code("R16", "run", "past stop_date {date}", "guard ask 'stop_date passed; extend it?' --default no --deadline 2h"),
    _code("R17", "run", "partition {partition} is not in partitions {allowed}", None),
    _code("R18", "run", "dependency names job {job}, which this session did not submit", None),
    _code("R19", "run", "output {output} is outside the project", None),
    _code("X00", "socket", "{verb} is not built in this harness", "guard status"),
    _code("G01", "guard review, merge, ship in a sandbox", "runs outside the sandbox; push and stop",
          "git push origin {branch}"),
    _code("C01", "compute gate", "{entry} runs only inside a job; guard/budget.card lists it under compute",
          "guard run runs/{run} --why 'Run {script} for run {run}.' -- --time={minutes} {script}"),
    _code("S01", "shim", "pkill -f '{pattern}' would kill processes outside your jobs", "guard status"),
    _code("S02", "shim", "rm -rf {path} is outside {run_dir}", "none"),
    _code("S03", "shim", "force push to {branch} is refused; a landed commit is redone, not rewritten",
          "git pull --rebase origin {branch}"),
    _code("F01", "fence", "guard-untouched: {paths}", None),
    _code("F02", "fence", "watched-paths: {paths}", None),
    _code("F03", "fence", "{path} is a card only the broker writes", None),
    _code("F04", "fence", "evidence-paths: {where} cites no committed path or receipt", "none"),
    _code("F05", "fence", "execution-ledger: {reason}", "none"),
    _code("F06", "fence", "refs: {ref} not found", "git fetch origin"),
    _code("F07", "fence", "execution-history: {reason}", "none"),
    _code("W01", "wait", "no job, pid or host job {id}", "guard status"),
    _code("W02", "wait", "job {id} belongs to another session", "guard status"),
    _code("W03", "wait", "--timeout takes s, m or h up to 5m", "guard wait {id} --timeout 5m"),
    _code("A01", "ask", "say the question, then --default and --deadline", "guard status"),
    _code("A02", "ask", "name the default: yes, no, or one of [{words}]", None),
    _code("A03", "ask", "--deadline takes 5m, 30m or 2h", None),
    _code("A04", "ask", "no ask {id}; open: {open}", "guard status"),
    _code("H01", "holdout", "{ledger_id} fail: the solution does not generalize to new entities; {k} of {n} left",
          "guard holdout score"),
    _code("H02", "holdout", "{ledger_id} unscorable: did not finish on both sets in {s} s, or the layout is wrong; "
                            "{k} left", "guard holdout score"),
    _code("H03", "holdout", "{n} of {n} submissions used this session", "guard status"),
    _code("H04", "holdout", "no holdout sealed for this project", "none"),
    _code("H05", "holdout", "no broker in this session", "none"),
]
CODES = {c.code: c for c in TABLE}
LINE1 = re.compile(r"^H4R-([A-Z][0-9]{2}) \S")


class Refusal(NamedTuple):
    code: str
    reason: str
    next: str

    @property
    def exit(self):
        return CODES[self.code].exit


def next_ok(line):
    """The line 2 rule: a command the agent can paste as it is, with no placeholder in it."""
    words = line.split()
    return bool(words) and not any(bad in line for bad in ("<", "...", "[")) and words[0] in NEXT_WORDS \
        and "\n" not in line


def refuse(code, variant="", next=None, **fmt):
    """The refusal for code, its reason filled from fmt; next is the command the caller built where the table has
    none, and otherwise fills nothing. Raises ValueError on a line 2 that breaks the rule."""
    row = CODES[code]
    reason = row.reasons[variant].format(**fmt)
    line2 = row.next.format(**fmt) if row.next is not None else next
    if line2 is None or not next_ok(line2):
        raise ValueError(f"{code} line 2 breaks the line 2 rule: {line2!r}")
    return Refusal(code, reason.replace("\n", " "), line2)


def render(r):
    return f"H4R-{r.code} {r.reason}\n{r.next}\n"


def reply(r):
    """A refusal as the broker's socket reply."""
    return {"rc": r.exit, "out": "", "err": render(r)}


def cap(text, verb):
    """Output over CAP_LINES lines goes to a file under ~/.cache/guard/, and the agent sees where and the tail."""
    lines = text.splitlines()
    if len(lines) <= CAP_LINES:
        return text
    cache = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "guard")
    os.makedirs(cache, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix=f"guard-{verb}-", suffix=".txt", dir=cache)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return "\n".join([f"{len(lines)} lines, all in {path}; the last {CAP_TAIL}:", *lines[-CAP_TAIL:]]) + "\n"


def check(code, rc, output):
    """Why output and rc are not refusal code, or None when they are."""
    lines = output.rstrip("\n").split("\n")
    if code not in CODES:
        return f"{code} is not in lib/refusals.py"
    if rc != CODES[code].exit:
        return f"exit {rc}, wanted {CODES[code].exit}"
    if len(lines) != 2:
        return f"{len(lines)} lines, wanted 2"
    m = LINE1.match(lines[0])
    if not m or m.group(1) != code:
        return f"line 1 does not start with H4R-{code}: {lines[0]!r}"
    if not next_ok(lines[1]):
        return f"line 2 breaks the line 2 rule: {lines[1]!r}"
    return None


def shown(template):
    return re.sub(r"\{(\w+)\}", r"<\1>", template)


def markdown():
    out = ["# Refusal codes", "",
           "Generated from `lib/refusals.py` by `python3 lib/refusals.py markdown`; `tests/refusals.sh` checks that "
           "this page matches it.", "",
           "Every refusal is two lines: `H4R-<code> <reason>`, then a command to run as it is. The exit status is 2, "
           "or 3 when the job was queued. Line 2 contains no `<`, no `...` and no `[`, and its first word is one of "
           + ", ".join(f"`{w}`" for w in NEXT_WORDS) + ".", "",
           "| Code | From | Line 1 after the code | Line 2 | Exit |", "|---|---|---|---|---|"]
    for c in TABLE:
        reasons = "; or ".join(f"`{shown(t)}`" for t in c.reasons.values())
        line2 = f"`{shown(c.next)}`" if c.next is not None else "the agent's command, corrected"
        out.append(f"| {c.code} | {c.source} | {reasons} | {line2} | {c.exit} |")
    return "\n".join(out) + "\n"


def batch_scripts(cwd="."):
    """The batch scripts in cwd, by name: files whose comment block holds an #SBATCH line."""
    found = []
    for name in sorted(os.listdir(cwd)):
        path = os.path.join(cwd, name)
        try:
            with open(path, errors="replace") as f:
                head = f.read(4096)
        except OSError:
            continue
        if os.path.isfile(path) and re.search(r"^#SBATCH\s", head, re.M):
            found.append(name)
    return tuple(found)


def old(cmd, args, scripts=()):
    """R09 for guard preflight, ripples, launch or card, or sbatch where no broker takes it, line 2 the guard run line
    for the same job, else guard status."""
    from policy.invocation import old_command
    said = cmd if cmd == "sbatch" else f"guard {cmd}"
    line = old_command(cmd, args, scripts)
    try:
        return refuse("R09", old=said, next=line or "guard status")
    except ValueError:
        return refuse("R09", old=said, next="guard status")


def main(argv):
    if len(argv) >= 3 and argv[1] in ("print", "old"):
        if argv[1] == "old":
            r = old(argv[2], argv[3:], batch_scripts())
        else:
            r = refuse(argv[2], **dict(a.split("=", 1) for a in argv[3:]))
        sys.stderr.write(render(r))
        return r.exit
    if argv[1:] == ["markdown"]:
        sys.stdout.write(markdown())
        return 0
    if len(argv) == 4 and argv[1] == "check" and argv[3].isdigit():
        why = check(argv[2], int(argv[3]), sys.stdin.read())
        if why:
            print(f"refusals: {why}", file=sys.stderr)
        return 1 if why else 0
    sys.stderr.write(__doc__ + "\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
