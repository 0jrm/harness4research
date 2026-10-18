#!/usr/bin/env python3
"""The sandbox's sbatch, squeue, sacct, scancel, sacctmgr, gh and guard, by the name they are called under, when the
episode runs behind the broker. Each sends one request to one of the broker's sockets and prints the reply.

sbatch never reaches the scheduler: it turns its options and the script's #SBATCH lines into the broker's request
fields and refuses an option it cannot map. A request names its run with --comment=run:<id>, which guard/run
preflight adds, so a bare sbatch call is refused. Only the broker decides what the scheduler sees.

guard needs-you, guard ledger, guard card and guard ask go to the records socket; every other guard subcommand runs
the installed guard. The records socket offers add, list, show and find, so guard needs-you ack, done and dismiss are
refused there:

    guard needs-you [--remind] | add --kind K --title T [...] | find --kind K --title T | show <id>
    guard ledger add <run_id> <field> <value> [--why W] [--evidence E] | list <run_id>
    guard card add <run_id> <card file> | show <run_id> | list
    guard ask "<question>" --default <the safe option> --deadline 5m|30m|2h | --status <id>

guard ask sends what it was given and the broker checks it (asks.py); words outside the options join the question,
so an unquoted question still arrives whole.

gh sends its arguments to the gh socket, which decides what it offers (forge.py): pr create, view, list, diff, checks
and comment, and api reads. Here it only reads --body-file into --body, names the current branch where gh would, and
applies --jq to the reply. guard pr open writes its brief through that socket into the broker's state (decision A3),
after pushing the branch. guard review, guard merge and guard ship run in the broker, outside the sandbox, so here
they are refused."""
import argparse
import json
import os
import socket
import subprocess
import sys

SOCKET = "/run/guard/scheduler.sock"
RECORDS = "/run/guard/records.sock"
GH = "/run/guard/gh.sock"
GUARD = "/opt/harness4research/bin/guard"

# sbatch option -> request field. Later values win, the command line over #SBATCH lines, as sbatch reads them.
FIELDS = {"time": "time", "nodes": "nodes", "ntasks": "tasks", "cpus-per-task": "cpus_per_task", "mem": "mem",
          "gpus": "gpus", "array": "array", "dependency": "dependency", "partition": "partition", "output": "output"}
SHORT = {"-t": "time", "-N": "nodes", "-n": "ntasks", "-c": "cpus-per-task", "-G": "gpus", "-a": "array",
         "-d": "dependency", "-p": "partition", "-o": "output", "-A": "account", "-J": "job-name"}
# Options preflight passes whose values the broker sets itself, or that change nothing it renders.
SET_BY_BROKER = {"account", "job-name", "comment"}
FLAGS = {"ignore-pbs", "parsable"}


class Refused(Exception):
    pass


def parse(words, opts):
    """Reads sbatch options from words into opts until the first word that is not one; returns the rest."""
    i = 0
    while i < len(words):
        w = words[i]
        if w.startswith("--") and len(w) > 2:
            name, eq, value = w[2:].partition("=")
            if name in FLAGS:
                opts[name] = True
                i += 1
                continue
            if name not in FIELDS and name not in SET_BY_BROKER:
                longer = sorted(o for o in list(FIELDS) + list(SET_BY_BROKER) + list(FLAGS) if o.startswith(name))
                hint = f"; {w.split('=')[0]} shortens --{longer[0]}, write it in full" if len(longer) == 1 else ""
                raise Refused(f"sbatch option --{name} is not one the broker takes{hint}")
        elif w in SHORT:
            name, eq, value = SHORT[w], "", ""
        elif w[:2] in SHORT and len(w) > 2:
            name, eq, value = SHORT[w[:2]], "=", w[2:]
        elif w.startswith("-") and w != "-":
            raise Refused(f"sbatch option {w} is not one the broker takes")
        else:
            return words[i:]
        if not eq:
            if i + 1 >= len(words):
                raise Refused(f"{w} has no value")
            value = words[i + 1]
            i += 1
        opts[name] = value
        i += 1
    return []


def script_words(path):
    words = []
    with open(path) as f:
        lines = f.read().splitlines()
    for line in lines[1:] if lines and lines[0].startswith("#!") else lines:
        s = line.strip()
        if s.startswith("#SBATCH"):
            words += s[len("#SBATCH"):].split("#", 1)[0].split()
        elif s and not s.startswith("#"):
            break
    return words


def sbatch_request(args):
    cli = {}
    rest = parse(args, cli)
    if not rest:
        raise Refused("no batch script given")
    opts = {}
    try:
        parse(script_words(rest[0]), opts)
    except OSError as e:
        raise Refused(f"cannot read {rest[0]}: {e.strerror}")
    opts.update(cli)
    run = str(opts.get("comment", ""))
    if not run.startswith("run:"):
        raise Refused("a job belongs to a run: submit it with guard/run preflight runs/<run_id> " + rest[0])
    fields = {FIELDS[k]: v for k, v in opts.items() if k in FIELDS}
    return {"verb": "submit", "run": run[4:], "cwd": os.getcwd(), "script": rest[0], "args": rest[1:],
            "fields": fields, "parsable": bool(opts.get("parsable"))}


def records_request(args):
    """One records request from guard needs-you, guard ledger or guard card arguments."""
    store, rest = args[0], args[1:]
    if store == "needs-you" and (not rest or rest[0].startswith("-")):
        return {"verb": "list", "store": store, "remind": "--remind" in rest}
    verb, rest = (rest[0], rest[1:]) if rest else ("list", [])
    p = argparse.ArgumentParser(prog=f"guard {store} {verb}")
    if store == "needs-you" and verb == "add":
        for name in ("kind", "title"):
            p.add_argument(f"--{name}", required=True)
        for name in ("why", "expect", "worry", "undo", "source"):
            p.add_argument(f"--{name}", default="")
        p.add_argument("--path", action="append", default=[])
        p.add_argument("--run", action="append", default=[])
        p.add_argument("--update", action="store_true")
        return {"verb": verb, "store": store, "item": vars(p.parse_args(rest))}
    if store == "needs-you" and verb == "find":
        p.add_argument("--kind", required=True)
        p.add_argument("--title", required=True)
        return {"verb": verb, "store": store, **vars(p.parse_args(rest))}
    if store == "needs-you" and verb == "show":
        p.add_argument("id")
        return {"verb": verb, "store": store, **vars(p.parse_args(rest))}
    if store == "ledger" and verb == "add":
        for name in ("run", "field", "value"):
            p.add_argument(name)
        p.add_argument("--why", default="")
        p.add_argument("--evidence", default="")
        return {"verb": verb, "store": store, **vars(p.parse_args(rest))}
    if store == "card" and verb == "add":
        p.add_argument("run")
        p.add_argument("file")
        a = p.parse_args(rest)
        try:
            with open(a.file) as f:
                return {"verb": verb, "store": store, "run": a.run, "text": f.read()}
        except OSError as e:
            raise Refused(f"cannot read {a.file}: {e.strerror}")
    if store == "card" and verb == "list" and not rest:
        return {"verb": verb, "store": store}
    if verb in ("list", "show") and store in ("ledger", "card") and len(rest) == 1:
        return {"verb": verb, "store": store, "run": rest[0]}
    # Anything else, such as done, ack, dismiss or approve, goes as it is, and the broker refuses what it does not offer.
    return {"verb": verb, "store": store, "args": rest}


def ask_request(args):
    """One records request from guard ask's arguments: --status <id>, or the question with --default and --deadline."""
    opts, words, it = {}, [], iter(args)
    for a in it:
        name, eq, value = a.partition("=")
        if name in ("--status", "--default", "--deadline"):
            opts[name[2:]] = value if eq else next(it, "")
        else:
            words.append(a)
    if "status" in opts:
        return {"verb": "show", "store": "ask", "id": opts["status"]}
    return {"verb": "add", "store": "ask", "question": " ".join(words), "default": opts.get("default", ""),
            "deadline": opts.get("deadline", "")}


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


def pr_open(args):
    """guard pr open, as lib/pr-open.sh takes it: pushes the branch, then sends the brief's parts and the body to the
    broker, which writes the brief in its state and opens the pull request."""
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


def guard(args):
    if args[:1] in (["review"], ["merge"], ["ship"]):
        sys.stderr.write(f"guard {args[0]}: refused: guard review, guard merge and guard ship run in the broker, "
                         "outside the sandbox; a person or the orchestrating session runs them there. Open the pull "
                         "request with guard pr open and stop.\n")
        return 2
    if args[:2] == ["pr", "open"]:
        try:
            request = pr_open(args[2:])
        except Refused as e:
            sys.stderr.write(f"guard pr open: {e}\n")
            return 2
        reply = ask(request, GH)
        sys.stdout.write(reply.get("out", ""))
        sys.stderr.write(reply.get("err", "").replace("gh: refused by the broker", "guard pr open: refused by the broker"))
        return 0 if reply.get("rc") == 0 else 2
    if not args or args[0] not in ("needs-you", "ledger", "card", "ask"):
        os.execv(GUARD, [GUARD, *args])
    try:
        request = ask_request(args[1:]) if args[0] == "ask" else records_request(args)
    except Refused as e:
        sys.stderr.write(f"guard {args[0]}: refused: {e}\n")
        return 2
    reply = ask(request, RECORDS)
    if request.get("remind") and "--format" in args and "claude-hook" in args:
        if reply.get("out"):
            sys.stdout.write(json.dumps({"systemMessage": reply["out"].strip()}) + "\n")
        return 0
    sys.stdout.write(reply.get("out", ""))
    sys.stderr.write(reply.get("err", ""))
    return reply.get("rc", 1)


def ask(request, path=SOCKET):
    conn = socket.socket(socket.AF_UNIX)
    try:
        conn.connect(path)
    except OSError as e:
        if path in (RECORDS, GH):
            return {"rc": 1, "err": f"guard broker unreachable ({e.strerror}); nothing was recorded\n"}
        return {"rc": 1, "err": f"guard broker unreachable ({e.strerror}); nothing was submitted, and nothing else "
                                f"reaches the scheduler from here\n"}
    with conn:
        conn.sendall(json.dumps(request).encode() + b"\n")
        line = conn.makefile().readline()
    return json.loads(line) if line else {"rc": 1, "err": "guard broker closed the connection\n"}


def main(cmd, args):
    if cmd == "guard":
        return guard(args)
    if cmd == "gh":
        return gh(args)
    verbs = {"squeue": "queue", "sacct": "acct", "scancel": "cancel"}
    try:
        if cmd == "sbatch":
            request = sbatch_request(args)
        elif cmd in verbs:
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
