"""The pre-flight probe lib/box.sh runs inside a new sandbox before the command: the audit's sandbox rows, checked
from the inside (net-internet, net-loopback, host-paths, gpu, real-slurm, munge, ssh-agent, gh-config,
harness-readonly, token-search's environment). It reads the checks lib/box.sh wrote as NUL-separated key and value
pairs on stdin, prints one line per failed check, and exits 1 when any failed, so nothing starts."""
import os
import socket
import stat
import sys

# Variables that carry a credential or a route to one; none crosses into a sandbox.
SECRETS = ("SSH_AUTH_SOCK", "SSH_AGENT_PID", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "ANTHROPIC_API_KEY",
           "OPENAI_API_KEY", "CURSOR_API_KEY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "MUNGE_SOCKET")
# What guard enter (lib/enter.py) puts in a model key variable when the broker's gateway adds the real key outside.
PLACEHOLDER = "guard-gateway-adds-the-key"
# Paths that never exist inside: munge's socket directory and the user's runtime directory (ssh-agent, dbus, gpg).
ABSENT = ("/run/munge", "/var/run/munge", f"/run/user/{os.getuid()}")


def read_checks():
    data = sys.stdin.buffer.read().split(b"\0")
    checks = {}
    for key, value in zip(data[0::2], data[1::2]):
        if key:
            checks.setdefault(key.decode(), []).append(os.fsdecode(value))
    return checks


def sockets(top, allowed):
    """Sockets under top that are not allowed, read from directory entries, so a large tree such as a CI runner's
    /opt takes seconds; links are not followed."""
    stack = [top]
    while stack:
        try:
            entries = list(os.scandir(stack.pop()))
        except OSError:
            continue
        for e in entries:
            try:
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                elif e.is_file(follow_symlinks=False) or e.is_symlink():
                    continue
                elif stat.S_ISSOCK(e.stat(follow_symlinks=False).st_mode) and not any(
                        e.path == a or a.endswith("/") and e.path.startswith(a) for a in allowed):
                    yield e.path
            except OSError:
                continue


def main():
    checks, failed = read_checks(), []
    names = [n for _, n in socket.if_nameindex()]
    if names != ["lo"]:
        failed.append(f"net: interfaces {','.join(names)}, wanted lo only")
    try:
        socket.create_connection(("1.1.1.1", 53), timeout=2).close()
        failed.append("net: 1.1.1.1:53 answered")
    except OSError:
        pass
    for path in ABSENT:
        if os.path.lexists(path):
            failed.append(f"hidden: {path} exists")
    for path, ident in zip(checks.get("hide", []), checks.get("hide_id", [])):
        try:
            st = os.stat(path)
        except OSError:
            continue
        if f"{st.st_dev}:{st.st_ino}" == ident:
            failed.append(f"hidden: {path} is the host's own")
    for name in SECRETS:
        if name in os.environ and os.environ[name] != PLACEHOLDER:
            failed.append(f"env: {name} is set")
    try:
        with open("/proc/1/environ", "rb") as f:
            held = [kv.split(b"=")[0].decode(errors="replace") for kv in f.read().split(b"\0") if kv]
    except OSError:
        held = []
    if held:
        failed.append(f"env: PID 1 holds an environment ({', '.join(held[:5])}), which every process inside can read")
    home = os.environ.get("HOME", "/")
    if checks.get("home_ino") and str(os.stat(home).st_ino) != checks["home_ino"][0]:
        failed.append(f"home: {home} is not the home lib/box.sh bound")
    for path in checks.get("ro", []):
        if os.path.exists(path) and not os.statvfs(path).f_flag & os.ST_RDONLY:
            failed.append(f"read-only: {path} is writable")
    allowed = checks.get("sock", [])
    for top in ("/run", "/tmp", "/var", "/opt"):
        failed += [f"socket: {p} is reachable" for p in sockets(top, allowed)]
    allowed_gpus = checks.get("gpu", [])
    gpus = sorted(n for n in os.listdir("/dev") if n.startswith("nvidia") and f"/dev/{n}" not in allowed_gpus)
    if gpus:
        failed.append(f"gpu: /dev/{gpus[0]} and {len(gpus) - 1} more, not given with --gpu")
    for line in failed:
        print(f"guard box: probe: {line}", file=sys.stderr)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
