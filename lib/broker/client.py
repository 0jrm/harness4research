#!/usr/bin/env python3
"""The sandbox's sbatch, squeue, sacct, scancel, sacctmgr, gh and guard, by the name they are called under, when the
episode runs behind the broker. Each sends one request to one of the broker's sockets and prints the reply.

sbatch never reaches the scheduler: it turns its options and the script's #SBATCH lines into the broker's request
fields and refuses an option it cannot map. A request names its run with --comment=run:<id>, which guard/run
preflight adds, so a bare sbatch call is refused. Only the broker decides what the scheduler sees.

guard ledger and guard card go to the records socket, until guard run writes the card and the job log (U2); every
other guard subcommand runs the installed guard, whose needs-you and pr open use the sockets (lib/verbs/records.py):

    guard ledger add <run_id> <field> <value> [--why W] [--evidence E] | list <run_id>
    guard card add <run_id> <card file> | show <run_id> | list

gh sends its arguments to the gh socket, which decides what it offers (forge.py): pr create, view, list, diff, checks
and comment, and api reads. Here it only reads --body-file into --body, names the current branch where gh would, and
applies --jq to the reply. guard review, guard merge and guard ship run in the broker, outside the sandbox, so here
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
    """One records request from guard ledger or guard card arguments."""
    store, rest = args[0], args[1:]
    verb, rest = (rest[0], rest[1:]) if rest else ("list", [])
    p = argparse.ArgumentParser(prog=f"guard {store} {verb}")
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


def guard(args):
    if args[:1] in (["review"], ["merge"], ["ship"]):
        sys.stderr.write(f"guard {args[0]}: refused: guard review, guard merge and guard ship run in the broker, "
                         "outside the sandbox; a person or the orchestrating session runs them there. Open the pull "
                         "request with guard pr open and stop.\n")
        return 2
    if not args or args[0] not in ("ledger", "card"):
        os.execv(GUARD, [GUARD, *args])
    try:
        request = records_request(args)
    except Refused as e:
        sys.stderr.write(f"guard {args[0]}: refused: {e}\n")
        return 2
    reply = ask(request, RECORDS)
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
