"""guard wait: block until something changes or 5 minutes pass, then print the last 20 log lines and a status.

    guard wait <id> [--timeout 5m]        a job id, a pid of yours, or a host job id
    guard wait [--timeout 5m] -- <command...>
    guard wait --stop <host job id>

An id is resolved in this order (design-v8 section 6): a job of this session that the scheduler's acct lists, numeric
or 1234_5; then a live pid of your uid; then a host job id, <host>-<UTC %Y%m%dT%H%M%SZ>, which the sandbox cannot see,
so it goes through the scheduler socket's wait and stop verbs. With -- the command runs with its output going to a log
and its stdio unbuffered, and the wait ends when it exits. --timeout is s, m or h and at most 5m; something still
running then keeps running, and the status names the commands to keep waiting and to stop it (exit 124).

The host verbs (lib/broker/host.py answers them) take and return JSON in the reply's out:
    {"verb": "wait", "id": "<host job id>"}  ->  {"state": "running|exited|timeout|stopped|unknown", "code": <int|null>,
                                                  "elapsed": "12m30s", "log": "<path>", "tail": "<last 20 lines>"}
    {"verb": "stop", "id": "<host job id>"}  ->  out: one line saying what was stopped
The session check for a numeric id the acct verb does not list is {"verb": "status", "job": "<id>"} ->
{"mine": true|false|null}: false is another session's job (W02), null a job nobody here knows (W01)."""
import collections
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

import refusals
from broker import transport

TAIL = 20
LINE_CHARS = 300
POLL = 5
MAX_WAIT = 5 * 60
UNITS = {"s": 1, "m": 60, "h": 3600}
ENDED = ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED", "BOOT_FAIL",
         "DEADLINE")
HOST_SLURM = {"running": "RUNNING", "timeout": "TIMEOUT", "stopped": "CANCELLED"}
HOST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*-\d{8}T\d{6}Z$")
JOB_ID = re.compile(r"^[0-9]+(_[0-9]+)?$")
USAGE = ("usage: guard wait <job id|pid|host job id> [--timeout 5m]\n"
         "       guard wait [--timeout 5m] -- <command...>\n       guard wait --stop <host job id>")

now = time.time
sleep = time.sleep


class Done(Exception):
    """The verb ends here: its text, then its exit status."""

    def __init__(self, text, rc):
        super().__init__(text)
        self.text, self.rc = text, rc


def refuse(code, **fmt):
    r = refusals.refuse(code, **fmt)
    raise Done(refusals.render(r), r.exit)


def wait_dir():
    return os.environ.get("GUARD_WAIT_DIR") or os.path.join(tempfile.gettempdir(), f"guard-wait-{os.getuid()}")


def seconds(text, again):
    """Seconds in a --timeout of s, m or h up to 5m; W03 otherwise, its line 2 the caller's own command, again."""
    m = re.fullmatch(r"(\d+)([smh])", text or "")
    if m and 0 < int(m.group(1)) * UNITS[m.group(2)] <= MAX_WAIT:
        return int(m.group(1)) * UNITS[m.group(2)]
    r = refusals.Refusal("W03", refusals.CODES["W03"].reasons[""], again)
    if not refusals.next_ok(again):
        raise ValueError(again)
    raise Done(refusals.render(r), r.exit)


def ask(request, sock="scheduler"):
    return transport.send(request, sock)


def tail(path):
    """The last TAIL lines of a file, each cut to LINE_CHARS, or '' when there is no file."""
    if not path or not os.path.isfile(path):
        return ""
    with open(path, errors="replace") as f:
        lines = collections.deque(f, TAIL)
    return "".join((l if len(l.rstrip("\n")) <= LINE_CHARS else l[:LINE_CHARS - 3] + "...\n") for l in lines)


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def mine(pid):
    try:
        return os.stat(f"/proc/{pid}").st_uid == os.getuid()
    except OSError:
        return False


def lasted(secs):
    return f"{int(secs) // 60}m{int(secs) % 60:02d}s"


def running_for(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            start = int(f.read().rsplit(")", 1)[1].split()[19]) / os.sysconf("SC_CLK_TCK")
        with open("/proc/uptime") as f:
            return lasted(float(f.read().split()[0]) - start)
    except (OSError, IndexError, ValueError):
        return "an unknown time"


def keep_going(what, elapsed, wait_id, stop):
    return f"{what} still running after {elapsed}\nkeep waiting: guard wait {wait_id}\nstop it: {stop}"


def pid_log(pid):
    """The log guard wait wrote for its own command, else the file the process writes its stdout to."""
    own = os.path.join(wait_dir(), f"{pid}.log")
    if os.path.isfile(own):
        return own
    try:
        out = os.readlink(f"/proc/{pid}/fd/1")
    except OSError:
        return None
    return out if os.path.isfile(out) else None


def leads_group(pid):
    try:
        return os.getpgid(pid) == pid
    except OSError:
        return False


def wait_pid(pid, deadline):
    log = pid_log(pid)
    stop = f"kill -- -{pid}" if leads_group(pid) else f"kill {pid}"
    while alive(pid) and now() < deadline:
        sleep(0.5)
    if alive(pid):
        return 124, tail(log), keep_going(f"pid {pid}", running_for(pid), pid, stop)
    rc_file = os.path.join(wait_dir(), f"{pid}.rc")
    try:
        with open(rc_file) as f:
            code = int(f.read())
    except (OSError, ValueError):
        code = None
    return (code or 0), tail(log), f"pid {pid} exited" + (f" with code {code}" if code is not None else "")


def run(cmd, deadline):
    os.makedirs(wait_dir(), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=wait_dir(), suffix=".log")
    # sh records the exit code under its own pid, so a later guard wait <pid> can report it. stdbuf makes C stdio
    # line-buffered and PYTHONUNBUFFERED the interpreter's, so a job's first line shows at once, not at exit.
    unbuffered = ["stdbuf", "-oL", "-eL"] if shutil.which("stdbuf") else []
    p = subprocess.Popen(["sh", "-c", '"$@"; echo $? > "$0/$$.rc"', wait_dir(), *unbuffered, *cmd],
                         stdin=subprocess.DEVNULL, stdout=fd, stderr=subprocess.STDOUT, start_new_session=True,
                         env={**os.environ, "PYTHONUNBUFFERED": "1"})
    os.close(fd)
    os.rename(tmp, os.path.join(wait_dir(), f"{p.pid}.log"))
    return wait_pid(p.pid, deadline)


# jobs of this session ------------------------------------------------------------------------------------------------
def rows_of(out, job):
    """(state, exit code, elapsed) of job from sacct -X -P rows JobID|State|ExitCode|Elapsed; an array's parent id is
    its tasks together, live while any is."""
    rows = []
    for line in out.splitlines():
        jid, state, code, elapsed = (line.split("|") + ["", "", ""])[:4]
        if jid == job or jid.startswith(job + "_"):
            rows.append((state.split()[0] if state else "", code, elapsed))
    if not rows:
        return None
    live = [r for r in rows if r[0] not in ENDED]
    bad = [r for r in rows if r[0] != "COMPLETED"]
    return (live or bad or rows)[0]


def job_state(job):
    """(state, code, elapsed) of a job of this session, or None when the scheduler's acct does not list it. With no
    broker (a plain shell) acct is X00, and the user's own sacct answers."""
    cols = ["-X", "-n", "-P", "-o", "JobID,State,ExitCode,Elapsed", "-S", "2000-01-01", "-j", job]
    reply = ask({"verb": "acct", "args": cols})
    if reply.get("rc") == 0:
        out = reply.get("out", "")
    elif reply.get("err", "").startswith("H4R-X00"):
        try:
            out = subprocess.run(["sacct", *cols], capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            return None
    else:
        return None
    return rows_of(out, job)


def job_log(job):
    """slurm-<id>.out in the working directory or a run directory, else a file under runs/ named for the job."""
    found = glob.glob(f"slurm-{job}*") + glob.glob(f"runs/*/slurm-{job}*") + glob.glob(f"runs/*/*{job}*")
    found = [f for f in found if os.path.isfile(f)]
    return max(found, key=os.path.getmtime) if found else None


def wait_job(job, first, deadline):
    state = first
    while state[0] == first[0] and state[0] not in ENDED and now() < deadline:
        sleep(max(0, min(POLL, deadline - now())))
        state = job_state(job) or state
    log = job_log(job)
    if state[0] == first[0] and state[0] not in ENDED:
        return 124, tail(log), keep_going(f"job {job} ({state[0]})", state[2] or "an unknown time", job,
                                          f"scancel {job}")
    moved = f"{first[0]} -> {state[0]}" if state[0] != first[0] else state[0]
    return 0, tail(log), f"job {job} {moved}" + (f" exit {state[1]}" if state[1] not in ("", "0:0") else "")


# host jobs -----------------------------------------------------------------------------------------------------------
def host_call(verb, ident):
    reply = ask({"verb": verb, "id": ident})
    if reply.get("rc") != 0:
        raise Done(reply.get("err", ""), reply.get("rc") or 1)
    return reply.get("out", "")


def host_state(ident):
    try:
        return json.loads(host_call("wait", ident))
    except ValueError:
        refuse("W01", id=ident)


def wait_host(ident, deadline):
    first = host_state(ident)
    if first.get("state") == "unknown":
        refuse("W01", id=ident)
    state = first
    while state["state"] == first["state"] and state["state"] == "running" and now() < deadline:
        sleep(max(0, min(POLL, deadline - now())))
        state = host_state(ident)
    if state["state"] == "running" and state["state"] == first["state"]:
        return 124, state.get("tail", ""), keep_going(f"job {ident}", state.get("elapsed", "an unknown time"), ident,
                                                      f"guard wait --stop {ident}")
    a, b = slurm_state(first), slurm_state(state)
    moved = f"{a} -> {b}" if b != a else b
    code = state.get("code")
    return 0, state.get("tail", ""), f"job {ident} {moved}" + (f" exit {code}" if code else "")


def slurm_state(reply):
    """A host job's state as Slurm names it, as a job's line says it: the supervisor's own (slurm_state), else from
    the wait verb's state and code."""
    if reply.get("slurm_state"):
        return reply["slurm_state"]
    if reply.get("state") == "exited":
        return "COMPLETED" if not reply.get("code") else "FAILED"
    return HOST_SLURM.get(reply.get("state"), str(reply.get("state", "")).upper())


# the verb ------------------------------------------------------------------------------------------------------------
def resolve(ident, deadline):
    if JOB_ID.match(ident):
        first = job_state(ident)
        if first is not None:
            return wait_job(ident, first, deadline)
        if ident.isdigit() and alive(int(ident)) and mine(int(ident)):
            return wait_pid(int(ident), deadline)
        reply = ask({"verb": "status", "job": ident})
        try:
            known = json.loads(reply.get("out") or "{}").get("mine")
        except ValueError:
            known = None
        refuse("W02" if known is False else "W01", id=ident)
    if HOST_ID.match(ident):
        return wait_host(ident, deadline)
    refuse("W01", id=ident)


def parse(argv):
    """(timeout seconds, id or None, command or None, stop id or None); a usage error or a bad --timeout is Done."""
    cmd = None
    if "--" in argv:
        cmd = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    asked, stop, rest, it = None, None, [], iter(argv)
    for a in it:
        if a == "--timeout":
            asked = next(it, "")
        elif a.startswith("--timeout="):
            asked = a.partition("=")[2]
        elif a == "--stop":
            stop = next(it, "")
        else:
            rest.append(a)
    if stop is not None:
        if not stop or rest or cmd is not None:
            raise Done(USAGE + "\n", 64)
    elif len(rest) > 1 or (cmd is None) == (len(rest) == 0) or cmd == []:
        raise Done(USAGE + "\n", 64)
    again = f"guard wait --timeout 5m -- {shlex.join(cmd)}" if cmd else f"guard wait {rest[0] if rest else stop} --timeout 5m"
    return (MAX_WAIT if asked is None else seconds(asked, again)), (rest[0] if rest else None), cmd, stop


def execute(argv):
    timeout, ident, cmd, stop = parse(argv)
    if stop is not None:
        if not HOST_ID.match(stop):
            refuse("W01", id=stop)
        return 0, "", host_call("stop", stop).rstrip("\n")
    deadline = now() + timeout
    return run(cmd, deadline) if cmd is not None else resolve(ident, deadline)


def main(argv):
    """Prints the verb's output, at most 23 lines, and returns its exit status."""
    try:
        rc, log, status = execute(argv)
        text = log + (status if status.endswith("\n") else status + "\n")
    except Done as e:
        sys.stderr.write(e.text)
        return e.rc
    sys.stdout.write(refusals.cap(text, "wait"))
    return rc
