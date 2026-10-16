"""The broker's model and network gateway (design increment 6), standard library only.

ModelHandler serves one model socket: every HTTP request on it goes to one upstream, the only host it can reach. It
drops the client's own credential headers, adds the upstream's key from outside the sandbox, removes every copy of
that key from the reply, and logs each request. A local vLLM is an upstream with no key. eval/driver/proxy.py is the
same handler with the evaluation's request repairs and full-body log.

The network side is an allowlist of host:port names that a person owns: net_allow: in guard/budget.card on main
(decision D4), PyPI and conda when the card does not say, and none for jobs. A CONNECT target counts only when its
name, lowercased and without a trailing dot, is on the list as written: an IP literal, another port or another
spelling of an address is a different name, refused before anything resolves it."""
import http.client
import http.server
import json
import os
import re
import socket
import socketserver
import struct
import time
import urllib.parse

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "content-length", "host", "accept-encoding"}
CREDENTIALS = {"authorization", "x-api-key", "api-key", "x-goog-api-key", "cookie", "proxy-authorization"}
DEFAULT_NET_ALLOW = ("pypi.org:443", "files.pythonhosted.org:443", "conda.anaconda.org:443", "repo.anaconda.com:443")
HOST = re.compile(r"^(\[[0-9a-f:.]+\]|[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*):[0-9]{1,5}$")
REMOVED = b"[removed by the gateway]"


def host_port(name):
    """A target in the allowlist's spelling: lowercased, without a trailing dot, port 443 unless given; None when it is
    not a plain host:port."""
    name = name.strip().lower()
    if not name.startswith("[") and name.count(":") == 0:
        name += ":443"
    host, _, port = name.rpartition(":")
    name = f"{host.rstrip('.')}:{port}"
    return name if HOST.match(name) and 0 < int(port) < 65536 else None


def net_allow(card_text):
    """The hosts a card's net_allow: names (spaces or commas between them; none for no hosts), the default when the
    card has no net_allow: line, and the words it could not read."""
    for line in (card_text or "").splitlines():
        key, sep, value = line.partition(":")
        if sep and key.strip() == "net_allow":
            words = [w for w in re.split(r"[\s,]+", value.split("#", 1)[0]) if w]
            if words == ["none"]:
                return [], []
            hosts = [host_port(w) for w in words]
            return [h for h in hosts if h], [w for w, h in zip(words, hosts) if not h]
    return list(DEFAULT_NET_ALLOW), []


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


class Scrubber:
    """Removes every copy of the secrets from a reply that arrives in chunks, holding back as many bytes as a copy
    split across two chunks needs."""

    def __init__(self, secrets):
        self.secrets = [s.encode() for s in secrets if s]
        self.keep = max((len(s) for s in self.secrets), default=1) - 1
        self.tail, self.removed = b"", 0

    def feed(self, chunk):
        data = self.tail + chunk
        for s in self.secrets:
            self.removed += data.count(s)
            data = data.replace(s, REMOVED)
        cut = len(data) - self.keep if self.keep else len(data)
        out, self.tail = data[:max(cut, 0)], data[max(cut, 0):]
        return out

    def flush(self):
        out, self.tail = self.tail, b""
        return out

    def text(self, value):
        for s in self.secrets:
            value = value.replace(s.decode(), REMOVED.decode())
        return value


class ModelHandler(http.server.BaseHTTPRequestHandler):
    """The server carries upstream (a URL), key (or None), header (authorization, sent as Bearer, or a header name
    such as x-api-key), upstream_timeout (seconds) and record(entry), which logs one request."""

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def rewrite(self, body):
        """The body sent upstream; the evaluation's proxy repairs requests here."""
        return body

    def entry(self, entry, body, received):
        """The log row; the evaluation's proxy adds the bodies."""
        return entry

    def body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            data = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def refuse(self, status, why):
        data = f"guard gateway: {why}\n".encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def forward(self):
        srv, started = self.server, time.time()
        scrub = Scrubber([srv.key])
        body = self.body()
        received, status, sent = bytearray(), 502, b""
        try:
            if not self.path.startswith("/"):
                status = 400
                self.refuse(400, "a request names a path on the model's upstream, never another host")
                return
            sent = self.rewrite(body)
            up = urllib.parse.urlsplit(srv.upstream)
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP | CREDENTIALS}
            if srv.key:
                headers["Authorization" if srv.header == "authorization" else srv.header] = (
                    f"Bearer {srv.key}" if srv.header == "authorization" else srv.key)
            headers["Content-Length"] = str(len(sent))
            kind = http.client.HTTPSConnection if up.scheme == "https" else http.client.HTTPConnection
            conn = kind(up.hostname, up.port, timeout=srv.upstream_timeout)
            try:
                conn.request(self.command, up.path.rstrip("/") + self.path, body=sent or None, headers=headers)
                resp = conn.getresponse()
                status = resp.status
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() not in HOP:
                        self.send_header(k, scrub.text(v))
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                while True:
                    chunk = resp.read1(65536)
                    out = scrub.feed(chunk) if chunk else scrub.flush()
                    if out:
                        received += out
                        self.wfile.write(b"%x\r\n%s\r\n" % (len(out), out))
                        self.wfile.flush()
                    if not chunk:
                        break
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            finally:
                conn.close()
        except (OSError, ValueError, http.client.HTTPException) as e:
            received += scrub.text(f"gateway error: {type(e).__name__}").encode()
            if status == 502:
                try:
                    self.refuse(502, "the model's upstream did not answer")
                except OSError:
                    pass
        finally:
            text = bytes(received).decode(errors="replace")
            srv.record(self.entry({"ts": started, "seconds": round(time.time() - started, 3), "method": self.command,
                                   "path": self.path[:300], "status": status, "bytes_up": len(sent),
                                   "bytes_down": len(received), "usage": usage_of(text), "key_removed": scrub.removed},
                                  body, text))

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = forward


class UnixModelServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """A model socket that answers only this user's processes (SO_PEERCRED)."""

    daemon_threads = True

    def verify_request(self, request, client_address):
        return struct.unpack("3i", request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1] == os.getuid()

    def get_request(self):
        conn, _ = super().get_request()
        return conn, ("unix", 0)
