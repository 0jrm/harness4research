#!/usr/bin/env python3
"""guard ask "<question>" --default <option> --deadline 5m|30m|2h
guard ask --status <id>

A question for a person that carries the safe answer to take if nobody gives one by the deadline. It returns at once;
do other work, and guard status shows the answer. This verb sends what it was given to the broker's records socket,
which checks it (lib/broker/asks.py); words outside the options join the question, so an unquoted question arrives
whole."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import refusals  # noqa: E402
from broker import transport  # noqa: E402

OPTIONS = ("--status", "--default", "--deadline")


def request(argv):
    """The ask request for argv: --status ID, or the question with --default and --deadline."""
    opts, words, it = {}, [], iter(argv)
    for a in it:
        name, eq, value = a.partition("=")
        if name in OPTIONS:
            opts[name[2:]] = value if eq else next(it, "")
        else:
            words.append(a)
    if "status" in opts:
        return {"verb": "ask", "action": "show", "id": opts["status"], "cwd": os.getcwd()}
    return {"verb": "ask", "action": "add", "question": " ".join(words), "default": opts.get("default", ""),
            "deadline": opts.get("deadline", ""), "cwd": os.getcwd()}


def main(argv):
    reply = transport.send(request(argv), "records")
    sys.stdout.write(refusals.cap(reply.get("out", ""), "ask"))
    sys.stderr.write(reply.get("err", ""))
    return reply["rc"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
