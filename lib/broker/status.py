"""The broker's half of guard status: the facts the sandbox cannot read, as one JSON object in the reply's out.

    {"verb": "status"}             -> {"running": [{"id", "run", "state", "elapsed", "limit", "backend"}],
                                       "blocked": [str: needs-you items, then asks.short lines],
                                       "refusal": {"ago_min", "where", "why"}|null,
                                       "budget": {"spent", "queued", "max", "reserve"}|null,
                                       "failed": {"id", "run", "state"}|null, "unsigned": bool,
                                       "receipts": str (receipts.status_line)}
    {"verb": "status", "job": "12"} -> {"mine": true|false|null}   (lib/wait.py's W02 check: another session's job)

It runs sacct and squeue through the scheduler, fetches main, and reads the job log, the mirror's card and the
needs-you queue. asks.report adds guard ask's open asks and the outcomes the agent has not yet seen, and marks those
seen, so a status call is not read-only. Local mode (no broker, session "local") answers it too, and says unsigned."""
import json
import os
import time

import needs_you
from broker import asks, receipts
from broker.records import Refused, read_rows
from policy.cost import CardError, limits
from policy.invocation import to_minutes

LIVE = ("PENDING", "CONFIGURING", "RUNNING", "COMPLETING", "SUSPENDED", "REQUEUED")
FAILED = ("TIMEOUT", "OUT_OF_ME", "NODE_FAIL", "FAILED", "PREEMPTED")
HOST_LIVE = ("running",)


def job_rows(broker):
    """This session's job-log rows as (job id, run id, backend, row) for every job the log shows submitted."""
    rows = [r for r in broker.rows if r.get("session", broker.cfg["session"]) == broker.cfg["session"]]
    intents = {r["seq"]: r for r in rows if r.get("state") == "intent"}
    out = []
    for r in rows:
        job = r.get("job") or r.get("job_id")
        if r.get("state") == "submitted" and job and r.get("seq") in intents:
            i = intents[r["seq"]]
            out.append((str(job), i.get("run") or i.get("run_id") or "", i.get("backend") or "slurm", i))
    return out


def host_state(job):
    """A host job's state from lib/broker/host.py, when this harness has it; None when it has not."""
    try:
        from broker import host
        got = host.state(job)
    except (ImportError, AttributeError, OSError, ValueError):
        return None
    return got.get("state") if isinstance(got, dict) else got


def spend(broker, card):
    """(core-hours spent since start_date, core-hours queued) for the card's account, as the scheduler reports them."""
    user, acct = broker.cfg["user"], card.account
    rc, out, _ = broker.slurm("sacct", "-A", acct, "-u", user, "-S", card.start_date, "-X", "-n", "-P", "-o",
                              "CPUTimeRAW")
    spent = sum(int(x or 0) for x in out.split() if x.isdigit()) // 3600 if rc == 0 else 0
    rc, out, _ = broker.slurm("squeue", "-A", acct, "-u", user, "-h", "-t", "PENDING", "-o", "%C %l")
    queued = 0
    for line in out.splitlines() if rc == 0 else []:
        cores, _, limit = line.partition(" ")
        if cores.isdigit():
            queued += int(cores) * (to_minutes(limit.strip()) or 0)
    return spent, queued // 60


def scheduler_jobs(broker, ids):
    """sacct's view of ids: {job id: (run, state, elapsed, limit)}."""
    if not ids or not broker.cfg.get("slurm_bin"):
        return {}
    rc, out, _ = broker.slurm("sacct", "-X", "-n", "-P", "-o", "JobID,JobName,State,Elapsed,Timelimit",
                              "--jobs=" + ",".join(ids))
    rows = [line.split("|") for line in out.splitlines() if line.count("|") == 4] if rc == 0 else []
    return {r[0]: (r[1], r[2].split()[0] if r[2] else "", r[3], r[4]) for r in rows}


def incident_jobs(broker):
    """Job ids an incident file on main already names."""
    import re
    seen = set()
    for p in getattr(broker.mirror, "files", {}):
        if "/incidents/" in p and p.endswith(".md"):
            seen |= {m.group(1) for m in re.finditer(r"(?m)^job: *([0-9A-Za-z_.-]+) *$", broker.mirror.show(p) or "")}
    return seen


def last_refusal(broker):
    rows = []
    for path in (broker.records.log_path, os.path.join(broker.dir, "refusals.jsonl")):
        for r in read_rows(path):
            why = r.get("refused") or r.get("why") or (f"{r['code']} {r.get('reason', '')}".strip() if r.get("code") else "")
            if why:
                rows.append((r.get("ts", 0), r.get("socket") or r.get("store") or "scheduler", str(why).strip()))
    if not rows:
        return None
    ts, where, why = max(rows)
    return {"ago_min": max(0, round((time.time() - ts) / 60)), "where": where, "why": why}


def facts(broker):
    try:
        broker.mirror.fetch()
    except Refused:
        pass  # main as last fetched, or nothing: the budget line then says it could not read the card
    rows = job_rows(broker)
    slurm = scheduler_jobs(broker, [j for j, _, b, _ in rows if b != "host"])
    running, failed = [], None
    for job, run, backend, _ in rows:
        if backend == "host":
            state = host_state(job)
            if state in HOST_LIVE:
                running.append({"id": job, "run": run, "state": "RUNNING", "elapsed": "", "limit": "", "backend": "host"})
            continue
        if job not in slurm:
            continue
        name, state, elapsed, limit = slurm[job]
        if state in LIVE:
            running.append({"id": job, "run": name or run, "state": state, "elapsed": elapsed, "limit": limit,
                            "backend": "slurm"})
        elif any(state.startswith(f) for f in FAILED):
            failed = {"id": job, "run": name or run, "state": state}
    if failed and failed["id"] in incident_jobs(broker):
        failed = None
    blocked = [f"needs-you {it.id} waits for a person: {it.title}" for it in needs_you.read(broker.records.queue)
               if it.state in ("open", "acked") and not it.id.startswith("a")]
    blocked += asks.report(broker, asks.short)  # last, so the 190-character cut of the line takes asks first
    budget = None
    try:
        card = limits((broker.mirror.show("guard/budget.card") if hasattr(broker.mirror, "files") else None) or "")
        spent, queued = spend(broker, card)
        budget = {"spent": spent, "queued": queued, "max": card.max_core_hours,
                  "reserve": card.verification_reserve_core_hours}
    except CardError:
        pass
    try:
        receipt_line = receipts.status_line(broker)
    except Exception:  # the ref is unreachable or the mirror is mid-fetch: say so, never fail the status
        receipt_line = "receipts: not readable now"
    return {"receipts": receipt_line, "running": running, "blocked": blocked, "refusal": last_refusal(broker), "budget": budget,
            "failed": failed, "unsigned": broker.cfg.get("session") == "local"}


def handle(request, broker):
    if "job" in request:
        job = str(request["job"])
        found = [r for r in broker.rows if str(r.get("job") or r.get("job_id")) == job.split("_")[0]]
        if not found:
            mine = None
        else:
            mine = all(r.get("session", broker.cfg["session"]) == broker.cfg["session"] for r in found)
        return {"rc": 0, "out": json.dumps({"mine": mine})}
    with broker.lock:
        return {"rc": 0, "out": json.dumps(facts(broker))}
