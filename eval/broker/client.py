#!/usr/bin/env python3
"""The sandbox's sbatch, squeue, sacct, scancel, sacctmgr and guard, by the name they are called under, when the
episode runs behind the broker. Each sends one request to one of the broker's sockets and prints the reply.

sbatch never reaches the scheduler: it turns its options and the script's #SBATCH lines into the broker's request
fields and refuses an option it cannot map. A request names its run with --comment=run:<id>, which guard/run
preflight adds, so a bare sbatch call is refused. Only the broker decides what the scheduler sees.

guard needs-you, guard ledger and guard card go to the records socket; every other guard subcommand runs the
installed guard. The records socket offers add, list, show and find, so guard needs-you ack, done and dismiss are
refused there:

    guard needs-you [--remind] | add --kind K --title T [...] | find --kind K --title T | show <id>
    guard ledger add <run_id> <field> <value> [--why W] [--evidence E] | list <run_id>
    guard card add <run_id> <card file> | show <run_id> | list"""
import argparse
import json
import os
import socket
import sys

SOCKET = "/run/guard/scheduler.sock"
RECORDS = "/run/guard/records.sock"
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


def guard(args):
    if not args or args[0] not in ("needs-you", "ledger", "card"):
        os.execv(GUARD, [GUARD, *args])
    try:
        request = records_request(args)
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
        if path == RECORDS:
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
