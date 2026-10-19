"""parse(): a Request and the script's bytes as the broker read them into an Invocation and an SbatchSpec.

The options are sbatch's, read the way sbatch reads them: the script's #SBATCH lines first, then the command line,
the later value winning. Only the v7 broker's fields are taken; the account, job name and comment are the broker's to
set and are dropped; anything else is Unparsed, which the caller turns into R01 with the command rebuilt."""
import hashlib
import os
import re
import shlex

from policy import Invocation, SbatchSpec

LAUNCHERS = ("sbatch", "srun", "bash", "sh")
# sbatch option -> SbatchSpec field
FIELDS = {"time": "time_min", "nodes": "nodes", "ntasks": "tasks", "cpus-per-task": "cpus_per_task", "mem": "mem_gb",
          "gpus": "gpus", "array": "array", "dependency": "dependency", "partition": "partition", "output": "output"}
SHORT = {"-t": "time", "-N": "nodes", "-n": "ntasks", "-c": "cpus-per-task", "-G": "gpus", "-a": "array",
         "-d": "dependency", "-p": "partition", "-o": "output", "-A": "account", "-J": "job-name"}
SET_BY_BROKER = ("account", "job-name", "comment")
FLAGS = ("ignore-pbs", "parsable")
RUN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
INDEX = r"[0-9]+(-[0-9]+(:[0-9]+)?)?"
ARRAY = re.compile(rf"^{INDEX}(,{INDEX})*(%[0-9]+)?$")
DEPENDENCY = re.compile(r"^(after|afterany|afterok|afternotok):[0-9]+(_[0-9]+)?(:[0-9]+(_[0-9]+)?)*$")
OUTPUT = re.compile(r"^[A-Za-z0-9_.%/-]+$")
MEM = re.compile(r"^([0-9]+)([KMGT]?)$")


class Unparsed(Exception):
    """What the agent typed is not a job this harness can price; the message says what, for R01's line 1."""


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


def read_options(words):
    """(options as {sbatch name: value}, the words after the last option)."""
    opts, i = {}, 0
    while i < len(words):
        w = words[i]
        if w.startswith("--") and len(w) > 2:
            name, eq, value = w[2:].partition("=")
            if name in FLAGS:
                i += 1
                continue
            if name not in FIELDS and name not in SET_BY_BROKER:
                longer = sorted(o for o in (*FIELDS, *SET_BY_BROKER, *FLAGS) if o.startswith(name))
                hint = f" ({w.split('=')[0]} shortens --{longer[0]}; write it in full)" if len(longer) == 1 else ""
                raise Unparsed(f"sbatch option --{name} is not one guard run takes{hint}")
        elif w in SHORT:
            name, eq, value = SHORT[w], "", ""
        elif w[:2] in SHORT and len(w) > 2:
            name, eq, value = SHORT[w[:2]], "=", w[2:]
        elif w.startswith("-") and w != "-":
            raise Unparsed(f"sbatch option {w} is not one guard run takes")
        else:
            return opts, words[i:]
        if not eq:
            if i + 1 >= len(words):
                raise Unparsed(f"{w} has no value")
            value = words[i + 1]
            i += 1
        opts[name] = value
        i += 1
    return opts, []


def split_command(words):
    """The words after guard run's --, as (options, script, args): a leading launcher dropped, sbatch's options up to
    the first word that is not one, then the script and its arguments."""
    words = list(words)
    while words and words[0] in LAUNCHERS:
        words.pop(0)
    _, rest = read_options(words)
    if not rest:
        raise Unparsed("no job script after the sbatch options")
    return tuple(words[:len(words) - len(rest)]), rest[0], tuple(rest[1:])


def script_words(text):
    """The #SBATCH words of a script: the comment block before its first command."""
    words = []
    lines = text.splitlines()
    for line in lines[1:] if lines and lines[0].startswith("#!") else lines:
        s = line.strip()
        if s.startswith("#SBATCH"):
            words += s[len("#SBATCH"):].split("#", 1)[0].split()
        elif s and not s.startswith("#"):
            break
    return words


def positive(name, value):
    if not value.isdigit() or int(value) < 1:
        raise Unparsed(f"{name} {value} is not one positive integer")
    return int(value)


def spec_of(opts):
    if "time" not in opts:
        raise Unparsed("state the walltime with --time")
    minutes = to_minutes(opts["time"])
    if minutes is None:
        raise Unparsed(f"time {opts['time']} is not a Slurm time such as 30 or 02:00:00")
    out = {"time_min": minutes}
    for name in ("nodes", "ntasks", "cpus-per-task"):
        if name in opts:
            out[FIELDS[name]] = positive(name, opts[name])
    if "mem" in opts:
        m = MEM.match(opts["mem"])
        if not m:
            raise Unparsed(f"mem {opts['mem']} is not a size such as 4G")
        mb = int(m.group(1)) * {"K": 1 / 1024, "": 1, "M": 1, "G": 1024, "T": 1024 * 1024}[m.group(2)]
        out["mem_gb"] = max(1, -(-int(mb) // 1024))
    if "gpus" in opts:
        if not opts["gpus"].isdigit():
            raise Unparsed(f"gpus {opts['gpus']} is not a count")
        out["gpus"] = int(opts["gpus"])
    if "array" in opts:
        if not ARRAY.match(opts["array"]):
            raise Unparsed(f"array {opts['array']} is not an index list such as 0-9")
        out["array"], out["array_n"] = opts["array"], count_tasks(opts["array"])
    if "dependency" in opts:
        for item in opts["dependency"].split(","):
            if item != "singleton" and not DEPENDENCY.match(item):
                raise Unparsed(f"dependency {item} is not after*:<job ids> or singleton")
        out["dependency"] = opts["dependency"]
    if "partition" in opts:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", opts["partition"]):
            raise Unparsed(f"partition {opts['partition']} is not a partition name")
        out["partition"] = opts["partition"]
    if "output" in opts:
        if not OUTPUT.match(opts["output"]):
            raise Unparsed(f"output {opts['output']} is not a plain path")
        out["output"] = opts["output"]
    return SbatchSpec(**out)


def run_id(run_dir):
    rid = os.path.basename(os.path.normpath(run_dir or ""))
    if not RUN.match(rid):
        raise Unparsed(f"run directory {run_dir!r} does not end in a run id such as runs/2026-10-19-sweep")
    return rid


def parse(request, script, session, ts):
    """(Invocation, SbatchSpec) from a Request and the script's bytes, which the broker read through its path map."""
    if not request.why or "\n" in request.why:
        raise Unparsed("--why is missing")
    file_opts, _ = read_options(script_words(script.decode(errors="replace")))
    cli_opts, rest = read_options(list(request.options))
    if rest:
        raise Unparsed(f"{rest[0]} is not an sbatch option")
    inv = Invocation(run_id=run_id(request.run_dir), why=request.why, cause=request.cause,
                     options=tuple(request.options), script=request.script,
                     script_sha256=hashlib.sha256(script).hexdigest(), args=tuple(request.args), cwd=request.cwd,
                     session=session, ts=ts)
    return inv, spec_of({**file_opts, **cli_opts})


def run_line(run_dir, options, script, args=(), why=None):
    """The guard run command for a job, as an agent can paste it: E2b's corrected_run, and R09's line 2."""
    why = why or f"Run {os.path.basename(script)} for run {os.path.basename(os.path.normpath(run_dir))}."
    words = ["guard", "run", run_dir, "--why", why, "--", *options, script, *args]
    return " ".join(shlex.quote(w) for w in words)


def old_command(cmd, args):
    """The guard run line for a v7 command (guard/run preflight or launch), or None when it names no job."""
    args = list(args)
    if cmd == "preflight" and len(args) >= 2 and not args[0].startswith("-"):
        return run_line(args[0], args[2:], args[1])
    if cmd == "launch" and args and not args[0].startswith("-") and "--" in args:
        cut = args.index("--")
        command, options = args[cut + 1:], []
        for a in args[1:cut]:
            name, _, value = a.partition("=")
            if name == "--gpus":
                n = 0 if value in ("", "none") else len(value.split(","))
                options += [f"--gpus={n}"] if n else []
            elif name in ("--time", "--mem"):
                options.append(a)
        if command:
            return run_line(args[0], options, command[0], command[1:])
    return None
