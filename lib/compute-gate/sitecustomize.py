"""The compute gate: a compute entrypoint started outside a Slurm job stops with two lines, what was refused and the
guard/run preflight command that submits it.

guard/budget.card on the protected branch lists a project's compute entrypoints, such as compute: sim.py job.sh. Python
imports this file as sitecustomize when PYTHONPATH names its directory, and checks the script it is about to run;
bash_env.sh, as BASH_ENV, runs it as python3 -I sitecustomize.py <script> for the script bash is about to run. A job
under Slurm carries SLURM_JOB_ID and passes. This is a guide, not a wall: python3 -I or -c with runpy, a renamed copy,
or an unset variable start the model anyway."""
import os
import sys


def repo_top(path):
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def card_entries(top):
    import subprocess
    git = ["git", "-C", top]
    base = os.environ.get("HPC_GUARD_REF") or subprocess.run(
        git + ["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"],
        capture_output=True, text=True).stdout.strip() or "origin/main"
    card = subprocess.run(git + ["show", f"{base}:guard/budget.card"], capture_output=True, text=True).stdout
    for line in card.splitlines():
        key, _, value = line.partition(":")
        if key.strip() == "compute":
            return [e for e in value.replace(",", " ").split() if e != "none"]
    return []


def batch_script(top, entries):
    for e in entries:
        try:
            with open(os.path.join(top, e)) as f:
                if "#SBATCH" in f.read(4096):
                    return e
        except OSError:
            pass
    return "JOB_SCRIPT"


def run_dir(top, entries):
    runs = os.path.join(top, "runs")
    cards = sorted(r for r in (os.listdir(runs) if os.path.isdir(runs) else [])
                   if not r.startswith("_") and os.path.isfile(os.path.join(runs, r, "question.card")))
    return "runs/" + (cards[0] if len(cards) == 1 else os.path.splitext(os.path.basename(entries[0]))[0])


def refusal(script):
    """The two refusal lines for running script outside a Slurm job, or None when the card does not list it."""
    top = repo_top(script)
    if top is None:
        return None
    entries = card_entries(top)
    rel = os.path.relpath(os.path.abspath(script), top)
    if not any(rel == e or os.path.basename(rel) == os.path.basename(e) for e in entries):
        return None
    home = os.path.expanduser("~")
    where = "~" + top[len(home):] if top.startswith(home + os.sep) else top
    cd = "" if os.path.abspath(os.getcwd()) == top else f"cd {where} && "
    return [f"guard compute: refused {rel} outside a Slurm job; guard/budget.card lists it under compute.",
            f"Submit it instead: {cd}guard/run preflight {run_dir(top, entries)} {batch_script(top, entries)}"]


def gate(script):
    if os.environ.get("SLURM_JOB_ID") or not os.path.isfile(script):
        return
    lines = refusal(script)
    if lines:
        sys.stderr.write("\n".join(lines) + "\n")
        sys.stderr.flush()
        os._exit(2)


if __name__ == "__main__":
    gate(sys.argv[1])
elif sys.argv and sys.argv[0]:
    gate(sys.argv[0])
