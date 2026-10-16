#!/usr/bin/env python3
"""usage: guard enter <project> [--agent NAME] [--no-tty] [--print] -- <command...>
Runs the command, any agent with any arguments, in a sandbox (lib/box.sh) that holds the project read-write and a home
of the agent's own, both at their real paths, and nothing else of yours: no ~/.ssh, ~/.config/gh or ~/.config/guard,
no ssh-agent or munge socket, no network but the broker's sockets (design increment 4). guard enter <project> -- bash
is how you look at a tree an agent wrote (decision D8): never open one outside a sandbox.

  --agent NAME   the profile to use; by default the command's name (claude, codex, cursor-agent), and none for any
                 other command. A profile is ~/.config/guard/agents/NAME, else the harness's templates/agents/NAME.
  --no-tty       an unattended session, as runhub starts one: a new terminal session, and no CLI login bound (D3)
  --print        print lib/box.sh's arguments instead of starting anything

The agent's home is ${XDG_DATA_HOME:-~/.local/share}/guard/homes/NAME, seeded once from the profile's copy: and
seed-json: files. The broker (guard broker) starts if it is not running; the session's sockets are
/tmp/guard-$UID/s-<session>/, at /run/guard inside: sbatch, squeue, sacct and scancel reach the scheduler only through
it, and a profile's net: hosts only through its proxy. The pre-flight probe checks the walls from inside first, and
nothing starts if one fails. Exit: the command's, 2 when guard enter refuses, 64 on a usage error, 70 when the probe
fails."""
import json
import os
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import broker_host as host  # noqa: E402

RELAY_PORT = 3128
STAND_INS = ("sbatch", "squeue", "sacct", "scancel")


def refuse(message, code=2):
    print(f"guard enter: {message}", file=sys.stderr)
    sys.exit(code)


def parse(argv):
    if "--" not in argv:
        refuse("usage: guard enter <project> [--agent NAME] [--no-tty] [--print] -- <command...>", 64)
    cut = argv.index("--")
    opts, cmd = argv[:cut], argv[cut + 1:]
    agent, no_tty, show, project = None, False, False, None
    it = iter(opts)
    for a in it:
        if a == "--agent":
            agent = next(it, None) or refuse("--agent takes a profile name", 64)
        elif a == "--no-tty":
            no_tty = True
        elif a == "--print":
            show = True
        elif a.startswith("-") or project is not None:
            refuse(f"unknown argument {a}; usage: guard enter <project> [--agent NAME] [--no-tty] [--print] -- "
                   "<command...>", 64)
        else:
            project = a
    if project is None or not cmd:
        refuse("usage: guard enter <project> [--agent NAME] [--no-tty] [--print] -- <command...>", 64)
    return project, agent, no_tty, show, cmd


def profile(name):
    """The profile's entries as (key, value) pairs; an unknown name named by --agent refuses."""
    for path in (os.path.join(host.config_dir(), "agents", name), os.path.join(HARNESS, "templates", "agents", name)):
        if os.path.isfile(path):
            entries = []
            with open(path) as f:
                for n, line in enumerate(f, 1):
                    line = line.split("#", 1)[0].strip()
                    if not line:
                        continue
                    key, sep, value = line.partition(":")
                    if not sep or key not in ("binary", "copy", "seed-json", "login", "net", "env") or not value.strip():
                        refuse(f"{path}:{n}: not a profile line: {line}")
                    entries.append((key, value.strip()))
            return path, entries
    return None, []


def under(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def check_project(project, home):
    """A project may not hold, or sit inside, anything the sandbox must not see."""
    if not os.path.isdir(project):
        refuse(f"{project} is not a directory")
    if project == "/" or under(home, project):
        refuse(f"{project} holds your home, so the sandbox would see all of it; enter the project's own directory")
    for secret in host.hidden():
        if under(secret, project) or under(project, secret):
            refuse(f"{project} overlaps {secret}, which no sandbox may see")


def planted_credentials(project):
    """Claude Code settings in the project that set a credential-like variable: whatever sits in the project is inside
    the sandbox, so such a token is the agent's."""
    found = []
    for name in ("settings.json", "settings.local.json"):
        path = os.path.join(project, ".claude", name)
        try:
            with open(path) as f:
                env = json.load(f).get("env") or {}
        except (OSError, ValueError, AttributeError):
            continue
        found += [f"{path} sets {k}" for k in env if any(w in k.upper() for w in ("TOKEN", "KEY", "SECRET", "PASS"))]
    return found


def seed(home, agent_home, entries):
    for key, value in entries:
        if key not in ("copy", "seed-json"):
            continue
        rel, *keys = value.split()
        src, dst = os.path.join(home, rel), os.path.join(agent_home, rel)
        if os.path.exists(dst) or not os.path.isfile(src):
            continue
        os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
        if key == "copy":
            shutil.copyfile(src, dst)
        else:
            with open(src) as f:
                data = json.load(f)
            with open(dst, "w") as f:
                json.dump({k: data[k] for k in keys if k in data}, f, indent=1)
        os.chmod(dst, 0o600)


def git_dirs(project):
    """A linked worktree's git directory and the repository's common directory, when they sit outside the project."""
    dot = os.path.join(project, ".git")
    if not os.path.isfile(dot):
        return []
    with open(dot) as f:
        line = f.read().strip()
    if not line.startswith("gitdir:"):
        return []
    gitdir = os.path.realpath(os.path.join(project, line[len("gitdir:"):].strip()))
    dirs = [gitdir]
    if os.path.isfile(os.path.join(gitdir, "commondir")):
        with open(os.path.join(gitdir, "commondir")) as f:
            dirs.append(os.path.realpath(os.path.join(gitdir, f.read().strip())))
    return [d for d in dirs if os.path.isdir(d) and not under(d, project)]


MOUNT_RANK = {"--ro-try": 0, "--ro": 1, "--home": 2, "--bind": 3}


def mounts(home, agent_home, project, entries, no_tty, bindir):
    """lib/box.sh's bind options, a parent before what sits inside it, so the host's read-only /opt never covers a
    project, git directory or home under it; at one path, the writable bind comes last and wins. The harness is
    read-only, unless it is the project itself, which the agent is there to change."""
    out = [("--ro-try", "/opt", "/opt"), ("--home", agent_home, home), ("--bind", project, project),
           ("--ro", bindir, "/run/guard-bin")]
    out += [("--bind", d, d) for d in git_dirs(project)]
    if HARNESS != project:
        out.append(("--ro", HARNESS, HARNESS))
    for key, value in entries:
        if key == "binary":
            found = shutil.which(value)
            if not found:
                refuse(f"the {value} profile needs {value} on your PATH, and it is not there")
            real = os.path.realpath(found)
            if any(under(real, s) for s in host.hidden()):
                refuse(f"{value} resolves to {real}, inside a path no sandbox may see")
            out.append(("--ro", os.path.dirname(real), os.path.dirname(real)))
            os.symlink(real, os.path.join(bindir, value))
        elif key == "login" and not no_tty:
            src = os.path.join(home, value)
            if os.path.isfile(src):
                out.append(("--bind", src, src))
        elif key == "login":
            # An owner's session leaves the bind's empty mount point in the agent's home; nothing stays in its place.
            left = os.path.join(agent_home, value)
            if os.path.isfile(left) and not os.path.islink(left) and os.path.getsize(left) == 0:
                os.unlink(left)
    order = sorted(set(out), key=lambda m: (m[2].rstrip("/").count("/"), m[2], MOUNT_RANK[m[0]]))
    return [x for m in order for x in m]


def main(argv):
    project, agent, no_tty, show, cmd = parse(argv)
    home = os.path.realpath(os.path.expanduser("~"))
    project = os.path.realpath(project)
    check_project(project, home)
    for found in planted_credentials(project):
        print(f"guard enter: warning: {found}, inside the project, so the agent can read it; move that credential "
              "out of the project", file=sys.stderr)
    name = agent or os.path.basename(cmd[0])
    path, entries = profile(name)
    if path is None:
        if agent and agent != "none":
            refuse(f"no profile {agent} in {host.config_dir()}/agents or {HARNESS}/templates/agents")
        name = "none"
    if not os.path.exists(os.path.join(host.state_dir(), "key")):
        refuse("the broker is not set up on this host; run guard broker setup once")

    agent_home = os.path.join(host.data_dir(), "homes", name)
    os.makedirs(agent_home, mode=0o700, exist_ok=True)
    seed(home, agent_home, entries)
    net = [v for k, v in entries if k == "net"]
    if not show:
        how = host.start()
        if how != "running":
            print(f"guard enter: started the broker ({how}); guard broker status shows it", file=sys.stderr)
        opened = host.ask({"verb": "open", "project": project, "agent": name, "net": net, "pid": os.getpid()})
        if not opened or opened.get("rc"):
            refuse(f"the broker did not open a session ({(opened or {}).get('err', 'no answer').strip()}); nothing "
                   "started")
        sid, sock_dir, record = opened["session"], opened["dir"], opened["record"]
    else:
        sid, sock_dir, record = "print", os.path.join(host.runtime_dir(), "s-print"), None
    bindir = os.path.join(host.private_dir(host.runtime_dir()), f"b-{sid}")
    shutil.rmtree(bindir, ignore_errors=True)
    os.mkdir(bindir, 0o700)
    for stand_in in STAND_INS:
        os.symlink(os.path.join(HARNESS, "eval", "broker", "client.py"), os.path.join(bindir, stand_in))
    os.symlink(os.path.join(HARNESS, "bin", "guard"), os.path.join(bindir, "guard"))

    try:
        box = [os.path.join(HERE, "box.sh"), *mounts(home, agent_home, project, entries, no_tty, bindir),
               "--sock-dir", sock_dir, "--path", "/run/guard-bin",
               "--env", f"GUARD_SESSION={sid}", "--probe", *[x for p in host.hidden() for x in ("--hide", p)]]
        for key, value in entries:
            if key == "env":
                box += ["--env", value]
        if net:
            proxy = f"http://127.0.0.1:{RELAY_PORT}"
            box += ["--relay", str(RELAY_PORT)]
            for var in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
                box += ["--env", f"{var}={proxy}"]
            box += ["--env", "NO_PROXY=127.0.0.1,localhost", "--env", "no_proxy=127.0.0.1,localhost"]
        for var in ("COLORTERM", "TZ", "LANG"):
            if os.environ.get(var):
                box += ["--env", f"{var}={os.environ[var]}"]
        cwd = os.path.realpath(os.getcwd())
        box += ["--chdir", cwd if under(cwd, project) else project]
        box += ["--no-tty"] if no_tty else []
        box += ["--record", record] if record else []
        if show:
            box.append("--print")
        if no_tty and any(k == "login" for k, _ in entries):
            print(f"guard enter: --no-tty, so no CLI login is bound for {name} (decision D3)", file=sys.stderr)
        for sig in (signal.SIGINT, signal.SIGQUIT):
            signal.signal(sig, signal.SIG_IGN)
        done = subprocess.run([*box, "--", *cmd], preexec_fn=lambda: [signal.signal(s, signal.SIG_DFL) for s in (signal.SIGINT, signal.SIGQUIT)])
        return done.returncode
    finally:
        shutil.rmtree(bindir, ignore_errors=True)
        if not show:
            host.ask({"verb": "close", "session": sid})


if __name__ == "__main__":
    if sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__)
        sys.exit(0)
    sys.exit(main(sys.argv[1:]))
