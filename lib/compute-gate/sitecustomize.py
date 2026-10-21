"""The compute gate: a compute entrypoint started outside a job stops with refusal C01, what was refused and the guard
run command that submits it (experiment E6b, design-v8 section 2).

guard/budget.card on the protected branch lists a project's compute entrypoints, such as compute: sim.py job.sh. Python
imports this file as sitecustomize when PYTHONPATH names its directory, and checks the script it is about to run;
bash_env.sh, as BASH_ENV, runs it as python3 -I sitecustomize.py <script> for the script bash is about to run. A Slurm
job carries SLURM_JOB_ID and a host job GUARD_JOB_ID, and either passes. This is a guide, not a wall: python3 -I or -c
with runpy, a renamed copy, or an unset variable start the model anyway."""
import os
import subprocess
import sys

LIB = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def repo_top(path):
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def card(top):
    """guard/budget.card on the protected branch. git runs without BASH_ENV and PYTHONPATH, so a git that is the PATH
    shim, a bash script, never re-enters the gate."""
    git = ["git", "-C", top]
    env = {k: v for k, v in os.environ.items() if k not in ("BASH_ENV", "PYTHONPATH")}
    base = os.environ.get("HPC_GUARD_REF") or subprocess.run(
        git + ["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"],
        capture_output=True, text=True, env=env).stdout.strip() or "origin/main"
    text = subprocess.run(git + ["show", f"{base}:guard/budget.card"], capture_output=True, text=True, env=env).stdout
    keys = {}
    for line in text.splitlines():
        key, _, value = line.partition(":")
        keys.setdefault(key.strip(), value.strip())
    return keys


def entries(keys):
    return [e for e in keys.get("compute", "").replace(",", " ").split() if e != "none"]


def batch_script(top, listed):
    for e in listed:
        try:
            with open(os.path.join(top, e)) as f:
                if "#SBATCH" in f.read(4096):
                    return e
        except OSError:
            pass
    return listed[0]


def run_id(top, listed):
    runs = os.path.join(top, "runs")
    dirs = sorted(r for r in (os.listdir(runs) if os.path.isdir(runs) else [])
                  if not r.startswith((".", "_")) and os.path.isdir(os.path.join(runs, r)))
    return dirs[0] if len(dirs) == 1 else os.path.splitext(os.path.basename(listed[0]))[0]


def refusal(script):
    """Refusal C01 for running script outside a job, or None when the card does not list it."""
    top = repo_top(script)
    if top is None:
        return None
    keys = card(top)
    listed = entries(keys)
    rel = os.path.relpath(os.path.abspath(script), top)
    if not any(rel == e or os.path.basename(rel) == os.path.basename(e) for e in listed):
        return None
    minutes = keys.get("max_walltime_minutes", "")
    sys.path.insert(0, LIB)
    import refusals
    fill = {"entry": rel, "run": run_id(top, listed), "script": batch_script(top, listed),
            "minutes": minutes if minutes.isdigit() else "60"}
    try:
        return refusals.render(refusals.refuse("C01", **fill))
    except ValueError:
        return refusals.render(refusals.refuse("C01", **{**fill, "run": "job", "script": "job.sh"}))


def gate(script):
    if os.environ.get("SLURM_JOB_ID") or os.environ.get("GUARD_JOB_ID") or not os.path.isfile(script):
        return
    text = refusal(script)
    if text:
        sys.stderr.write(text)
        sys.stderr.flush()
        os._exit(2)


if __name__ == "__main__":
    gate(sys.argv[1])
elif sys.argv and sys.argv[0] and not {"-h", "--help"} & set(sys.argv[1:]):
    gate(sys.argv[0])
