#!/usr/bin/env python3
"""usage: netrelay.py <port> <unix socket>

Runs inside the sandbox, which has no network: it listens on 127.0.0.1:<port> and copies each connection to and
from the unix socket that the logging proxy listens on outside, so the agent client reaches the model and nothing
else. Standard library only."""
import socket
import sys
import threading


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def serve(client, path):
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(path)
    except OSError:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    pipe(upstream, client)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    port, path = int(sys.argv[1]), sys.argv[2]
    listener = socket.create_server(("127.0.0.1", port))
    while True:
        client, _ = listener.accept()
        threading.Thread(target=serve, args=(client, path), daemon=True).start()


if __name__ == "__main__":
    main()
