"""backend() and decide(): the pure end of the policy pipeline (design-v8 section 3). Nothing here reads a file, a
clock or a socket; every input a rule needs is in the Invocation, the SbatchSpec, the Cost, the Limits or the view.

    backend(limits, view)                  -> "slurm" | "host"
    decide(inv, spec, cost, limits, view)  -> Decision

A refusal's line 2 is the agent's own guard run line with the one flag fixed, so pasting it is the next step. The
rules run in RULES order; the first that answers wins. A per-job overage (R02, R03, R04, R13) is a refusal; the broker
turns the second identical one into an ask (question 11). R08 is a queue: the broker makes the ask and fills {ask}
and {due} in the reason.

An effect ask in view.open_asks answered yes, for this run, script and spec, is the human's approval: it lifts R08
(the budget, the run's cap, approval: queue) and nothing else, so a yes to a repeated per-job overage is answered by
that refusal again (coordinator, 2026-10-19). One still unanswered for this run queues the run again on that ask."""
import dataclasses
import datetime as dt
import shlex
from dataclasses import dataclass

import refusals
from policy import Decision, JobRow, LedgerView
from policy.invocation import Unparsed, read_options

ENDED_BADLY = ("TIMEOUT", "FAILED", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED")
LIMIT_CODES = ("R02", "R03", "R04", "R13")
# guard run's flags, each as (long, short): what line 2 removes before it sets the fixed value.
FLAG = {"time": ("--time", "-t"), "nodes": ("--nodes", "-N"), "gpus": ("--gpus", "-G"), "mem": ("--mem", None),
        "partition": ("--partition", "-p"), "array": ("--array", "-a"), "dependency": ("--dependency", "-d"),
        "ntasks": ("--ntasks", "-n"), "output": ("--output", "-o")}
SLURM_ONLY = ("nodes", "ntasks", "partition", "array", "dependency")
# R08 lines lib/refusals.py does not have yet (a change for U1's file): the card's approval: queue, the second identical
# per-job overage, and a run that already waits on an ask.
R08_MORE = {"approval": "approval is queue on guard/budget.card; queued as ask {ask}, default no at {due} UTC",
            "limit": "{reason}; asked a person as ask {ask}, default no at {due} UTC",
            "open": "run {run} already waits on ask {ask}, default no at {due} UTC"}


@dataclass(frozen=True)
class ViewJob(JobRow):
    """A JobRow with what decide() also reads: the job's arguments (R11's key), its log as the agent's sandbox sees it
    (R05's line 2), and the scheduler's state word."""
    args: tuple = ()
    log: str = ""
    sched_state: str = ""


@dataclass(frozen=True)
class RunView(LedgerView):
    """A LedgerView with the project's path inside the sandbox, R12's line 2."""
    project: str = ""


def backend(limits, view):
    return "host" if view.host is not None and view.host.in_launch_hosts else "slurm"


def without(words, names):
    """sbatch option words with every --name=V, --name V, -xV and -x V of each flag in names removed."""
    flags = [f for n in names for f in FLAG[n] if f]
    out, it = [], iter(words)
    for w in it:
        if w in flags:
            next(it, None)
        elif not any(w.startswith(f + "=") or (len(f) == 2 and w.startswith(f) and len(w) > 2) for f in flags):
            out.append(w)
    return out


def known_options(words):
    """The option words guard run takes, each with its value; the rest dropped, for R01's rebuilt line."""
    out, i = [], 0
    while i < len(words):
        pair = words[i:i + 1] if "=" in words[i] or not words[i].startswith("-") else words[i:i + 2]
        try:
            read_options(pair)
            out += pair
        except Unparsed:
            pass
        i += len(pair)
    return out


def line(inv, options):
    """The agent's guard run line with these sbatch options: the line 2 of a refusal it can paste."""
    words = ["guard", "run", f"runs/{inv.run_id}", "--why", inv.why, *(["--cause", inv.cause] if inv.cause else []),
             "--", *options, inv.script, *inv.args]
    return " ".join(shlex.quote(w) for w in words)


def fixed(inv, flag, value):
    return line(inv, without(inv.options, [flag]) + [f"--{flag}={value}"])


def refuse(code, variant="", next=None, backend_="slurm", **fmt):
    """The refusal as a Decision; line 2 is guard status where the built one breaks the line 2 rule (a path with a [
    in it, say)."""
    try:
        r = refusals.refuse(code, variant, next=next, **fmt)
    except ValueError:
        return status_next(code, variant, backend_, **fmt)
    return Decision("refuse", backend_, code=r.code, reason=r.reason, next=r.next)


def status_next(code, variant, backend_, **fmt):
    return Decision("refuse", backend_, code=code, reason=refusals.CODES[code].reasons[variant].format(**fmt),
                    next="guard status")


def queue(variant, backend_, ask_id=None, **fmt):
    reason = (refusals.CODES["R08"].reasons.get(variant) or R08_MORE[variant]).format(ask="{ask}", due="{due}", **fmt)
    return Decision("queue", backend_, code="R08", reason=reason, next="guard status", ask_id=ask_id)


def hours(x):
    return f"{round(x, 2):.12g}"


def approved(inv, spec, view):
    """The effect ask answered yes for this exact job, or None."""
    want = {"kind": "submit", "run_id": inv.run_id, "script_sha256": inv.script_sha256,
            "spec": dataclasses.asdict(spec)}
    return next((a for a in view.open_asks if a.get("answer") == "yes" and a.get("effect") == want), None)


def waiting(inv, view):
    return next((a for a in view.open_asks if "answer" not in a and (a.get("effect") or {}).get("run_id") == inv.run_id),
                None)


def session_job_ids(view):
    return {j.job_id for rows in view.run_jobs.values() for j in rows if j.job_id}


# the rules: each takes (inv, spec, cost, limits, view, b) and returns a Decision or None ----------------------------
def r12_outside(inv, spec, cost, limits, view, b):
    if not view.run_dir_in_project:
        return refuse("R12", run_dir=f"runs/{inv.run_id}", project=getattr(view, "project", "") or ".", backend_=b)


def r07_script(inv, spec, cost, limits, view, b):
    if not view.script_exists:
        return refuse("R07", "missing", next="guard status", script=inv.script, backend_=b)


def r16_stop_date(inv, spec, cost, limits, view, b):
    today = dt.datetime.fromtimestamp(inv.ts, dt.timezone.utc).date().isoformat()
    if today > limits.stop_date:
        return refuse("R16", date=limits.stop_date, backend_=b)


def r06_watched(inv, spec, cost, limits, view, b):
    if view.changed_paths_vs_main:
        return refuse("R06", paths=" ".join(view.changed_paths_vs_main), backend_=b)


def r05_failed(inv, spec, cost, limits, view, b):
    job = view.last_failed_job
    if job is None or (inv.cause or "").strip():
        return None
    fmt = dict(job=job.job_id, state=getattr(job, "sched_state", "") or "badly", backend_=b)
    log = getattr(job, "log", "")
    return refuse("R05", log=shlex.quote(log), **fmt) if log else status_next("R05", "", **fmt)


def r08_waiting(inv, spec, cost, limits, view, b):
    a = waiting(inv, view)
    if a is not None and approved(inv, spec, view) is None:
        return queue("open", b, ask_id=a["id"], run=inv.run_id)


def r11_identical(inv, spec, cost, limits, view, b):
    live = {j.seq for j in view.live_jobs}
    for j in view.run_jobs.get(inv.run_id, ()):
        if (j.seq in live and j.script_sha256 == inv.script_sha256 and tuple(j.options) == tuple(inv.options)
                and tuple(getattr(j, "args", ())) == tuple(inv.args)):
            return refuse("R11", state=getattr(j, "sched_state", "") or "live", job=j.job_id, backend_=b)


def r17_partition(inv, spec, cost, limits, view, b):
    if b == "slurm" and spec.partition and limits.partitions and spec.partition not in limits.partitions:
        return refuse("R17", next=fixed(inv, "partition", limits.partitions[0]), partition=spec.partition,
                      allowed=" ".join(limits.partitions), backend_=b)


def r18_dependency(inv, spec, cost, limits, view, b):
    if b == "slurm" and spec.dependency:
        mine = session_job_ids(view)
        for item in spec.dependency.split(","):
            for j in item.split(":")[1:]:
                if j not in mine and j.split("_")[0] not in mine:
                    return refuse("R18", next=line(inv, without(inv.options, ["dependency"])), job=j, backend_=b)


def r19_output(inv, spec, cost, limits, view, b):
    out = spec.output
    if out and (out.startswith("/") or ".." in out.split("/")):
        return refuse("R19", next=fixed(inv, "output", f"runs/{inv.run_id}/slurm-%j.out"), output=out, backend_=b)


def r02_time(inv, spec, cost, limits, view, b):
    if b == "slurm" and spec.time_min > limits.max_walltime_minutes:
        return refuse("R02", next=fixed(inv, "time", limits.max_walltime_minutes), time=spec.time_min,
                      max=limits.max_walltime_minutes, backend_=b)


def r03_nodes(inv, spec, cost, limits, view, b):
    if b == "slurm" and spec.nodes > limits.max_nodes_per_job:
        return refuse("R03", next=fixed(inv, "nodes", limits.max_nodes_per_job), nodes=spec.nodes,
                      max=limits.max_nodes_per_job, backend_=b)


def r04_gpus(inv, spec, cost, limits, view, b):
    if b == "slurm" and spec.gpus and not limits.max_gpu_hours:
        return refuse("R04", next=fixed(inv, "gpus", 0), gpus=spec.gpus, max=0, backend_=b)


def r13_slurm_only(inv, spec, cost, limits, view, b):
    if b != "host":
        return None
    given = [n for n, on in (("nodes", spec.nodes > 1), ("ntasks", (spec.tasks or 1) > 1),
                             ("partition", spec.partition), ("array", spec.array), ("dependency", spec.dependency)) if on]
    if not given:
        return None
    # A flag from the script's #SBATCH lines stays unless argv overrides it: --nodes=1 and --ntasks=1 do; partition,
    # array and dependency have no neutral value, so line 2 is guard status there.
    scripted = [n for n in given if without(inv.options, [n]) == list(inv.options)]
    if set(scripted) - {"nodes", "ntasks"}:
        return refuse("R13", "slurm_only", next="guard status", flag="/".join(f"--{n}" for n in given), backend_=b)
    return refuse("R13", "slurm_only", next=line(inv, without(inv.options, SLURM_ONLY) + [f"--{n}=1" for n in scripted]),
                  flag="/".join(f"--{n}" for n in given), backend_=b)


def r13_mem(inv, spec, cost, limits, view, b):
    if b == "host" and spec.mem_gb is not None and spec.mem_gb > limits.host_max_mem_gb:
        return refuse("R13", "mem", next=fixed(inv, "mem", f"{limits.host_max_mem_gb:g}G"), mem=spec.mem_gb,
                      backend_=b)


def r13_time(inv, spec, cost, limits, view, b):
    if b == "host" and spec.time_min > limits.host_max_walltime_minutes:
        return refuse("R13", "time", next=fixed(inv, "time", limits.host_max_walltime_minutes), time=spec.time_min,
                      max=limits.host_max_walltime_minutes, backend_=b)


def r13_gpu_hours(inv, spec, cost, limits, view, b):
    remaining = limits.max_gpu_hours - view.spent_gpu_hours
    if b == "host" and cost.gpu_hours > remaining:
        fits = max(0, int(remaining // (spec.time_min / 60))) if spec.time_min else 0
        return refuse("R13", "gpu_hours", next=fixed(inv, "gpus", fits), gpu_hours=hours(cost.gpu_hours),
                      remaining=hours(max(remaining, 0)), backend_=b)


def holder(view, inv, key):
    """guard wait on this session's live launch holding the most of what is short, else on any live launch, else
    guard status. held rows are (job_id, session, gpus, mem_gb), as lib/broker/host.py reports them."""
    mine = [h for h in getattr(view, "held", ()) if h[1] == inv.session]
    if mine:
        return f"guard wait {max(mine, key=key)[0]}"
    return f"guard wait {view.live_launches[0]}" if view.live_launches else "guard status"


def r14_host(inv, spec, cost, limits, view, b):
    """This host now, in lib/broker/host.py check()'s order; the host checks again under its lock at launch."""
    if b != "host":
        return None
    h = view.host
    if not h.bwrap:
        return refuse("R14", "bwrap", next="guard status", backend_=b)
    if spec.gpus and getattr(h, "nvidia_smi", "ok") != "ok":
        return refuse("R14", "nvidia_smi", next="guard status", backend_=b)
    if spec.gpus > len(h.gpus_free):
        return refuse("R14", "gpus", next=holder(h, inv, lambda x: len(x[2])), free=len(h.gpus_free),
                      asked=spec.gpus, backend_=b)
    mem = spec.mem_gb if spec.mem_gb is not None else limits.host_max_mem_gb
    if h.available_gb - mem < limits.host_min_available_gb:
        return refuse("R14", "memory", next=holder(h, inv, lambda x: x[3]), host=h.name,
                      available=f"{h.available_gb - mem:g}", min=f"{limits.host_min_available_gb:g}", backend_=b)


def r10_concurrent(inv, spec, cost, limits, view, b):
    live = sorted(view.live_jobs, key=lambda j: j.submitted_ts)
    if live and len(live) + spec.array_n > limits.max_concurrent_jobs:
        return refuse("R10", n=len(live), oldest=live[0].job_id, backend_=b)


def r08_budget(inv, spec, cost, limits, view, b):
    if b != "slurm":
        return None
    remaining = (limits.max_core_hours - limits.verification_reserve_core_hours - view.spent_core_hours
                 - view.queued_core_hours)
    if cost.core_hours > remaining:
        return queue("budget", b, core_hours=hours(cost.core_hours), remaining=hours(max(remaining, 0)))
    if limits.default_run_core_hours:
        spent = sum(j.cost.core_hours for j in view.run_jobs.get(inv.run_id, ()) if j.cost and j.state == "submitted")
        if spent + cost.core_hours > limits.default_run_core_hours:
            return queue("run", b, core_hours=hours(cost.core_hours), run=inv.run_id,
                         cap=hours(limits.default_run_core_hours))


def r08_approval(inv, spec, cost, limits, view, b):
    if limits.approval == "queue":
        return queue("approval", b)


RULES = (r12_outside, r07_script, r16_stop_date, r06_watched, r05_failed, r08_waiting, r11_identical, r17_partition,
         r18_dependency, r19_output, r13_slurm_only, r13_time, r13_mem, r13_gpu_hours, r14_host, r02_time, r03_nodes,
         r04_gpus, r10_concurrent, r08_budget, r08_approval)
LIFTED_BY_YES = (r08_waiting, r08_budget, r08_approval)


def decide(inv, spec, cost, limits, view):
    b = backend(limits, view)
    yes = approved(inv, spec, view)
    for rule in RULES:
        if yes is not None and rule in LIFTED_BY_YES:
            continue
        d = rule(inv, spec, cost, limits, view, b)
        if d is not None:
            return d
    return Decision("run", b, ask_id=yes["id"] if yes else None)
