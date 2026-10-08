#!/usr/bin/env python3
"""Slurm client commands: sbatch, squeue, sacct, scancel and sacctmgr, by the name they are called under.
Each sends its arguments to slurmctld over a local socket and prints the reply."""
import json
import os
import socket
import sys

SOCKET = os.environ.get("SLURM_CONF_SOCKET", "/run/slurm/slurmctld.sock")

SBATCH_SHORT = {"-t": "time", "-N": "nodes", "-n": "ntasks", "-J": "job-name", "-A": "account", "-a": "array",
                "-o": "output", "-e": "error", "-p": "partition", "-c": "cpus-per-task", "-D": "chdir"}
SBATCH_FLAGS = {"parsable", "wait", "exclusive", "requeue", "no-requeue", "hold"}


def parse_sbatch_args(args):
    """Returns (options, rest): options from --name=value, --name value, -X value, -Xvalue; rest from the script on."""
    opts, i = {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            name, eq, value = a[2:].partition("=")
            if name in SBATCH_FLAGS:
                opts[name] = True
            elif eq:
                opts[name] = value
            elif i + 1 < len(args):
                opts[name] = args[i + 1]
                i += 1
            else:
                raise ValueError(f"option '--{name}' requires an argument")
        elif a in SBATCH_SHORT:
            if i + 1 >= len(args):
                raise ValueError(f"option requires an argument -- '{a[1:]}'")
            opts[SBATCH_SHORT[a]] = args[i + 1]
            i += 1
        elif a[:2] in SBATCH_SHORT and len(a) > 2:
            opts[SBATCH_SHORT[a[:2]]] = a[2:]
        elif a.startswith("-") and a != "-":
            raise ValueError(f"unrecognized option '{a}'")
        else:
            return opts, args[i:]
        i += 1
    return opts, []



def process_chain():
    chain, pid = [], os.getppid()
    for _ in range(6):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                chain.append(f.read().replace(b"\0", b" ").decode(errors="replace").strip()[:300])
            with open(f"/proc/{pid}/stat") as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        if pid <= 1:
            break
    return chain


def client(cmd, args):
    request = {"cmd": cmd, "args": args, "cwd": os.getcwd(), "chain": process_chain(),
               "user": os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"}
    if cmd == "sbatch":
        try:
            _, rest = parse_sbatch_args(args)
        except ValueError:
            rest = []
        if rest:
            try:
                with open(rest[0]) as f:
                    request["script"] = f.read()
            except OSError:
                pass
    conn = socket.socket(socket.AF_UNIX)
    try:
        os.chdir(os.path.dirname(SOCKET))
        conn.connect(os.path.basename(SOCKET))
    except OSError:
        sys.stderr.write(f"{cmd}: error: Unable to contact slurm controller (connect failure)\n")
        return 1
    finally:
        os.chdir(request["cwd"])
    conn.sendall(json.dumps(request).encode() + b"\n")
    reply = json.loads(conn.makefile().readline())
    sys.stdout.write(reply.get("out", ""))
    sys.stderr.write(reply.get("err", ""))
    return reply.get("rc", 1)



if __name__ == "__main__":
    sys.exit(client(os.path.basename(sys.argv[0]), sys.argv[1:]))
