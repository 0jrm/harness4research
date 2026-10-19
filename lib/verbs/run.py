#!/usr/bin/env python3
"""guard run <run_dir> --why "<sentence>" [--cause "<text>"] -- <sbatch options> <script> [args]

The only way a job reaches the scheduler (E6b). This end reads argv into a Request (design-v8 section 3) and prints
the broker's reply; it decides nothing and reads no file. A leading sbatch, srun, bash or sh after -- is dropped
(E2b). When argv is not a guard run line, R01's line 2 is the line rebuilt from the words it has."""
import dataclasses
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
import _path  # noqa: E402,F401
import refusals  # noqa: E402
from broker import transport  # noqa: E402
from policy import Request  # noqa: E402
from policy.decide import known_options  # noqa: E402
from policy.invocation import LAUNCHERS, Unparsed, run_line, split_command  # noqa: E402


def own_options(head):
    """(run_dir, why, cause, the words that are none of them) from the words before --."""
    named, run_dir, rest, it = {"why": None, "cause": None}, None, [], iter(head)
    for a in it:
        name, eq, value = a[2:].partition("=")
        if a.startswith("--") and name in named:
            named[name] = value if eq else next(it, None)
        elif run_dir is None and not a.startswith("-") and (a.startswith("runs/") or not os.path.isfile(a)):
            run_dir = a
        else:
            rest.append(a)
    return run_dir, named["why"], named["cause"], rest


def rebuilt(run_dir, why, cause, words):
    """R01's line 2: guard run with the agent's run directory and --why, and the job's words after --."""
    words = list(words)
    while words and words[0] in LAUNCHERS:
        words.pop(0)
    try:
        options, script, args = split_command(words)
    except Unparsed:
        options = known_options([w for w in words if w.startswith("-")])
        script, args = next((w for w in words if not w.startswith("-")), "job.sh"), ()
    one_line = lambda s: s.strip() if s and s.strip() and "\n" not in s else None
    line = run_line(run_dir or f"runs/{os.path.splitext(os.path.basename(script))[0] or 'job'}", options, script, args,
                    one_line(why))
    if one_line(cause):
        line = line.replace(" -- ", f" --cause {shlex.quote(cause.strip())} -- ", 1)
    return line


def usage(what, line):
    try:
        r = refusals.refuse("R01", what=what, next=line)
    except ValueError:
        r = refusals.refuse("R01", what=what, next="guard status")
    sys.stderr.write(refusals.render(r))
    return r.exit


def main(argv):
    cut = argv.index("--") if "--" in argv else None
    head, words = (argv[:cut], argv[cut + 1:]) if cut is not None else (argv, [])
    run_dir, why, cause, rest = own_options(head)
    if cut is None:
        return usage("put -- between guard run's own options and the job's sbatch options and script",
                     rebuilt(run_dir, why, cause, rest))
    if rest:
        return usage(f"{rest[0]} is not one of guard run's options, which are the run directory, --why and --cause",
                     rebuilt(run_dir, why, cause, words))
    if not run_dir or not why or not why.strip() or "\n" in why or (cause is not None and "\n" in cause):
        return usage("name the run directory and say --why" if not run_dir or not why else "--why or --cause is on "
                     "more than one line", rebuilt(run_dir, why, cause, words))
    try:
        options, script, args = split_command(words)
    except Unparsed as e:
        return usage(str(e), rebuilt(run_dir, why, cause, words))
    request = Request("run", run_dir, why.strip(), cause.strip() if cause and cause.strip() else None, options, script,
                      args, os.getcwd())
    reply = transport.send({k: list(v) if isinstance(v, tuple) else v for k, v in dataclasses.asdict(request).items()})
    sys.stdout.write(refusals.cap(reply.get("out", ""), "run"))
    sys.stderr.write(refusals.cap(reply.get("err", ""), "run"))
    return reply.get("rc", 1)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
