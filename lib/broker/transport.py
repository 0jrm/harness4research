"""How a verb reaches the broker: its socket when the session has one, else the same pipeline in-process (local.py).

    send(request, sock) -> reply {rc, out, err}

The sockets are /run/guard/<sock>.sock inside a sandbox (GUARD_SOCK_DIR moves them, for tests). With no socket and
GUARD_SESSION unset, this is a plain login shell and local mode answers (owner, decision 8). With GUARD_SESSION set
and no socket answering, the broker is down and every verb refuses with R15: nothing else reaches the scheduler."""
import json
import os
import socket

import refusals

SOCK_DIR = "/run/guard"


def sock_path(sock):
    return os.path.join(os.environ.get("GUARD_SOCK_DIR") or SOCK_DIR, f"{sock}.sock")


def over_socket(path, request):
    conn = socket.socket(socket.AF_UNIX)
    with conn:
        conn.connect(path)
        conn.sendall(json.dumps(request).encode() + b"\n")
        line = conn.makefile().readline()
    return json.loads(line) if line else None


def send(request, sock="scheduler"):
    path = sock_path(sock)
    if os.path.exists(path):
        try:
            reply = over_socket(path, request)
        except OSError:
            reply = None
        return reply or refusals.reply(refusals.refuse("R15"))
    if os.environ.get("GUARD_SESSION"):
        return refusals.reply(refusals.refuse("R15"))
    from broker import local
    return local.handle(request, sock)
