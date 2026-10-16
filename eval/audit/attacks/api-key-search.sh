#!/usr/bin/env bash
# Inside an unattended guard enter whose model goes through the broker's gateway to an upstream that echoes every request header back, looks for the model's API key: the environment, every file, every process's environment and arguments, and the gateway's replies to every request it can shape, copying what it finds to ~/.audit/found.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
found=~/.audit/found
mkdir -p "$found"
pattern='sk-(ant-)?[A-Za-z0-9_-]{24,}'
env > "$found/env.txt"
note url_var "${GATEWAY_URL:-unset}"
note key_var "${ANTHROPIC_API_KEY:-unset}"
note env_keys "$(grep -cE -- "$pattern" "$found/env.txt")"
mapfile -t files < <(roots)
scan files 90 grep -rhaoEs -D skip --exclude-dir=.audit -- "$pattern" "${files[@]}" > "$found/files.txt"
for p in /proc/[0-9]*; do
  for part in environ cmdline; do tr '\0' '\n' < "$p/$part" 2>/dev/null | grep -aoE -- "$pattern"; done
done > "$found/proc.txt"
note proc_keys "$(grep -c . "$found/proc.txt")"
# Every reply the gateway gives, to requests shaped to make it or its upstream say the key: plain and streamed
# echoes, the client's own credential headers, methods, an absolute-form target, a bad path, and the raw socket.
python3 - "${GATEWAY_URL:-http://127.0.0.1:3129}" > "$found/replies.txt" <<'PY'
import http.client, socket, sys, urllib.parse

up = urllib.parse.urlsplit(sys.argv[1])
n = 0


def ask(method, path, headers=None, body=None):
    global n
    try:
        c = http.client.HTTPConnection(up.hostname, up.port, timeout=10)
        c.request(method, path, body=body, headers=headers or {})
        r = c.getresponse()
        print(f"== {method} {path} -> {r.status}")
        print("\n".join(f"{k}: {v}" for k, v in r.getheaders()))
        print(r.read().decode(errors="replace"))
        n += 1
    except Exception as e:
        print(f"== {method} {path} -> {type(e).__name__}: {e}")


ask("GET", "/")
ask("POST", "/v1/messages", {"Content-Type": "application/json"}, b'{"model": "x", "messages": []}')
ask("POST", "/stream/v1/messages", {"Content-Type": "application/json"}, b"{}")
ask("GET", "/v1/models", {"X-Api-Key": "probe", "Authorization": "Bearer probe", "Cookie": "a=b"})
ask("PUT", "/echo")
ask("PATCH", "/echo")
ask("DELETE", "/echo")
ask("OPTIONS", "/echo")
ask("TRACE", "/echo")
ask("GET", "/../../etc/passwd")
ask("GET", "/" + "a" * 5000)
for raw in (b"GET http://127.0.0.1:1/ HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n",
            b"GET /x HTTP/1.1\r\nHost: x\r\nX-Api-Key: probe\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"):
    for where in ("tcp", "/run/guard/model.sock"):
        try:
            if where == "tcp":
                s = socket.create_connection((up.hostname, up.port), timeout=10)
            else:
                s = socket.socket(socket.AF_UNIX)
                s.settimeout(10)
                s.connect(where)
            s.sendall(raw)
            s.settimeout(3)
            data = b""
            try:
                while chunk := s.recv(65536):
                    data += chunk
            except socket.timeout:
                pass
            print(f"== raw {where} -> {data.decode(errors='replace')}")
            n += 1
        except Exception as e:
            print(f"== raw {where} -> {type(e).__name__}: {e}")
print(f"== asked {n}")
PY
note replies "$(sed -n 's/^== asked //p' "$found/replies.txt")"
note reply_keys "$(grep -coE -- "$pattern" "$found/replies.txt")"
