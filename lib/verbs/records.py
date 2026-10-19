#!/usr/bin/env python3
"""guard needs-you and guard pr open, inside a sandbox through the broker's sockets, else the human commands.

    records.py needs-you [--remind] | add --kind K --title T [...] | find --kind K --title T | show <id>
    records.py pr open --title T --request FILE --plan FILE --test CMD --body FILE [--item ID] [--scope FILE] [--base B]

With /run/guard/records.sock (GUARD_SOCK_DIR moves it), needs-you is one request on it, which offers add, list, show
and find; ack, done and dismiss are a person's and the broker refuses them. With /run/guard/gh.sock, pr open pushes
the branch and sends the brief's parts to it, and the broker writes the brief in its own state and opens the pull
request (decision A3). Without the socket, each runs lib/needs_you.py or lib/pr-open.sh, as on a person's machine."""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
from broker import transport  # noqa: E402


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
    p = argparse.ArgumentParser(prog=f"guard needs-you {verb}")
    if verb == "add":
        for name in ("kind", "title"):
            p.add_argument(f"--{name}", required=True)
        for name in ("why", "expect", "worry", "undo", "source"):
            p.add_argument(f"--{name}", default="")
        p.add_argument("--path", action="append", default=[])
        p.add_argument("--run", action="append", default=[])
        p.add_argument("--update", action="store_true")
        return {"verb": verb, "store": "needs-you", "item": vars(p.parse_args(rest))}
    if verb == "find":
        p.add_argument("--kind", required=True)
        p.add_argument("--title", required=True)
        return {"verb": verb, "store": "needs-you", **vars(p.parse_args(rest))}
    if verb == "show":
        p.add_argument("id")
        return {"verb": verb, "store": "needs-you", **vars(p.parse_args(rest))}
    return {"verb": verb, "store": "needs-you", "args": rest}


def pr_open_request(args):
    """The pr-open request; pushes the branch first, so the broker opens a pull request for a head it can fetch."""
    p = argparse.ArgumentParser(prog="guard pr open")
    for name in ("title", "request", "plan", "test", "body"):
        p.add_argument(f"--{name}", required=True)
    for name in ("item", "scope"):
        p.add_argument(f"--{name}", default="")
    p.add_argument("--base", default="main")
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
    os.execvp("bash", ["bash", os.path.join(lib, "pr-open.sh"), *argv[2:]])


def main(argv):
    if not argv or argv[0] not in ("needs-you", "pr") or (argv[0] == "pr" and argv[1:2] != ["open"]):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 64
    sock = "records" if argv[0] == "needs-you" else "gh"
    if not os.path.exists(transport.sock_path(sock)):
        human(argv)
    try:
        request = needs_you_request(argv[1:]) if argv[0] == "needs-you" else pr_open_request(argv[2:])
    except Refused as e:
        sys.stderr.write(f"guard {' '.join(argv[:2]) if argv[0] == 'pr' else argv[0]}: refused: {e}\n")
        return 2
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
