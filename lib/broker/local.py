"""Local mode (owner, decision 8): a verb answered in-process, in a plain shell with no broker, by the same module the
socket would use, against a scheduler.Broker for the enclosing project whose state is <git dir>/guard/broker/.

Only the verbs with a module answer here; the v7 stand-ins' verbs (queue, acct, cancel, the records' add and list)
exist only behind a sandbox's sockets, so here they are X00 too. A record written here is unsigned: there is no
broker key, and a reply says so where it matters (U2's guard run, U3's guard status)."""
import os
import shutil
import subprocess

import refusals
from broker import scheduler, server


def git(*args, cwd=None):
    done = subprocess.run(["git", *args], capture_output=True, text=True, cwd=cwd)
    return done.stdout.strip() if done.returncode == 0 else None


def user_env():
    """The environment the scheduler's clients run in. A broker clears it, since its sbatch is not the agent's; here
    the shell is the user's own, and a site's sbatch, or the evaluation's fake one, names the job's owner by USER and
    finds its controller by SLURM_CONF, so they keep it. The job itself still starts with --export=NONE."""
    return {k: v for k, v in os.environ.items() if not k.startswith("GUARD_")}


def project_broker(cwd=None):
    """The Broker for the git project around cwd, made on first use."""
    top = git("rev-parse", "--show-toplevel", cwd=cwd)
    if top is None:
        raise scheduler.Refused(f"{cwd or os.getcwd()} is not inside a git project")
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=top)
    state = os.path.join(common, "guard", "broker")
    os.makedirs(state, exist_ok=True)
    cfg = {"session": "local", "project": top, "paths": [[top, top]],
           "origin": git("remote", "get-url", "origin", cwd=top) or top,
           "slurm_bin": os.path.dirname(shutil.which("sbatch") or "") or None, "slurm_env": user_env(),
           "user": os.environ.get("USER", ""), "compute_bwrap": False}
    return scheduler.Broker(state, cfg)


def handle(request, sock="scheduler"):
    verb = request.get("verb")
    module = server.module_for(sock, verb) if isinstance(verb, str) else None
    if module is None or module == "X00":
        return refusals.reply(refusals.refuse("X00", verb=verb))
    try:
        return module.handle(request, project_broker(request.get("cwd")))
    except scheduler.Refused as e:
        return {"rc": 1, "err": f"guard broker: refused: {e}\n"}
