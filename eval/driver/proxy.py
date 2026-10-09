#!/usr/bin/env python3
"""usage: proxy.py --upstream URL --alias NAME --log FILE --port-file FILE [--seed N]

A logging proxy between one episode's agent client and the model server. It runs outside the sandbox, on
127.0.0.1 at a free port, which it writes to --port-file once it listens. For every request it:

- pins the model: a JSON body's "model" becomes --alias, so the agent cannot pick another GPU or model;
- adds a seed: with --seed, a body without "seed" gets one, as the model host asked for per-request seeds;
- streams the reply back unchanged, server-sent events included;
- appends one JSON line to --log: the time, path, status, the request as sent upstream, the reply as received,
  and the token usage the reply reports.

The model host keeps no request bodies for shared traffic, so this log is the record of what the model saw and
said. Standard library only.
"""
import argparse
import http.client
import http.server
import json
import threading
import time
import urllib.parse

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "content-length", "host", "accept-encoding"}


def usage_of(text):
    """The token usage a reply reports: the last usage object in a JSON body or in server-sent events."""
    found = None
    candidates = [text] + [line[5:].strip() for line in text.splitlines() if line.startswith("data:")]
    for chunk in candidates:
        try:
            obj = json.loads(chunk)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        usage = obj.get("usage") or (obj.get("response") or {}).get("usage")
        if usage:
            found = usage
    return found


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def forward(self):
        cfg = self.server.cfg
        started = time.time()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        sent = body
        request_json = None
        if body and "json" in (self.headers.get("Content-Type") or ""):
            try:
                request_json = json.loads(body)
            except ValueError:
                request_json = None
            if isinstance(request_json, dict) and self.command == "POST":
                if "model" in request_json:
                    request_json["model"] = cfg.alias
                if cfg.seed is not None and "seed" not in request_json:
                    request_json["seed"] = cfg.seed
                sent = json.dumps(request_json).encode()
        up = urllib.parse.urlsplit(cfg.upstream)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Content-Length"] = str(len(sent))
        conn = http.client.HTTPConnection(up.hostname, up.port or 80, timeout=cfg.timeout)
        received = bytearray()
        status = 502
        try:
            conn.request(self.command, up.path.rstrip("/") + self.path, body=sent if sent else None, headers=headers)
            resp = conn.getresponse()
            status = resp.status
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                received += chunk
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (OSError, http.client.HTTPException) as e:
            received += f"proxy error: {e!r}".encode()
            if status == 502:
                try:
                    self.send_error(502, "upstream unreachable")
                except OSError:
                    pass
        finally:
            conn.close()
            text = received.decode(errors="replace")
            entry = {"ts": started, "seconds": round(time.time() - started, 3), "method": self.command,
                     "path": self.path, "status": status,
                     "request": request_json if request_json is not None else body.decode(errors="replace"),
                     "response": text, "usage": usage_of(text)}
            with self.server.lock:
                with open(cfg.log, "a") as f:
                    f.write(json.dumps(entry) + "\n")

    do_GET = do_POST = do_DELETE = forward


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--alias", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--timeout", type=float, default=600)
    cfg = ap.parse_args()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.cfg, server.lock = cfg, threading.Lock()
    with open(cfg.port_file, "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
