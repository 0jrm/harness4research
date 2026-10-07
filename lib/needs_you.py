#!/usr/bin/env python3
"""usage: guard needs-you [--remind [--format text|claude-hook]]
       guard needs-you add --kind approve|run|check --title T [--why W] [--path P]... [--run CMD]...
                           [--expect E] [--undo U] [--source S]
       guard needs-you show <id>
       guard needs-you ack|done|dismiss <id> [--note N]

A queue of what only a human can do, check, or approve. With no arguments it prints every open or acked item
as a 🩺 block. add prints the new id, and refuses (exit 2) a path that is relative, missing, or somewhere that
gets cleaned: /tmp, /var/tmp, $TMPDIR, or a directory named scratchpad. --remind prints nothing when no item
is open or outside a git repository, so it can run on every prompt.
"""
import argparse, datetime as dt, fcntl, json, os, subprocess, sys
from collections import namedtuple

COLUMNS = ("id", "ts", "state", "kind", "title", "action", "paths", "commands", "source")
KINDS = ("approve", "run", "check")
ACTION_KEYS = ("why", "expect", "undo", "note")
SEP = ";;"
Move = namedtuple("Move", "sets from_states")
MOVES = {"ack": Move("acked", {"open"}), "done": Move("done", {"open", "acked"}), "dismiss": Move("dismissed", {"open", "acked"})}
HOOK_EVENTS = ("SessionStart", "UserPromptSubmit")
STABLE = "Copy the file to a stable place first, such as the project, and queue that path."

Item = namedtuple("Item", COLUMNS[:5] + ACTION_KEYS + COLUMNS[6:])

class Refused(Exception):
    pass

def git_dir(cwd):
    p = subprocess.run(["git", "-C", cwd, "rev-parse", "--git-common-dir", "--show-toplevel"], capture_output=True, text=True)
    if p.returncode:
        return None, None
    common, top = (p.stdout.splitlines() + [""])[:2]
    return os.path.join(os.path.abspath(os.path.join(cwd, common)), "guard", "needs-you.tsv"), top or cwd

def from_row(line):
    cells = line.split("\t")
    if len(cells) != len(COLUMNS) or cells[0] == "id":
        return None
    row = dict(zip(COLUMNS, cells))
    action = dict(part.split(": ", 1) for part in row.pop("action").split(SEP) if ": " in part)
    return Item(**{k: row[k] for k in COLUMNS[:5]}, **{k: action.get(k, "") for k in ACTION_KEYS},
                paths=[p for p in row["paths"].split(SEP) if p], commands=[c for c in row["commands"].split(SEP) if c],
                source=row["source"])

def to_row(it):
    action = SEP.join(f"{k}: {getattr(it, k)}" for k in ACTION_KEYS if getattr(it, k))
    return "\t".join([it.id, it.ts, it.state, it.kind, it.title, action, SEP.join(it.paths), SEP.join(it.commands), it.source]) + "\n"

def latest(text):
    items = {}
    for line in text.split("\n"):
        it = from_row(line)
        if it:
            items[it.id] = it
    return sorted(items.values(), key=lambda it: int(it.id[1:]) if it.id[1:].isdigit() else 0)

def read(queue):
    try:
        with open(queue) as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            return latest(f.read())
    except FileNotFoundError:
        return []

def transact(queue, change):
    os.makedirs(os.path.dirname(queue), exist_ok=True)
    with open(queue, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        text = f.read()
        it = change(latest(text))
        if it:
            lead = "\t".join(COLUMNS) + "\n" if not text else "" if text.endswith("\n") else "\n"
            f.write(lead + to_row(it))
        return it

def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def cell(name, value, part=False):
    if any(c in value for c in "\t\n\r"):
        raise Refused(f"--{name} holds a tab or a newline; give it on one line")
    if part and (SEP in value or value.startswith(";") or value.endswith(";")):
        raise Refused(f"--{name} {value!r} holds ';;' or starts or ends with ';', which the queue uses to separate entries")
    return value

def cleaned_dirs():
    dirs = {"/tmp", "/var/tmp", os.environ.get("TMPDIR") or "/tmp"}
    return {d for t in dirs for d in (os.path.normpath(t), os.path.realpath(t)) if d != "/"}

def checked_path(p):
    cell("path", p, part=True)
    if not os.path.isabs(p):
        raise Refused(f"{p} is a relative path; give it absolute")
    if not os.path.exists(p):
        raise Refused(f"{p} does not exist")
    norm = os.path.normpath(p)
    for form in (norm, os.path.realpath(p)):
        if "scratchpad" in form.split("/"):
            raise Refused(f"{p} is in a scratchpad directory, which ends with the agent's session. {STABLE}")
        for d in cleaned_dirs():
            if form == d or form.startswith(d + "/"):
                raise Refused(f"{p} is under {d}, which gets cleaned. {STABLE}")
    return norm

def block(it):
    lines = [f"🩺 {it.id} · {it.kind} · {it.title}", ""]
    if it.why:
        lines += [f"Why: {it.why}", ""]
    if it.commands:
        lines += ["Run, in order:", *("  " + c for c in it.commands), ""]
    if it.expect:
        lines.append(f"Expect: {it.expect}")
    if it.undo:
        lines.append(f"Undo: {it.undo}")
    if len(it.paths) == 1:
        lines.append(f"Files: {it.paths[0]}")
    elif it.paths:
        lines += ["Files:", *("  " + p for p in it.paths)]
    return "\n".join(lines + [f"Done: guard needs-you done {it.id}", "", "🩺"])

def summary(top, items):
    head = f"🩺 {len(items)} item{'s' if len(items) > 1 else ''} in {top} need{'s' if len(items) == 1 else ''} you:"
    return "\n".join([head, *(f"  {it.id} · {it.kind} · {it.title}" for it in items),
                      "See them with guard needs-you. guard needs-you ack <id> stops this reminder for one."])

def hook_input():
    if not sys.stdin or sys.stdin.isatty():
        return {}
    try:
        data = json.loads(sys.stdin.read() or "{}")
        return data if isinstance(data, dict) else {}
    except ValueError:
        return {}

def remind(fmt):
    hook = hook_input() if fmt == "claude-hook" else {}
    queue, top = git_dir(hook.get("cwd") or os.getcwd())
    items = [it for it in read(queue) if it.state == "open"] if queue else []
    if not items:
        return
    if fmt == "text":
        print(summary(top, items))
        return
    context = (f"The human has {len(items)} open item{'s' if len(items) > 1 else ''} in the guard needs-you queue for {top}: "
               "things only they can do, check, or approve. Start your reply with each 🩺 block below, verbatim, before "
               "anything else, and keep doing so on every reply until the human acks it (guard needs-you ack <id>), "
               "finishes it, or dismisses it. Never ack, finish, or dismiss an item yourself.\n\n"
               + "\n\n".join(block(it) for it in items))
    out = {"systemMessage": summary(top, items)}
    event = hook.get("hook_event_name")
    if event in HOOK_EVENTS:
        out["hookSpecificOutput"] = {"hookEventName": event, "additionalContext": context}
    print(json.dumps(out))

def add(queue, a):
    if not all(c.strip() for c in a.run):
        raise Refused("--run is empty")
    if a.kind == "run" and not a.run:
        raise Refused("--kind run needs at least one --run command")
    if not a.title.strip():
        raise Refused("--title is empty")
    fields = dict(title=cell("title", a.title), why=cell("why", a.why, part=True), expect=cell("expect", a.expect, part=True),
                  undo=cell("undo", a.undo, part=True), note="", source=cell("source", a.source),
                  paths=[checked_path(p) for p in a.path], commands=[cell("run", c, part=True) for c in a.run])
    def new(items):
        n = max((int(it.id[1:]) for it in items if it.id[1:].isdigit()), default=0) + 1
        return Item(id=f"n{n}", ts=now(), state="open", kind=a.kind, **fields)
    print(transact(queue, new).id)

def move(queue, verb, ident, note):
    state, from_states = MOVES[verb]
    note = cell("note", note, part=True)
    def change(items):
        it = next((it for it in items if it.id == ident), None)
        if not it:
            raise Refused(f"no item {ident} in {queue}")
        if it.state == state:
            print(f"{ident} is already {state}")
            return None
        if it.state not in from_states:
            raise Refused(f"{ident} is {it.state}, so it cannot become {state}")
        print(f"{ident} {state}")
        return it._replace(ts=now(), state=state, note=note or it.note)
    transact(queue, change)

class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: {message}", file=sys.stderr)
        sys.exit(64)

def main():
    ap = Parser(prog="guard needs-you", description=__doc__.split("\n\n")[1])
    ap.add_argument("--remind", action="store_true", help="print the open items for a person or an agent hook, or nothing")
    ap.add_argument("--format", choices=("text", "claude-hook"), default="text")
    sub = ap.add_subparsers(dest="cmd", parser_class=Parser)
    p = sub.add_parser("add", help="queue an item and print its id")
    p.add_argument("--kind", required=True, choices=KINDS)
    p.add_argument("--title", required=True)
    p.add_argument("--why", default="")
    p.add_argument("--path", action="append", default=[])
    p.add_argument("--run", action="append", default=[])
    p.add_argument("--expect", default="")
    p.add_argument("--undo", default="")
    p.add_argument("--source", default="")
    sub.add_parser("show", help="print one item's block").add_argument("id")
    for verb in MOVES:
        p = sub.add_parser(verb, help=f"mark an item {MOVES[verb].sets}")
        p.add_argument("id")
        p.add_argument("--note", default="")
    a = ap.parse_args()

    if a.remind:
        try:
            remind(a.format)
        except Exception:
            pass
        return
    queue, _ = git_dir(os.getcwd())
    try:
        if not queue:
            raise Refused(f"{os.getcwd()} is not a git repository")
        if a.cmd == "add":
            add(queue, a)
        elif a.cmd == "show":
            it = next((it for it in read(queue) if it.id == a.id), None)
            if not it:
                raise Refused(f"no item {a.id} in {queue}")
            print(block(it))
        elif a.cmd in MOVES:
            move(queue, a.cmd, a.id, a.note)
        else:
            items = [it for it in read(queue) if it.state in ("open", "acked")]
            print("\n\n".join(block(it) for it in items) if items else "Nothing needs you.")
    except Refused as e:
        print(f"guard needs-you: {e}", file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
