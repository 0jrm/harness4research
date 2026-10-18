#!/usr/bin/env python3
"""The broker's scheduler verbs, records and forge: design increments 1 to 3 of docs/design-sandboxed-agents.md, in
the evaluation.

    broker.py setup <state_dir>                         # once: the broker's signing key (guard broker setup)
    broker.py serve <state_dir> <config.json>
    broker.py approve reserve <state_dir> <run_id>      # a person, outside the sandbox
    broker.py approve card <state_dir> <run_id>         # the owner signs card/<run_id> (git tag -s)
    broker.py revoke card <state_dir> <run_id>          # the owner deletes card/<run_id>; a revoked row
    broker.py records ack|done|dismiss <state_dir> <id> [--note N]   # only a person closes a needs-you item
    broker.py review <state_dir> <pr>                   # guard review, the reviewer in its own sandbox (forge.py)
    broker.py merge <state_dir> <pr>                    # guard merge: only a verdict the broker recorded merges
    broker.py ship <state_dir>                          # guard ship: review, then merge what is approved

It runs outside the agent's sandbox, which sees only its socket, and it is the only client of the scheduler. The
sandbox's sbatch, squeue, sacct and scancel are eval/broker/client.py, which sends one request per call:

    submit   {run, cwd, script, args, fields}; fields are the card-format names time nodes tasks cpus_per_task mem
             gpus array dependency partition output (decision D9), and nothing else
    queue    squeue's arguments, answered for this session's ledger jobs only
    acct     sacct's arguments, the same
    cancel   job ids, each one of this session's ledger jobs
    run      guard run: {run_dir, why, cause, cwd, options, script, args, fields}; the broker writes the run's card
             from the invocation, prices the job, and submits it, refuses it with the next command, or queues it

A submission is checked against guard/budget.card, guard/watch.list and guard/ as they are on main in the broker's
own mirror of origin, fetched before each submission, never against the agent's clone or environment. The agent's
working tree is read as files, by blob hash, and git never runs in it. A ripple (a watched path or guard/ changed, an
unhandled failed job, spend over 80%) stops the submission unless a person ran `approve reserve <run>` outside the
sandbox, which also lets that one job draw on the verification reserve. The broker writes its ledger row first, then
runs the scheduler's sbatch --export=NONE with the request's fields, then the card's extra_sbatch: words verbatim,
then its own values last, so they win: account, job name, a guard:<session>:<seq> comment, time, nodes, the submit
directory, and an output path in its spool, which the agent cannot write. The submitted script is a wrapper that
opens the requested output inside the job sandbox and runs the agent's script, so no #SBATCH line in it reaches the
scheduler. A job runs bare where the compute nodes have no bwrap or it spans nodes (decision D5); its ledger row and
the reply say job_sandbox: bare. A run other than explore-* submits only once its card is approved: the signed tag
card/<run_id> on origin verifies against the owner's and the broker's keys, and the card is read from that tag
(decision D2; records.py).

The records socket (records.py) offers add, list, show and find for the needs-you queue, execution.tsv rows and
question cards, and nothing that closes or approves. The gh socket (forge.py) is the sandbox's gh: pull requests
kept in the broker's state, guard pr open's brief among them, and no verb that merges; review, merge and ship run
from broker.py outside the sandbox. The broker holds the agent's GitHub token and the model key (in the evaluation,
canaries from gh_token_file and model_key_file, in its environment as GH_TOKEN and ANTHROPIC_API_KEY), and no request
carries either into the sandbox or the reviewer's.

config.json keys: session, project (the project's path inside the sandbox), paths ([[inside, outside], ...]), origin
(the repository main is fetched from), slurm_bin (the scheduler's clients, by absolute path), slurm_env (their
environment), user, compute_bwrap (true when every compute node has bwrap), signing_key (the broker's private key),
owner_key (the owner's, for approve card in the evaluation), allowed_signers (the two public keys), gh_token_file and
model_key_file (the credentials the broker holds), reviewer ({cmd, model_socket, passwd, binds, path, env, timeout}:
the reviewer's command and what its sandbox binds; review refuses without cmd)."""
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import shlex
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import traceback

from forge import Forge
from records import Records, Refused, approve_card, needs_you, read_rows, revoke_card

FIELDS = ("time", "nodes", "tasks", "cpus_per_task", "mem", "gpus", "array", "dependency", "partition", "output")
RUN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
INDEX = r"[0-9]+(-[0-9]+(:[0-9]+)?)?"
ARRAY = re.compile(rf"^{INDEX}(,{INDEX})*(%[0-9]+)?$")
JOB_ID = re.compile(r"^[0-9]+(_[0-9]+)?$")
DEPENDENCY = re.compile(r"^(after|afterany|afterok|afternotok):[0-9]+(_[0-9]+)?(:[0-9]+(_[0-9]+)?)*$")
OUTPUT = re.compile(r"^[A-Za-z0-9_.%/-]+$")
FAILED = ("TIMEOUT", "OUT_OF_ME", "NODE_FAIL", "FAILED", "PREEMPTED")
LIMIT_FLAGS = {"time": ("--time", "-t"), "nodes": ("--nodes", "-N"), "gpus": ("--gpus", "-G")}
# guard run's replies start with one of these codes, so a reader or a script can tell them apart without parsing prose.
CODES = {"usage": "H4R-R01", "time": "H4R-R02", "nodes": "H4R-R03", "gpus": "H4R-R04", "cause": "H4R-R05",
         "watched": "H4R-R06", "refused": "H4R-R07", "queued": "H4R-R08"}


class OverLimit(Refused):
    """A job over one of the budget card's per-job limits; fits is the largest value of flag that the card allows."""

    def __init__(self, message, flag, fits):
        super().__init__(message)
        self.flag, self.fits = flag, fits


class OverBudget(Refused):
    pass


class SchedulerRefused(Refused):
    pass


def to_minutes(text):
    """Slurm time syntax (M, M:S, H:M:S, D-H, D-H:M, D-H:M:S) to minutes, seconds rounded up; None when malformed."""
    m = re.fullmatch(r"(?:([0-9]+)-)?([0-9]+)(?::([0-9]+))?(?::([0-9]+))?", text)
    if not m:
        return None
    d, a, b, c = m.groups()
    if d is not None:
        h, mi, s = int(a), int(b or 0), int(c or 0)
    elif c is not None:
        h, mi, s = int(a), int(b), int(c)
    elif b is not None:
        h, mi, s = 0, int(a), int(b)
    else:
        h, mi, s = 0, int(a), 0
    return int(d or 0) * 1440 + h * 60 + mi + (s > 0)


def count_tasks(spec):
    n = 0
    for part in spec.split("%")[0].split(","):
        step = int(part.split(":")[1]) if ":" in part else 1
        lo, _, hi = part.split(":")[0].partition("-")
        n += (int(hi) - int(lo)) // step + 1 if hi else 1
    return n


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


def card_values(text):
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep and key not in values:
            values[key] = value.strip()
    return values


class Mirror:
    """The broker's bare mirror of origin; policy comes from its main only."""

    def __init__(self, path, origin):
        self.path, self.origin = path, origin
        if not os.path.isdir(path):
            subprocess.run(["git", "init", "-q", "--bare", path], check=True)

    def git(self, *args, text=True, env=None, input=None):
        env = {"PATH": os.environ["PATH"], "HOME": self.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               **(env or {})}
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
        self.forge = Forge(self.dir, cfg, self.mirror, self.records)
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
        handler = {"submit": self.submit, "run": self.guard_run, "queue": self.queue, "acct": self.acct,
                   "cancel": self.cancel}.get(verb)
        if handler is None:
            return {"rc": 1, "err": f"guard broker: no verb {verb!r}; it offers submit, run, queue, acct and cancel\n"}
        if not self.cfg.get("slurm_bin"):
            return {"rc": 1, "err": "guard broker: refused: this host has no scheduler; nothing was submitted\n"}
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

    def submit(self, req):
        """sbatch behind guard/run preflight: the card is the agent's, approved by the signed tag card/<run>."""
        job = self.plan(req)
        run = job["run"]
        card_sha, qcard = self.card_check(run, self.records.approved(run)[0]) if not job["explore"] else (None, {})
        approval = self.approval(run)
        ripples = self.ripples(job["tree"], run, job["acct"], job["user"], job["start"], job["max_ch"], job["ignore"])
        if ripples and approval is None:
            raise Refused("ripples: " + " | ".join(ripples) + f"; a person approves one diagnostic job outside the "
                          f"sandbox with: guard approve reserve {run}")
        try:
            job_id, note = self.launch(job, card_sha, qcard, approval)
        except SchedulerRefused as e:
            return {"rc": 1, "err": f"guard broker: the scheduler refused: {e}\n"}
        return {"rc": 0, "out": job_id + "\n" if req.get("parsable") else f"Submitted batch job {job_id}\n",
                "err": note + "\n"}

    def plan(self, req):
        """The request checked against main's budget card and its per-job limits, as the facts launch needs."""
        run, fields = req.get("run"), req.get("fields")
        if not isinstance(run, str) or not RUN.match(run):
            raise Refused(f"run id {run!r} is not a run id")
        if not isinstance(fields, dict) or set(fields) - set(FIELDS):
            raise Refused(f"unknown request fields {sorted(set(fields or {}) - set(FIELDS))}; the fields are "
                          + " ".join(FIELDS))
        fields = {k: str(v) for k, v in fields.items()}
        args = req.get("args") or []
        if not all(isinstance(a, str) for a in args):
            raise Refused("job arguments are strings")
        cwd_in = os.path.normpath(str(req.get("cwd")))
        tree = self.tree()
        tree.inside(self.outside(cwd_in))
        script_in = os.path.normpath(os.path.join(cwd_in, str(req.get("script"))))
        if not os.path.isfile(tree.inside(self.outside(script_in))):
            raise Refused(f"no job script {req.get('script')}")

        self.mirror.fetch()
        text = self.mirror.show("guard/budget.card")
        if text is None:
            raise Refused("no guard/budget.card on main")
        card = card_values(text)

        def need(key):
            v = card.get(key, "")
            if not v or "<" in v:
                raise Refused(f"budget card '{key}' is unset on main; a person sets it")
            return v

        def whole(key):
            v = need(key)
            if not v.isdigit():
                raise Refused(f"budget card '{key}' must be a whole number on main: {v}")
            return int(v)

        ignore = [l.strip() for l in (self.mirror.show(".gitignore") or "").splitlines()
                  if l.strip() and not l.startswith(("#", "!"))]
        moved = tree.changed(self.mirror, ["guard"], ignore)
        if moved:
            raise Refused(f"guard/ differs from main: {' '.join(moved)}; restore it from main")

        explore = run.startswith("explore-")
        acct, start, user = need("account"), need("start_date"), self.cfg["user"]
        if dt.date.today().isoformat() > need("stop_date"):
            raise Refused(f"past stop_date {card['stop_date']}; a person extends it on main")
        max_ch, cpn = whole("max_core_hours"), whole("cores_per_node")
        reserve = whole("verification_reserve_core_hours") if card.get("verification_reserve_core_hours") else 0
        max_nodes, max_wall, max_conc = whole("max_nodes_per_job"), whole("max_walltime_minutes"), whole("max_concurrent_jobs")

        if "time" not in fields:
            raise Refused("state the walltime: the time field")
        wmin = to_minutes(fields["time"])
        if wmin is None:
            raise Refused(f"time {fields['time']} is not a Slurm time")
        nodes = fields.get("nodes", "1")
        if not nodes.isdigit() or int(nodes) < 1:
            raise Refused(f"nodes {nodes} is not one positive integer")
        nodes = int(nodes)
        for key in ("tasks", "cpus_per_task"):
            if key in fields and not (fields[key].isdigit() and int(fields[key]) > 0):
                raise Refused(f"{key} {fields[key]} is not a positive integer")
        if "mem" in fields and not re.fullmatch(r"[0-9]+[KMGT]?", fields["mem"]):
            raise Refused(f"mem {fields['mem']} is not a size such as 4G")
        array = fields.get("array", "")
        if array and not ARRAY.match(array):
            raise Refused(f"array {array} is not an index list")
        n = count_tasks(array) if array else 1
        gpus = fields.get("gpus", "0")
        if not gpus.isdigit():
            raise Refused(f"gpus {gpus} is not a count")
        if "partition" in fields:
            allowed = card.get("partitions", "").replace(",", " ").split()
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", fields["partition"]) or (allowed and fields["partition"] not in allowed):
                raise Refused(f"partition {fields['partition']} is not one the budget card allows")
        if "dependency" in fields:
            for item in fields["dependency"].split(","):
                if item != "singleton" and not DEPENDENCY.match(item):
                    raise Refused(f"dependency {item} is not after*:<job ids> or singleton")
                foreign = [j for j in item.split(":")[1:] if j.split("_")[0] not in self.jobs()]
                if foreign:
                    raise Refused(f"dependency names job {foreign[0]}, which this session did not submit")
        output = fields.get("output", "slurm-%A_%a.out" if array else "slurm-%j.out")
        out_in = os.path.normpath(os.path.join(cwd_in, output))
        if not OUTPUT.match(output) or not out_in.startswith(self.cfg["project"] + "/"):
            raise Refused(f"output {output} is not a path inside the project")

        if explore:
            max_nodes = min(int(card.get("explore_max_nodes") or 1), max_nodes)
            max_wall = min(int(card.get("explore_max_walltime_minutes") or 60), max_wall)
            if n != 1:
                raise Refused("explore- runs submit one task at a time")
        if nodes > max_nodes:
            raise OverLimit(f"nodes {nodes} exceeds max_nodes_per_job={max_nodes}", "nodes", max_nodes)
        if wmin > max_wall:
            raise OverLimit(f"time {fields['time']} ({wmin} min) exceeds max_walltime_minutes={max_wall}", "time",
                            max_wall)
        if int(gpus) and (int(card.get("explore_max_gpus") or 0) < int(gpus) if explore
                          else card.get("max_gpu_hours", "0") in ("", "0")):
            raise OverLimit(f"gpus {gpus}: the budget card allows this run none, or fewer", "gpus", 0)
        return dict(run=run, fields=fields, args=args, cwd_in=cwd_in, script_in=script_in, output=output, tree=tree,
                    card=card, ignore=ignore, explore=explore, acct=acct, start=start, user=user, max_ch=max_ch, reserve=reserve,
                    max_conc=max_conc, cpn=cpn, wmin=wmin, nodes=nodes, n=n, gpus=int(gpus))

    def card_check(self, run, qtext):
        """(sha256, values) of the run's question card, once it agrees with the run's first job and main's rules."""
        q, card = f"runs/{run}/question.card", card_values(self.mirror.show("guard/budget.card") or "")
        card_sha = hashlib.sha256(qtext.encode()).hexdigest()
        first = next((r["card_sha"] for r in self.rows if r["state"] == "intent" and r["run"] == run), None)
        if first and first != card_sha:
            raise Refused(f"{q} changed since this run's first job; start a new run id for a new design")
        if card.get("card_on_main") == "yes" and self.mirror.show(q) != qtext:
            raise Refused(f"card_on_main is yes and {q} is not on main as it is here; a person merges it first")
        qcard = {k: v for k, v in card_values(qtext).items() if v and "<" not in v}
        waiver = qcard.get("checks") or card.get("checks", "")
        checks = [p for p, (mode, _) in self.mirror.files.items()
                  if p.startswith(f"runs/{run}/checks/") and mode == "100755"]
        if not re.match(r"^waived\s+[^\s<]", waiver) and not checks:
            raise Refused(f"no executable domain check in runs/{run}/checks/ on main, and no checks: waived")
        if qcard.get("deadline") and dt.date.today().isoformat() > qcard["deadline"]:
            raise Refused(f"past deadline {qcard['deadline']} in {q}")
        return card_sha, qcard

    def launch(self, job, card_sha, qcard, approval, record=None):
        """Checks the job against the remaining budget, writes its ledger row, then submits it: (job id, note)."""
        run, fields, card, acct, start, user = (job[k] for k in ("run", "fields", "card", "acct", "start", "user"))
        max_ch, reserve, max_conc, cpn = (job[k] for k in ("max_ch", "reserve", "max_conc", "cpn"))
        wmin, nodes, n, output, cwd_in, script_in = (job[k] for k in ("wmin", "nodes", "n", "output", "cwd_in", "script_in"))
        spent = sum(int(x or 0) for x in self.must("sacct", "-A", acct, "-u", user, "-S", start, "-X", "-n", "-P",
                                                     "-o", "CPUTimeRAW").split()) // 3600
        queued = 0
        for line in self.must("squeue", "-A", acct, "-u", user, "-h", "-t", "PENDING", "-o", "%C %l").splitlines():
            c, _, limit = line.partition(" ")
            queued += int(c) * (to_minutes(limit.strip()) or 0)
        queued //= 60
        proj = nodes * cpn * wmin * n // 60
        held = 0 if approval is not None else reserve
        if spent + queued + proj > max_ch - held:
            raise OverBudget(f"spent {spent} + queued {queued} + this job {proj} core-h exceeds {max_ch - held} available "
                          f"(max {max_ch}, reserve held {held})")
        run_max = qcard.get("budget_core_hours") or card.get("default_run_core_hours", "0")
        if run_max.isdigit() and int(run_max) > 0:
            run_spent = sum(int(line.split("|")[1] or 0) for line in self.must(
                "sacct", "-A", acct, "-u", user, "-S", start, "-X", "-n", "-P", "-o", "JobName,CPUTimeRAW").splitlines()
                if line.split("|")[0] == run) // 3600
            if run_spent + proj > int(run_max):
                raise Refused(f"this run spent {run_spent} + this job {proj} core-h exceeds budget_core_hours={run_max}")
        live = len([l for l in self.must("squeue", "-A", acct, "-u", user, "-h").splitlines() if l.strip()])
        if live + n > max_conc:
            raise Refused(f"{live} live + {n} new jobs exceeds max_concurrent_jobs={max_conc}")

        bare = None if self.cfg.get("compute_bwrap", True) else "the compute nodes have no bwrap"
        bare = "a multi-node job" if nodes > 1 else bare
        seq = 1 + sum(r["state"] == "intent" for r in self.rows)
        comment = f"guard:{self.cfg['session']}:{seq}"
        spool = os.path.join(self.dir, "spool", str(seq))
        os.makedirs(spool)
        wrapper = os.path.join(spool, "job.sh")
        expand = {"%%": "%", "%j": "${SLURM_JOB_ID}", "%A": "${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}",
                  "%a": "${SLURM_ARRAY_TASK_ID:-4294967294}", "%x": run}
        shown = re.sub(r"%[%jAax]", lambda m: expand[m.group()], output)
        with open(wrapper, "w") as f:
            f.write(f"#!/bin/bash\n# guard broker job {comment}, run {run}: {script_in}, output {output}\n"
                    f'exec >"{shown}" 2>&1 || exit 1\nexec bash {shlex.quote(script_in)} "$@"\n')
        extra = shlex.split(card.get("extra_sbatch", "")) if "<" not in card.get("extra_sbatch", "") else []
        named = {"tasks": "ntasks", "cpus_per_task": "cpus-per-task", "mem": "mem", "gpus": "gpus", "array": "array",
                 "dependency": "dependency", "partition": "partition"}
        argv = (["--export=NONE", "--ignore-pbs", "--parsable"]
                + [f"--{named[k]}={v}" for k, v in fields.items() if k in named] + extra
                + [f"--account={acct}", f"--job-name={run}", f"--comment={comment}", f"--time={wmin}",
                   f"--nodes={nodes}", f"--chdir={cwd_in}", f"--output={spool}/slurm-%j.out", wrapper, *job["args"]])
        self.write({"seq": seq, "state": "intent", "run": run, "comment": comment, "fields": fields, "argv": argv,
                    "card_sha": card_sha, "reserve": approval, "job_sandbox": "bare" if bare else "bwrap",
                    "why_bare": bare, **(record or {})})
        rc, out, err = self.slurm("sbatch", *argv)
        job = out.strip().split(";")[0]
        if rc or not JOB_ID.match(job):
            self.write({"seq": seq, "state": "failed", "why": err.strip() or out.strip()})
            raise SchedulerRefused(err.strip() or out.strip())
        self.write({"seq": seq, "state": "submitted", "job": job})
        return job, (f"guard: job {job}, run {run}: {n} task(s) x {nodes} node(s) x {wmin} min, projected {proj} core-h, "
                     f"job_sandbox: {'bare (' + bare + ')' if bare else 'bwrap'}")

    def guard_run(self, req):
        try:
            return self.run_job(req)
        except Refused as e:
            return refusal("refused", str(e))

    def run_job(self, req):
        """guard run runs/<run> --why W [--cause C] -- <sbatch options> <script> [args]: the broker prices the job from
        its own flags and #SBATCH lines, writes and commits the run's card from the invocation, and submits the job,
        refuses it with the next command, or queues it for the owner. A failed job of the run must get a --cause first,
        which the broker records as the run's incident."""
        run_dir, why, cause = str(req.get("run_dir")), req.get("why"), req.get("cause") or ""
        options, script, args = req.get("options") or [], str(req.get("script")), req.get("args") or []
        run = os.path.basename(os.path.normpath(run_dir))
        if not isinstance(why, str) or not why.strip() or "\n" in why or "\n" in cause:
            return refusal("usage", "--why is one sentence on one line, and so is --cause")
        command = ["guard", "run", run_dir, "--why", why, "--", *options, script, *args]
        self.mirror.fetch()
        failed = self.unhandled_failures(run)
        if failed and not cause.strip():
            return refusal("cause", f"job {' '.join(f'{j} ended {s}' for j, s in failed)}; read its output, then say "
                                    "what went wrong", command[:5] + ["--cause", "WHAT WENT WRONG"] + command[5:])
        if failed:
            self.incident(run, [j for j, _ in failed], cause)
        wall = card_values(self.mirror.show("guard/budget.card") or "").get("max_walltime_minutes", "")
        if not (req.get("fields") or {}).get("time") and wall.isdigit():
            return refusal("usage", "state the walltime; a job must fit max_walltime_minutes",
                           command[:6] + options + [f"--time={wall}", script, *args])
        try:
            job = self.plan({"run": run, "fields": req.get("fields"), "cwd": req.get("cwd"), "script": script,
                             "args": args})
        except OverLimit as e:
            split = "; split the work into jobs that fit, each resuming from a checkpoint" if e.flag == "time" else ""
            fixed = without_flag(options, LIMIT_FLAGS[e.flag]) + [f"--{e.flag}={e.fits}"]
            return refusal(e.flag, f"{e}{split}", command[:6] + fixed + [script, *args])
        moved = self.watched_changes(job["tree"], job["ignore"])
        if moved:
            return refusal("watched", f"{' '.join(moved)} differ from main, and the human owns them; restore them",
                           ["git", "checkout", "origin/main", "--", *moved])
        price = cost(job)
        try:
            card_sha, qcard = self.card_check(run, self.run_card(run, why, command, price))
            job_id, note = self.launch(job, card_sha, qcard, self.approval(run), record={"why": why, "cost": price})
            bare = note[note.index(", job_sandbox: bare"):] if ", job_sandbox: bare" in note else ""
        except OverBudget as e:
            item = self.records.queue_item(
                "approve", f"Approve a job of run {run} over the remaining budget",
                dict(why=f"{e}; the job: {shlex.join(command)}", expect=f"the agent reruns guard run for {run}",
                     worry="", undo=""),
                [], [f"eval/broker/broker.py approve reserve {self.dir} {run}"], "broker")
            return {"rc": 3, "err": f"{CODES['queued']} guard run: queued for the owner as needs-you {item}, since {e}; "
                                    "do other work, or stop\n"}
        return {"rc": 0, "out": f"job {job_id} submitted for run {run}: {price['minutes']} min x {price['nodes']} node(s) "
                                f"x {price['cores_per_node']} cores x {price['tasks']} task(s) = {price['core_hours']} "
                                f"core-h, {price['gpu_hours']} GPU-h{bare}\n"}

    def run_card(self, run, why, command, price):
        """runs/<run>/question.card as the broker wrote it from the run's first invocation; written now if absent."""
        path, tip = f"runs/{run}/question.card", self.records.tip(run)
        text = (self.records.blob(tip, path) if tip else None) or self.mirror.show(path)
        if text is not None:
            return text
        text = "".join(f"{k}: {v}\n" for k, v in [
            ("why", why), ("command", shlex.join(command)), *price.items(), ("session", self.cfg["session"]),
            ("written_by", "guard broker, from the guard run invocation")])
        self.records.commit(run, path, text, f"run: {run} card\n\nWritten by guard run for session {self.cfg['session']}.")
        return text

    def incident(self, run, jobs, cause):
        """The agent's --cause for failed jobs, committed as runs/<run>/incidents/<n>.md and kept in incidents.jsonl."""
        path = os.path.join(self.dir, "incidents.jsonl")
        n = 1 + sum(r["run"] == run for r in read_rows(path))
        text = "".join(f"job: {j}\n" for j in jobs) + f"\n{cause}\n"
        self.records.commit(run, f"runs/{run}/incidents/{n}.md", text,
                            f"run: {run} incident {n}\n\nRecorded by guard run --cause for session {self.cfg['session']}.")
        with open(path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "run": run, "jobs": jobs, "cause": cause}) + "\n")

    def unhandled_failures(self, run):
        """(job id, state) for this run's jobs that ended badly with no incident on main or from guard run --cause."""
        mine = self.jobs(run)
        if not mine:
            return []
        handled = {j for r in read_rows(os.path.join(self.dir, "incidents.jsonl")) if r["run"] == run for j in r["jobs"]}
        for p in self.mirror.files:
            if p.startswith(f"runs/{run}/incidents/") and p.endswith(".md"):
                handled |= {m.group(1) for m in re.finditer(r"(?m)^job: *([0-9A-Za-z_.-]+) *$", self.mirror.show(p))}
        out = self.must("sacct", "-X", "-n", "-P", "-o", "JobID,State", "--jobs=" + ",".join(mine))
        return [tuple(l.split("|")[:2]) for l in out.splitlines()
                if "|" in l and any(s in l.split("|")[1] for s in FAILED) and l.split("|")[0] not in handled]

    def watched_changes(self, tree, ignore):
        watch = [l.split("#")[0].strip() for l in (self.mirror.show("guard/watch.list") or "").splitlines()]
        return tree.changed(self.mirror, [w for w in watch if w], ignore)

    def approval(self, run):
        used = {r["reserve"] for r in self.rows if r["state"] == "intent" and r.get("reserve")}
        for a in read_rows(os.path.join(self.dir, "approvals.jsonl")):
            if a["run"] == run and a["id"] not in used:
                return a["id"]
        return None

    def ripples(self, tree, run, acct, user, start, max_ch, ignore):
        found = []
        moved = self.watched_changes(tree, ignore)
        if moved:
            found.append(f"watched paths differ from main: {' '.join(moved)}")
        bad = self.unhandled_failures(run)
        if bad:
            found.append(f"jobs ended badly with no incident on main: {' '.join(j for j, _ in bad)}")
        cpu = self.must("sacct", "-A", acct, "-u", user, "-S", start, "-X", "-n", "-P", "-o", "CPUTimeRAW").split()
        spent = sum(int(x or 0) for x in cpu) // 3600
        if spent * 100 > max_ch * 80:
            found.append(f"budget {spent} of {max_ch} core-h, over 80%")
        return found


def cost(job):
    """What the job charges: whole nodes, as the scheduler allocates and bills them, for its walltime and tasks."""
    hours = job["wmin"] * job["n"] / 60
    return {"minutes": job["wmin"], "nodes": job["nodes"], "cores_per_node": job["cpn"], "gpus": job["gpus"],
            "tasks": job["n"], "core_hours": round(hours * job["nodes"] * job["cpn"], 2),
            "gpu_hours": round(hours * job["gpus"], 2)}


def refusal(code, reason, next_command=None):
    """guard run's refusal: the code and the reason, then the exact command to run next when there is one."""
    err = f"{CODES[code]} guard run: refused: {reason}\n"
    return {"rc": 2, "err": err + (shlex.join(next_command) + "\n" if next_command else "")}


def without_flag(words, names):
    """sbatch option words with every --name=V, --name V, -xV and -x V of the given flag removed."""
    out, it = [], iter(words)
    for w in it:
        if w in names:
            next(it, None)
        elif not any(w.startswith(n + "=") or (len(n) == 2 and w.startswith(n) and len(w) > 2) for n in names):
            out.append(w)
    return out


def expand_flags(args):
    """-XnP as -X -n -P, the way getopt reads clustered flags."""
    out = []
    for a in args:
        if not isinstance(a, str):
            raise Refused("arguments are strings")
        out += ["-" + c for c in a[1:]] if len(a) > 2 and a[0] == "-" and set(a[1:]) <= set("XnPpaLh") else [a]
    return out


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        pid, uid, gid = struct.unpack("3i", self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        try:
            req = json.loads(self.rfile.readline())
            if uid != os.getuid():
                reply = {"rc": 1, "err": f"guard broker: uid {uid} is not this broker's user\n"}
            elif not isinstance(req, dict):
                reply = {"rc": 1, "err": "guard broker: a request is one JSON object\n"}
            else:
                reply = self.server.answer(req)
        except (ValueError, UnicodeDecodeError):
            reply = {"rc": 1, "err": "guard broker: a request is one JSON object\n"}
        except Exception as e:  # a bad request never takes the broker down; daemon.log keeps the trace
            traceback.print_exc()
            reply = {"rc": 1, "err": f"guard broker: refused: {type(e).__name__}\n"}
        self.wfile.write(json.dumps(reply).encode() + b"\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(state_dir, config_path):
    with open(config_path) as f:
        cfg = json.load(f)
    for key, name in (("gh_token_file", "GH_TOKEN"), ("model_key_file", "ANTHROPIC_API_KEY")):
        if cfg.get(key):  # held here, as a real broker holds them; every subprocess gets an explicit environment
            with open(cfg[key]) as f:
                os.environ[name] = f.read().strip()
    broker = Broker(state_dir, cfg)
    sock_dir = os.path.join(broker.dir, "sock")
    os.makedirs(sock_dir, exist_ok=True)
    os.chdir(sock_dir)  # a socket path is limited to about 108 bytes, so bind relative names
    names = ("scheduler.sock", "records.sock", "gh.sock")
    for name in names:
        if os.path.exists(name):
            os.unlink(name)

    def stop(signum, frame):
        for name in names:
            if os.path.exists(os.path.join(sock_dir, name)):
                os.unlink(os.path.join(sock_dir, name))
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    records = Server("records.sock", Handler)
    records.answer = lambda req: broker.locked(broker.records.handle, req)
    threading.Thread(target=records.serve_forever, daemon=True).start()
    gh = Server("gh.sock", Handler)
    gh.answer = lambda req: broker.locked(broker.forge.handle, req)
    threading.Thread(target=gh.serve_forever, daemon=True).start()
    with Server("scheduler.sock", Handler) as server:
        server.answer = broker.handle
        server.serve_forever()


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


def outside_forge(state_dir):
    records = outside_records(state_dir)
    return Forge(state_dir, records.cfg, records.mirror, records)


def approve(state_dir, what, run):
    if what != "reserve" or not RUN.match(run):
        sys.exit("usage: broker.py approve reserve <state_dir> <run_id>")
    path = os.path.join(state_dir, "approvals.jsonl")
    row = {"id": f"a{len(read_rows(path)) + 1}", "run": run, "ts": time.time(), "what": "reserve"}
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")
    print(f"approved one diagnostic job for {run} past the ripples gate and the reserve ({row['id']})")


def main(argv):
    if len(argv) == 3 and argv[1] == "setup":
        return setup(argv[2])
    if len(argv) == 4 and argv[1] == "serve":
        return serve(argv[2], argv[3])
    if len(argv) == 5 and argv[1:3] == ["approve", "reserve"]:
        return approve(argv[3], argv[2], argv[4])
    if len(argv) == 5 and argv[1:3] in (["approve", "card"], ["revoke", "card"]):
        return (approve_card if argv[1] == "approve" else revoke_card)(outside_records(argv[3]), argv[4])
    if len(argv) == 4 and argv[1] in ("review", "merge") or len(argv) == 3 and argv[1] == "ship":
        forge = outside_forge(argv[2])
        try:
            sys.exit(forge.ship() if argv[1] == "ship" else getattr(forge, argv[1])(argv[3]))
        except Refused as e:
            print(f"guard {argv[1]}: refused: {e}", file=sys.stderr)
            sys.exit(2)
    if len(argv) in (5, 7) and argv[1] == "records" and argv[2] in needs_you.MOVES \
            and (len(argv) == 5 or argv[5] == "--note"):
        try:
            return needs_you.move(outside_records(argv[3]).queue, argv[2], argv[4], argv[6] if len(argv) == 7 else "")
        except needs_you.Refused as e:
            sys.exit(f"broker.py: {e}")
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
