#!/usr/bin/env python3
"""Replay a run's recorded tool calls, blind and with no model, against a harness checkout, and count its refusals.

usage: eval/replay.py <verdicts.jsonl> --episodes <dir> [--harness <checkout>] [--only id,id] [--out <file>]
                      [--work <dir>] [--parallel N]
       eval/replay.py --table <out.jsonl> [<other out.jsonl>]

For each episode in the verdicts, it rebuilds the episode with the checkout's eval/episode.sh (same family, variant,
arm, --broker and seed), then runs the agent's recorded exec_command and write_stdin calls in order inside the sandbox
through eval/driver/standin.py. Calls Codex never ran (an unknown tool, apply_patch, a rejected command) are skipped.
A poll that the record shows still running waits at most POLL_WAIT seconds. Recorded Slurm job ids in a command become
the replay's, paired in order of submission per call. Per command it records which refusals the record and the replay
show, and flags a command whose outcome depends on state the replay lacks. Each episode is one line of --out, written
as it finishes; a rerun skips the episodes already there. The replay says which recorded commands the harness refuses,
never how an agent would behave: an agent that saw a different output would have typed different commands."""
import argparse
import collections
import concurrent.futures
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from typing import NamedTuple, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import modellog  # noqa: E402

BLIND = ("replayed blind: the recorded commands ran with no model, so this counts what the harness refuses of them; "
         "it does not show how an agent would behave")
POLL_WAIT = 2.0
EXEC_CAP = 60.0
SLACK = 5.0

# --- the record, read as steps ---------------------------------------------------------------------------------------

HEADER = re.compile(r"\AChunk ID: \S+\nWall time: ([\d.]+) seconds\n"
                    r"(?:Process exited with code (-?\d+)|Process running with session ID (\d+))\n")


class Recorded(NamedTuple):
    exit: Optional[int]
    session: Optional[str]
    wall: float
    body: str


class Step(NamedTuple):
    number: int
    op: str                # exec or poll
    text: str              # the command, or the characters a poll writes
    session: str           # the record's session id, which the stand-in keys its processes by
    workdir: Optional[str]
    login: bool
    tty: bool
    recorded: Recorded


def parse_output(text):
    """The record of a call Codex ran, from its output header; None for one it answered without running anything."""
    m = HEADER.match(text or "")
    if not m:
        return None
    body = text[m.end():]
    body = body.split("Output:\n", 1)[1] if "Output:\n" in body else body
    return Recorded(int(m.group(2)) if m.group(2) is not None else None, m.group(3), float(m.group(1)), body)


def flag(value, default):
    return value if isinstance(value, bool) else default


def steps(calls):
    """The calls to replay, in order: every exec_command and write_stdin Codex ran."""
    out = []
    for c in calls:
        rec = parse_output(c.output)
        if rec is None:
            continue
        if c.name == "exec_command" and modellog.command(c.args):
            workdir = c.args.get("workdir") if isinstance(c.args.get("workdir"), str) else None
            out.append(Step(c.number, "exec", modellog.command(c.args), rec.session or f"x{c.number}", workdir,
                            flag(c.args.get("login"), True), flag(c.args.get("tty"), False), rec))
        elif c.name == "write_stdin":
            out.append(Step(c.number, "poll", str(c.args.get("chars") or ""), str(c.args.get("session_id")), None,
                            True, False, rec))
    return out


def wait_for(step):
    """How long the replay waits for the command to exit: as long as the record took, with slack when it exited there,
    and a short wait for a poll the record shows still running."""
    rec = step.recorded
    if rec.exit is not None:
        return min(rec.wall + SLACK, EXEC_CAP)
    return min(rec.wall, POLL_WAIT if step.op == "poll" else EXEC_CAP)


# --- ids: Slurm job ids and git hashes -------------------------------------------------------------------------------

JOB_ID = re.compile(r"Submitted batch job (\d+)|^guard: job (\d+),", re.M)
HEX = re.compile(r"(?<![0-9A-Za-z])(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![0-9A-Za-z])")


def job_ids(text):
    seen = []
    for m in JOB_ID.finditer(text or ""):
        j = m.group(1) or m.group(2)
        if j not in seen:
            seen.append(j)
    return seen


def hash_pairs(recorded_text, replay_text):
    """Hashes paired by the line they sit in: a line that reads the same in both outputs once its hashes are masked,
    and that appears once in each."""
    def by_line(text):
        lines = collections.defaultdict(list)
        for line in (text or "").splitlines():
            if HEX.search(line):
                lines[HEX.sub("#", line)].append(HEX.findall(line))
        return {k: v[0] for k, v in lines.items() if len(v) == 1}
    a, b = by_line(recorded_text), by_line(replay_text)
    return [(x, y) for k in a.keys() & b.keys() for x, y in zip(a[k], b[k])]


class Ids:
    """The record's job ids and commit hashes, paired with the replay's. Job ids pair in order of submission within a
    command; hashes pair by the output line they sit in, and match a command's hash by prefix, as git does."""

    def __init__(self, hashes=()):
        self.jobs, self.recorded_jobs = {}, set()
        self.hashes, self.recorded_hashes = dict(hashes), set(dict(hashes))

    def learn(self, recorded_text, replay_text):
        rec = job_ids(recorded_text)
        self.recorded_jobs.update(rec)
        self.jobs.update(zip(rec, job_ids(replay_text)))
        self.recorded_hashes.update(HEX.findall(recorded_text or ""))
        for a, b in hash_pairs(recorded_text, replay_text):
            self.hashes[a] = b

    def replay_hash(self, h):
        for a, b in self.hashes.items():
            if (a.startswith(h) or h.startswith(a)) and len(b) >= len(h):
                return b[:len(h)]
        return None

    def substitute(self, cmd):
        """The command with the record's ids replaced by the replay's, and a flag for each kind of recorded id it names
        that the replay has no counterpart for."""
        flags = set()

        def job(m):
            j = m.group(0)
            if j in self.jobs:
                return self.jobs[j]
            if j in self.recorded_jobs:
                flags.add("unmapped-job-id")
            return j

        def commit(m):
            h = m.group(0)
            new = self.replay_hash(h)
            if new is None and any(r.startswith(h) or h.startswith(r) for r in self.recorded_hashes):
                flags.add("unmapped-hash")
            return new or h
        ids = self.recorded_jobs | set(self.jobs)
        if ids:
            alts = "|".join(sorted(map(re.escape, ids), key=len, reverse=True))
            cmd = re.sub(r"(?<![\w.])(" + alts + r")(?!\w)", job, cmd)
        return HEX.sub(commit, cmd), sorted(flags)


# --- the classifier --------------------------------------------------------------------------------------------------

# One refusal kind per output line, the first that matches, each anchored at the start of a line so that a file the
# agent printed (a script that contains these words) does not count. remote: lines are the forge's refusals as git
# relays them; forge.log counts those, so they are kept apart as a cross-check.
KINDS = [
    ("ripples", re.compile(r"^(PREFLIGHT FAIL: ripples reports|RIPPLE\t)")),
    ("preflight", re.compile(r"^PREFLIGHT FAIL:")),
    ("launch", re.compile(r"^LAUNCH FAIL:")),
    ("card", re.compile(r"^guard broker: refused: .*(question\.card|card/)")),
    ("scheduler", re.compile(r"^guard broker: the scheduler refused|^sbatch: error: (?!Invalid user for SlurmUser)")),
    ("broker", re.compile(r"^guard broker: refused|^(sbatch|squeue|sacct|scancel): refused")),
    ("gh", re.compile(r"^(gh: refused|guard (pr open|review|merge|ship): refused)")),
    ("guard", re.compile(r"^guard [\w -]{1,30}: refused")),
    ("remote", re.compile(r"^remote: (FAIL\t|.* refused\b|main is a protected branch)")),
]


def classify(text):
    """The refusal kinds in a command's output, each with the first line that showed it."""
    found = {}
    for line in (text or "").splitlines():
        for kind, pattern in KINDS:
            if pattern.match(line):
                found.setdefault(kind, line.strip()[:300])
                break
    return found


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def log_refusals(ep):
    """Refusals from the episode's own logs: the forge's refused pushes by kind (counted), and the broker's refused
    records and gh requests and failed submissions (a cross-check, since their text also reaches the tool output)."""
    pushes = collections.Counter()
    forge = os.path.join(ep, "state", "git", "forge.log")
    if os.path.exists(forge):
        with open(forge) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) > 1 and parts[1].startswith("refuse"):
                    pushes["push-" + parts[1].removeprefix("refuse-")] += 1
    broker = os.path.join(ep, "state", "broker")
    cross = {"records_refused": sum("refused" in r for r in read_jsonl(os.path.join(broker, "records", "log.jsonl"))),
             "gh_refused": sum("refused" in r for r in read_jsonl(os.path.join(broker, "forge", "log.jsonl"))),
             "ledger_failed": sum(r.get("state") == "failed" for r in read_jsonl(os.path.join(broker, "ledger.jsonl")))}
    return pushes, cross


def counts(commands, side, pushes):
    """An episode's refusal counts on one side (recorded_refusals or refusals): each kind at most once per command, and
    only for commands the record saw exit. A command the record left running, whose output the agent never read,
    holds no evidence of what was refused, so it counts on neither side; forge.log's rows count every push."""
    c = collections.Counter(k for cmd in commands if cmd["recorded_exit"] is not None
                            for k in cmd[side] if k != "remote")
    c.update(pushes)
    return dict(c)


def unobserved(commands):
    """The replay's refusals in commands the record never saw exit, which the counts leave out."""
    return dict(collections.Counter(k for cmd in commands if cmd["recorded_exit"] is None
                                    for k in cmd["refusals"] if k != "remote"))


def pushes(row, side):
    return {k: v for k, v in row[side].items() if k.startswith("push-")}


# --- one episode -----------------------------------------------------------------------------------------------------

class StandIn:
    def __init__(self, harness, ep, project):
        cmd = [os.path.join(harness, "eval", "env", "sandbox.sh"), ep, "--", "bash", "-c",
               'exec -a replay-client python3 -u /opt/codex/standin.py "$0"', f"/home/agent/{project}"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(ep, "state", "replay-standin.log"), "a"),
                                     text=True, start_new_session=True)

    def ask(self, req):
        try:
            self.proc.stdin.write(json.dumps(req) + "\n")
            self.proc.stdin.flush()
            line = self.proc.stdout.readline()
        except BrokenPipeError:
            line = ""
        return json.loads(line) if line else None

    def end(self):
        try:
            self.ask({"op": "end"})
            self.proc.wait(30)
        except (subprocess.TimeoutExpired, ValueError, OSError):
            self.proc.kill()


def build(harness, meta, ep):
    """The episode, built fresh as the record's was."""
    arm = "A" if meta["arm"] == "A" else "E"
    broker = meta.get("broker", meta["arm"] == "E")
    cmd = [os.path.join(harness, "eval", "episode.sh"), meta["family"], meta["variant"], arm, ep,
           "--seed", str(meta["seed"])] + (["--broker"] if broker else [])
    done = subprocess.run(cmd, capture_output=True, text=True)
    if done.returncode:
        raise RuntimeError(f"episode.sh failed: {done.stderr.strip()[-500:]}")
    with open(os.path.join(ep, "sandbox", "binds"), "a") as f:
        f.write(f"{os.path.join(HERE, 'driver', 'standin.py')} /opt/codex/standin.py\n")


class Command:
    """One recorded exec_command and the polls of its session: what the record and the replay printed, and how each
    ended. A refusal the record shows in a poll may come in the replay's exec output, so commands, not calls, compare."""

    def __init__(self, step, text):
        self.n, self.cmd, self.replayed_cmd = step.number, step.text, text
        self.recorded_text, self.text, self.recorded_exit, self.exit, self.flags = "", "", None, None, set()

    def add(self, step, reply, flags):
        self.recorded_text += step.recorded.body
        self.text += reply["output"]
        self.recorded_exit = step.recorded.exit if step.recorded.exit is not None else self.recorded_exit
        self.exit = reply["exit"] if reply["exit"] is not None else self.exit
        self.flags.update(flags)

    def record(self):
        rec, rep = classify(self.recorded_text), classify(self.text)
        flags = set(self.flags)
        if None not in (self.recorded_exit, self.exit) and self.recorded_exit != self.exit:
            flags.add("exit-differs")
        if set(rec) != set(rep):
            flags.add("refusal-differs")
        return {"n": self.n, "cmd": self.cmd[:400], "replayed_cmd": self.replayed_cmd[:400]
                if self.replayed_cmd != self.cmd else None, "recorded_exit": self.recorded_exit, "exit": self.exit,
                "recorded_refusals": rec, "refusals": rep, "flags": sorted(flags)}


def start_commit(ep):
    path = os.path.join(ep, "state", "git", "start-commit")
    return open(path).read().strip() if os.path.exists(path) else None


def replay_episode(record_dir, harness, work):
    meta = json.load(open(os.path.join(record_dir, "meta.json")))
    todo = steps(modellog.calls(modellog.read(os.path.join(record_dir, "state", "model", "requests.jsonl"))))
    ep = os.path.join(work, secrets.token_hex(6))
    build(harness, meta, ep)
    replay_meta = json.load(open(os.path.join(ep, "meta.json")))
    seeds = [(start_commit(record_dir), start_commit(ep))]
    ids, commands, by_session, standin, started = Ids(p for p in seeds if None not in p), [], {}, None, time.time()
    try:
        for step in todo:
            flags = []
            if standin is None or standin.proc.poll() is not None:
                if standin is not None:
                    flags.append("stand-in-restarted")
                standin = StandIn(harness, ep, meta["project"])
            text, unmapped = ids.substitute(step.text)
            flags += unmapped
            req = {"op": step.op, "id": step.session, "wait": wait_for(step)}
            req.update({"cmd": text, "workdir": step.workdir, "login": step.login, "tty": step.tty}
                       if step.op == "exec" else {"chars": text})
            reply = standin.ask(req) or {"exit": None, "output": "", "error": "stand-in died"}
            if reply.get("error"):
                flags.append("no-session" if reply["error"] == "unknown session" else reply["error"])
            command = by_session.get(step.session) if step.op == "poll" else None
            if command is None:
                command = Command(step, text)
                commands.append(command)
                by_session[step.session] = command
            command.add(step, reply, flags)
            ids.learn(command.recorded_text, command.text)
    finally:
        if standin is not None:
            standin.end()
        subprocess.run([os.path.join(harness, "eval", "env", "down.sh"), ep], capture_output=True)
    out = [c.record() for c in commands]
    rec_push, rec_cross = log_refusals(record_dir)
    rep_push, rep_cross = log_refusals(ep)
    return {"episode": os.path.basename(record_dir.rstrip("/")), "family": meta["family"],
            "variant": meta["variant"], "arm": meta["arm"], "seed": meta["seed"], "blind": BLIND,
            "harness_commit": replay_meta.get("harness_commit"), "replay_dir": ep,
            "seconds": round(time.time() - started, 1), "calls": len(todo), "commands_run": len(out),
            "recorded": counts(out, "recorded_refusals", rec_push), "replayed": counts(out, "refusals", rep_push),
            "unobserved": unobserved(out),
            "cross": {"recorded": {**rec_cross, "remote_lines": sum("remote" in c["recorded_refusals"] for c in out)},
                      "replayed": {**rep_cross, "remote_lines": sum("remote" in c["refusals"] for c in out)}},
            "flags": dict(collections.Counter(f for c in out for f in c["flags"])), "commands": out}


# --- the tables ------------------------------------------------------------------------------------------------------

def per_chore(rows, side):
    """Counts per chore, recomputed from each row's commands under the current counting rule."""
    c = collections.defaultdict(collections.Counter)
    for r in rows:
        c[r["family"]].update(unobserved(r["commands"]) if side == "unobserved" else
                              counts(r["commands"], {"recorded": "recorded_refusals", "replayed": "refusals"}[side],
                                     pushes(r, side)))
    return c


def table(rows, other=None):
    """Refusals per chore, recorded against replayed (and against a second replay), then by kind."""
    rec, rep, left = per_chore(rows, "recorded"), per_chore(rows, "replayed"), per_chore(rows, "unobserved")
    alt = per_chore(other, "replayed") if other else None
    lines = [f"_{BLIND}_", "", "| chore | episodes | recorded | replayed | difference | left out |"
             + (" second replay |" if alt else ""), "|---|---|---|---|---|---|" + ("---|" if alt else "")]
    worst = 0.0
    for fam in sorted(rec.keys() | rep.keys()):
        a, b = sum(rec[fam].values()), sum(rep[fam].values())
        diff = (b - a) / a if a else (0.0 if b == 0 else float("inf"))
        worst = max(worst, abs(diff))
        n = sum(r["family"] == fam for r in rows)
        lines.append(f"| {fam} | {n} | {a} | {b} | {diff:+.1%} | {sum(left[fam].values())} |"
                     + (f" {sum(alt[fam].values())} |" if alt else ""))
    lines += ["", "| chore | kind | recorded | replayed |" + (" second replay |" if alt else ""),
              "|---|---|---|---|" + ("---|" if alt else "")]
    for fam in sorted(rec.keys() | rep.keys()):
        for kind in sorted(rec[fam].keys() | rep[fam].keys() | (alt[fam].keys() if alt else set())):
            lines.append(f"| {fam} | {kind} | {rec[fam][kind]} | {rep[fam][kind]} |"
                         + (f" {alt[fam][kind]} |" if alt else ""))
    flags = collections.Counter()
    for r in rows:
        flags.update(r["flags"])
    lines += ["", "flags: " + ", ".join(f"{k} {v}" for k, v in flags.most_common()),
              f"largest per-chore difference: {worst:.1%}"]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("verdicts", nargs="?")
    ap.add_argument("--episodes")
    ap.add_argument("--harness", default=os.path.dirname(HERE))
    ap.add_argument("--only", default="")
    ap.add_argument("--out")
    ap.add_argument("--work")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--table", nargs="+")
    a = ap.parse_args()
    if a.table:
        rows = [read_jsonl(p) for p in a.table]
        print(table(rows[0], rows[1] if len(rows) > 1 else None))
        return 0
    if not (a.verdicts and a.episodes):
        ap.error("give <verdicts.jsonl> and --episodes, or --table")
    harness = os.path.abspath(a.harness)
    out = a.out or f"replay-{subprocess.run(['git', '-C', harness, 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()}.jsonl"
    work = a.work or tempfile.mkdtemp(prefix="replay-")
    os.makedirs(work, exist_ok=True)
    only = set(filter(None, a.only.split(",")))
    done = {r["episode"] for r in read_jsonl(out)}
    todo, missing = [], []
    for v in sorted(read_jsonl(a.verdicts), key=lambda v: v["arm"] == "A"):  # the harness arms first
        ep = v["episode"]
        if (only and ep not in only) or ep in done:
            continue
        d = os.path.join(a.episodes, ep)
        (todo if os.path.exists(os.path.join(d, "state", "model", "requests.jsonl")) else missing).append(d)
    if missing:
        print(f"replay: no requests.jsonl for {len(missing)}: " + " ".join(map(os.path.basename, missing)), file=sys.stderr)
    print(f"replay: {len(todo)} episodes against {harness}, {len(done)} already in {out}; {BLIND}", file=sys.stderr)
    with concurrent.futures.ThreadPoolExecutor(a.parallel) as pool, open(out, "a") as f:
        futures = {pool.submit(replay_episode, d, harness, work): d for d in todo}
        for fut in concurrent.futures.as_completed(futures):
            d = os.path.basename(futures[fut])
            try:
                row = fut.result()
            except Exception as e:  # noqa: BLE001 - one episode's failure is reported, the rest go on
                print(f"replay: {d} failed: {e}", file=sys.stderr)
                continue
            f.write(json.dumps(row) + "\n")
            f.flush()
            print(f"replay: {d} {row['family']} {row['variant']} {row['arm']} seed {row['seed']}: recorded "
                  f"{sum(row['recorded'].values())} replayed {sum(row['replayed'].values())} refusals, "
                  f"{row['commands_run']} commands, {row['seconds']} s", file=sys.stderr)
    print(table(read_jsonl(out)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
