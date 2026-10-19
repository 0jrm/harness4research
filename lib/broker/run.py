"""guard run behind the broker (design-v8 sections 2 to 6): the run verb's handle(request, broker), and redecide(broker,
effect), which lib/broker/asks.py calls when a person answers an effect ask yes.

    {verb: run, run_dir, why, cause?, options[], script, args[], cwd}

The broker reads the script's bytes through its path map (git never runs in the agent's checkout), fetches main into
its mirror, reads guard/budget.card there, parses the options and #SBATCH lines itself, gathers the view (the job log,
sacct and squeue for this session's jobs, the watched paths, the open asks, the launch host), and asks
policy.decide what to do. Nothing the agent sends is trusted as a number.

    run     the run's card (runs/<run_id>/question.card on run/<run_id>, written once) and the job log's intent row
            are written first, then sbatch or the host supervisor, then the job id; an incident first when --cause
            answers a failed job
    refuse  two lines and exit 2; the second identical per-job overage becomes an effect ask instead (question 11)
    queue   an effect ask with the default no (lib/broker/asks.py), two lines and exit 3

Every refusal and queue is a row of <state>/refusals.jsonl: guard status reads its last one, the repeat check reads the
key, and redecide reads the queued request back. Without a broker (local mode) the card and incidents are commits with
no signature, and the card says so."""
import dataclasses
import importlib
import json
import os
import re
import shlex
import subprocess
import tempfile
import time

import refusals
from broker.records import IDENT, Refused, read_rows
from broker.scheduler import JOB_ID
from policy import Cost, HostView, Request
from policy.cost import CardError, cost, limits as read_limits
from policy.decide import (ENDED_BADLY, LIMIT_CODES, R08_MORE, RunView, ViewJob, backend, decide, hours, known_options,
                           line)
from policy.invocation import Unparsed, parse, run_line, to_minutes

KEYS = ("verb", "run_dir", "why", "cause", "options", "script", "args", "cwd")
LIVE = ("PENDING", "RUNNING", "REQUEUED", "SUSPENDED", "CONFIGURING", "COMPLETING", "RESIZING")
CARD_KEYS = ("minutes", "nodes", "cores", "gpus", "tasks", "core_hours", "gpu_hours")


def handle(request, broker):
    with broker.lock:
        asks = optional("asks")
        if asks is not None:
            asks.settle(broker)
        return run(broker, request)


def redecide(broker, effect):
    """A person's yes to a submit ask: the queued guard run, decided again now against the pinned script and spec. The
    caller (asks.settle) holds broker.lock."""
    queued = [r for r in read_rows(refusals_path(broker)) if r.get("request") and r.get("run_id") == effect.get("run_id")
              and r.get("script_sha256") == effect.get("script_sha256") and r.get("spec") == effect.get("spec")]
    if not queued:
        raise Refused(f"no queued guard run of run {effect.get('run_id')} matches this ask")
    asks = optional("asks")
    pending = next((a for a in (asks.open_asks(broker) if asks else ()) if a.get("effect") == effect), {"id": "yes"})
    return run(broker, queued[-1]["request"], yes={**pending, "answer": "yes", "effect": effect})


# the request -------------------------------------------------------------------------------------------------------
def request_of(req):
    """The Request the agent's process sent, or Unparsed: the wire carries only what the agent typed."""
    extra = set(req) - set(KEYS)
    if extra:
        raise Unparsed(f"the request carries {', '.join(sorted(extra))}, which guard run does not send")
    strs = {k: req.get(k) for k in ("run_dir", "why", "script", "cwd")}
    lists = {k: req.get(k) or [] for k in ("options", "args")}
    cause = req.get("cause")
    if not all(isinstance(v, str) for v in strs.values()) or not isinstance(cause, (str, type(None))) \
            or not all(isinstance(v, list) and all(isinstance(w, str) for w in v) for v in lists.values()):
        raise Unparsed("run_dir, why, script and cwd are strings, options and args lists of strings")
    if "\n" in (cause or ""):
        raise Unparsed("--cause is one line")
    return Request("run", strs["run_dir"], strs["why"], cause or None, tuple(lists["options"]), strs["script"],
                   tuple(lists["args"]), strs["cwd"])


def usage_line(r, limits_):
    """R01's line 2: the agent's command with what guard run cannot take dropped and a walltime stated."""
    options = known_options(list(r.options))
    if limits_ and not any(w.split("=")[0] in ("--time", "-t") or (w.startswith("-t") and len(w) > 2) for w in options):
        options.append(f"--time={limits_.max_walltime_minutes}")
    run_dir = r.run_dir if r.run_dir.strip() else "runs/job"
    try:
        return run_line(run_dir, options, r.script or "job.sh", r.args, r.why if r.why and "\n" not in r.why else None)
    except Exception:
        return "guard status"


def r01(what, next_line):
    try:
        return refusals.refuse("R01", what=what, next=next_line)
    except ValueError:
        return refusals.refuse("R01", what=what, next="guard status")


# the run -----------------------------------------------------------------------------------------------------------
def run(broker, req, yes=None):
    session, ts = broker.cfg["session"], time.time()
    try:
        r = request_of(req)
    except Unparsed as e:
        return refusals.reply(r01(str(e), "guard status"))
    try:
        broker.mirror.fetch()
        card = broker.mirror.show("guard/budget.card")
        if card is None:
            raise Refused("no guard/budget.card on main")
        lim = read_limits(card)
    except (Refused, CardError) as e:
        return {"rc": 1, "err": f"guard broker: refused: {e}\n"}
    project = broker.cfg["project"]
    cwd = os.path.normpath(r.cwd or project)
    inside = lambda p: p == project or p.startswith(project + "/")
    script_in = os.path.normpath(os.path.join(cwd, r.script))
    data = read_script(broker, script_in) if inside(script_in) else None
    try:
        inv, spec = parse(r, data or b"", session, ts)
    except Unparsed as e:
        if data is None and r.script:
            return refused(broker, refusals.refuse("R07", "missing", next="guard status", script=r.script), r)
        return refused(broker, r01(str(e), usage_line(r, lim)), r)
    view, failed = gather(broker, inv, lim, data is not None, inside(os.path.normpath(os.path.join(cwd, r.run_dir))),
                          yes)
    b = backend(lim, view)
    c = cost(spec, lim, b)
    d = decide(inv, spec, c, lim, view)
    if d.verdict == "refuse":
        if d.code in LIMIT_CODES and yes is None and optional("asks") and repeated(broker, d.code, inv):
            return ask(broker, inv, spec, lim, r, "limit", question=over_question(d.code, inv, spec), reason=d.reason)
        return refused(broker, refusals.Refusal(d.code, d.reason, d.next), r, inv)
    if d.verdict == "queue":
        return ask(broker, inv, spec, lim, r, None, decision=d,
                   question=f"run {inv.run_id}: submit {hours(c.core_hours)} core-h? {inv.why}")
    return submit(broker, inv, spec, c, lim, b, r, cwd, script_in, failed)


def read_script(broker, script_in):
    try:
        path = broker.tree().inside(broker.outside(script_in))
    except Refused:
        return None
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def over_question(code, inv, spec):
    what = {"R02": f"{spec.time_min} min", "R03": f"{spec.nodes} nodes", "R04": f"{spec.gpus} GPUs"}.get(code)
    return f"allow {what} for run {inv.run_id}?" if what else f"allow this host job for run {inv.run_id}?"


# records -----------------------------------------------------------------------------------------------------------
def refusals_path(broker):
    return os.path.join(broker.dir, "refusals.jsonl")


def log_refusal(broker, rf, r, inv=None, **more):
    row = {"ts": time.time(), "session": broker.cfg["session"], "socket": "scheduler", "verb": "run", "code": rf.code,
           "reason": rf.reason, "run_id": inv.run_id if inv else None,
           "script_sha256": inv.script_sha256 if inv else None, "options": list(r.options), "args": list(r.args),
           **more}
    with open(refusals_path(broker), "a") as f:
        f.write(json.dumps(row) + "\n")


def refused(broker, rf, r, inv=None):
    log_refusal(broker, rf, r, inv)
    return refusals.reply(rf)


def repeated(broker, code, inv):
    return any(row.get("code") == code and row.get("run_id") == inv.run_id
               and row.get("script_sha256") == inv.script_sha256 and row.get("options") == list(inv.options)
               and row.get("args") == list(inv.args) and row.get("session") == inv.session
               for row in read_rows(refusals_path(broker)))


def ask(broker, inv, spec, lim, r, variant, question, decision=None, reason=None):
    """R08: the effect ask the broker makes (default no), and its two lines; X00 where lib/broker/asks.py is absent."""
    try:
        asks = importlib.import_module("broker.asks")
    except ModuleNotFoundError as e:
        if e.name != "broker.asks":
            raise
        return refusals.reply(refusals.refuse("X00", verb="guard ask, which R08 queues on,"))
    spec_d = dataclasses.asdict(spec)
    a = asks.open_effect(broker, inv.run_id) or asks.create_effect(broker, "submit", inv.run_id, question,
                                                                    inv.script_sha256, spec_d, lim.ask_deadline)
    due = asks.clock(a["due_ts"]).removesuffix(" UTC")
    text = decision.reason if decision else R08_MORE[variant].format(reason=reason, ask="{ask}", due="{due}")
    rf = refusals.Refusal("R08", text.format(ask=a["id"], due=due), "guard status")
    log_refusal(broker, rf, r, inv, request=dataclasses.asdict(r), spec=spec_d, ask=a["id"])
    return refusals.reply(rf)


def commit(broker, run_id, path, text, message):
    """A record on run/<run_id>: signed by the broker's key, or, in local mode with no key, an unsigned commit."""
    if broker.cfg.get("signing_key"):
        return broker.records.commit(run_id, path, text, message)
    git = broker.mirror.git
    parent = broker.records.tip(run_id) or git("rev-parse", "refs/heads/main").stdout.strip()
    blob = git("hash-object", "-w", "--stdin", input=text).stdout.strip()
    with tempfile.TemporaryDirectory() as tmp:
        env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
        git("read-tree", parent, env=env)
        git("update-index", "--add", "--cacheinfo", f"100644,{blob},{path}", env=env)
        tree = git("write-tree", env=env).stdout.strip()
    sha = git("commit-tree", "-p", parent, "-m", message, tree, env=IDENT).stdout.strip()
    pushed = git("push", "-q", broker.mirror.origin, f"{sha}:refs/heads/run/{run_id}")
    if pushed.returncode:
        raise Refused(f"origin refused run/{run_id}: {pushed.stderr.strip()[-300:]}")
    return sha


def write_card(broker, inv, c):
    """runs/<run_id>/question.card, the CardRecord, from the run's first job; kept as it is after that."""
    path, tip = f"runs/{inv.run_id}/question.card", broker.records.tip(inv.run_id)
    if (tip and broker.records.blob(tip, path) is not None) or broker.mirror.show(path) is not None:
        return
    local = not broker.cfg.get("signing_key")
    cr = dataclasses.asdict(c)
    rows = [("why", inv.why), ("command", line(inv, inv.options)), ("backend", c.backend),
            *((k, cr[k]) for k in CARD_KEYS), ("session", inv.session),
            ("written_by", "guard run, local, unsigned" if local else "guard broker, from the guard run invocation")]
    commit(broker, inv.run_id, path, "".join(f"{k}: {'' if v is None else v}\n" for k, v in rows),
           f"run: {inv.run_id} card\n\nWritten by guard run for session {inv.session}.")


def write_incident(broker, inv, jobs):
    """The agent's --cause for this session's failed jobs, as runs/<run_id>/incidents/<n>.md on each job's run."""
    path = os.path.join(broker.dir, "incidents.jsonl")
    for run_id in sorted({j.run_id for j in jobs}):
        ids = [j.job_id for j in jobs if j.run_id == run_id]
        n = 1 + sum(r["run"] == run_id for r in read_rows(path)) + sum(
            p.startswith(f"runs/{run_id}/incidents/") for p in broker.mirror.files)
        commit(broker, run_id, f"runs/{run_id}/incidents/{n}.md", "".join(f"job: {j}\n" for j in ids) + f"\n{inv.cause}\n",
               f"run: {run_id} incident {n}\n\nRecorded by guard run --cause for session {inv.session}.")
        with open(path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "run": run_id, "jobs": ids, "cause": inv.cause,
                                "session": inv.session}) + "\n")


# the view ----------------------------------------------------------------------------------------------------------
def optional(name):
    try:
        return importlib.import_module(f"broker.{name}")
    except ModuleNotFoundError as e:
        if e.name != f"broker.{name}":
            raise
        return None


def handled(broker):
    """Job ids an incident answers: guard run --cause's, and runs/*/incidents/*.md on main."""
    seen = {j for r in read_rows(os.path.join(broker.dir, "incidents.jsonl")) for j in r["jobs"]}
    for p in broker.mirror.files:
        if p.startswith("runs/") and "/incidents/" in p and p.endswith(".md"):
            seen |= {m.group(1) for m in re.finditer(r"(?m)^job: *([0-9A-Za-z_.-]+) *$", broker.mirror.show(p) or "")}
    return seen


def expand(output, job_id, run_id):
    base, _, task = job_id.partition("_")
    sub = {"%%": "%", "%j": job_id, "%A": base, "%a": task or "4294967294", "%x": run_id}
    return re.sub(r"%[%jAax]", lambda m: sub[m.group()], output)


def slurm_states(broker, ids):
    """{job id: the state word} from sacct, an array's tasks folded into the job: live if any task is, else failed if
    any ended badly."""
    if not ids or not broker.cfg.get("slurm_bin"):
        return {}
    rc, out, _ = broker.slurm("sacct", "-X", "-n", "-P", "-o", "JobID,State", "--jobs=" + ",".join(ids))
    states = {}
    for row in out.splitlines() if rc == 0 else []:
        jid, _, state = row.partition("|")
        word = (state.split() or [""])[0].rstrip("+")
        word = "OUT_OF_MEMORY" if word.startswith("OUT_OF_ME") else word
        key = jid.split("_")[0] if jid.split("_")[0] in ids and jid not in ids else jid
        old = states.get(key)
        rank = lambda w: 2 if w in LIVE else 1 if w in ENDED_BADLY else 0
        if old is None or rank(word) > rank(old):
            states[key] = word
    return states


def job_rows(broker, session):
    """This session's jobs as ViewJobs, oldest first."""
    rows = [r for r in broker.rows if r.get("session") == session]
    outcome = {r["seq"]: r for r in rows if r["state"] != "intent"}
    intents = [r for r in rows if r["state"] == "intent"]
    ids = [outcome[r["seq"]]["job"] for r in intents
           if outcome.get(r["seq"], {}).get("state") == "submitted" and r.get("backend", "slurm") == "slurm"]
    states = slurm_states(broker, ids)
    host = optional("host")
    out = []
    for r in intents:
        o = outcome.get(r["seq"], {})
        job = o.get("job")
        if job and r.get("backend", "slurm") == "host":
            got = host.state(job) if host and hasattr(host, "state") else ""
            word = (got.get("state") if isinstance(got, dict) else got) or ""
        else:
            word = states.get(job, "") if job else ""
        if o.get("state") == "submitted" and not word:
            word = "PENDING"
        log = os.path.join(r["cwd"], expand(r["output"], job, r["run"])) if job and r.get("output") else ""
        out.append(ViewJob(seq=r["seq"], job_id=job, run_id=r["run"], backend=r.get("backend", "slurm"),
                           state=o.get("state", "intent"), submitted_ts=o.get("ts", r["ts"]), why=r.get("why", ""),
                           cost=Cost(**r["cost"]) if r.get("cost") else None, comment=r["comment"],
                           script_sha256=r.get("script_sha256", ""), options=tuple(r.get("options") or ()),
                           args=tuple(r.get("args") or ()), log=log, sched_state=word))
    return out


def budget(broker, lim):
    """(spent, queued) core-hours on the account since start_date, as the scheduler reports them."""
    if not broker.cfg.get("slurm_bin"):
        return 0.0, 0.0
    user = broker.cfg["user"]
    spent = sum(int(x or 0) for x in broker.must("sacct", "-A", lim.account, "-u", user, "-S", lim.start_date, "-X",
                                                 "-n", "-P", "-o", "CPUTimeRAW").split()) / 3600
    queued = 0
    for row in broker.must("squeue", "-A", lim.account, "-u", user, "-h", "-t", "PENDING", "-o", "%C %l").splitlines():
        cores, _, limit = row.partition(" ")
        queued += int(cores or 0) * (to_minutes(limit.strip()) or 0) / 60
    return spent, queued


def host_view(broker, lim):
    if not lim.launch_hosts:
        return None, 0.0
    host = optional("host")
    if host is not None and hasattr(host, "view"):
        return host.view(broker, lim), host.spent_gpu_hours(broker, lim)
    name = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
    return HostView(name=name, in_launch_hosts=name in lim.launch_hosts, available_gb=0.0), 0.0


def gather(broker, inv, lim, script_exists, run_dir_in_project, yes):
    """(the view decide() reads, this session's failed jobs no incident answers yet)."""
    jobs = job_rows(broker, inv.session)
    done = handled(broker)
    failed = [j for j in jobs if j.job_id and j.sched_state in ENDED_BADLY and j.job_id not in done]
    run_jobs = {}
    for j in jobs:
        run_jobs.setdefault(j.run_id, []).append(j)
    ignore = [l.strip() for l in (broker.mirror.show(".gitignore") or "").splitlines()
              if l.strip() and not l.startswith(("#", "!"))]
    watch = [l.split("#")[0].strip() for l in (broker.mirror.show("guard/watch.list") or "").splitlines()]
    asks = optional("asks")
    spent, queued = budget(broker, lim)
    host, gpu_spent = host_view(broker, lim)
    view = RunView(spent_core_hours=spent, queued_core_hours=queued, spent_gpu_hours=gpu_spent,
                   live_jobs=tuple(j for j in jobs if j.sched_state in LIVE),
                   run_jobs={k: tuple(v) for k, v in run_jobs.items()},
                   last_failed_job=failed[-1] if failed else None,
                   changed_paths_vs_main=tuple(broker.tree().changed(broker.mirror, ["guard", *filter(None, watch)],
                                                                     ignore)),
                   script_exists=script_exists, run_dir_in_project=run_dir_in_project,
                   open_asks=tuple(a for a in (asks.open_asks(broker) if asks else ()) if not yes or a["id"] != yes["id"])
                   + ((yes,) if yes else ()),
                   host=host, project=broker.cfg["project"])
    return view, failed


# the submission ----------------------------------------------------------------------------------------------------
def submit(broker, inv, spec, c, lim, b, r, cwd, script_in, failed):
    if b == "slurm" and not broker.cfg.get("slurm_bin"):
        return refused(broker, refusals.refuse("R07", "sbatch", next="guard status", line="no sbatch on this host"),
                       r, inv)
    try:
        if inv.cause and failed:
            write_incident(broker, inv, failed)
        write_card(broker, inv, c)
    except Refused as e:
        return {"rc": 1, "err": f"guard broker: refused: {e}\n"}
    seq = 1 + sum(row["state"] == "intent" for row in broker.rows)
    comment = f"guard:{inv.session}:{seq}"
    output = spec.output or ("slurm-%A_%a.out" if spec.array else "slurm-%j.out")
    row = {"seq": seq, "state": "intent", "run": inv.run_id, "run_id": inv.run_id, "comment": comment, "backend": b,
           "why": inv.why,
           "cost": dataclasses.asdict(c), "script_sha256": inv.script_sha256, "options": list(inv.options),
           "args": list(inv.args), "cwd": cwd, "output": output}
    if b == "host":
        return launch_host(broker, inv, spec, c, row, r, script_in)
    spool = os.path.join(broker.dir, "spool", str(seq))
    os.makedirs(spool, exist_ok=True)
    wrapper = os.path.join(spool, "job.sh")
    shown = re.sub(r"%[%jAax]", lambda m: {"%%": "%", "%j": "${SLURM_JOB_ID}", "%A": "${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}",
                                           "%a": "${SLURM_ARRAY_TASK_ID:-4294967294}", "%x": inv.run_id}[m.group()], output)
    with open(wrapper, "w") as f:
        f.write(f"#!/bin/bash\n# guard broker job {comment}, run {inv.run_id}: {script_in}, output {output}\n"
                f"export GUARD_JOB_ID=$SLURM_JOB_ID\n"
                f'exec >"{shown}" 2>&1 || exit 1\nexec bash {shlex.quote(script_in)} "$@"\n')
    bare = None if broker.cfg.get("compute_bwrap", True) else "the compute nodes have no bwrap"
    bare = "a multi-node job" if spec.nodes > 1 else bare
    extra = shlex.split(lim.extra_sbatch) if "<" not in lim.extra_sbatch else []
    asked = [f"--{k}={v}" for k, v in (("ntasks", spec.tasks), ("cpus-per-task", spec.cpus_per_task),
                                        ("mem", f"{spec.mem_gb}G" if spec.mem_gb else None),
                                        ("gpus", spec.gpus or None), ("array", spec.array),
                                        ("dependency", spec.dependency), ("partition", spec.partition)) if v]
    argv = (["--export=NONE", "--ignore-pbs", "--parsable", *asked, *extra, f"--account={lim.account}",
             f"--job-name={inv.run_id}", f"--comment={comment}", f"--time={spec.time_min}", f"--nodes={spec.nodes}",
             f"--chdir={cwd}", f"--output={spool}/slurm-%j.out", wrapper, *inv.args])
    broker.write({**row, "argv": argv, "job_sandbox": "bare" if bare else "bwrap", "why_bare": bare})
    rc, out, err = broker.slurm("sbatch", *argv)
    job = out.strip().split(";")[0]
    if rc or not JOB_ID.match(job):
        said = (err.strip() or out.strip() or f"exit {rc}").splitlines()[0]
        broker.write({"seq": seq, "state": "failed", "why": said})
        return refused(broker, refusals.refuse("R07", "sbatch", next="guard status", line=said[:200]), r, inv)
    broker.write({"seq": seq, "state": "submitted", "job": job, "job_id": job})
    tasks = f" x {spec.array_n} tasks" if spec.array_n > 1 else ""
    return {"rc": 0, "out": f"job {job} submitted for run {inv.run_id}: {c.minutes} min x {c.nodes} node(s) x "
                            f"{lim.cores_per_node} cores{tasks} = {hours(c.core_hours)} core-h; guard wait {job}\n"}


def launch_host(broker, inv, spec, c, row, r, script_in):
    """The host backend: lib/broker/host.py's launch under the supervisor (U8); R14 when it does not start."""
    host = optional("host")
    broker.write(row)
    try:
        if host is None or not hasattr(host, "launch"):
            raise Refused("lib/broker/host.py is not in this harness")
        job = host.launch(broker, spec, broker.outside(os.path.join(row["cwd"], f"runs/{inv.run_id}")),
                          [broker.outside(script_in), *inv.args])
    except Refused as e:
        broker.write({"seq": row["seq"], "state": "failed", "why": str(e)})
        return refused(broker, refusals.refuse("R14", "supervisor", next="guard status", reason=str(e)[:200]), r, inv)
    broker.write({"seq": row["seq"], "state": "submitted", "job": job, "job_id": job})
    return {"rc": 0, "out": f"job {job} launched for run {inv.run_id}: {c.minutes} min x {c.cores} cores x {c.gpus} "
                            f"GPUs = {hours(c.core_hours)} core-h, {hours(c.gpu_hours)} GPU-h; guard wait {job}\n"}
