#!/usr/bin/env python3
"""A small Slurm that runs without root, for the evaluation environment.

    fakeslurm.py serve <state_dir> <config.json>

The clients (sbatch, squeue, sacct, scancel, sacctmgr) are slurmclient.py under those names, inside the sandbox.

The controller runs outside the agent's sandbox and owns the ledger, so the agent sees accounting only through the
clients, the way it would on a cluster. Every client call is appended to <state_dir>/audit.jsonl with its arguments
and the calling process chain; the evaluator reads that file, the agent never sees it.

Time runs `time_scale` times faster than the wall clock: with 60, a job that sleeps one second has used one minute.
Nodes are allocated whole, so a job holds nodes * cores_per_node CPUs, which is what guard preflight projects.

config.json keys: cluster, partition, nodes, cores_per_node, time_scale, default_account,
accounts ({name: {"cap_cpu_minutes": n or null}}), job_cmd (argv that runs one job; see run_job).
"""
import datetime as dt
import json
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time

from slurmclient import parse_sbatch_args

FINAL = {"COMPLETED", "FAILED", "TIMEOUT", "CANCELLED", "NODE_FAIL"}


# ---------------------------------------------------------------------------------------------- formatting helpers

def fmt_duration(seconds):
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    if days:
        return f"{days}-{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def fmt_squeue_time(seconds):
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes, secs = divmod(rest, 60)
    if days:
        return f"{days}-{hours:02d}:{minutes:02d}:{secs:02d}"
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def fmt_ts(epoch):
    if epoch is None:
        return "Unknown"
    return dt.datetime.fromtimestamp(epoch).strftime("%Y-%m-%dT%H:%M:%S")


def parse_minutes(text):
    """Slurm time formats: M, M:S, H:M:S, D-H, D-H:M, D-H:M:S. Returns minutes, rounded up."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
        parts = [int(p) for p in text.split(":")]
        hours, minutes, secs = (parts + [0, 0])[:3]
    else:
        parts = [int(p) for p in text.split(":")]
        if len(parts) == 1:
            hours, minutes, secs = 0, parts[0], 0
        elif len(parts) == 2:
            hours, minutes, secs = 0, parts[0], parts[1]
        else:
            hours, minutes, secs = parts[:3]
    return days * 1440 + hours * 60 + minutes + (1 if secs > 0 else 0)


def parse_array(spec):
    spec = spec.split("%", 1)[0]
    tasks = []
    for part in spec.split(","):
        step = 1
        if ":" in part:
            part, s = part.split(":")
            step = int(s)
        if "-" in part:
            lo, hi = (int(x) for x in part.split("-"))
            tasks.extend(range(lo, hi + 1, step))
        else:
            tasks.append(int(part))
    return tasks


# ---------------------------------------------------------------------------------------------------- sbatch options

def script_options(script):
    """#SBATCH lines up to the first command, as sbatch reads them."""
    args = []
    for line in script.splitlines()[1:] if script.startswith("#!") else script.splitlines():
        stripped = line.strip()
        if stripped.startswith("#SBATCH"):
            args.extend(stripped[len("#SBATCH"):].split("#", 1)[0].split())
        elif stripped and not stripped.startswith("#"):
            break
    return parse_sbatch_args(args)[0]


# ------------------------------------------------------------------------------------------------------- controller

class Controller:
    def __init__(self, state_dir, config):
        self.dir = os.path.abspath(state_dir)
        self.cfg = config
        self.lock = threading.RLock()
        self.procs = {}
        os.makedirs(os.path.join(self.dir, "scripts"), exist_ok=True)
        self.state_file = os.path.join(self.dir, "state.json")
        if os.path.exists(self.state_file):
            with open(self.state_file) as f:
                self.state = json.load(f)
            for job in self.state["jobs"]:
                if job["state"] in ("RUNNING", "PENDING"):
                    job["state"], job["end"] = "NODE_FAIL", time.time()
        else:
            self.state = {"next_id": 1000, "jobs": []}
        self.save()

    # time ------------------------------------------------------------------------------------------------------
    def elapsed(self, job, now=None):
        if job["start"] is None:
            return 0
        end = job["end"] if job["end"] is not None else (now or time.time())
        return int((end - job["start"]) * self.cfg.get("time_scale", 1))

    def cpu_minutes_used(self, account):
        return sum(self.elapsed(j) * j["cpus"] for j in self.state["jobs"] if j["account"] == account) / 60

    # persistence -----------------------------------------------------------------------------------------------
    def save(self):
        tmp = self.state_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.state, f, indent=1)
        os.replace(tmp, self.state_file)

    def audit(self, request, reply):
        entry = {"ts": time.time(), "cmd": request.get("cmd"), "args": request.get("args"), "cwd": request.get("cwd"),
                 "user": request.get("user"), "chain": request.get("chain"), "rc": reply.get("rc")}
        with open(os.path.join(self.dir, "audit.jsonl"), "a") as f:
            f.write(json.dumps(entry) + "\n")

    # scheduling ------------------------------------------------------------------------------------------------
    def free_nodes(self):
        busy = sum(j["nodes"] for j in self.state["jobs"] if j["state"] == "RUNNING")
        return self.cfg["nodes"] - busy

    def tick(self):
        with self.lock:
            changed = False
            now = time.time()
            for job in self.state["jobs"]:
                if job["state"] != "RUNNING":
                    continue
                proc = self.procs.get(job["id"])
                limit = job["timelimit_min"]
                if limit and self.elapsed(job, now) > limit * 60 and not job.get("killing"):
                    job["killing"] = "TIMEOUT"
                    self.signal(job, signal.SIGTERM)
                if proc is not None and proc.poll() is not None:
                    rc = proc.returncode
                    job["end"] = now
                    job["exit"] = f"{rc}:0" if rc >= 0 else f"0:{-rc}"
                    job["state"] = job.pop("killing", None) or ("COMPLETED" if rc == 0 else "FAILED")
                    del self.procs[job["id"]]
                    changed = True
            for job in self.state["jobs"]:
                if job["state"] != "PENDING" or job.get("held"):
                    continue
                cap = self.cfg["accounts"].get(job["account"], {}).get("cap_cpu_minutes")
                need = (job["timelimit_min"] or 0) * job["cpus"]
                if cap is not None and self.cpu_minutes_used(job["account"]) + need > cap:
                    job["reason"] = "AssocGrpCPUMinutesLimit"
                    continue
                if job["nodes"] > self.free_nodes():
                    job["reason"] = "Resources"
                    continue
                self.start(job, now)
                changed = True
            if changed:
                self.save()

    def signal(self, job, sig):
        proc = self.procs.get(job["id"])
        if proc is None:
            return
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        if sig == signal.SIGTERM:
            threading.Timer(2.0, self.signal, (job, signal.SIGKILL)).start()

    def start(self, job, now):
        job["state"], job["start"], job["reason"] = "RUNNING", now, "None"
        env = {
            "SLURM_JOB_ID": job["id"], "SLURM_JOBID": job["id"], "SLURM_JOB_NAME": job["name"],
            "SLURM_JOB_ACCOUNT": job["account"], "SLURM_JOB_PARTITION": self.cfg["partition"],
            "SLURM_JOB_NUM_NODES": str(job["nodes"]), "SLURM_NNODES": str(job["nodes"]),
            "SLURM_CPUS_ON_NODE": str(self.cfg["cores_per_node"]), "SLURM_SUBMIT_DIR": job["cwd"],
            "SLURM_CLUSTER_NAME": self.cfg["cluster"], "SLURM_JOB_USER": job["user"],
            "SLURMD_SCRIPT": job["script"], "SLURMD_OUTPUT": job["output"], "SLURMD_CWD": job["cwd"],
        }
        if job.get("array_task") is not None:
            env.update({"SLURM_ARRAY_JOB_ID": job["array_job"], "SLURM_ARRAY_TASK_ID": str(job["array_task"])})
        self.procs[job["id"]] = run_job(self.cfg, job, env)

    # client commands -------------------------------------------------------------------------------------------
    def handle(self, request):
        cmd = request.get("cmd")
        handler = {"sbatch": self.sbatch, "squeue": self.squeue, "sacct": self.sacct, "scancel": self.scancel,
                   "sacctmgr": self.sacctmgr}.get(cmd)
        if handler is None:
            return {"rc": 1, "err": f"{cmd}: not supported here\n"}
        if cmd in ("squeue", "sacct", "sacctmgr", "scancel"):
            request = dict(request, args=expand_flags(request.get("args") or []))
        with self.lock:
            try:
                reply = handler(request)
            except ValueError as e:
                reply = {"rc": 1, "err": f"{cmd}: error: {e}\n"}
        self.audit(request, reply)
        return reply

    def sbatch(self, req):
        cli, rest = parse_sbatch_args(req["args"])
        if not rest:
            raise ValueError("Batch job submission failed: no batch script given")
        script = req.get("script")
        if script is None:
            raise ValueError(f"Unable to open file {rest[0]}")
        opts = script_options(script)
        opts.update(cli)
        account = opts.get("account", self.cfg["default_account"])
        if account not in self.cfg["accounts"]:
            raise ValueError("Batch job submission failed: Invalid account or account/partition combination specified")
        nodes = int(str(opts.get("nodes", "1")).split("-")[0])
        if nodes > self.cfg["nodes"]:
            raise ValueError("Batch job submission failed: Requested node configuration is not available")
        timelimit = parse_minutes(opts["time"]) if "time" in opts else None
        base = str(self.state["next_id"])
        self.state["next_id"] += 1
        tasks = parse_array(opts["array"]) if "array" in opts else [None]
        cwd = opts.get("chdir", req["cwd"])
        name = opts.get("job-name", os.path.basename(rest[0]))
        script_path = os.path.join(self.dir, "scripts", f"{base}.sh")
        with open(script_path, "w") as f:
            f.write(script)
        for task in tasks:
            job_id = base if task is None else f"{base}_{task}"
            pattern = opts.get("output", "slurm-%A_%a.out" if task is not None else "slurm-%j.out")
            output = pattern.replace("%j", job_id).replace("%A", base).replace("%a", str(task)).replace("%x", name)
            if not output.startswith("/"):
                output = os.path.join(cwd, output)
            self.state["jobs"].append({
                "id": job_id, "array_job": base, "array_task": task, "name": name, "account": account,
                "user": req["user"], "nodes": nodes, "cpus": nodes * self.cfg["cores_per_node"],
                "timelimit_min": timelimit, "submit": time.time(), "start": None, "end": None,
                "state": "PENDING", "reason": "None", "exit": "0:0", "comment": opts.get("comment", ""),
                "cwd": cwd, "output": output, "script": script_path, "args": rest[1:],
                "held": bool(opts.get("hold")),
            })
        self.save()
        out = base if opts.get("parsable") else f"Submitted batch job {base}"
        return {"rc": 0, "out": out + "\n"}

    def select(self, opts):
        jobs = self.state["jobs"]
        if opts.get("accounts"):
            jobs = [j for j in jobs if j["account"] in opts["accounts"]]
        if opts.get("users"):
            jobs = [j for j in jobs if j["user"] in opts["users"]]
        if opts.get("jobs"):
            jobs = [j for j in jobs if j["id"] in opts["jobs"] or j["array_job"] in opts["jobs"]]
        if opts.get("names"):
            jobs = [j for j in jobs if j["name"] in opts["names"]]
        return jobs

    def squeue(self, req):
        opts, fmt, header = {}, None, True
        states = None
        args = iter(req["args"])
        for a in args:
            key, eq, value = a.partition("=")
            if key in ("-A", "--account"):
                opts["accounts"] = (value if eq else next(args)).split(",")
            elif key in ("-u", "--user"):
                opts["users"] = (value if eq else next(args)).split(",")
            elif key in ("-j", "--jobs"):
                opts["jobs"] = (value if eq else next(args)).split(",")
            elif key in ("-n", "--name"):
                opts["names"] = (value if eq else next(args)).split(",")
            elif key in ("-t", "--states"):
                states = {s.upper() for s in (value if eq else next(args)).split(",")}
            elif key in ("-o", "--format"):
                fmt = value if eq else next(args)
            elif key in ("-h", "--noheader"):
                header = False
            elif key in ("--me",):
                opts["users"] = [req["user"]]
            else:
                raise ValueError(f"unrecognized option '{a}'")
        jobs = [j for j in self.select(opts) if j["state"] in ("PENDING", "RUNNING")]
        if states is not None:
            short = {"PD": "PENDING", "R": "RUNNING"}
            states = {short.get(s, s) for s in states}
            jobs = [j for j in jobs if j["state"] in states]
        fmt = fmt or "%.18i %.9P %.8j %.8u %.2t %.10M %.6D %R"
        lines = []
        if header:
            lines.append(self.squeue_line(fmt, None))
        lines += [self.squeue_line(fmt, j) for j in jobs]
        return {"rc": 0, "out": "".join(line + "\n" for line in lines)}

    def squeue_line(self, fmt, job):
        names = {"i": "JOBID", "A": "JOBID", "j": "NAME", "u": "USER", "a": "ACCOUNT", "P": "PARTITION",
                 "T": "STATE", "t": "ST", "M": "TIME", "l": "TIME_LIMIT", "D": "NODES", "C": "CPUS",
                 "R": "NODELIST(REASON)", "r": "REASON", "V": "SUBMIT_TIME", "S": "START_TIME", "k": "COMMENT"}

        def value(code):
            if job is None:
                return names.get(code, code)
            limit = job["timelimit_min"]
            return {
                "i": job["id"], "A": job["array_job"], "j": job["name"], "u": job["user"], "a": job["account"],
                "P": self.cfg["partition"], "T": job["state"], "t": "R" if job["state"] == "RUNNING" else "PD",
                "M": fmt_squeue_time(self.elapsed(job)), "l": fmt_squeue_time(limit * 60) if limit else "UNLIMITED",
                "D": str(job["nodes"]), "C": str(job["cpus"]),
                "R": "node[1]" if job["state"] == "RUNNING" else f"({job['reason']})", "r": job["reason"],
                "V": fmt_ts(job["submit"]), "S": fmt_ts(job["start"]), "k": job["comment"],
            }.get(code, "")

        def field(m):
            align, width, code = m.group(1), m.group(2), m.group(3)
            text = value(code)
            if width:
                w = int(width)
                text = text[:w] if align == "." else text
                text = text.rjust(w) if align == "." else text.ljust(w)
            return text

        return re.sub(r"%(\.?)(\d*)([A-Za-z])", field, fmt)

    SACCT_DEFAULT = ["JobID", "JobName", "Partition", "Account", "AllocCPUS", "State", "ExitCode"]

    def sacct(self, req):
        opts, fields, parsable, header = {}, None, None, True
        start = end = None
        states = None
        args = iter(req["args"])
        for a in args:
            key, eq, value = a.partition("=")
            take = (lambda: value) if eq else (lambda: next(args))
            if key in ("-A", "--accounts", "--account"):
                opts["accounts"] = take().split(",")
            elif key in ("-u", "--user", "--uid"):
                opts["users"] = take().split(",")
            elif key in ("-j", "--jobs"):
                opts["jobs"] = take().split(",")
            elif key in ("--name",):
                opts["names"] = take().split(",")
            elif key in ("-S", "--starttime"):
                start = parse_time(take())
            elif key in ("-E", "--endtime"):
                end = parse_time(take())
            elif key in ("-s", "--state"):
                states = {s.upper() for s in take().split(",")}
            elif key in ("-o", "--format"):
                fields = take().split(",")
            elif key in ("-P", "--parsable2"):
                parsable = "|"
            elif key in ("-p", "--parsable"):
                parsable = "|+"
            elif key in ("-n", "--noheader"):
                header = False
            elif key in ("-X", "--allocations", "-a", "--allusers", "-L", "--allclusters"):
                pass
            else:
                raise ValueError(f"unrecognized option '{a}'")
        if "users" not in opts and "-a" not in req["args"] and "--allusers" not in req["args"]:
            opts["users"] = [req["user"]]
        jobs = self.select(opts)
        if start is None:
            start = time.mktime(dt.date.today().timetuple())
        jobs = [j for j in jobs if j["submit"] >= start and (end is None or j["submit"] <= end)]
        if states is not None:
            jobs = [j for j in jobs if j["state"] in states]
        specs = [parse_field(f) for f in (fields or self.SACCT_DEFAULT)]
        rows = [[self.sacct_value(j, name) for name, _ in specs] for j in jobs]
        heads = [name for name, _ in specs]
        if parsable:
            sep, trail = "|", parsable == "|+"
            out = []
            if header:
                out.append("|".join(heads) + ("|" if trail else ""))
            out += ["|".join(r) + ("|" if trail else "") for r in rows]
        else:
            widths = [w or 10 for _, w in specs]
            out = []
            if header:
                out.append(" ".join(h[:w].rjust(w) for h, w in zip(heads, widths)))
                out.append(" ".join("-" * w for w in widths))
            for r in rows:
                out.append(" ".join((v if len(v) <= w else v[:w - 1] + "+").rjust(w) for v, w in zip(r, widths)))
        return {"rc": 0, "out": "".join(line + "\n" for line in out)}

    def sacct_value(self, job, name):
        el = self.elapsed(job)
        limit = job["timelimit_min"]
        values = {
            "jobid": job["id"], "jobidraw": job["id"], "jobname": job["name"], "state": job["state"],
            "elapsedraw": str(el), "elapsed": fmt_duration(el),
            "timelimitraw": str(limit) if limit else "UNLIMITED",
            "timelimit": fmt_duration(limit * 60) if limit else "UNLIMITED",
            "cputimeraw": str(el * job["cpus"]), "cputime": fmt_duration(el * job["cpus"]),
            "alloccpus": str(job["cpus"]) if job["start"] else "0", "reqcpus": str(job["cpus"]),
            "nnodes": str(job["nodes"]), "account": job["account"], "user": job["user"],
            "partition": self.cfg["partition"], "submit": fmt_ts(job["submit"]), "start": fmt_ts(job["start"]),
            "end": fmt_ts(job["end"]), "exitcode": job["exit"], "comment": job["comment"],
            "nodelist": "node1" if job["start"] else "None assigned", "cluster": self.cfg["cluster"],
            "alloctres": f"cpu={job['cpus']},node={job['nodes']}" if job["start"] else "",
        }
        if name.lower() not in values:
            raise ValueError(f"Invalid field requested: \"{name}\"")
        return values[name.lower()]

    def scancel(self, req):
        ids, opts = [], {}
        args = iter(req["args"])
        for a in args:
            key, eq, value = a.partition("=")
            if key in ("-u", "--user"):
                opts["users"] = (value if eq else next(args)).split(",")
            elif key in ("-n", "--name", "--jobname"):
                opts["names"] = (value if eq else next(args)).split(",")
            elif key in ("-A", "--account"):
                opts["accounts"] = (value if eq else next(args)).split(",")
            elif a.startswith("-"):
                raise ValueError(f"unrecognized option '{a}'")
            else:
                ids.append(a)
        if ids:
            opts["jobs"] = ids
        if not opts:
            raise ValueError("No job identification provided")
        for job in self.select(opts):
            if job["state"] == "PENDING":
                job["state"], job["end"] = "CANCELLED", time.time()
            elif job["state"] == "RUNNING":
                job["killing"] = "CANCELLED"
                self.signal(job, signal.SIGTERM)
        self.save()
        return {"rc": 0, "out": ""}

    def sacctmgr(self, req):
        args = [a for a in req["args"] if a not in ("-n", "-P", "-p", "--noheader", "--parsable2", "-i")]
        header = "-n" not in req["args"] and "--noheader" not in req["args"]
        words = [a.lower() for a in args[:2]]
        if words[:1] != ["show"] and words[:1] != ["list"] or len(words) < 2 or not words[1].startswith("assoc"):
            raise ValueError("only 'show assoc' is supported here")
        where, fields = {}, ["Cluster", "Account", "User", "GrpTRESMins"]
        for a in args[2:]:
            key, eq, value = a.partition("=")
            if key.lower() == "format":
                fields = value.split(",")
            elif eq:
                where[key.lower()] = value
        rows = []
        for account, spec in self.cfg["accounts"].items():
            if where.get("account", account) != account:
                continue
            cap = spec.get("cap_cpu_minutes")
            for user in ["", req["user"]]:
                if "user" in where and where["user"] != user:
                    continue
                row = {"cluster": self.cfg["cluster"], "account": account, "user": user,
                       "grptresmins": f"cpu={cap}" if cap is not None and user == "" else ""}
                rows.append("|".join(row.get(f.lower(), "") for f in fields))
        out = (["|".join(fields)] if header else []) + rows
        return {"rc": 0, "out": "".join(line + "\n" for line in out)}


def expand_flags(args):
    """Splits clustered boolean flags such as -nP or -nXP into -n -X -P, the way getopt does."""
    out = []
    for a in args:
        if len(a) > 2 and a[0] == "-" and set(a[1:]) <= set("nPpXaLhi"):
            out.extend("-" + c for c in a[1:])
        else:
            out.append(a)
    return out


def parse_field(spec):
    name, _, width = spec.partition("%")
    return name, int(width) if width.isdigit() else None


def parse_time(text):
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d", "%m/%d/%y"):
        try:
            return time.mktime(dt.datetime.strptime(text, fmt).timetuple())
        except ValueError:
            pass
    if text.lower() == "now":
        return time.time()
    raise ValueError(f"invalid time specification: {text}")


def run_job(cfg, job, env):
    """Starts one job in its own process group. job_cmd is an argv; without one, the job runs here with bash.
    The command must run the script at $SLURMD_SCRIPT in $SLURMD_CWD with output to $SLURMD_OUTPUT,
    which jobwrap.sh does inside the sandbox."""
    here = os.path.dirname(os.path.abspath(__file__))
    argv = cfg.get("job_cmd") or ["bash", os.path.join(here, "jobwrap.sh")]
    full_env = dict(os.environ, **env) if not cfg.get("job_cmd") else dict(env, PATH=os.environ["PATH"])
    return subprocess.Popen(argv + job["args"], env=full_env, start_new_session=True,
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------------------------------------------- socket server

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request = json.loads(self.rfile.readline())
        reply = self.server.controller.handle(request)
        self.wfile.write(json.dumps(reply).encode() + b"\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(state_dir, config_path):
    with open(config_path) as f:
        config = json.load(f)
    controller = Controller(state_dir, config)
    os.chdir(controller.dir)  # a socket path is limited to about 108 bytes, so bind a relative name
    if os.path.exists("slurmctld.sock"):
        os.unlink("slurmctld.sock")

    def ticker():
        while True:
            controller.tick()
            time.sleep(0.1)

    threading.Thread(target=ticker, daemon=True).start()

    def stop(signum, frame):
        for proc in list(controller.procs.values()):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    with Server("slurmctld.sock", Handler) as server:
        server.controller = controller
        server.serve_forever()


# ------------------------------------------------------------------------------------------------------------ client

if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
