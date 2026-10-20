#!/usr/bin/env python3
"""guard needs-you, guard ledger and guard pr open, inside a sandbox through the broker's sockets, else the human
commands.

    records.py needs-you [--remind] | add --kind K --title T [...] | find --kind K --title T | show <id>
    records.py ledger add <run_id> <field> <value> [--why W] [--evidence E] | list <run_id>
    records.py pr open --title T --request FILE --plan FILE --test CMD --body FILE [--item ID] [--scope FILE] [--base B]

With /run/guard/records.sock (GUARD_SOCK_DIR moves it), needs-you is one request on it, which offers add, list, show
and find; ack, done and dismiss are a person's and the broker refuses them. With /run/guard/gh.sock, pr open pushes
the branch and sends the brief's parts to it, and the broker writes the brief in its own state and opens the pull
request (decision A3). Without the socket, each runs lib/needs_you.py or lib/pr-open.sh, as on a person's machine.

guard ledger appends one row to runs/<run_id>/execution.tsv, the execution envelope (design-v8 section 3): behind the
broker the records socket commits it to run/<run_id>, signed, after the fence's ledger check; without one this
appends it to the working tree's file, checks it with this harness's fence --ledger, and leaves the commit to the
agent, as any file of the run."""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import needs_you  # noqa: E402
import refusals  # noqa: E402
from broker import transport  # noqa: E402


PR_OPEN = "guard pr open --title TITLE --request FILE --plan FILE --test COMMAND --body FILE"


class Refused(Exception):
    pass


def read_text(path, what):
    try:
        with open(path) as f:
            return f.read()
    except OSError as e:
        raise Refused(f"cannot read {what} {path}: {e.strerror}")


def branch():
    return subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True).stdout.strip()


def needs_you_request(args):
    """One records request from guard needs-you arguments."""
    if not args or args[0].startswith("-"):
        return {"verb": "list", "store": "needs-you", "remind": "--remind" in args}
    verb, rest = args[0], args[1:]
    line2 = {"add": needs_you.ADD, "find": needs_you.FIND}.get(verb, needs_you.LIST)
    p = refusals.ArgumentParser(prog=f"guard needs-you {verb}", next=line2)
    if verb == "add":
        p.add_argument("--kind", required=True, choices=needs_you.KINDS)
        p.add_argument("--title", required=True)
        for name in ("why", "expect", "worry", "undo", "source"):
            p.add_argument(f"--{name}", default="")
        p.add_argument("--path", action="append", default=[])
        p.add_argument("--run", action="append", default=[])
        p.add_argument("--update", action="store_true")
        return {"verb": verb, "store": "needs-you", "item": vars(p.parse_args(rest))}
    if verb == "find":
        p.add_argument("--kind", required=True, choices=needs_you.KINDS)
        p.add_argument("--title", required=True)
        return {"verb": verb, "store": "needs-you", **vars(p.parse_args(rest))}
    if verb == "show":
        p.add_argument("id")
        return {"verb": verb, "store": "needs-you", **vars(p.parse_args(rest))}
    return {"verb": verb, "store": "needs-you", "args": rest}


def pr_open_request(args):
    """The pr-open request; pushes the branch first, so the broker opens a pull request for a head it can fetch."""
    p = refusals.ArgumentParser(prog="guard pr open")
    for name, value in (("title", "TITLE"), ("request", "FILE"), ("plan", "FILE"), ("test", "COMMAND"),
                        ("body", "FILE")):
        p.add_argument(f"--{name}", required=True, metavar=value)
    for name, value in (("item", "ID"), ("scope", "FILE")):
        p.add_argument(f"--{name}", default="", metavar=value)
    p.add_argument("--base", default="main", metavar="BRANCH")
    a = p.parse_args(args)
    head = branch()
    if not head:
        raise Refused("HEAD is detached. Check out the branch the pull request is for.")
    if head == a.base:
        raise Refused(f"the current branch is {a.base} itself. Commit the change on its own branch.")
    request = {"verb": "pr-open", "item": a.item, "title": a.title, "base": a.base, "head": head, "test": a.test,
               "request": read_text(a.request, "--request"), "plan": read_text(a.plan, "--plan"),
               "scope": read_text(a.scope, "--scope") if a.scope else "", "body": read_text(a.body, "--body")}
    pushed = subprocess.run(["git", "push", "-q", "-u", "origin", f"HEAD:refs/heads/{head}"], capture_output=True,
                            text=True)
    if pushed.returncode:
        raise Refused(f"cannot push {head}: {(pushed.stderr.strip().splitlines() or ['git push failed'])[-1]}")
    return request


LEDGER_USAGE = "usage: guard ledger add <run_id> <field> <value> [--why W] [--evidence E] | list <run_id>"


def ledger_request(args):
    """One records request from guard ledger arguments; Refused with the usage when they are not one."""
    p = refusals.ArgumentParser(prog="guard ledger", add_help=False, usage=LEDGER_USAGE.removeprefix("usage: "),
                                next="guard status")
    p.add_argument("verb", choices=("add", "list"))
    p.add_argument("run")
    p.add_argument("field", nargs="?")
    p.add_argument("value", nargs="?")
    p.add_argument("--why", default="")
    p.add_argument("--evidence", default="")
    a = p.parse_args(args)
    run = os.path.basename(os.path.normpath(a.run))
    if a.verb == "list":
        return {"verb": "list", "store": "ledger", "run": run}
    if a.field is None or a.value is None:
        raise Refused(LEDGER_USAGE)
    return {"verb": "add", "store": "ledger", "run": run, "field": a.field, "value": a.value, "why": a.why,
            "evidence": a.evidence}


def ledger_local(request):
    """guard ledger without a broker: the row appended to the working tree's runs/<run_id>/execution.tsv, kept only
    when this harness's fence --ledger passes it. (exit status, text for stdout, text for stderr)"""
    lib = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
    if not top:
        return 2, "", f"guard ledger: refused: {os.getcwd()} is not inside a git project\n"
    rel = f"runs/{request['run']}/execution.tsv"
    path = os.path.join(top, rel)
    old = open(path).read() if os.path.isfile(path) else None
    if request["verb"] == "list":
        return (0, old, "") if old is not None else (2, "", f"guard ledger: refused: no {rel}\n")
    template = os.path.join(top, "runs", "_template", "execution.tsv")
    text = old if old is not None else (open(template).read() if os.path.isfile(template)
                                        else "id\tts\tfield\tvalue\twhy\tevidence\n")
    text += "" if text.endswith("\n") else "\n"
    cells = [request[k] for k in ("field", "value", "why", "evidence")]
    if any(c in v for v in cells for c in "\t\n\r"):
        return 2, "", "guard ledger: refused: a ledger cell holds no tab or newline\n"
    n = sum(1 for line in text.splitlines()[1:] if line.strip() and not line.startswith("#")) + 1
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text + "\t".join([f"x{n}", ts, *cells]) + "\n")
    checked = subprocess.run(["bash", os.path.join(lib, "guard", "fence.sh"), "--ledger", rel], cwd=top,
                             capture_output=True, text=True)
    if checked.returncode:
        if old is None:
            os.unlink(path)
        else:
            with open(path, "w") as f:
                f.write(old)
        refusal = [l for l in checked.stdout.splitlines() if l.startswith("H4R-")]
        tail = checked.stdout.splitlines()[-2:] if refusal else [checked.stderr.strip() or "fence --ledger failed"]
        return 2, "", "\n".join(tail) + "\n"
    return 0, f"x{n} written to {rel}; commit it with the run\n", ""


def send(request, sock):
    try:
        reply = transport.over_socket(transport.sock_path(sock), request)
    except OSError as e:
        return {"rc": 1, "err": f"guard broker unreachable ({e.strerror}); nothing was recorded\n"}
    return reply or {"rc": 1, "err": "guard broker closed the connection\n"}


def human(argv):
    lib = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    if argv[0] == "needs-you":
        os.execv(sys.executable, [sys.executable, os.path.join(lib, "needs_you.py"), *argv[1:]])
    os.execvp("bash", ["bash", os.path.join(lib, "pr-open.sh"), *argv[1:]])


def ledger(args):
    try:
        request = ledger_request(args)
    except Refused as e:
        r = refusals.refuse("U01", what=str(e).removeprefix("usage: "), next="guard status")
        sys.stderr.write(refusals.render(r))
        return r.exit
    if os.path.exists(transport.sock_path("records")):
        reply = send(request, "records")
        rc, out, err = reply.get("rc", 1), reply.get("out", ""), reply.get("err", "")
    else:
        rc, out, err = ledger_local(request)
    sys.stdout.write(out)
    sys.stderr.write(err)
    return rc


def main(argv):
    if argv[:1] == ["ledger"]:
        return ledger(argv[1:])
    if argv[:1] == ["pr"] and argv[1:2] != ["open"]:
        r = refusals.usage(f"guard pr takes open, not {' '.join(argv[1:2]) or 'nothing'}", PR_OPEN)
        sys.stderr.write(refusals.render(r))
        return r.exit
    if not argv or argv[0] not in ("needs-you", "pr"):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 64
    sock = "records" if argv[0] == "needs-you" else "gh"
    if not os.path.exists(transport.sock_path(sock)):
        human(argv)
    try:
        request = needs_you_request(argv[1:]) if argv[0] == "needs-you" else pr_open_request(argv[2:])
    except Refused as e:
        r = refusals.refuse("U01", what=f"guard {' '.join(argv[:2]) if argv[0] == 'pr' else argv[0]}: {e}",
                            next="guard status")
        sys.stderr.write(refusals.render(r))
        return r.exit
    reply = send(request, sock)
    if request.get("remind") and "--format" in argv and "claude-hook" in argv:
        if reply.get("out"):
            sys.stdout.write(json.dumps({"systemMessage": reply["out"].strip()}) + "\n")
        return 0
    sys.stdout.write(reply.get("out", ""))
    err = reply.get("err", "")
    sys.stderr.write(err.replace("gh: refused by the broker", "guard pr open: refused by the broker"))
    if argv[0] == "pr":
        return 0 if reply.get("rc") == 0 else 2
    return reply.get("rc", 1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
