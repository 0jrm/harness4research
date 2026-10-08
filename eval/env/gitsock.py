#!/usr/bin/env python3
"""A git remote over a Unix socket, so an agent can fetch and push without write access to the repository files.

    gitsock.py serve <repo.git> <socket>

Runs outside the sandbox, one git process per connection. Inside, the agent's remote URL is `ext::forge-connect %S`
(forge_connect.py) with protocol.ext.allow=always in its git config. The server runs git-upload-pack or
git-receive-pack on the repository, so receive-pack's hooks run here, where the agent cannot edit them.
"""
import os
import socket
import socketserver
import subprocess
import sys
import threading

from forge_connect import pump, write_all

SERVICES = {"git-upload-pack", "git-receive-pack"}


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        line = b""
        while not line.endswith(b"\n") and len(line) < 64:
            byte = conn.recv(1)
            if not byte:
                return
            line += byte
        service = line.decode().strip()
        if service not in SERVICES:
            return
        proc = subprocess.Popen([service, self.server.repo], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        to_git, from_git = proc.stdin.fileno(), proc.stdout.fileno()
        threading.Thread(target=pump, args=(conn.recv, lambda b: write_all(to_git, b), proc.stdin.close),
                         daemon=True).start()
        pump(lambda n: os.read(from_git, n), conn.sendall, lambda: conn.shutdown(socket.SHUT_WR))
        proc.wait()


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(repo, path):
    repo = os.path.abspath(repo)
    # A socket path is limited to about 108 bytes, so bind a relative name from the socket's own directory.
    os.chdir(os.path.dirname(os.path.abspath(path)))
    name = os.path.basename(path)
    if os.path.exists(name):
        os.unlink(name)
    with Server(name, Handler) as server:
        server.repo = repo
        server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
