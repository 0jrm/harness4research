#!/usr/bin/env python3
"""usage: guard broker setup | status | stop
  setup    once per host: the state directory, the broker's signing key, the default agent profiles in
           ~/.config/guard/agents/ and model upstreams in ~/.config/guard/models/, and a self-test that starts a
           sandbox and runs the pre-flight probe in it
  status   whether the broker answers, and its sessions, live jobs and recent refusals; exit 1 when it is down
  stop     stops the broker; every session's sockets then refuse

The broker is one process per user per host, outside every sandbox (design increment 4, decisions D1 and D7). guard
enter starts it when it is not running: under systemd-run --user where a user service manager answers, which
outlives the login without a terminal, else in tmux, else detached. GUARD_BROKER_LAUNCH=systemd|tmux|detached picks
one; on skynet, whose user manager answers only in interactive logins, set GUARD_BROKER_LAUNCH=tmux (decision D7). For each session it serves a
directory /tmp/guard-$UID/s-<session>/ (mode 0700; GUARD_RUNTIME_DIR moves the parent) that the sandbox sees at
/run/guard:

    records.sock     lib/broker/records.py's needs-you queue and the verbs lib/broker/server.py registers there
                     (ask, holdout, receipt), the project's records in its state directory
    scheduler.sock   lib/broker/scheduler.py's verbs, one broker per project, against this host's Slurm by
                     absolute path; with no sbatch on the host it refuses every request
    net.sock         a CONNECT proxy to the session's allowlist and no other host: net_allow: in the project's
                     guard/budget.card as the broker's mirror of main has it (decision D4: PyPI and conda when the card
                     does not say, none when main cannot be read), plus the profile's net: hosts; each connection
                     logged with its host and byte counts, the traffic itself never opened
    model.sock       in an unattended session (--no-tty) whose profile names model: NAME, lib/gateway.py's model
                     gateway to the upstream in ~/.config/guard/models/NAME, which adds the key outside the sandbox,
                     removes it from every reply, and logs each request (decision D3)

A model file holds upstream: URL, key: FILE (beside it, mode 0600; none for a local vLLM) and header: authorization
(sent as Bearer) or a header name such as x-api-key. Its state, which no sandbox sees:
${XDG_STATE_HOME:-~/.local/state}/guard/, holding key (the signing key), projects/<name>/ (each project's ledger,
mirror and spool, as lib/broker lays them out, and the origin pinned the first time the project was entered),
broker.log, sessions.jsonl, net.jsonl, model.jsonl and refusals.jsonl. The sockets fail closed: with the broker down
nothing answers, and a sandbox has no other route out."""
import contextlib
import hashlib
import io
import json
import os
import secrets
import shlex
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.dirname(HERE)
import _path  # noqa: E402,F401
from broker import scheduler, server as sockets  # noqa: E402  lib/broker/, the scheduler socket
import gateway  # noqa: E402  lib/gateway.py, the model gateway and the allowlist

SOCKET_MAX = 104  # sun_path is 108 bytes on Linux; leave room for the terminating NUL and a margin


def person_config(key):
    """A key's value in the person's guard config (lib/config.sh's file), or None."""
    path = os.environ.get("GUARD_CONFIG") or os.path.join(config_dir(), "config")
    try:
        with open(path) as f:
            for line in f:
                k, sep, v = line.partition(":")
                if sep and k == key:
                    return v.strip() or None
    except OSError:
        pass
    return None


def project_name(path):
    """The name of a project's directory under the broker's state, projects/<name>/: lib/needs_you.py finds a
    project's asks there by it."""
    real = os.path.realpath(path)
    return f"{os.path.basename(real) or 'root'}-{hashlib.sha1(real.encode()).hexdigest()[:8]}"


def xdg(var, default):
    return os.path.join(os.environ.get(var) or os.path.expanduser(default), "guard")


def state_dir():
    return xdg("XDG_STATE_HOME", "~/.local/state")


def config_dir():
    return xdg("XDG_CONFIG_HOME", "~/.config")


def data_dir():
    return xdg("XDG_DATA_HOME", "~/.local/share")


def runtime_dir():
    return os.environ.get("GUARD_RUNTIME_DIR") or f"/tmp/guard-{os.getuid()}"


def private_dir(path):
    """A directory only this user can enter; refuses one that another user owns or that is a link."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    st = os.lstat(path)
    if not os.path.isdir(path) or os.path.islink(path) or st.st_uid != os.getuid():
        sys.exit(f"guard broker: {path} is not a directory this user owns; remove it or set GUARD_RUNTIME_DIR")
    os.chmod(path, 0o700)
    return path


def append(path, row):
    with open(path, "a") as f:
        f.write(json.dumps({"ts": time.time(), **row}) + "\n")


def peer_uid(conn):
    return struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]


# the daemon ------------------------------------------------------------------------------------------------------
class Session:
    def __init__(self, sid, path, project, agent, net, pid):
        self.sid, self.path, self.project, self.agent, self.net, self.pid = sid, path, project, agent, net, pid
        self.started, self.servers, self.record, self.model = time.time(), [], None, None

    def limits(self):
        """What lib/box.sh recorded for this session's sandbox: a scope's wall or prlimit's speed bump."""
        try:
            with open(self.record) as f:
                return json.loads(f.read().splitlines()[-1])
        except (OSError, ValueError, IndexError):
            return None

    def view(self):
        return {"session": self.sid, "dir": self.path, "project": self.project, "agent": self.agent,
                "net": self.net, "model": self.model, "pid": self.pid, "started": self.started,
                "record": self.record, "limits": self.limits()}


class Connect(socketserver.BaseRequestHandler):
    """One CONNECT tunnel to a host on the session's allowlist; TLS stays end to end, so the broker sees only the host
    and the byte counts."""

    def handle(self):
        conn, host = self.request, self.server.host
        if peer_uid(conn) != os.getuid():
            return
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 8192:
            byte = conn.recv(1)
            if not byte:
                return
            head += byte
        words = head.split(b"\r\n", 1)[0].decode("latin-1").split()
        target = gateway.host_port(words[1]) if len(words) == 3 and words[0] == "CONNECT" else None
        if target not in self.server.allowed:
            said = " ".join(words[:2])[:200] or "an empty request"
            why = (f"{said} is not on this session's allowlist" if words[:1] == ["CONNECT"] else
                   f"{said}: the proxy takes CONNECT only")
            host.refused(self.server.sid, "net", why)
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        name, _, port = target.rpartition(":")
        try:
            upstream = socket.create_connection((name.strip("[]"), int(port)), timeout=30)
        except OSError as e:
            host.refused(self.server.sid, "net", f"CONNECT {target} failed: {e.strerror or e}")
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return
        upstream.settimeout(None)
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        counts = {}
        down = threading.Thread(target=pipe, args=(upstream, conn, counts, "down"), daemon=True)
        down.start()
        pipe(conn, upstream, counts, "up")
        down.join()
        append(os.path.join(host.state, "net.jsonl"), {"session": self.server.sid, "host": target, **counts})


def pipe(src, dst, counts, key):
    counts[key] = 0
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
            counts[key] += len(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            with contextlib.suppress(OSError):
                s.shutdown(socket.SHUT_RDWR)


class Host:
    """The broker's sessions and its per-project schedulers."""

    def __init__(self, state, runtime):
        self.state, self.runtime, self.started = state, runtime, time.time()
        self.sessions, self.projects, self.lock = {}, {}, threading.Lock()
        self.slurm_bin = os.path.dirname(shutil.which("sbatch") or "") or None

    def refused(self, sid, where, why):
        append(os.path.join(self.state, "refusals.jsonl"), {"session": sid, "socket": where, "why": why})

    def project(self, path):
        """The scheduler broker for a project, made once; its ledger and spool outlive every session."""
        if path not in self.projects:
            name = project_name(path)
            pdir = os.path.join(self.state, "projects", name)
            os.makedirs(pdir, exist_ok=True)
            # The origin main is read from is pinned the first time: the clone's .git/config is the agent's to edit.
            try:
                with open(os.path.join(pdir, "config.json")) as f:
                    pinned = json.load(f)["origin"]
            except (OSError, ValueError, KeyError):
                pinned = origin(path)
            if inside(pinned, path):
                pinned = ""  # a repository inside the project is the agent's own
            cfg = {"session": name, "project": path, "paths": [[path, path]], "origin": pinned,
                   "slurm_bin": self.slurm_bin, "slurm_env": {}, "user": os.environ.get("USER", ""),
                   "compute_bwrap": False}
            if os.path.exists(os.path.join(self.state, "key")):  # guard broker setup ran; else receipts stay local
                cfg["signing_key"] = os.path.join(self.state, "key")
            if person_config("receipts_email"):
                cfg["receipts_email"] = person_config("receipts_email")
            with open(os.path.join(pdir, "config.json"), "w") as f:
                json.dump(cfg, f, indent=1)
            self.projects[path] = scheduler.Broker(pdir, cfg)
        return self.projects[path]

    def serve_socket(self, session, name, server):
        server.sid, server.agent = session.sid, session.agent
        session.servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()

    def open(self, req):
        project = os.path.realpath(str(req.get("project")))
        sid = secrets.token_hex(4)
        path = os.path.join(self.runtime, f"s-{sid}")
        if len(os.path.join(path, "scheduler.sock").encode()) > SOCKET_MAX:
            return {"rc": 1, "err": f"guard broker: {path} is too long for a socket path; set GUARD_RUNTIME_DIR "
                                    "to a short directory such as /tmp/guard-$UID\n"}
        os.mkdir(path, 0o700)
        broker = self.project(project)
        card, notes = self.allowlist(broker)
        profile = [gateway.host_port(h) for h in req.get("net") or []]
        net = list(dict.fromkeys(card + [h for h in profile if h]))
        session = Session(sid, path, project, str(req.get("agent")), net, req.get("pid"))
        session.record = os.path.join(private_dir(os.path.join(self.state, "limits")), f"s-{sid}.jsonl")
        sched = sockets.bind(os.path.join(path, "scheduler.sock"), "scheduler", broker,
                             lambda r, reply: self.logged(sid, "scheduler", r, reply), session=sid)
        self.serve_socket(session, "scheduler", sched)
        recs = sockets.bind(os.path.join(path, "records.sock"), "records", broker,
                            lambda r, reply: self.logged(sid, "records", r, reply), session=sid)
        self.serve_socket(session, "records", recs)
        if net:
            proxy = sockets.Server(os.path.join(path, "net.sock"), Connect)
            proxy.host, proxy.allowed = self, set(net)
            self.serve_socket(session, "net", proxy)
        if req.get("model"):
            try:
                self.serve_model(session, str(req["model"]))
            except ValueError as e:
                notes.append(f"no model gateway: {e}")
                self.refused(sid, "model", str(e))
        self.sessions[sid] = session
        append(os.path.join(self.state, "sessions.jsonl"), {"opened": session.view()})
        return {"rc": 0, **session.view(), "notes": notes}

    def allowlist(self, broker):
        """The hosts net_allow: names in guard/budget.card on the broker's mirror of main, which only a person's merge
        changes; the default when the card does not say; none, with a note, when main cannot be read."""
        try:
            with broker.lock:
                broker.mirror.fetch()
                card = broker.mirror.show("guard/budget.card")
        except Exception as e:  # noqa: BLE001  Refused, or git missing: either way no host is allowed
            return [], [f"no package hosts this session: the broker cannot read guard/budget.card on main ({e})"]
        hosts, bad = gateway.net_allow(card)
        return hosts, [f"net_allow: on main has words that are not host[:port], ignored: {' '.join(bad)}"] if bad else []

    def serve_model(self, session, name):
        """The session's model.sock: lib/gateway.py's handler to the upstream in ~/.config/guard/models/NAME."""
        spec = read_model(name)
        server = gateway.UnixModelServer(os.path.join(session.path, "model.sock"), gateway.ModelHandler)
        server.upstream, server.key, server.header = spec["upstream"], spec.get("key"), spec["header"]
        server.upstream_timeout = 600
        log = os.path.join(self.state, "model.jsonl")
        server.record = lambda entry: append(log, {"session": session.sid, "model": name, **entry})
        self.serve_socket(session, "model", server)
        session.model = name

    def logged(self, sid, where, req, reply):
        if reply.get("rc"):
            said = (reply.get("err") or "").strip().splitlines()
            self.refused(sid, where, f"{req.get('verb')}: {said[0] if said else 'refused'}")
        return reply

    def close(self, sid):
        session = self.sessions.pop(sid, None)
        if session is None:
            return {"rc": 1, "err": f"guard broker: no session {sid}\n"}
        for server in session.servers:
            server.shutdown()
            server.server_close()
        shutil.rmtree(session.path, ignore_errors=True)
        append(os.path.join(self.state, "sessions.jsonl"), {"closed": sid, "limits": session.limits()})
        return {"rc": 0}

    def reap(self):
        """Closes the sessions whose guard enter is gone, so their sockets refuse."""
        for sid, session in list(self.sessions.items()):
            try:
                os.kill(int(session.pid), 0)
            except (ProcessLookupError, TypeError, ValueError):
                self.close(sid)
            except PermissionError:
                pass

    def status(self):
        self.reap()
        jobs = []
        for path, broker in self.projects.items():
            ids = broker.jobs()
            if ids and self.slurm_bin:
                rc, out, _ = broker.slurm("squeue", "-h", "-o", "%i %T %j", "--jobs=" + ",".join(ids))
                jobs += [f"{path}: {line}" for line in out.splitlines() if rc == 0 and line.strip()]
        refusals = []
        log = os.path.join(self.state, "refusals.jsonl")
        if os.path.exists(log):
            with open(log) as f:
                refusals = [json.loads(line) for line in f.readlines()[-5:] if line.strip()]
        return {"rc": 0, "pid": os.getpid(), "started": self.started, "state": self.state, "runtime": self.runtime,
                "harness": HARNESS, "slurm_bin": self.slurm_bin, "sessions": [s.view() for s in self.sessions.values()],
                "jobs": jobs, "refusals": refusals}

    def answer(self, req):
        verb = req.get("verb")
        with self.lock:
            if verb == "ping":
                return {"rc": 0, "pid": os.getpid(), "harness": HARNESS}
            if verb == "open":
                self.reap()
                return self.open(req)
            if verb == "close":
                return self.close(str(req.get("session")))
            if verb == "status":
                return self.status()
            if verb == "stop":
                for sid in list(self.sessions):
                    self.close(sid)
                threading.Thread(target=lambda: (time.sleep(0.2), os._exit(0)), daemon=True).start()
                return {"rc": 0}
        return {"rc": 1, "err": f"guard broker: no verb {verb!r} on the control socket\n"}


class Control(socketserver.StreamRequestHandler):
    def handle(self):
        if peer_uid(self.request) != os.getuid():
            return
        try:
            req = json.loads(self.rfile.readline())
            reply = self.server.host.answer(req) if isinstance(req, dict) else {"rc": 1, "err": "not an object\n"}
        except ValueError:
            reply = {"rc": 1, "err": "guard broker: a request is one JSON object\n"}
        self.wfile.write(json.dumps(reply).encode() + b"\n")


def under(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def inside(url, project):
    """Whether a git URL names a repository inside the project: a plain or relative path, or a file:// URL (file:///p,
    file://localhost/p), as git would open it, with or without the .git it tries after the name."""
    if url.startswith("file://"):
        url = urllib.parse.unquote(urllib.parse.urlsplit(url).path)
    elif not url or url.startswith("ext::") or ":" in url.split("/", 1)[0]:
        return False  # empty, a transport helper, a URL with a scheme, or scp-like host:path
    local = os.path.join(project, url.rstrip("/"))
    return any(under(os.path.realpath(p), project) for p in (local, local + ".git"))


def read_model(name):
    """~/.config/guard/models/NAME as {upstream, header, key}; ValueError naming what is wrong."""
    models = os.path.join(config_dir(), "models")
    path = os.path.join(models, name)
    if not name.replace("-", "").isalnum() or not os.path.isfile(path):
        raise ValueError(f"no model {name} in {models}; guard broker setup writes the defaults")
    spec = {"header": "authorization"}
    with open(path) as f:
        for line in f:
            key, sep, value = line.split("#", 1)[0].partition(":")
            if sep and key.strip() in ("upstream", "key", "header"):
                spec[key.strip()] = value.strip()
    if not spec.get("upstream", "").startswith(("http://", "https://")):
        raise ValueError(f"{path} names no upstream: http(s)://...")
    if spec.get("key"):
        key_file = os.path.join(models, spec["key"])
        try:
            st = os.stat(key_file)
            with open(key_file) as f:
                spec["key"] = f.read().strip()
        except OSError:
            raise ValueError(f"no key for {name}: put it in {key_file}, mode 0600") from None
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise ValueError(f"{key_file} must be yours and mode 0600, so only you and the broker read it")
        if not spec["key"]:
            raise ValueError(f"{key_file} is empty")
    return spec


def origin(project):
    """The project's origin URL, read as a config file, never by running git in a tree an agent writes (#82)."""
    gitdir = os.path.join(project, ".git")
    if os.path.isfile(gitdir):
        with open(gitdir) as f:
            line = f.read().strip()
        gitdir = os.path.join(project, line[len("gitdir:"):].strip()) if line.startswith("gitdir:") else gitdir
        common = os.path.join(gitdir, "commondir")
        if os.path.isfile(common):
            with open(common) as f:
                gitdir = os.path.join(gitdir, f.read().strip())
    done = subprocess.run(["git", "config", "--file", os.path.join(gitdir, "config"), "--get", "remote.origin.url"],
                          capture_output=True, text=True, env={"PATH": os.environ["PATH"], "GIT_CONFIG_NOSYSTEM": "1"})
    return done.stdout.strip()


def serve():
    state, runtime = private_dir(state_dir()), private_dir(runtime_dir())
    control = os.path.join(runtime, "control.sock")
    if os.path.exists(control):
        os.unlink(control)
    host = Host(state, runtime)
    signal.signal(signal.SIGTERM, lambda *_: (host.answer({"verb": "stop"}), None))
    server = sockets.Server(control, Control)
    server.host = host
    print(f"guard broker: serving {control}, pid {os.getpid()}, harness {HARNESS}", flush=True)
    threading.Thread(target=reaper, args=(host,), daemon=True).start()
    server.serve_forever()


def reaper(host):
    while True:
        time.sleep(10)
        with host.lock:
            host.reap()


# the client ------------------------------------------------------------------------------------------------------
def ask(req, timeout=10):
    """The broker's reply, or None when nothing answers."""
    conn = socket.socket(socket.AF_UNIX)
    conn.settimeout(timeout)
    try:
        conn.connect(os.path.join(runtime_dir(), "control.sock"))
        conn.sendall(json.dumps(req).encode() + b"\n")
        line = conn.makefile().readline()
    except OSError:
        return None
    finally:
        conn.close()
    return json.loads(line) if line else None


LAUNCHERS = ("systemd", "tmux", "detached")


def launcher():
    """How the broker starts: GUARD_BROKER_LAUNCH when set, so a host such as skynet, whose user manager answers only
    in interactive logins, follows D7 with GUARD_BROKER_LAUNCH=tmux; otherwise systemd-run --user where a user
    manager answers, since that outlives the login without a terminal, then tmux, then a detached process."""
    chosen = os.environ.get("GUARD_BROKER_LAUNCH", "")
    if chosen:
        if chosen not in LAUNCHERS or chosen != "detached" and not shutil.which(
                "systemd-run" if chosen == "systemd" else "tmux"):
            sys.exit(f"guard broker: GUARD_BROKER_LAUNCH={chosen} is not one of {', '.join(LAUNCHERS)} available here")
        return chosen
    if shutil.which("systemd-run") and subprocess.run(["systemctl", "--user", "show-environment"],
                                                       capture_output=True).returncode == 0:
        return "systemd"
    return "tmux" if shutil.which("tmux") else "detached"


def start():
    """Starts the broker unless it answers; returns how it was started, or exits naming the log."""
    if ask({"verb": "ping"}):
        return "running"
    state = private_dir(state_dir())
    private_dir(runtime_dir())
    log = os.path.join(state, "broker.log")
    argv = [sys.executable, os.path.abspath(__file__), "serve"]
    how = launcher()
    keep = {k: v for k, v in os.environ.items()
            if k in ("PATH", "HOME", "USER", "LANG", "GUARD_RUNTIME_DIR") or k.startswith("XDG_")}
    unit = "guard-broker-" + hashlib.sha1(state.encode()).hexdigest()[:8]
    if how == "systemd":
        subprocess.run(["systemd-run", "--user", "--quiet", "--collect", f"--unit={unit}",
                        *[f"--setenv={k}={v}" for k, v in keep.items()],
                        "/bin/sh", "-c", 'exec "$@" >> "$0" 2>&1', log, *argv], check=True)
    elif how == "tmux":
        # A tmux server that is already running starts the session with its own environment, not this one, so the
        # broker's is spelled out in the command.
        command = shlex.join(["env", "-i", *[f"{k}={v}" for k, v in keep.items()], *argv]) + f" >> {shlex.quote(log)} 2>&1"
        subprocess.run(["tmux", "new-session", "-d", "-s", unit, command], check=True)
    else:
        with open(log, "a") as out:
            subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True, env=keep)
    for _ in range(100):
        if ask({"verb": "ping"}, timeout=1):
            return how
        time.sleep(0.1)
    sys.exit(f"guard broker: started it ({how}) but it does not answer; see {log}")


def limits_said(rec):
    if not rec:
        return "none recorded yet"
    if rec["limits"] == "scope":
        return (f"a systemd user scope, MemoryMax {rec['memory_max'] / 2**30:.1f} GiB, TasksMax {rec['tasks_max']}: "
                "a wall for the sandbox as a whole")
    return (f"prlimit ({rec['why']}): memory and file size per process only; no cap on the sandbox's processes, "
            "since a per-uid cap starves the sandbox when other work runs as you")


def ago(ts):
    s = int(time.time() - ts)
    return f"{s // 3600}h {s % 3600 // 60}m" if s >= 3600 else f"{s // 60}m {s % 60}s"


def status():
    reply = ask({"verb": "status"})
    if not reply:
        print(f"guard broker: not running: nothing answers on {os.path.join(runtime_dir(), 'control.sock')}, so every "
              "session's sockets refuse; guard enter starts it")
        return 1
    print(f"guard broker: running, pid {reply['pid']}, up {ago(reply['started'])}, harness {reply['harness']}")
    print(f"state {reply['state']}, sockets {reply['runtime']}, scheduler "
          + (f"{reply['slurm_bin']}/sbatch" if reply["slurm_bin"] else "none on this host (scheduler.sock refuses)"))
    print(f"sessions: {len(reply['sessions'])}")
    for s in reply["sessions"]:
        print(f"  s-{s['session']}  {s['agent']}  {s['project']}  up {ago(s['started'])}, guard enter pid {s['pid']}"
              + (f", model gateway {s['model']}" if s.get("model") else "")
              + (f", net {' '.join(s['net'])}" if s["net"] else ", no network"))
        print(f"    limits: {limits_said(s['limits'])}")
    print(f"live jobs: {len(reply['jobs'])}")
    for j in reply["jobs"]:
        print(f"  {j}")
    print(f"recent refusals: {len(reply['refusals'])}" + ("" if reply["refusals"] else " (none)"))
    for r in reply["refusals"]:
        print(f"  {time.strftime('%H:%M:%S', time.localtime(r['ts']))} s-{r['session']} {r['socket']}: {r['why']}")
    return 0


def stop():
    if ask({"verb": "stop"}) is None:
        print("guard broker: not running")
        return 0
    for _ in range(50):
        if ask({"verb": "ping"}, timeout=1) is None:
            print("guard broker: stopped; every session's sockets now refuse")
            return 0
        time.sleep(0.1)
    print("guard broker: asked it to stop, and it still answers", file=sys.stderr)
    return 1


def prereq():
    if not shutil.which("bwrap"):
        sys.exit("guard broker: needs bubblewrap; install it, for example sudo apt-get install bubblewrap")
    if subprocess.run(["bwrap", "--unshare-user", "--ro-bind", "/", "/", "true"], capture_output=True).returncode:
        sys.exit("guard broker: bwrap cannot make a user namespace here; enable unprivileged user namespaces, for "
                 "example sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0")


def setup():
    prereq()
    state = private_dir(state_dir())
    with contextlib.redirect_stdout(io.StringIO()) as key:
        scheduler.setup(state)
    print(f"signing key: {state}/key ({' '.join(key.getvalue().split()[:2])[:40]}...)")
    agents = os.path.join(private_dir(config_dir()), "agents")
    os.makedirs(agents, mode=0o700, exist_ok=True)
    made, kept = [], []
    for name in sorted(os.listdir(os.path.join(HARNESS, "templates", "agents"))):
        dst = os.path.join(agents, name)
        if os.path.exists(dst):
            kept.append(name)
        else:
            shutil.copyfile(os.path.join(HARNESS, "templates", "agents", name), dst)
            os.chmod(dst, 0o600)
            made.append(name)
    print(f"profiles in {agents}: " + ", ".join(made + [f"{k} (kept yours)" for k in kept]))
    models = os.path.join(config_dir(), "models")
    os.makedirs(models, mode=0o700, exist_ok=True)
    said = []
    for name in sorted(os.listdir(os.path.join(HARNESS, "templates", "models"))):
        dst = os.path.join(models, name)
        if not os.path.exists(dst):
            shutil.copyfile(os.path.join(HARNESS, "templates", "models", name), dst)
            os.chmod(dst, 0o600)
        try:
            spec = read_model(name)
            said.append(f"{name} ({'key in place' if spec.get('key') else 'no key'})")
        except ValueError as e:
            said.append(f"{name} ({e})")
    print(f"model upstreams in {models}: " + ", ".join(said))
    runtime = private_dir(runtime_dir())
    print(f"sockets: {runtime}/s-<session>/, mode 0700, outside the home so an NFS home never holds one")
    sbatch = shutil.which("sbatch")
    print(f"scheduler: {sbatch}, reached only through the broker" if sbatch else
          "scheduler: none on this host, so every session's scheduler.sock refuses")
    print("credentials: the agent's GitHub token and model keys stay outside every sandbox, with this key; "
          "~/.config/guard, ~/.ssh, ~/.config/gh, /run/user and /run/munge are invisible inside")
    print(f"broker: starts with the first guard enter ({launcher()}); guard broker status shows it")
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, "home"))
        os.makedirs(os.path.join(tmp, "project"))
        done = subprocess.run([os.path.join(HERE, "box.sh"), "--no-tty", "--home", os.path.join(tmp, "home"),
                               os.path.expanduser("~"), "--bind", os.path.join(tmp, "project"),
                               os.path.join(tmp, "project"), "--ro", HARNESS, HARNESS, "--probe",
                               *[x for p in hidden() for x in ("--hide", p)], "--", "true"],
                              capture_output=True, text=True)
    if done.returncode:
        print("self-test: FAIL, the pre-flight probe refused a fresh sandbox:\n" + done.stderr.strip())
        return 1
    print("self-test: a fresh sandbox passed the pre-flight probe")
    return 0


def hidden():
    """The host paths no sandbox may reach: the broker's state, guard's config, every agent home, the runtime root,
    the owner's ssh and gh configuration, and the session's agent and bus sockets."""
    home = os.path.expanduser("~")
    paths = [state_dir(), config_dir(), data_dir(), runtime_dir(), os.path.join(home, ".ssh"),
             os.path.join(home, ".config", "gh"), os.path.join(os.path.dirname(config_dir()), "gh")]
    paths += [os.environ[v] for v in ("SSH_AUTH_SOCK", "XDG_RUNTIME_DIR", "GH_CONFIG_DIR") if os.environ.get(v)]
    return list(dict.fromkeys(paths))


def main(argv):
    verbs = {"setup": setup, "status": status, "stop": stop, "serve": serve}
    if len(argv) != 2 or argv[1] not in verbs:
        print(__doc__, file=sys.stderr if len(argv) > 1 and argv[1] not in ("-h", "--help") else sys.stdout)
        return 0 if argv[1:] in (["-h"], ["--help"]) else 64
    return verbs[argv[1]]() or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
