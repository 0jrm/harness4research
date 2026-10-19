"""The broker's scheduler: design increments 1 to 3 of docs/design-sandboxed-agents.md, moved from eval/broker/ so
every host of it runs the code that ships (design-v8 section 4). lib/broker/server.py serves it;
lib/broker_host.py hosts it for guard enter; eval/broker/broker.py hosts it with a forge.

It runs outside the agent's sandbox, which sees only its sockets, and it is the only client of the scheduler. Jobs
enter only through guard run (lib/broker/run.py, the run verb); this module keeps what that and the sandbox's squeue,
sacct and scancel stand-ins (lib/broker/client.py) need:

    queue    squeue's arguments, answered for this session's job-log jobs only
    acct     sacct's arguments, the same
    cancel   job ids, each one of this session's job-log jobs

and the mirror of origin that policy is read from (guard/budget.card, guard/watch.list and guard/ as they are on main,
fetched before each decision, never the agent's clone), the agent's working tree read as files by blob hash (git never
runs in it), and the job log, ledger.jsonl, whose intent rows are reconciled by their guard:<session>:<seq> comment.
Any other verb, v7's submit among them, is X00.

The records socket (records.py) offers the needs-you queue's add, list, show and find, and nothing that closes or
approves. The gh socket (eval/broker/forge.py) is the sandbox's gh: pull requests kept in the broker's state, guard pr
open's brief among them, and no verb that merges; review, merge and ship run from broker.py outside the sandbox. The
broker holds the agent's GitHub token and the model key (read from gh_token_file and model_key_file into its
environment as GH_TOKEN and ANTHROPIC_API_KEY), and no request carries either into the sandbox or the reviewer's.

config.json keys: session, project (the project's path inside the sandbox), paths ([[inside, outside], ...]), origin
(the repository main is fetched from), slurm_bin (the scheduler's clients, by absolute path), slurm_env (their
environment), user, compute_bwrap (true when every compute node has bwrap), signing_key (the broker's private key),
owner_key (the owner's, for approve card where no person signs), allowed_signers (the two public keys), gh_token_file and
model_key_file (the credentials the broker holds), reviewer ({cmd, model_socket, passwd, binds, path, env, timeout}:
the reviewer's command and what its sandbox binds; review refuses without cmd)."""
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import threading
import time

import refusals
from broker.records import Records, Refused, read_rows

JOB_ID = re.compile(r"^[0-9]+(_[0-9]+)?$")


def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def pathspec(path, spec):
    """A git pathspec's default matching: a literal path or directory prefix, or a glob whose * crosses /."""
    spec = spec.rstrip("/")
    return path == spec or path.startswith(spec + "/") or fnmatch.fnmatchcase(path, spec)


def ignored(path, patterns):
    """Approximates .gitignore: a pattern without / matches any component, one with / matches from the top.
    Negations are skipped, so a re-included file still counts as ignored."""
    parts = path.split("/")
    for p in patterns:
        directory = p.endswith("/")
        p = p.rstrip("/")
        if "/" in p:
            p = p.lstrip("/")
            if fnmatch.fnmatchcase(path, p) or any(fnmatch.fnmatchcase("/".join(parts[:i]), p) for i in range(1, len(parts))):
                return True
        elif any(fnmatch.fnmatchcase(c, p) for c in (parts[:-1] if directory else parts)):
            return True
    return False




def transport(url):
    """The git transport a remote URL names: ext for ext::<cmd>, https for https://..., ssh for user@host:path, file
    for a path."""
    if "::" in url.split("/", 1)[0]:
        return url.split("::", 1)[0]
    if "://" in url:
        return url.split("://", 1)[0]
    head = url.split("/", 1)[0]
    return "ssh" if ":" in head and not os.path.exists(url) else "file"


class Mirror:
    """The broker's bare mirror of origin; policy comes from its main only.

    Its git reads no user or system config, so the user's protocol.<name>.allow is gone with it: a sandbox clone's
    ext::forge-connect origin, allowed in the agent's ~/.gitconfig, would be "transport 'ext' not allowed" here. The
    mirror therefore allows exactly its origin's transport (and file, for its own objects), through
    GIT_ALLOW_PROTOCOL, which git checks before any protocol.*.allow."""

    def __init__(self, path, origin):
        self.path, self.origin = path, origin
        self.allow = ":".join(sorted({"file", transport(origin)}))
        if not os.path.isdir(path):
            subprocess.run(["git", "init", "-q", "--bare", path], check=True)

    def git(self, *args, text=True, env=None, input=None):
        env = {"PATH": os.environ["PATH"], "HOME": self.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_ALLOW_PROTOCOL": self.allow, **(env or {})}
        return subprocess.run(["git", "--git-dir", self.path, *args], capture_output=True, text=text, env=env,
                              input=input)

    def fetch(self):
        done = self.git("fetch", "-q", "--no-tags", self.origin, "+refs/heads/main:refs/heads/main")
        if done.returncode:
            raise Refused(f"the broker could not fetch main from origin ({done.stderr.strip()[-200:]}); not submitting")
        self.files = {}
        for entry in self.git("ls-tree", "-r", "-z", "refs/heads/main", text=False).stdout.split(b"\0"):
            if entry:
                meta, path = entry.split(b"\t", 1)
                mode, _, sha = meta.decode().split()
                self.files[path.decode()] = (mode, sha)

    def show(self, path):
        if path not in self.files:
            return None
        return self.git("cat-file", "blob", self.files[path][1], text=False).stdout.decode(errors="replace")


class Tree:
    """The agent's project as files. Every path is confined to the project after resolving links."""

    def __init__(self, root):
        self.root = os.path.realpath(root)

    def inside(self, path):
        real = os.path.realpath(path)
        if real != self.root and not real.startswith(self.root + "/"):
            raise Refused(f"{path} is outside the project")
        return real

    def entry(self, rel):
        """(mode, blob sha) as git would record the path, or None."""
        path = os.path.join(self.root, rel)
        if os.path.islink(path):
            return "120000", blob(os.readlink(path).encode())
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as f:
            data = f.read()
        return ("100755" if os.access(path, os.X_OK) else "100644"), blob(data)

    def walk(self):
        for top, dirs, files in os.walk(self.root):
            rel = os.path.relpath(top, self.root)
            if rel == ".":
                dirs[:] = [d for d in dirs if d != ".git"]
            names = files + [d for d in dirs if os.path.islink(os.path.join(top, d))]
            for name in names:
                yield name if rel == "." else f"{rel}/{name}"

    def changed(self, mirror, specs, ignore):
        """Paths matching the pathspecs whose content, mode or presence differs from main."""
        on_main = {p: e for p, e in mirror.files.items() if any(pathspec(p, s) for s in specs)}
        out = {p for p, e in on_main.items() if self.entry(p) != e}
        out |= {p for p in self.walk() if p not in on_main and any(pathspec(p, s) for s in specs) and not ignored(p, ignore)}
        return sorted(out)


class Broker:
    def __init__(self, state_dir, cfg):
        self.dir, self.cfg = os.path.abspath(state_dir), cfg
        self.lock = threading.Lock()
        self.mirror = Mirror(os.path.join(self.dir, "mirror.git"), cfg["origin"])
        self.records = Records(self.dir, cfg, self.mirror)
        self.ledger_path = os.path.join(self.dir, "ledger.jsonl")
        self.rows = read_rows(self.ledger_path)
        self.reconcile()

    # paths ---------------------------------------------------------------------------------------------------------
    def outside(self, inside):
        for a, b in self.cfg["paths"]:
            if inside == a or inside.startswith(a + "/"):
                return b + inside[len(a):]
        raise Refused(f"{inside} is outside the project")

    def tree(self):
        return Tree(self.outside(self.cfg["project"]))

    # ledger --------------------------------------------------------------------------------------------------------
    def write(self, row):
        row = {"ts": time.time(), "session": self.cfg["session"], **row}
        with open(self.ledger_path, "a") as f:
            f.write(json.dumps(row) + "\n")
            f.flush()
            os.fsync(f.fileno())
        self.rows.append(row)
        return row

    def jobs(self, run=None):
        intents = {r["seq"]: r for r in self.rows if r["state"] == "intent"}
        return [r["job"] for r in self.rows
                if r["state"] == "submitted" and (run is None or intents[r["seq"]]["run"] == run)]

    def reconcile(self):
        """An intent with no outcome is a crash between the ledger row and sbatch: find its job by the comment."""
        done = {r["seq"] for r in self.rows if r["state"] != "intent"}
        for r in [r for r in self.rows if r["state"] == "intent" and r["seq"] not in done]:
            day = dt.date.fromtimestamp(r["ts"]).isoformat()
            rc, out, _ = self.slurm("sacct", "-X", "-n", "-P", "-o", "JobID,Comment", "-S", day)
            hit = [line.split("|")[0] for line in out.splitlines() if line.endswith("|" + r["comment"])] if rc == 0 else []
            if hit:
                self.write({"seq": r["seq"], "state": "submitted", "job": hit[0], "reconciled": True})
            else:
                self.write({"seq": r["seq"], "state": "lost", "why": "no job carries its comment" if rc == 0 else out})

    # the scheduler -------------------------------------------------------------------------------------------------
    def slurm(self, cmd, *args):
        done = subprocess.run([os.path.join(self.cfg["slurm_bin"], cmd), *args], capture_output=True, text=True,
                              env={"PATH": os.environ["PATH"], **self.cfg.get("slurm_env", {})})
        return done.returncode, done.stdout, done.stderr

    def must(self, cmd, *args):
        rc, out, err = self.slurm(cmd, *args)
        if rc:
            raise Refused(f"{cmd} failed ({(err.strip() or f'exit {rc}').splitlines()[0]}); not submitting")
        return out

    # verbs ---------------------------------------------------------------------------------------------------------
    def handle(self, req):
        verb = req.get("verb")
        handler = {"queue": self.queue, "acct": self.acct, "cancel": self.cancel}.get(verb)
        if handler is None:  # v7's submit among them: guard run is the only way in (E2b)
            return refusals.reply(refusals.refuse("X00", verb=verb))
        if not self.cfg.get("slurm_bin"):
            return {"rc": 1, "err": "guard broker: refused: this host has no scheduler\n"}
        return self.locked(handler, req)

    def locked(self, handler, req):
        with self.lock:
            try:
                return handler(req)
            except Refused as e:
                return {"rc": 1, "err": f"guard broker: refused: {e}\n"}

    def scoped(self, args, take, drop):
        """Arguments with the scoping options dropped, then --jobs set to this session's ledger jobs, which the caller's
        own -j can narrow but never widen."""
        out, mine, it = [], set(self.jobs()), iter(expand_flags(args))
        wanted = None
        for a in it:
            key, eq, value = a.partition("=")
            if key in drop:
                if drop[key] and not eq:
                    next(it, None)
            elif key in ("-j", "--jobs"):
                wanted = set((value if eq else next(it, "")).split(","))
            elif key in take:
                out.append(a)
                if take[key] and not eq:
                    out.append(next(it, ""))
            else:
                raise Refused(f"option {a} is not offered here")
        ids = sorted(mine if wanted is None else {j for j in wanted if j in mine or j.split("_")[0] in mine})
        return out + ["--jobs=" + (",".join(ids) or "0")]

    def queue(self, req):
        take = {"-h": False, "--noheader": False, "-o": True, "--format": True, "-t": True, "--states": True,
                "-n": True, "--name": True}
        drop = {"-u": True, "--user": True, "-A": True, "--account": True, "--me": False, "-a": False, "--all": False}
        rc, out, err = self.slurm("squeue", *self.scoped(req.get("args") or [], take, drop))
        return {"rc": rc, "out": out, "err": err}

    def acct(self, req):
        take = {"-X": False, "--allocations": False, "-n": False, "--noheader": False, "-P": False, "--parsable2": False,
                "-p": False, "--parsable": False, "-o": True, "--format": True, "-S": True, "--starttime": True,
                "-E": True, "--endtime": True, "-s": True, "--state": True, "--name": True}
        drop = {"-u": True, "--user": True, "--uid": True, "-A": True, "--account": True, "--accounts": True,
                "-a": False, "--allusers": False, "-L": False, "--allclusters": False}
        rc, out, err = self.slurm("sacct", *self.scoped(req.get("args") or [], take, drop))
        return {"rc": rc, "out": out, "err": err}

    def cancel(self, req):
        ids, mine = req.get("args") or [], set(self.jobs())
        if not ids:
            raise Refused("name the job ids to cancel")
        for j in ids:
            if not isinstance(j, str) or not JOB_ID.match(j):
                raise Refused(f"{j!r} is not a job id; scancel here takes this session's job ids only")
            if j not in mine and j.split("_")[0] not in mine:
                raise Refused(f"job {j} is not one this session submitted")
        rc, out, err = self.slurm("scancel", *ids)
        return {"rc": rc, "out": out, "err": err}


def expand_flags(args):
    """-XnP as -X -n -P, the way getopt reads clustered flags."""
    out = []
    for a in args:
        if not isinstance(a, str):
            raise Refused("arguments are strings")
        out += ["-" + c for c in a[1:]] if len(a) > 2 and a[0] == "-" and set(a[1:]) <= set("XnPpaLh") else [a]
    return out


def setup(state_dir):
    """The broker's signing key, made once (guard broker setup); prints its public key."""
    key = os.path.join(state_dir, "key")
    os.makedirs(state_dir, exist_ok=True)
    if not os.path.exists(key):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "guard-broker", "-f", key], check=True)
    with open(key + ".pub") as f:
        print(f.read().strip())


def outside_records(state_dir):
    """The records as a person outside the sandbox reaches them, without starting a broker."""
    with open(os.path.join(state_dir, "config.json")) as f:
        cfg = json.load(f)
    return Records(state_dir, cfg, Mirror(os.path.join(state_dir, "mirror.git"), cfg["origin"]))
