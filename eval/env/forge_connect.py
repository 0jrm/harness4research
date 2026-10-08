#!/usr/bin/env python3
"""git transport to the forge: git runs `forge-connect <service>` through its ext:: remote helper, and this
pipes the session to the forge over its local socket."""
import os
import socket
import sys
import threading

SOCKET = os.environ.get("FORGE_SOCKET", "/run/forge/forge.sock")


def pump(src, dst, close):
    try:
        while True:
            chunk = src(65536)
            if not chunk:
                break
            dst(chunk)
    except OSError:
        pass
    finally:
        close()


def connect(path, service):
    conn = socket.socket(socket.AF_UNIX)
    here = os.getcwd()
    os.chdir(os.path.dirname(os.path.abspath(path)))  # a socket path is limited to about 108 bytes
    conn.connect(os.path.basename(path))
    os.chdir(here)
    conn.sendall(service.encode() + b"\n")
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    threading.Thread(target=pump, args=(lambda n: os.read(stdin, n), conn.sendall,
                                        lambda: conn.shutdown(socket.SHUT_WR)), daemon=True).start()
    pump(conn.recv, lambda b: write_all(stdout, b), lambda: None)


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: forge-connect <git-upload-pack|git-receive-pack>")
    connect(SOCKET, sys.argv[1])
