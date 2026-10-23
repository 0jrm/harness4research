#!/usr/bin/env python3
"""usage: guard needs-you [--remind [--format text|claude-hook]]
       guard needs-you add --kind approve|run|check --title T [--why W] [--path P]... [--run CMD]...
                           [--expect E] [--worry W] [--undo U] [--source S] [--update]
       guard needs-you --json [--state open|acked|done|dismissed|all]
       guard needs-you find --kind approve|run|check --title T
       guard needs-you show <id>
       guard needs-you ack|done|dismiss <id> [--note N]

A queue of what only a human can do, check, or approve. With no arguments it prints every open or acked item
as a 🩺 block: the commands in one fenced block the person can paste whole, a --run that starts with "# " as a
short comment in it, then a sample of the expected (--expect) and the worrisome (--worry) output, and the command
that closes the item. add prints the new id, and refuses (exit 2) a path that is relative, missing, or somewhere that
gets cleaned: /tmp, /var/tmp, $TMPDIR, or a directory named scratchpad, and a --run that escapes a shell
character with a backslash (\\| \\& \\; \\< \\>), which a second shell such as ssh's reads unescaped. --remind
prints nothing when no item is open or outside a git repository, so it can run on every prompt. Adding an item with
the kind and title of an open one prints that item's id and queues nothing. With --update, an open or acked item of that kind and title takes
the new content under the same id and opens again; when the content is the same, nothing changes. find prints the id
of the open or acked item with that kind and title, and exits 1 when there is none.

The items a<n> are the broker's guard asks, kept where the agent's sandbox cannot write (ask_queues). They list, show
and close here with the project's own: done a<n> [--note ANSWER] answers it (no note means yes), dismiss a<n> means no.

--json prints the queue as one JSON object, {"schema": 1, "repo", "queue", "items"}, and never writes. --state picks
the items by state; the default is open and acked, like the bare command. Each item carries its latest state, its
created time (its first row in the log) and updated time (its latest row), a body of the non-empty action parts and
commands, its evidence paths, its source, and block, the text the bare command prints for it. A row with the wrong
number of cells, or a last line with no newline, is skipped, with one line on stderr. Exit 0 for an empty or missing
queue (items: []) as for a full one, 2 outside a git repository, and U01 (exit 2) when --json comes with --remind or a
subcommand.
"""
import datetime as dt, fcntl, hashlib, json, os, re, subprocess, sys
from collections import namedtuple

import refusals

COLUMNS = ("id", "ts", "state", "kind", "title", "action", "paths", "commands", "source")
KINDS = ("approve", "run", "check")
ADD, FIND, LIST = ("guard needs-you add --kind check --title TITLE", "guard needs-you find --kind check --title TITLE",
                   "guard needs-you")
ACTION_KEYS = ("why", "expect", "worry", "undo", "note")
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

def ask_queues(queue, top):
    """The queues that hold this project's guard asks, which the broker keeps out of the agent's sight: its records in
    <git dir>/guard/broker/ when guard ask ran with no broker, and in the broker's state, named as lib/broker_host.py
    names a project, when one served the sandbox. Their items are the ones with ids a<n>; the project's own are n<n>."""
    real = os.path.realpath(top)
    state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "guard", "projects",
                         f"{os.path.basename(real) or 'root'}-{hashlib.sha1(real.encode()).hexdigest()[:8]}")
    paths = [os.path.join(state, "records", "needs-you.tsv"),  # first: an ask id in a sandbox's checkout never wins
             os.path.join(os.path.dirname(queue), "broker", "records", "needs-you.tsv")]
    return [p for p in paths if os.path.exists(p)]

def asks(queue, top):
    return [(q, it) for q in ask_queues(queue, top) for it in read(q) if it.id.startswith("a")]

def home(queue, top, ident):
    """The queue that holds item ident: an ask's, else the project's."""
    return next((q for q, it in asks(queue, top) if it.id == ident), queue)

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

def read_json_items(queue):
    """The latest item per id with the ts of its first row, and a line for each skipped row. A last line with no
    newline may be cut short, so it is skipped even when it has enough cells."""
    try:
        with open(queue) as f:
            fcntl.flock(f, fcntl.LOCK_SH)
            text = f.read()
    except FileNotFoundError:
        return [], {}, []
    lines = text.split("\n")
    unterminated = lines.pop()
    skipped = [f"row {n}: {len(l.split(chr(9)))} cells, want {len(COLUMNS)}" for n, l in enumerate(lines, 1)
               if l and not l.startswith("id\t") and len(l.split("\t")) != len(COLUMNS)]
    if unterminated:
        skipped.append(f"row {len(lines) + 1}: no newline at the end")
    created = {}
    for line in lines:
        it = from_row(line)
        if it:
            created.setdefault(it.id, it.ts)
    return latest("\n".join(lines)), created, skipped

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

ESCAPED = re.compile(r"\\[|&;<>]")

def checked_run(command):
    """A --run command, refused when it escapes a shell character with a backslash. The person's shell drops the
    backslash, and a second shell, as ssh starts on the remote host, then reads the bare character: ssh host grep -E
    A\\|B log ran grep A into a command named B."""
    m = ESCAPED.search(command)
    if m:
        raise Refused(f"--run '{command}' holds {m.group()}, a backslash before a shell character, which a second shell "
                      "such as ssh's on the remote host reads without the backslash. Quote the remote command as a whole, "
                      "as in ssh host 'grep -E \"A|B\" log', or give grep each pattern with -e: grep -e A -e B")
    return command

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

def block(it, top):
    """One item as a 🩺 block. Commands go in one fenced block, so a person can copy them and run them with one
    Enter; a command starting with "# " is a comment there. The closing command cds into the repository first,
    because the queue belongs to the repository it runs in."""
    lines = [f"🩺 {it.id} · {it.kind} · {it.title}", ""]
    if it.why:
        lines += [f"Why: {it.why}", ""]
    if it.commands:
        lines += ["```bash", *it.commands, "```", ""]
    if it.expect:
        lines.append(f"Expected: {it.expect}")
    if it.worry:
        lines.append(f"Worrisome: {it.worry}")
    if it.undo:
        lines.append(f"Undo: {it.undo}")
    if len(it.paths) == 1:
        lines.append(f"Files: {it.paths[0]}")
    elif it.paths:
        lines += ["Files:", *("  " + p for p in it.paths)]
    if lines[-1]:
        lines.append("")
    return "\n".join(lines + ["Close it once it is done:", "```bash", f"cd {top} && guard needs-you done {it.id}", "```",
                              "", "🩺"])

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
    items += [it for _, it in asks(queue, top) if it.state == "open"] if queue else []
    if not items:
        return
    if fmt == "text":
        print(summary(top, items))
        return
    context = (f"The human has {len(items)} open item{'s' if len(items) > 1 else ''} in the guard needs-you queue for {top}: "
               "things only they can do, check, or approve. Start your reply with each 🩺 block below, verbatim, before "
               "anything else, and keep doing so on every reply until the human acks it (guard needs-you ack <id>), "
               "finishes it, or dismisses it. Never ack, finish, or dismiss an item yourself.\n\n"
               + "\n\n".join(block(it, top) for it in items))
    out = {"systemMessage": summary(top, items)}
    event = hook.get("hook_event_name")
    if event in HOOK_EVENTS:
        out["hookSpecificOutput"] = {"hookEventName": event, "additionalContext": context}
    print(json.dumps(out))

JSON_STATES = ("open", "acked", "done", "dismissed")

def queue_json(queue, top, state):
    items, created, skipped = read_json_items(queue)
    for line in skipped:
        print(f"guard needs-you: {queue}: skipped {line}", file=sys.stderr)
    wanted = JSON_STATES if state == "all" else (state,) if state else ("open", "acked")
    out = []
    for it in items:
        if it.state not in wanted:
            continue
        body = {k: getattr(it, k) for k in ACTION_KEYS if getattr(it, k)}
        if it.commands:
            body["commands"] = it.commands
        out.append(dict(id=it.id, status=it.state, kind=it.kind, repo=top, title=it.title, created=created[it.id],
                        updated=it.ts, body=body, evidence=it.paths, source=it.source, block=block(it, top)))
    out.sort(key=lambda d: (int(d["id"][1:]) if d["id"][1:].isdigit() else 0, d["updated"]))
    return json.dumps(dict(schema=1, repo=top, queue=queue, items=out), sort_keys=True, ensure_ascii=False)

def add(queue, a):
    if not all(c.strip() for c in a.run):
        raise Refused("--run is empty")
    if a.kind == "run" and not a.run:
        raise Refused("--kind run needs at least one --run command")
    if not a.title.strip():
        raise Refused("--title is empty")
    fields = dict(title=cell("title", a.title), why=cell("why", a.why, part=True), expect=cell("expect", a.expect, part=True),
                  worry=cell("worry", a.worry, part=True),
                  undo=cell("undo", a.undo, part=True), note="", source=cell("source", a.source),
                  paths=[checked_path(p) for p in a.path], commands=[cell("run", checked_run(c), part=True) for c in a.run])
    def new(items):
        same = find(items, a.kind, a.title, ("open", "acked") if a.update else ("open",))
        if same:
            print(same.id)
            fresh = same._replace(ts=now(), state="open", **fields)
            unchanged = fresh._replace(ts=same.ts, state=same.state, note=same.note) == same
            return fresh if a.update and not unchanged else None
        n = max((int(it.id[1:]) for it in items if it.id[1:].isdigit()), default=0) + 1
        print(f"n{n}")
        return Item(id=f"n{n}", ts=now(), state="open", kind=a.kind, **fields)
    transact(queue, new)

def find(items, kind, title, states=("open", "acked")):
    return next((it for it in reversed(items) if it.state in states and it.kind == kind and it.title == title), None)

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

def main():
    ap = refusals.ArgumentParser(prog="guard needs-you", description=__doc__.split("\n\n")[1])
    ap.add_argument("--remind", action="store_true", help="print the open items for a person or an agent hook, or nothing")
    ap.add_argument("--format", choices=("text", "claude-hook"), default="text")
    ap.add_argument("--json", action="store_true", help="print the queue as JSON")
    ap.add_argument("--state", choices=JSON_STATES + ("all",), help="with --json, the state of the items to print")
    sub = ap.add_subparsers(dest="cmd", parser_class=refusals.ArgumentParser)
    p = sub.add_parser("add", help="queue an item and print its id", next=ADD)
    p.add_argument("--kind", required=True, choices=KINDS)
    p.add_argument("--title", required=True)
    p.add_argument("--why", default="")
    p.add_argument("--path", action="append", default=[])
    p.add_argument("--run", action="append", default=[])
    p.add_argument("--expect", default="", help="a sample of the output that means it worked")
    p.add_argument("--worry", default="", help="a sample of the output that means it did not")
    p.add_argument("--undo", default="")
    p.add_argument("--source", default="")
    p.add_argument("--update", action="store_true", help="give an open or acked item of the same kind and title this content")
    p = sub.add_parser("find", help="print the id of the open or acked item with this kind and title", next=FIND)
    p.add_argument("--kind", required=True, choices=KINDS)
    p.add_argument("--title", required=True)
    sub.add_parser("show", help="print one item's block", next=LIST).add_argument("id")
    for verb in MOVES:
        p = sub.add_parser(verb, help=f"mark an item {MOVES[verb].sets}", next=LIST)
        p.add_argument("id")
        p.add_argument("--note", default="")
    a = ap.parse_args()
    if a.json and (a.remind or a.cmd):
        ap.error("--json cannot be combined with --remind or a subcommand")
    if a.state and not a.json:
        ap.error("--state needs --json")

    if a.remind:
        try:
            remind(a.format)
        except Exception:
            pass
        return
    queue, top = git_dir(os.getcwd())
    try:
        if not queue:
            raise Refused(f"{os.getcwd()} is not a git repository")
        if a.json:
            print(queue_json(queue, top, a.state))
        elif a.cmd == "add":
            add(queue, a)
        elif a.cmd == "find":
            it = find(read(queue), a.kind, a.title)
            if not it:
                sys.exit(1)
            print(it.id)
        elif a.cmd == "show":
            it = next((it for it in read(home(queue, top, a.id)) if it.id == a.id), None)
            if not it:
                raise Refused(f"no item {a.id} in {queue}")
            print(block(it, top))
        elif a.cmd in MOVES:
            move(home(queue, top, a.id), a.cmd, a.id, a.note)
        else:
            items = [it for it in read(queue) + [it for _, it in asks(queue, top)] if it.state in ("open", "acked")]
            print("\n\n".join(block(it, top) for it in items) if items else "Nothing needs you.")
    except Refused as e:
        print(f"guard needs-you: {e}", file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
