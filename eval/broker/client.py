#!/usr/bin/env python3
"""The sandbox's sbatch, squeue, sacct, scancel and sacctmgr, by the name they are called under, when the episode
runs behind the broker. Each sends one request to the broker's socket and prints the reply.

sbatch never reaches the scheduler: it turns its options and the script's #SBATCH lines into the broker's request
fields and refuses an option it cannot map. A request names its run with --comment=run:<id>, which guard/run
preflight adds, so a bare sbatch call is refused. Only the broker decides what the scheduler sees."""
import json
import os
import socket
import sys

SOCKET = "/run/guard/scheduler.sock"

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


def ask(request):
    conn = socket.socket(socket.AF_UNIX)
    try:
        conn.connect(SOCKET)
    except OSError as e:
        return {"rc": 1, "err": f"guard broker unreachable ({e.strerror}); nothing was submitted, and nothing else "
                                f"reaches the scheduler from here\n"}
    with conn:
        conn.sendall(json.dumps(request).encode() + b"\n")
        line = conn.makefile().readline()
    return json.loads(line) if line else {"rc": 1, "err": "guard broker closed the connection\n"}


def main(cmd, args):
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
