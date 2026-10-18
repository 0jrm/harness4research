#!/usr/bin/env python3
"""usage: guard wait <job_id|pid> [--timeout 5m]
       guard wait [--timeout 5m] -- <command...>

Blocks until something changes or 5 minutes pass, then prints the last 20 lines of output and a status.
A number that is a live process of yours is a pid: it waits for it to exit. Any other number is a Slurm job id: it
waits, through squeue's and sacct's own commands, until the job's state changes or it ends. With -- it runs the
command with PYTHONUNBUFFERED=1, its output going to a log, and waits for it to exit. It never blocks past
--timeout (s, m or h; at most 5m). Something still running then keeps running, and the status names how long it
has run, the command to keep waiting and the command to stop it. Output is at most 23 lines.
Exit status: the command's, or 0 once a job or pid ends or changes state, or 124 while it still runs."""
import collections, glob, os, re, subprocess, sys, tempfile, time

TAIL = 20
DIR = os.path.join(tempfile.gettempdir(), "guard-wait")
UNITS = {"s": 1, "m": 60, "h": 3600}
MAX_WAIT = 5 * 60
ENDED = ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED", "BOOT_FAIL",
         "DEADLINE")


def refuse(why, next_command):
    sys.stderr.write(f"guard wait: refused: {why}\n{next_command}\n")
    sys.exit(2)


def seconds(text):
    m = re.fullmatch(r"(\d+)([smh]?)", text)
    if not m:
        refuse(f"--timeout {text} is not a duration", "guard wait --timeout 5m -- <command>")
    return int(m.group(1)) * UNITS[m.group(2) or "s"]


def tail(path):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, errors="replace") as f:
        return "".join(collections.deque(f, TAIL))


def alive(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def running_for(pid):
    """How long the process has run, as 12m30s, from its start time in /proc."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            start = int(f.read().rsplit(")", 1)[1].split()[19]) / os.sysconf("SC_CLK_TCK")
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]) - start)
    except (OSError, IndexError, ValueError):
        return "an unknown time"
    return f"{secs // 60}m{secs % 60:02d}s"


def still_running(what, elapsed, wait_id, stop, log):
    where = f"; log {log}" if log else ""
    return f"{what} still running after {elapsed}{where}\nkeep waiting: guard wait {wait_id}\nstop it: {stop}"


def leads_group(pid):
    try:
        return os.getpgid(pid) == pid
    except OSError:
        return False


def mine(pid):
    try:
        return os.stat(f"/proc/{pid}").st_uid == os.getuid()
    except OSError:
        return False


def pid_log(pid):
    """The log guard wait wrote for its own command, else the file the process writes its stdout to."""
    own = os.path.join(DIR, f"{pid}.log")
    if os.path.isfile(own):
        return own
    try:
        out = os.readlink(f"/proc/{pid}/fd/1")
    except OSError:
        return None
    return out if os.path.isfile(out) else None


def wait_pid(pid, deadline, log, stop):
    while alive(pid) and time.time() < deadline:
        time.sleep(0.5)
    if alive(pid):
        return 124, still_running(f"pid {pid}", running_for(pid), pid, stop, log)
    rc_file = os.path.join(DIR, f"{pid}.rc")
    rc = int(open(rc_file).read()) if os.path.isfile(rc_file) else None
    return (rc or 0), f"pid {pid} exited" + (f" with code {rc}" if rc is not None else "") + (f"; log {log}" if log else "")


def run(cmd, deadline):
    os.makedirs(DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DIR, suffix=".log")
    # sh records the exit code under its own pid, so a later guard wait <pid> can report it.
    p = subprocess.Popen(["sh", "-c", '"$@"; echo $? > "$0/$$.rc"', DIR, *cmd], stdin=subprocess.DEVNULL,
                         stdout=fd, stderr=subprocess.STDOUT, start_new_session=True,
                         env={**os.environ, "PYTHONUNBUFFERED": "1"})
    os.close(fd)
    log = os.path.join(DIR, f"{p.pid}.log")
    os.rename(tmp, log)
    # The command leads its own process group, so killing the group stops everything it started.
    return wait_pid(p.pid, deadline, log, f"kill -- -{p.pid}") + (log,)


def slurm(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout
    except OSError:
        return ""


def job_state(job):
    for line in slurm("sacct", "-X", "-n", "-P", "-o", "JobID,State,ExitCode,Elapsed", "-S", "2000-01-01", "-j",
                      job).splitlines():
        jid, state, code, elapsed = (line.split("|") + ["", "", ""])[:4]
        if jid == job:
            return state.split()[0], code, elapsed
    return (slurm("squeue", "-h", "-o", "%T", "-j", job).split() or [None])[0], "", ""


def job_log(job):
    """slurm-<id>.out or any file named for the job under the current directory, newest first."""
    found = [f for f in glob.glob(f"**/*{job}*", recursive=True) if os.path.isfile(f) and ".git/" not in f]
    return max(found, key=os.path.getmtime) if found else None


def wait_job(job, deadline):
    first, code, elapsed = job_state(job)
    if first is None:
        refuse(f"{job} is neither a live process of yours nor a job squeue or sacct knows", "guard wait -- <command>")
    state = first
    while state == first and state not in ENDED and time.time() < deadline:
        time.sleep(min(10, max(0, deadline - time.time())))
        state, code, elapsed = job_state(job)
    log = job_log(job)
    where = f"; log {log}" if log else ""
    if state == first and state not in ENDED:
        return 124, still_running(f"job {job} ({state})", elapsed or "an unknown time", job, f"scancel {job}", log), log
    moved = f"{first} -> {state}" if state != first else state
    return 0, f"job {job} {moved}" + (f" exit {code}" if code else "") + where, log


def main(argv):
    timeout, cmd = MAX_WAIT, None
    if "--" in argv:
        cmd = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    if "--timeout" in argv:
        i = argv.index("--timeout")
        timeout = min(MAX_WAIT, seconds((argv[i + 1:] or [""])[0]))
        del argv[i:i + 2]
    if (cmd is None) == (len(argv) != 1) or (cmd is not None and not cmd) or (cmd is None and not argv[0].isdigit()):
        sys.exit(__doc__.split("\n\n")[0])
    deadline = time.time() + timeout
    if cmd is not None:
        rc, status, log = run(cmd, deadline)
    elif alive(int(argv[0])) and mine(int(argv[0])):
        log = pid_log(int(argv[0]))
        pid = int(argv[0])
        rc, status = wait_pid(pid, deadline, log, f"kill -- -{pid}" if leads_group(pid) else f"kill {pid}")
    else:
        rc, status, log = wait_job(argv[0], deadline)
    sys.stdout.write(tail(log))
    print(status)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
