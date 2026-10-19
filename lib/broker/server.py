"""The broker's sockets: one JSON request per connection, one JSON reply {rc, out, err}, from a caller of the broker's
own uid (SO_PEERCRED). The session is the socket directory the request came in on, which the sandbox cannot change.

A verb is answered by the module MODULES names, whose handle(request, broker) returns the reply; one whose module is
not in this harness yet answers X00. Every other verb goes to the store that served it before v8: the scheduler's
queue, acct and cancel (and submit, until guard run and the rewritten audit attacks replace it), the records' add,
list, show and find, and the forge's gh verbs in the evaluation, which refuse a verb they do not offer as they did."""
import importlib
import json
import os
import signal
import socket
import socketserver
import struct
import threading
import traceback

import refusals
from broker.records import Refused

MODULES = {
    "scheduler": {"run": "run", "status": "status", "wait": "host", "stop": "host"},
    "records": {"ask": "asks", "holdout": "holdout", "receipt": "receipts"},
    "gh": {},
}
SOCKETS = ("records", "gh", "scheduler")  # bound in this order; a waiter on scheduler.sock finds them all


def module_for(sock, verb):
    """The module that answers verb on sock; None when the verb is the v7 store's; "X00" when it is not built."""
    name = MODULES[sock].get(verb)
    if name is None:
        return None
    try:
        module = importlib.import_module(f"broker.{name}")
    except ModuleNotFoundError as e:
        if e.name != f"broker.{name}":
            raise
        return "X00"
    return module if hasattr(module, "handle") else "X00"


def answer(broker, sock, req):
    """The reply to one request on sock ("scheduler", "records" or "gh")."""
    verb = req.get("verb")
    module = module_for(sock, verb) if isinstance(verb, str) else None
    if module == "X00":
        return refusals.reply(refusals.refuse("X00", verb=verb))
    if module is not None:
        try:
            return module.handle(req, broker)
        except Refused as e:
            return {"rc": 1, "err": f"guard broker: refused: {e}\n"}
    if sock == "scheduler":
        return broker.handle(req)
    if sock == "records":
        return broker.locked(broker.records.handle, req)
    return broker.locked(broker.forge.handle, req)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        pid, uid, gid = struct.unpack("3i", self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        try:
            req = json.loads(self.rfile.readline())
            if uid != os.getuid():
                reply = {"rc": 1, "err": f"guard broker: uid {uid} is not this broker's user\n"}
            elif not isinstance(req, dict):
                reply = {"rc": 1, "err": "guard broker: a request is one JSON object\n"}
            else:
                reply = self.server.answer(req)
        except (ValueError, UnicodeDecodeError):
            reply = {"rc": 1, "err": "guard broker: a request is one JSON object\n"}
        except Exception as e:  # a bad request never takes the broker down; daemon.log keeps the trace
            traceback.print_exc()
            reply = {"rc": 1, "err": f"guard broker: refused: {type(e).__name__}\n"}
        self.wfile.write(json.dumps(reply).encode() + b"\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def bind(path, sock, broker, wrap=None):
    """A server on path answering sock's verbs for broker; wrap(req, reply) sees each reply, as guard broker logs
    refusals."""
    server = Server(path, Handler)
    server.answer = (lambda req: wrap(req, answer(broker, sock, req))) if wrap else (lambda req: answer(broker, sock, req))
    return server


def serve(broker, sock_dir, socks=SOCKETS):
    """Serves broker on sock_dir/<sock>.sock for each of socks until SIGTERM, which removes the sockets."""
    os.makedirs(sock_dir, exist_ok=True)
    os.chdir(sock_dir)  # a socket path is limited to about 108 bytes, so bind relative names
    names = [f"{s}.sock" for s in socks]
    for name in names:
        if os.path.exists(name):
            os.unlink(name)

    def stop(signum, frame):
        for name in names:
            if os.path.exists(os.path.join(sock_dir, name)):
                os.unlink(os.path.join(sock_dir, name))
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    servers = [bind(name, s, broker) for name, s in zip(names, socks)]
    for server in servers[:-1]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with servers[-1]:
        servers[-1].serve_forever()
