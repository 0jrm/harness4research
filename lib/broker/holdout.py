#!/usr/bin/env python3
"""The broker's sealed holdout (design-v8 sections 3 and 6; E7, finding 8, owner decision 3).

    holdout.py push <state_dir> <commit>    the forge's pre-receive, through git config guard.holdout, on a push to
                                            main that changes solution.py; exit 0 lets it through
    handle(request, broker)                 the records socket's holdout verb: guard holdout score
    seal(state_dir, data_dir, ...)          guard holdout seal, outside the sandbox (lib/verbs/holdout.py)

seal copies train.csv, public_test.csv, sealed_test.csv and sealed_features.csv from data_dir into
<state_dir>/holdout/, writes seal.json (the threshold, the submission limit, the scorer command, its time limit and
the inputs' sha256), and, when origin is a repository on this host, sets guard.holdout there for the pre-receive.

A submission lays out the commit's tree from git, never from the agent's checkout, and runs the scorer command as
`<scorer> <train> <test> <out>` (E7's predict contract) once on the public test rows and once on the sealed features,
each in a box of its own (lib/box.sh) holding the tree and copies of the inputs, and nothing of the sealed targets.
Its verdict:

    unscorable  a run timed out, the tree has no solution.py, or the public run gave no predictions
    fail        the public run scored and the sealed run did not, or sealed minus public RMSE is over the threshold
    pass        both scored, and the gap is within it
    limit       a score asked for after this session's N counted ones

Only the verdict and the ledger id leave the broker; the numbers stay in holdout/log.jsonl, which only the evaluator and
the owner read, so no score is an oracle (E7 seed 7 tuned against printed scores). A solution_sha256 already scored
answers with that verdict and a new receipt and counts nothing. A score counts; a push never counts and is never
refused for the limit, so the deliverable push cannot deadlock, but a push that fails or is unscorable is refused.
Each row's receipt (receipts.receipt_add) carries the verdict, the commit and the sha, never a number.

At the limit the broker opens one holdout_more ask for the session (asks.create_effect, default no); a person's yes
calls redecide(), which grants N more scores."""
import contextlib
import csv
import fcntl
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import types

if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import refusals  # noqa: E402
from broker import asks, receipts, scheduler  # noqa: E402

LIB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
INPUTS = ("train.csv", "public_test.csv", "sealed_test.csv", "sealed_features.csv")
SOLUTION = "solution.py"
SCORED = ("pass", "fail", "unscorable")


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def column(path, name):
    with open(path) as f:
        return [float(r[name]) for r in csv.DictReader(f)]


def rmse(pred, truth):
    """None for a wrong length or a NaN or infinite prediction, as the t3 scorer."""
    if len(pred) != len(truth) or any(math.isnan(p) or math.isinf(p) for p in pred):
        return None
    return math.sqrt(sum((p - t) ** 2 for p, t in zip(pred, truth)) / len(truth))


def judge(public, sealed, timed_out, threshold):
    if timed_out or public is None:
        return "unscorable"
    if sealed is None or sealed - public > threshold:
        return "fail"
    return "pass"


def seal(state_dir, data_dir, threshold, max_submissions, scorer, timeout=300, python=None, origin=None):
    hold = os.path.join(os.path.abspath(state_dir), "holdout")
    os.makedirs(hold, exist_ok=True)
    for name in INPUTS:
        shutil.copyfile(os.path.join(data_dir, name), os.path.join(hold, name))
    record = {"sealed": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "gap_threshold": float(threshold),
              "max_submissions": int(max_submissions), "scorer": scorer, "timeout": int(timeout),
              "python": os.path.abspath(python) if python else None,
              "sha256": {name: sha256(os.path.join(hold, name)) for name in INPUTS}}
    with open(os.path.join(hold, "seal.json"), "w") as f:
        json.dump(record, f, indent=1)
    if origin and os.path.isdir(origin):
        subprocess.run(["git", "--git-dir", origin, "config", "guard.holdout",
                        f"python3 {os.path.realpath(__file__)} push {os.path.dirname(hold)}"], check=True)
    return record


def sealed(state_dir):
    return os.path.isfile(os.path.join(state_dir, "holdout", "seal.json"))


class Holdout:
    """The seal and the log of one broker (its dir, cfg and mirror); the session is the broker's."""

    def __init__(self, broker):
        self.broker, self.state, self.session = broker, os.path.abspath(broker.dir), broker.cfg["session"]
        self.dir = os.path.join(self.state, "holdout")
        with open(os.path.join(self.dir, "seal.json")) as f:
            self.seal = json.load(f)
        self.log_path = os.path.join(self.dir, "log.jsonl")

    def rows(self):
        if not os.path.exists(self.log_path):
            return []
        with open(self.log_path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def locked(self, fn, *args):
        with open(os.path.join(self.dir, "lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return fn(*args)

    def used(self):
        return sum(1 for r in self.rows() if r.get("n") is not None and r["session"] == self.session)

    def allowed(self):
        """N, plus N more for each yes to a holdout_more ask in this session."""
        grants = sum(1 for r in self.rows() if r["verdict"] == "grant" and r["session"] == self.session)
        return self.seal["max_submissions"] * (1 + grants)

    def cached(self, sha):
        return next((r for r in reversed(self.rows()) if sha and r["solution_sha256"] == sha and r["verdict"] in SCORED),
                    None)

    # scoring -------------------------------------------------------------------------------------------------------
    @contextlib.contextmanager
    def tree(self, git, commit):
        """(work dir, solution_sha256) for commit's tree, laid out with git (an argv prefix naming the git dir) under a
        scratch directory; the sha is None when there is no commit, no tree or no solution.py."""
        work = tempfile.mkdtemp(prefix="holdout-", dir=self.state)
        try:
            project = os.path.join(work, "project")
            os.makedirs(project)
            env = {**os.environ, "GIT_INDEX_FILE": os.path.join(work, "index")}
            laid = bool(commit) and all(
                subprocess.run(git + ["--work-tree", project, *args], env=env, capture_output=True).returncode == 0
                for args in (["read-tree", commit], ["checkout-index", "-a", "-f"]))
            path = os.path.join(project, SOLUTION)
            yield work, sha256(path) if laid and os.path.isfile(path) else None
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def measure(self, work):
        """Both sets' RMSE, the gap and the verdict for the tree in work; numbers never leave the broker."""
        inputs = os.path.join(work, "score")
        os.makedirs(inputs)
        for name in ("train.csv", "public_test.csv", "sealed_features.csv"):
            shutil.copyfile(os.path.join(self.dir, name), os.path.join(inputs, name))
        row, timed_out = {}, False
        for name, test, truth in (("public", "public_test.csv", "public_test.csv"),
                                  ("sealed", "sealed_features.csv", "sealed_test.csv")):
            rc, err = self.run(work, test, f"{name}_pred.csv")
            timed_out |= rc == 124
            try:
                pred = column(os.path.join(inputs, f"{name}_pred.csv"), "prediction") if rc == 0 else None
            except (OSError, KeyError, ValueError):
                pred = None
            row[f"{name}_err"] = rmse(pred, column(os.path.join(self.dir, truth), "target")) if pred is not None else None
            if rc:
                row[f"{name}_error"] = (err.strip().splitlines() or [""])[-1][:200]
        pub, sea = row["public_err"], row["sealed_err"]
        row["gap"] = sea - pub if pub is not None and sea is not None else None
        row["verdict"] = judge(pub, sea, timed_out, self.seal["gap_threshold"])
        return row

    def run(self, work, test, out):
        """(exit status, stderr) of the scorer on one set, in a box; 124 past the seal's time limit."""
        argv = [os.path.join(LIB, "box.sh"), "--no-tty", "--hostname", "holdout", "--user", "scorer",
                "--tmp-home", "/tmp/home", "--bind", work, "/work"]
        if self.seal.get("python"):
            argv += ["--ro", self.seal["python"], "/opt/site/python", "--path", "/opt/site/python/bin"]
        argv += ["--chdir", "/work/project", "--probe", "--hide", self.dir, "--hide", os.path.expanduser("~"),
                 "--", "bash", "-c", self.seal["scorer"] + ' "$@"', "scorer",
                 "/work/score/train.csv", f"/work/score/{test}", f"/work/score/{out}"]
        try:
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                  timeout=self.seal["timeout"])
        except subprocess.TimeoutExpired:
            return 124, f"ran past the holdout's {self.seal['timeout']} s limit"
        return done.returncode, done.stderr

    # one submission ------------------------------------------------------------------------------------------------
    def submit(self, via, git, commit, branch=None):
        """The HoldoutRow of one score or push, appended with its ledger id; the caller holds the lock."""
        used, counts = self.used(), False
        with self.tree(git, commit) as (work, sha):
            hit = self.cached(sha)
            if hit:
                found = {k: hit[k] for k in ("public_err", "sealed_err", "gap", "verdict") if k in hit}
                found["cached"] = hit.get("cached", hit["ledger_id"])
            elif sha is None:
                found = {"verdict": "unscorable", "why": "no solution.py in the commit's tree"}
            elif via == "score" and used >= self.allowed():
                found = {"verdict": "limit"}
            else:
                found, counts = self.measure(work), via == "score"
        fields = {"via": via, "verdict": found["verdict"], "commit": commit, "solution_sha256": sha,
                  "session": self.session}
        row = {"ledger_id": receipts.receipt_add(self.broker, "holdout", None, fields).id, **({"n": used + 1} if counts else {}), "via": via,
               "commit": commit, "branch": branch, "solution_sha256": sha, **found, "ts": time.time(),
               "session": self.session}
        with open(self.log_path, "a") as f:
            f.write(json.dumps(row) + "\n")
        return row

    def line(self, row):
        """The verdict as the agent sees it: a refusal, or the pass line for a score; never a number but k, N, s."""
        cap = self.allowed()
        left = max(cap - self.used(), 0)
        if row["verdict"] == "fail":
            return refusals.refuse("H01", ledger_id=row["ledger_id"], k=left, n=cap)
        if row["verdict"] == "unscorable":
            return refusals.refuse("H02", ledger_id=row["ledger_id"], s=self.seal["timeout"], k=left)
        if row["verdict"] == "limit":
            return refusals.refuse("H03", n=cap)
        return f"holdout {row['ledger_id']} pass; {left} of {cap} submissions left\n"

    def answer(self, via, git, commit, branch=None):
        row = self.submit(via, git, commit, branch)
        return row, self.line(row)


def reply(said):
    return {"rc": 0, "out": said, "err": ""} if isinstance(said, str) else refusals.reply(said)


def handle(request, broker):
    """guard holdout score: the branch the agent is on, fetched from origin into the broker's mirror and scored."""
    if broker.cfg.get("session") == "local":
        return reply(refusals.refuse("H05"))
    if not sealed(broker.dir):
        return reply(refusals.refuse("H04"))
    branch = request.get("branch")
    if request.get("action") != "score" or not isinstance(branch, str):
        return {"rc": 64, "out": "", "err": "usage: guard holdout score\n"}
    h = Holdout(broker)

    def score():
        commit = None
        if not subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True).returncode:
            ref = f"refs/holdout/{len(h.rows()) + 1}"
            if not broker.mirror.git("fetch", "-q", "--no-tags", broker.mirror.origin,
                                     f"+refs/heads/{branch}:{ref}").returncode:
                commit = broker.mirror.git("rev-parse", ref).stdout.strip()
        return h.answer("score", ["git", "--git-dir", broker.mirror.path], commit, branch)

    row, said = h.locked(score)
    if row["verdict"] == "limit":
        with broker.lock:
            asks.create_effect(broker, "holdout_more", f"holdout:{h.session}",
                               f"Allow {h.seal['max_submissions']} more holdout scores for session {h.session}?")
    return reply(said)


def redecide(broker, effect):
    """A yes to the holdout_more ask that H03 made: N more scores for this session. broker.lock is held."""
    h = Holdout(broker)

    def grant():
        with open(h.log_path, "a") as f:
            f.write(json.dumps({"via": "ask", "verdict": "grant", "solution_sha256": None, "ts": time.time(),
                                "session": h.session}) + "\n")
        return {"rc": 0, "out": f"holdout: {h.seal['max_submissions']} more scores, "
                                f"{h.allowed() - h.used()} left this session\n", "err": ""}

    return h.locked(grant)


def push(state_dir, commit):
    """The pre-receive's check: exit 0 lets the push through; a refusal prints its two lines and its status."""
    with open(os.path.join(state_dir, "config.json")) as f:
        cfg = json.load(f)
    broker = types.SimpleNamespace(dir=os.path.abspath(state_dir), cfg=cfg,
                                   mirror=scheduler.Mirror(os.path.join(state_dir, "mirror.git"), cfg["origin"]))
    h = Holdout(broker)
    _, said = h.locked(h.answer, "push", ["git"], commit)
    if isinstance(said, str):
        return 0
    sys.stdout.write(refusals.render(said))
    return said.exit


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "push":
        sys.exit(push(sys.argv[2], sys.argv[3]))
    sys.exit(__doc__)
