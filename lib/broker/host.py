"""The host backend: a guard run job on a host named in launch_hosts, under lib/guard/launch.sh's supervisor and inside
lib/box.sh (design-v8 section 4). It runs in the broker, outside the agent's sandbox, and reads the card and the
project id from the broker's mirror of main; git never runs in the agent's checkout.

    check(inv, spec, limits, view, run_dir) -> Refusal | None    R13 and R14, pure
    translate(spec, limits, view)           -> Translation        SbatchSpec to launch.sh's request, pure
    Host.of(broker): view() launch() record() state() log() stop()
    handle(request, broker)                 the scheduler socket's wait and stop verbs for a <host>-<UTC stamp> id

SbatchSpec to the supervisor: time_min is the time limit; a GPU count becomes the first free device indices; a
missing mem_gb is host_max_mem_gb (A10: default, do not ask); cpus_per_task enters the cost only; nodes over 1,
partition, array, dependency and ntasks over 1 are R13 with the flag removed in line 2."""
import fcntl
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass

import refusals
from broker.records import Refused
from policy import HostView
from policy.cost import card_values, limits as card_limits
from policy.invocation import SHORT, run_line

HARNESS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
LAUNCH = os.path.join(HARNESS, "lib", "guard", "launch.sh")
BOX = os.path.join(HARNESS, "lib", "box.sh")
# launch.sh's Slurm words as lib/wait.py's host states; the Slurm word itself rides along as slurm_state.
WAIT_STATE = {"PENDING": "running", "RUNNING": "running", "TIMEOUT": "timeout", "CANCELLED": "stopped",
              "PREEMPTED": "stopped", "COMPLETED": "exited", "FAILED": "exited", "OUT_OF_MEMORY": "exited",
              "HOST_OUT_OF_MEMORY": "exited", "NODE_FAIL": "exited", "SUPERVISOR_FAILED": "exited",
              "LAUNCH_FAILED": "exited"}
JOB = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*-[0-9]{8}T[0-9]{6}Z$")
START_WAIT = 15
GB = 1048576  # kB


@dataclass(frozen=True)
class HostReport(HostView):
    """HostView plus what R14's line 2 and guard status need. held: (job_id, session, gpus, mem_gb) per live launch."""
    nvidia_smi: str = "missing"            # ok | missing | failed
    strays: tuple = ()
    held: tuple = ()
    spent_gpu_hours: float = 0.0           # this project's records since start_date, running launches at their limit


@dataclass(frozen=True)
class Translation:
    time_limit_seconds: int
    gpus: tuple                            # device indices, () for none
    mem_gb: float


@dataclass(frozen=True)
class Launched:
    job_id: str
    gpus: tuple
    log: str                               # the agent's path to the job's log


# ------------------------------------------------------------------------------------------------------- pure policy

SLURM_ONLY = (("nodes", lambda s: s.nodes > 1), ("partition", lambda s: s.partition is not None),
              ("array", lambda s: s.array is not None), ("dependency", lambda s: s.dependency is not None),
              ("ntasks", lambda s: (s.tasks or 1) > 1))


def edited(options, name, value=None):
    """options with every occurrence of sbatch option name dropped, then --name=value appended when value is given."""
    out, words, i = [], list(options), 0
    while i < len(words):
        w = words[i]
        if w.startswith("--"):
            n, eq, _ = w[2:].partition("=")
            width = 1 if eq or n in ("ignore-pbs", "parsable") else 2
        elif w in SHORT:
            n, width = SHORT[w], 2
        elif w[:2] in SHORT:
            n, width = SHORT[w[:2]], 1
        else:
            n, width = None, 1
        if n != name:
            out += words[i:i + width]
        i += width
    return out + ([f"--{name}={value}"] if value is not None else [])


def fixed(inv, run_dir, options):
    """The agent's guard run line with options in place of theirs; the agent's --why when it obeys the line 2 rule."""
    line = run_line(run_dir, options, inv.script, inv.args, why=inv.why)
    return line if refusals.next_ok(line) else run_line(run_dir, options, inv.script, inv.args)


def mem_word(gb):
    return f"{int(gb)}G" if float(gb).is_integer() else f"{int(gb * 1024)}M"


def wait_on(view, session, key):
    """guard wait on this session's live launch with the largest key, else guard status."""
    mine = [h for h in view.held if h[1] == session]
    return f"guard wait {max(mine, key=key)[0]}" if mine else "guard status"


def check(inv, spec, limits, view, run_dir):
    """R13 (the card's host limits, Slurm-only flags) then R14 (this host now), or None when the job may launch."""
    for name, present in SLURM_ONLY:
        if present(spec):
            return refusals.refuse("R13", "slurm_only", flag=f"--{name}",
                                   next=fixed(inv, run_dir, edited(inv.options, name)))
    if spec.time_min > limits.host_max_walltime_minutes:
        return refusals.refuse("R13", "time", time=spec.time_min, max=limits.host_max_walltime_minutes,
                               next=fixed(inv, run_dir, edited(inv.options, "time", limits.host_max_walltime_minutes)))
    if spec.mem_gb is not None and spec.mem_gb > limits.host_max_mem_gb:
        return refusals.refuse("R13", "mem", mem=spec.mem_gb,
                               next=fixed(inv, run_dir, edited(inv.options, "mem", mem_word(limits.host_max_mem_gb))))
    if spec.gpus:
        asked = spec.time_min / 60 * spec.gpus
        left = limits.max_gpu_hours - view.spent_gpu_hours
        if asked > left:
            fit = int(max(left, 0) * 60 / spec.gpus)
            line = fixed(inv, run_dir, edited(inv.options, "time", fit)) if fit >= 1 else "guard status"
            return refusals.refuse("R13", "gpu_hours", gpu_hours=f"{asked:.1f}", remaining=f"{max(left, 0):.1f}",
                                   next=line)
    if not view.bwrap:
        return refusals.refuse("R14", "bwrap", next="guard status")
    if spec.gpus and view.nvidia_smi != "ok":
        return refusals.refuse("R14", "nvidia_smi", next="guard status")
    if len(view.gpus_free) < spec.gpus:
        return refusals.refuse("R14", "gpus", free=len(view.gpus_free), asked=spec.gpus,
                               next=wait_on(view, inv.session, key=lambda h: len(h[2])))
    mem = spec.mem_gb if spec.mem_gb is not None else limits.host_max_mem_gb
    if view.available_gb - mem < limits.host_min_available_gb:
        return refusals.refuse("R14", "memory", host=view.name, available=f"{view.available_gb - mem:.1f}",
                               min=f"{limits.host_min_available_gb:g}",
                               next=wait_on(view, inv.session, key=lambda h: h[3]))
    return None


def translate(spec, limits, view):
    return Translation(time_limit_seconds=spec.time_min * 60, gpus=tuple(sorted(view.gpus_free))[:spec.gpus],
                       mem_gb=spec.mem_gb if spec.mem_gb is not None else limits.host_max_mem_gb)


# --------------------------------------------------------------------------------------------------------- the host

def read_record(path):
    """A record file's key: value lines, the first of each key winning; None when the file is absent."""
    try:
        with open(path) as f:
            return card_values(f.read())
    except FileNotFoundError:
        return None


def put_once(path, text):
    """Written whole or not at all, and never over an existing file: launch.sh's put_once."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.link(tmp, path)
    finally:
        os.unlink(tmp)


class Host:
    def __init__(self, broker, card_text):
        self.broker, self.cfg = broker, broker.cfg
        self.card, self.limits = card_values(card_text), card_limits(card_text)
        self.dir = os.path.expanduser(self.limits.host_state_dir)
        if not os.path.isabs(self.dir):
            raise Refused(f"host_state_dir must be an absolute path on main: {self.limits.host_state_dir}")
        root = broker.mirror.git("rev-list", "--max-parents=0", "refs/heads/main").stdout.split()
        self.project = root[-1] if root else "none"

    @classmethod
    def of(cls, broker, fetch=True):
        """The host backend for broker's project, its card read from the mirror's main (fetched first, or when the
        mirror has never been fetched)."""
        if fetch or not hasattr(broker.mirror, "files"):
            broker.mirror.fetch()
        text = broker.mirror.show("guard/budget.card")
        if text is None:
            raise Refused("no guard/budget.card on main")
        return cls(broker, text)

    def sh(self, *args):
        done = subprocess.run(["bash", LAUNCH, *args], capture_output=True, text=True, cwd="/")
        return done.returncode, done.stdout, done.stderr

    # paths ---------------------------------------------------------------------------------------------------------
    def inside(self, outside):
        for a, b in self.cfg["paths"]:
            if outside == b or outside.startswith(b + "/"):
                return a + outside[len(b):]
        return outside

    def project_paths(self):
        """(outside, inside) of the project root."""
        return self.broker.outside(self.cfg["project"]), self.cfg["project"]

    # views ---------------------------------------------------------------------------------------------------------
    def view(self):
        rc, out, err = self.sh("--view", self.dir, self.project, self.limits.start_date or "-",
                               f"{self.limits.host_max_mem_gb:g}", self.card.get("stray_ignore") or "none")
        if rc:
            raise Refused(f"launch.sh --view failed: {(err.strip() or f'exit {rc}').splitlines()[-1]}")
        v = dict(line.split("\t", 1) for line in out.splitlines() if "\t" in line)
        live = tuple(v.get("live", "").split())
        held = []
        for job in live:
            req = read_record(os.path.join(self.dir, job, "request")) or {}
            gpus = tuple(g for g in req.get("gpus", "none").split(",") if g and g != "none")
            held.append((job, req.get("session", ""), gpus, float(req.get("mem_limit_gb") or 0)))
        taken = set(v.get("busy_gpus", "").split()) | set(v.get("held_gpus", "").split())
        spent, remaining = (int(x) for x in (v.get("gpu_seconds") or "0 0").split())
        return HostReport(
            name=v.get("host", ""), in_launch_hosts=v.get("host", "") in self.limits.launch_hosts,
            available_gb=(int(v.get("mem_available_kb") or 0) - int(v.get("reserved_kb") or 0)) / GB,
            gpus_free=tuple(sorted((g for g in v.get("gpus", "").split() if g not in taken), key=int)),
            bwrap=bwrap_works(), live_launches=live, nvidia_smi=v.get("nvidia_smi", "missing"),
            strays=tuple(v.get("strays", "").split()), held=tuple(held), spent_gpu_hours=(spent + remaining) / 3600)

    def record(self, job):
        return read_record(os.path.join(self.dir, job, "request")) if JOB.match(job) else None

    def row(self, job):
        """launch.sh --list's row for job as a dict, or None."""
        rc, out, _ = self.sh("--list", self.dir, self.project)
        lines = [line.split("\t") for line in out.splitlines()]
        head = lines[0] if lines else []
        return next((dict(zip(head, r)) for r in lines[1:] if r and r[0] == job), None)

    def state(self, job):
        row = self.row(job)
        return row["state"] if row else None

    def log(self, job, lines=20):
        path = (self.record(job) or {}).get("log")
        try:
            with open(path, "rb") as f:
                f.seek(0, os.SEEK_END)
                f.seek(max(0, f.tell() - 65536))
                text = f.read().decode(errors="replace")
        except (OSError, TypeError):
            return ""
        return "".join(text.splitlines(keepends=True)[-lines:])

    def stop(self, job, reason):
        rc, out, err = self.sh("--stop", self.dir, self.project, job, f"--reason={reason}")
        if rc:
            raise Refused(err.strip().splitlines()[-1] if err.strip() else f"launch.sh --stop exit {rc}")
        before, after = out.split()[-2:]
        return before, after

    # launch --------------------------------------------------------------------------------------------------------
    def launch(self, inv, spec, run_dir):
        """Starts the job under its supervisor, boxed; Launched, or the R13/R14 refusal that stopped it. The check runs
        again under the host lock, so two launches never claim the same GPU or the same memory."""
        with open(os.path.join(tempfile.gettempdir(), f"guard-launch-{self.cfg.get('user') or os.getuid()}.lock"),
                  "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            view = self.view()
            if not view.in_launch_hosts:
                raise Refused(f"{view.name} is not in launch_hosts on main")
            refusal = check(inv, spec, self.limits, view, run_dir)
            if refusal:
                return refusal
            t = translate(spec, self.limits, view)
            job, rec = self.claim(view.name)
            paths = self.job_paths(inv, spec, run_dir, job)
            command = self.boxed(job, t, paths, ["bash", paths["script"], *inv.args])
            put_once(os.path.join(rec, "request"), self.request_text(job, inv, view.name, t, paths, command))
        os.makedirs(paths["run_dir_out"], exist_ok=True)
        subprocess.run(["setsid", "-f", "bash", LAUNCH, "--supervise", rec, "--", *command], env=job_env(self.cfg),
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd="/")
        for _ in range(START_WAIT * 10):
            if os.path.exists(os.path.join(rec, "start")):
                return Launched(job, t.gpus, paths["log"])
            time.sleep(0.1)
        return refusals.refuse("R14", "supervisor", reason=f"no start record after {START_WAIT} s",
                               next="guard status")

    def claim(self, host):
        """<host>-<UTC %Y%m%dT%H%M%SZ>, claimed by mkdir; a second launch in the same second waits for the next."""
        os.makedirs(self.dir, exist_ok=True)
        while True:
            job = f"{host}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
            try:
                os.mkdir(os.path.join(self.dir, job))
                return job, os.path.join(self.dir, job)
            except FileExistsError:
                time.sleep(1)

    def job_paths(self, inv, spec, run_dir, job):
        """Inside and outside paths of the job's cwd, run dir, script and log, each confined to the project."""
        tree = self.broker.tree()
        cwd = os.path.normpath(inv.cwd)
        rd = os.path.normpath(os.path.join(cwd, run_dir))
        script = os.path.normpath(os.path.join(cwd, inv.script))
        out = spec.output or f"launch-{job}.log"
        out = re.sub(r"%[%jAax]", lambda m: {"%%": "%", "%j": job, "%A": job, "%a": "0", "%x": inv.run_id}[m.group()], out)
        log = os.path.normpath(os.path.join(cwd, out))
        for p in (cwd, rd, script, log):
            tree.inside(self.broker.outside(p))
        return {"cwd": cwd, "run_dir": rd, "script": script, "log": log, "cwd_out": self.broker.outside(cwd),
                "run_dir_out": self.broker.outside(rd), "log_out": self.broker.outside(log)}

    def boxed(self, job, t, paths, command):
        """lib/box.sh around command: a cleared environment, the project read-write at the agent's path, an empty home,
        no network, the chosen GPUs only, and the job's id in GUARD_JOB_ID and HPC_JOB_ID."""
        out, inside = self.project_paths()
        gpus = ",".join(t.gpus)
        argv = [BOX, "--no-tty", "--as", "none", "--ro-try", "/opt", "/opt", "--tmp-home", os.path.expanduser("~"),
                "--bind", out, inside, "--chdir", paths["cwd"],
                "--env", f"HPC_JOB_ID={job}", "--env", f"GUARD_JOB_ID={job}", "--env", f"HPC_RUN_DIR={paths['run_dir']}",
                "--env", f"CUDA_VISIBLE_DEVICES={gpus}", "--env", "CUDA_DEVICE_ORDER=PCI_BUS_ID"]
        for g in t.gpus:
            argv += ["--gpu", g]
        return [*argv, "--", *command]

    def request_text(self, job, inv, host, t, paths, command):
        rows = {"job_id": job, "run_id": inv.run_id, "run_dir": paths["run_dir_out"], "project": self.project,
                "origin": self.cfg.get("origin", "none"), "host": host, "session": self.cfg["session"],
                "why": inv.why.replace("\n", " "), "cwd": paths["cwd_out"], "log": paths["log_out"],
                "gpus": ",".join(t.gpus) or "none", "time_limit_seconds": t.time_limit_seconds,
                "mem_limit_gb": f"{t.mem_gb:g}", "shm": "", "stop_grace_seconds": self.limits.host_stop_grace_seconds,
                "host_min_available_gb": f"{self.limits.host_min_available_gb:g}", "boxed": "yes",
                "command": " ".join(command[command.index("--") + 1:]),
                "requested": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        return "".join(f"{k}: {v}\n" for k, v in rows.items())


def job_env(cfg):
    """The supervisor's environment: nothing of the broker's but a PATH, a home, a user and a locale, so a token the
    broker holds never reaches a job even before lib/box.sh clears the environment again."""
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.path.expanduser("~"),
            "USER": cfg.get("user") or os.environ.get("USER", ""), "LANG": "C.UTF-8", "GUARD_BOX_LIMITS": "prlimit"}


def bwrap_works():
    return shutil.which("bwrap") is not None and subprocess.run(
        ["bwrap", "--unshare-user", "--ro-bind", "/", "/", "true"], capture_output=True).returncode == 0


# ------------------------------------------------------------------------------------------------------- the socket

def handle(request, broker):
    """lib/wait.py's host verbs. wait {id, lines?}: out is JSON {state, code, elapsed, log, tail, slurm_state};
    stop {id, reason?}: out is one line, the state it went from and to. W01 for an id with no record of this project,
    W02 for another session's."""
    job = request.get("id")
    if not isinstance(job, str) or not job:
        return refusals.reply(refusals.refuse("W01", id=str(job)))
    h = Host.of(broker, fetch=False)
    rec = h.record(job)
    if rec is None or rec.get("project") != h.project:
        return refusals.reply(refusals.refuse("W01", id=job))
    if rec.get("session") != broker.cfg["session"]:
        return refusals.reply(refusals.refuse("W02", id=job))
    if request.get("verb") == "stop":
        before, after = h.stop(job, str(request.get("reason") or "guard wait --stop"))
        return {"rc": 0, "out": f"job {job} {before} -> {after}\n", "err": "", "job": job, "state": after}
    lines = request.get("lines")
    lines = lines if isinstance(lines, int) and 0 < lines <= 200 else 20
    row = h.row(job) or {}
    end = read_record(os.path.join(h.dir, job, "end")) or {}
    code = end.get("exit")
    out = {"state": WAIT_STATE.get(row.get("state"), "unknown"), "code": int(code) if (code or "").isdigit() else None,
           "elapsed": elapsed_words(row.get("elapsed")), "log": h.inside(rec.get("log", "")), "tail": h.log(job, lines),
           "slurm_state": row.get("state")}
    return {"rc": 0, "out": json.dumps(out), "err": ""}


def state(job, broker=None):
    """guard status's view of a host job: running, exited, timeout, stopped or unknown; None without a broker."""
    if broker is None or not JOB.match(job or ""):
        return None
    return WAIT_STATE.get(Host.of(broker, fetch=False).state(job), "unknown")


def elapsed_words(seconds):
    s = int(seconds) if (seconds or "").isdigit() else 0
    return f"{s // 3600}h{s % 3600 // 60}m" if s >= 3600 else f"{s // 60}m{s % 60}s"
