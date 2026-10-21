#!/usr/bin/env python3
"""usage: eval/run.py <config.json> [--limit N] [--unfrozen]

Runs the evaluation, scaffold.parallel episodes at a time (1 when absent). Each episode: build it, check the model,
start the logging proxy, run the agent client in the sandbox with the task's prompt, stop everything, score it.
The main thread appends each verdict as it arrives. The scaffold is a config value; this version knows `codex`.
The config is the question card's machine part:

{
  "run_id": "smoke-1",
  "question_card": "eval/cards/first-qwen3.6.card",    frozen: committed once, unchanged, no <placeholder>
  "episodes_dir": "~/.cache/hpc-sessions",            episode directories, named at random so nothing in a path
                                                       names the task, arm or seed (the mount table shows paths)
  "approver": "never",                                optional: behind the broker, never (the default) or after:<seconds>,
                                                       the scripted approver of eval/broker/approver.py: the third arm's
                                                       after:300 answers every queued ask and job after five minutes
  "results_dir": "eval/results/smoke-1",              verdicts.jsonl
  "model": {"upstream": "http://127.0.0.1:9090",      the model host's relay
            "alias": "default-model",                 the name the proxy pins every request to
            "expect_upstream_model": "gemma4-26B-mtp", the run stops if the alias serves anything else
            "expect_root": "/path/to/checkpoint",     optional: the checkpoint path vLLM reports as root
            "expect_max_model_len": 131072,           optional: the context length vLLM reports
            "seed_base": 1000,                        each episode's requests carry seed_base + its seed
            "sampling": {"temperature": 1.0},         the proxy sets these on every request
            "fold_developer": true,                   the proxy sends Codex's developer messages as system/user
            "text_into_reasoning": true},             and the agent's past text inside its reasoning
  "scaffold": {"name": "codex", "release_dir": "~/.codex/packages/standalone/releases/<version>",
               "context_window": 65536, "timeout_minutes": 30, "parallel": 4, "disable_features": [...],
               "timeout_minutes_by_family": {"t3-entity-overlap": 180}},   optional: a family's own time limit
  "matrix": {"families": ["t1-walltime"], "variants": ["trap", "control"], "arms": ["A", "E", "E-nobroker"],
             "arm_variants": {"E-nobroker": ["control"]},   optional: the variants an arm runs, else all of them
             "seeds": [1, 2],
             "order_seed": 20261010}                 the cases run in an order shuffled with this seed, so that
}                                                      arm and family do not move with the time of day or the server

The arms (ARMS below): A, no harness; E, the full harness behind the evaluation's broker (episode.sh E --broker);
E-nobroker, the same harness without the broker (episode.sh E). E-nobroker exists to measure task success with the
broker against without, so the first run's config gives it the controls only.

Before the first episode it checks the question card, refuses one that is not frozen, and writes run.json in
results_dir with the card's sha256 and commit, the harness commit and the config; a resumed run must match it.
--unfrozen skips the check for a smoke run and says so in run.json and in every verdict.

A frozen run also refuses to start without eval/env/.site-venv (built by eval/env/site-python.sh), or with one whose
numpy, pandas, scikit-learn or scipy differ from eval/env/site-requirements.txt. run.json and every verdict record
the Python the sandbox offered as "python": the venv's path and those versions, or, with no venv (an --unfrozen run
only), "source": "host" with the host python3's versions. A resumed run must offer the same.

A rerun resumes: it skips every case whose latest verdict has no "error". A case whose latest verdict has one (a
failure of episode.sh, score.py or the model check, the harness's failures and not outcomes) runs again; a client
error or a time-out is an outcome and does not. A client error the model server caused is the harness's: when the
client exits nonzero before its time limit and the last request in the proxy log failed with status 500 or above
(the relay's 502 when its server is down, or the proxy's own 502 when the relay is), the verdict gets the error
"upstream: <status> <reason>". --limit N runs at most N of the cases left.

The model check runs before the first episode and before each one. It reads the served name from the relay's
/v1/models. A relay may restart its server with another checkpoint under the same served name, so with expect_root
or expect_max_model_len it also looks up the alias's base_url in the relay's /admin/endpoints and reads root and
max_model_len from <base_url>/models; a failed lookup fails the check. Those URLs name the relay's own host, so run
the driver there. run.json and every verdict record what it saw: served, and served_root and served_max_model_len
when they were read.

When the model check fails, or the card's kill criterion trips (from 10 outcomes on, more than 20% client errors or
time-outs with no tool call, as eval/analyze.py counts them), the run submits no new episode, records the running
ones as they finish, and exits 2.
An interrupt (Ctrl-C, SIGTERM or SIGHUP) does the same and exits 130; a second one quits at once, leaving the
running episodes unrecorded and their processes alive.

Each verdict line holds the scorer's verdict plus the costs (eval/modellog.py): requests, input and output tokens,
the largest prompt, cached input tokens, model seconds, harness-triggered requests, compactions; then the
scaffold's context window, wall seconds, the client's exit code, and whether the episode hit its time limit; and the
case's arm, whether it ran behind the broker ("broker"), and the Python offered ("python").
"""
import concurrent.futures
import hashlib
import itertools
import json
import os
import random
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from typing import NamedTuple, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import modellog  # noqa: E402
from analyze import KILL_THRESHOLD, scaffold_failure  # noqa: E402

KILL_MIN = 10  # the kill criterion is judged once this many episodes have an outcome
RELAY_PORT = 18080   # inside each sandbox's own network namespace, so every episode can use it
MAX_HOME_GB = 5      # an episode whose home grows past this is killed, checked every 2 s; the tasks need megabytes
MIN_FREE_GB = 100    # below this much free under episodes_dir, no episode starts and running ones are killed
SITE_VENV = os.path.join(HERE, "env", ".site-venv")   # sandbox.sh offers it at /opt/site/python when it exists
SITE_PACKAGES = ("numpy", "pandas", "scikit-learn", "scipy")
HOST_PATH = "/usr/local/bin:/usr/bin:/bin"            # the host's /usr, which the sandbox binds read-only


class Arm(NamedTuple):
    """What episode.sh builds for an arm: its harness arm, and whether the sandbox reaches the scheduler, the
    records and gh only through the evaluation's broker."""
    harness: str
    broker: bool


ARMS = {"A": Arm("A", broker=False), "E": Arm("E", broker=True), "E-nobroker": Arm("E", broker=False)}


def expand(path):
    return os.path.abspath(os.path.expanduser(path))


def git(*args):
    out = subprocess.run(["git", "-C", os.path.dirname(HERE), *args], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def matrix_cases(m):
    """Every case (family, variant, arm, seed) of the config's matrix, in the order shuffled with order_seed. An arm
    runs the variants arm_variants gives it, else all of them; without arm_variants the cases and their order are
    those of itertools.product."""
    unknown = [a for a in m["arms"] if a not in ARMS]
    if unknown:
        sys.exit(f"run.py: unknown arm {', '.join(unknown)}; the arms are {', '.join(ARMS)}")
    arm_variants = m.get("arm_variants", {})
    for arm, variants in arm_variants.items():
        if arm not in m["arms"] or not set(variants) <= set(m["variants"]):
            sys.exit(f"run.py: arm_variants names {arm}: {variants}, not an arm of the matrix with its variants")
    every = [(f, v, a, s) for f, v, a, s in itertools.product(m["families"], m["variants"], m["arms"], m["seeds"])
             if v in arm_variants.get(a, m["variants"])]
    random.Random(m["order_seed"]).shuffle(every)
    return every


def case_key(row):
    return row["family"], row["variant"], row["arm"], row["seed"]


def cases_left(every, verdicts):
    """The cases of every, in its order, whose latest verdict is missing or has an error."""
    latest = {}
    if os.path.exists(verdicts):
        with open(verdicts) as f:
            for line in f:
                r = json.loads(line)
                latest[case_key(r)] = r
    return [c for c in every if c not in latest or "error" in latest[c]]


PROBE = """import json, platform, sys
from importlib import metadata
def version(name):
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None
print(json.dumps({"python": platform.python_version(), **{n: version(n) for n in sys.argv[1:]}}))"""


def offered_python(venv=SITE_VENV):
    """The Python the sandbox offers: the site venv and the versions of SITE_PACKAGES installed in it, or, when
    there is none, the host's python3 and its own. Read from the packages' metadata, without importing them."""
    if os.path.isdir(venv):
        record, exe = {"source": "site", "path": venv, "sandbox_path": "/opt/site/python"}, venv + "/bin/python"
    else:
        exe = shutil.which("python3", path=HOST_PATH)
        record = {"source": "host", "path": exe}
    if not exe:
        return {**record, "error": f"no python3 on {HOST_PATH}"}
    out = subprocess.run([exe, "-I", "-s", "-c", PROBE, *SITE_PACKAGES], capture_output=True, text=True)
    if out.returncode:
        return {**record, "error": out.stderr.strip()[-200:]}
    return {**record, **json.loads(out.stdout)}


def require_site_python(python, requirements=os.path.join(HERE, "env", "site-requirements.txt")):
    """Exits unless the sandbox offers the site venv with the pinned versions of SITE_PACKAGES."""
    if python["source"] != "site":
        sys.exit("run.py: no eval/env/.site-venv; a frozen run offers the pinned Python: build it once on this "
                 "machine with eval/env/site-python.sh, or pass --unfrozen for a smoke run")
    with open(requirements) as f:
        pins = dict(line.strip().split("==", 1) for line in f if "==" in line)
    wrong = [f"{n} {python.get(n)} (pinned {pins.get(n)})" for n in SITE_PACKAGES if python.get(n) != pins.get(n)]
    if wrong:
        sys.exit(f"run.py: {python['path']} offers {', '.join(wrong)}; remove it and rerun eval/env/site-python.sh")


def frozen_card(path):
    """The card's sha256 and the commit that froze it; exits with the reason when the card is not frozen."""
    path = os.path.abspath(path)
    rel = os.path.relpath(path, os.path.dirname(HERE))
    if not os.path.isfile(path):
        sys.exit(f"run.py: no question card at {rel}")
    commits = (git("log", "--format=%H", "--", rel) or "").split()
    if len(commits) != 1:
        sys.exit(f"run.py: {rel} has {len(commits)} commits; a card is frozen by exactly one")
    if git("status", "--porcelain", "--", rel):
        sys.exit(f"run.py: {rel} has uncommitted edits")
    text = open(path).read()
    holes = re.findall(r"<[^>\n]*>", text)
    if holes:
        sys.exit(f"run.py: {rel} still has placeholders: {', '.join(holes)}")
    return hashlib.sha256(text.encode()).hexdigest(), commits[0]


class Served(NamedTuple):
    """What the alias serves now. mismatch says how that differs from the config, and is None when it does not."""
    name: Optional[str]
    root: Optional[str] = None
    max_model_len: Optional[int] = None
    mismatch: Optional[str] = None

    def record(self):
        observed = {"served": self.name, "served_root": self.root, "served_max_model_len": self.max_model_len}
        return {k: v for k, v in observed.items() if k == "served" or v is not None}


def get_json(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def model_check(model):
    """What the alias serves now. upstream is either the model host's relay, whose /v1/models lists aliases, or a
    vLLM server, whose /v1/models lists the one model it loaded under its served name, which is then the alias.
    Through a relay, expect_root or expect_max_model_len makes the check also read the vLLM server behind the
    alias, found through the relay's /admin/endpoints; a failed lookup is a mismatch."""
    upstream, alias = model["upstream"].rstrip("/"), model["alias"]
    try:
        listing = get_json(upstream + "/v1/models")
    except (OSError, ValueError) as e:
        return Served(None, mismatch=f"{alias} unreachable ({e})")
    entry = next((m for m in listing.get("data", []) if m.get("id") == alias), {})
    relayed = "relay" in entry
    name = entry["relay"].get("upstream_model") if relayed else entry.get("id")
    if name != model["expect_upstream_model"]:
        return Served(name, mismatch=f"{alias} serves {name}, not {model['expect_upstream_model']}")
    expected = {field: model[key] for field, key in (("root", "expect_root"), ("max_model_len", "expect_max_model_len"))
                if key in model}
    if relayed and not expected:
        return Served(name)
    try:
        if relayed:
            base_urls = {e["alias"]: e["base_url"] for e in get_json(upstream + "/admin/endpoints")}
            entry = get_json(base_urls[alias].rstrip("/") + "/models")["data"][0]
        served = Served(name, entry["root"], entry["max_model_len"])
    except (OSError, ValueError, LookupError, TypeError, AttributeError) as e:
        return Served(name, mismatch=f"cannot read what the server behind {alias} loaded ({e!r})")
    wrong = [f"{field} {getattr(served, field)!r}, not {want!r}" for field, want in expected.items()
             if getattr(served, field) != want]
    return served._replace(mismatch=f"{alias} serves {', '.join(wrong)}") if wrong else served


def codex_config(scaffold, port, alias):
    lines = [
        f'model = "{alias}"',
        'model_provider = "site"',
        f'model_context_window = {int(scaffold["context_window"])}',
        'approval_policy = "never"',
        'sandbox_mode = "danger-full-access"',
        'web_search = "disabled"',
        "",
        "[model_providers.site]",
        'name = "site"',
        f'base_url = "http://127.0.0.1:{port}/v1"',
        'wire_api = "responses"',
        "",
        "[features]",
    ]
    lines += [f"{f} = false" for f in scaffold.get("disable_features", [])]
    return "\n".join(lines) + "\n"


def upstream_failure(log_path):
    """How the last request in the proxy log failed upstream, status 500 or above, or None. The last one, because
    the client gives up when its last retry fails, so that request's failure is what ended the episode."""
    last = None
    if os.path.exists(log_path):
        with open(log_path) as f:
            for last in f:
                pass
    if not last:
        return None
    e = json.loads(last)
    if e["status"] < 500:
        return None
    try:
        reason = json.loads(e["response"])["error"]["message"]
    except (ValueError, LookupError, TypeError):
        reason = e["response"]
    return f"{e['status']} {reason.strip()}"[:200]


def kill_tripped(verdicts):
    """(tripped, failures, outcomes) over the latest line of each case in verdicts.jsonl that is an outcome, not a
    harness error: tripped once KILL_MIN have an outcome and more than KILL_THRESHOLD of them are scaffold failures."""
    latest = {}
    for line in open(verdicts):
        r = json.loads(line)
        latest[(r["family"], r["variant"], r["arm"], r["seed"])] = r
    outcomes = [r for r in latest.values() if "error" not in r]
    failures = sum(scaffold_failure(r.get("client_exit"), r.get("timed_out"), r.get("requests")) for r in outcomes)
    return len(outcomes) >= KILL_MIN and failures > KILL_THRESHOLD * len(outcomes), failures, len(outcomes)


def timeout_minutes(scaffold, family):
    """The episode's time limit: scaffold.timeout_minutes_by_family for the family, else scaffold.timeout_minutes."""
    return scaffold.get("timeout_minutes_by_family", {}).get(family, scaffold["timeout_minutes"])


def run_episode(cfg, ep, family, variant, arm, seed):
    model, scaffold = cfg["model"], cfg["scaffold"]
    os.makedirs(os.path.dirname(ep), exist_ok=True)
    if disk_free_gb(ep) < MIN_FREE_GB:
        return {"episode": ep, "error": f"disk: {disk_free_gb(ep):.0f} GiB free under episodes_dir, below "
                f"{MIN_FREE_GB}", "stop_run": True}
    env = dict(os.environ)
    if ARMS[arm].broker:
        env["H4R_APPROVER"] = cfg.get("approver", "never")
    built = subprocess.run([os.path.join(HERE, "episode.sh"), family, variant, ARMS[arm].harness, ep, "--seed",
                            str(seed)] + (["--broker"] if ARMS[arm].broker else []), capture_output=True, text=True,
                           env=env)
    if built.returncode:
        subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
        return {"episode": ep, "error": "episode.sh: " + built.stderr.strip()[-300:]}
    meta = json.load(open(os.path.join(ep, "meta.json")))
    python = offered_python()
    meta.update({"run_id": cfg["run_id"], "arm": arm, "broker": ARMS[arm].broker, "python": python})
    with open(os.path.join(ep, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    served = model_check(model)
    if served.mismatch:
        subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
        return {"episode": ep, **served.record(), "error": f"model check: {served.mismatch}", "stop_run": True}
    os.makedirs(os.path.join(ep, "state", "model"))
    os.makedirs(os.path.join(ep, "state", "agent"))
    sock = os.path.join(ep, "state", "model", "proxy.sock")
    log = os.path.join(ep, "state", "model", "requests.jsonl")
    proxy = subprocess.Popen([sys.executable, os.path.join(HERE, "driver", "proxy.py"), "--upstream", model["upstream"],
                              "--alias", model["alias"], "--seed", str(model["seed_base"] + seed), "--log", log,
                              "--unix", sock, "--sampling", json.dumps(model.get("sampling", {}))]
                             + (["--fold-developer"] if model.get("fold_developer") else [])
                             + (["--text-into-reasoning"] if model.get("text_into_reasoning") else []),
                             start_new_session=True)
    for _ in range(200):
        if os.path.exists(sock):
            break
        time.sleep(0.05)
    release = expand(scaffold["release_dir"])
    with open(os.path.join(ep, "sandbox", "binds"), "w") as f:
        f.write(f"{release} /opt/codex\n{os.path.join(HERE, 'driver', 'netrelay.py')} /opt/model/netrelay.py\n"
                f"{os.path.join(HERE, 'driver', 'relay.sh')} /opt/model/relay.sh\n")
    with open(os.path.join(ep, "sandbox", "path"), "w") as f:
        f.write("/opt/codex/bin\n")
    os.makedirs(os.path.join(ep, "home", ".codex"), exist_ok=True)
    with open(os.path.join(ep, "home", ".codex", "config.toml"), "w") as f:
        f.write(codex_config(scaffold, RELAY_PORT, model["alias"]))
    prompt = open(os.path.join(ep, "prompt.md")).read()
    relay = (f"bash /opt/model/relay.sh {RELAY_PORT} /run/model/proxy.sock & "
             f"until (exec 3<>/dev/tcp/127.0.0.1/{RELAY_PORT}) 2>/dev/null; do sleep 0.1; done; exec \"$@\"")
    cmd = [os.path.join(HERE, "env", "sandbox.sh"), ep, "--", "bash", "-c", relay, "relay", "codex", "exec", "--json", "--skip-git-repo-check",
           "--dangerously-bypass-approvals-and-sandbox", "-C", f"/home/agent/{meta['project']}", prompt]
    started = time.time()
    timed_out = disk_kill = None
    minutes = timeout_minutes(scaffold, meta["family"])
    limit = started + minutes * 60
    with open(os.path.join(ep, "state", "agent", "events.jsonl"), "w") as out, \
         open(os.path.join(ep, "state", "agent", "stderr.log"), "w") as err:
        agent = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, start_new_session=True)
        while (rc := agent.poll()) is None:
            if time.time() > limit:
                timed_out = True
            elif home_bytes(os.path.join(ep, "home")) > MAX_HOME_GB * 2**30:
                disk_kill = f"home over {MAX_HOME_GB} GiB"
            elif disk_free_gb(ep) < MIN_FREE_GB:
                disk_kill = f"under {MIN_FREE_GB} GiB free on the host"
            else:
                time.sleep(2)
                continue
            os.killpg(agent.pid, signal.SIGKILL)
            rc = agent.wait()
    wall = round(time.time() - started, 1)
    os.killpg(proxy.pid, signal.SIGTERM)
    proxy.wait()
    subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
    scored = subprocess.run([sys.executable, os.path.join(HERE, "score.py"), ep], capture_output=True, text=True)
    row = {"episode": os.path.basename(ep), **served.record(), "python": python, "client_exit": rc,
           "timed_out": bool(timed_out), "timeout_minutes": minutes,
           "disk_kill": disk_kill,
           "wall_seconds": wall, "context_window": scaffold.get("context_window"), **modellog.costs(log)}
    if not scored.returncode:
        row.update(json.loads(scored.stdout))
    outage = upstream_failure(log) if rc and not timed_out else None
    if disk_kill and "host" in disk_kill:
        row.update({"error": "disk: " + disk_kill, "stop_run": True})
    elif outage:
        row["error"] = "upstream: " + outage
    elif scored.returncode:
        row["error"] = "score.py: " + scored.stderr.strip()[-300:]
    with open(os.path.join(ep, "verdict.json"), "w") as f:
        json.dump(row, f, indent=1)
    return row


def home_bytes(path):
    """Bytes under path, as du counts them: what the agent wrote, since its home is its only writable place."""
    out = subprocess.run(["du", "-sb", path], capture_output=True, text=True)
    return int(out.stdout.split()[0]) if out.stdout else 0


def disk_free_gb(path):
    return shutil.disk_usage(path if os.path.exists(path) else os.path.dirname(path)).free / 2**30


def attempt(cfg, case):
    """run_episode in a fresh directory, with an exception kept as the case's error, so that the other episodes go
    on and a rerun retries the case."""
    ep = os.path.join(expand(cfg["episodes_dir"]), secrets.token_hex(6))
    try:
        return run_episode(cfg, ep, *case)
    except Exception as e:
        subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
        return {"episode": os.path.basename(ep), "error": f"run.py: {e!r}"}


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    cfg = json.load(open(args[0]))
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else None
    unfrozen = "--unfrozen" in args
    card_sha = card_commit = None
    every = matrix_cases(cfg["matrix"])
    if not re.fullmatch(r"never|after:[0-9]+", cfg.get("approver", "never")):
        sys.exit(f"run.py: approver {cfg['approver']!r} is never or after:<seconds>")
    python = offered_python()
    if not unfrozen:
        require_site_python(python)
        card_sha, card_commit = frozen_card(cfg["question_card"])
    served = model_check(cfg["model"])
    if served.mismatch:
        sys.exit(f"run.py: model check: {served.mismatch}")
    results = expand(cfg["results_dir"])
    os.makedirs(results, exist_ok=True)
    run_json = os.path.join(results, "run.json")
    if os.path.exists(run_json):
        before = json.load(open(run_json))
        if before.get("card_sha256") != card_sha:
            sys.exit(f"run.py: {run_json} was started under card sha256 {before.get('card_sha256')}, not {card_sha}")
        if "python" in before and before["python"] != python:
            sys.exit(f"run.py: {run_json} was started with the Python {before['python']}, not {python}")
    else:
        with open(run_json, "w") as f:
            json.dump({"run_id": cfg["run_id"], "question_card": cfg.get("question_card"), "card_sha256": card_sha,
                       "card_commit": card_commit, "unfrozen": unfrozen, "harness_commit": git("rev-parse", "HEAD"),
                       "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **served.record(),
                       "python": python, "arms": {a: ARMS[a]._asdict() for a in cfg["matrix"]["arms"]},
                       "config": cfg}, f, indent=1)
    verdicts = os.path.join(results, "verdicts.jsonl")
    cases = cases_left(every, verdicts)
    print(f"skipping {len(every) - len(cases)} of {len(every)} cases, finished earlier", flush=True)
    cases = cases[:limit]
    parallel = cfg["scaffold"].get("parallel", 1)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.default_int_handler)
    todo = iter(cases)
    n = 0
    stop = interrupted = False
    with concurrent.futures.ThreadPoolExecutor(parallel) as pool:
        running = {pool.submit(attempt, cfg, c): c for c in itertools.islice(todo, parallel)}
        while running:
            try:
                done, _ = concurrent.futures.wait(running, return_when=concurrent.futures.FIRST_COMPLETED)
            except KeyboardInterrupt:
                if interrupted:
                    os._exit(130)
                interrupted = True
                print(f"interrupted: finishing the {len(running)} running episodes; interrupt again to quit "
                      "without them", flush=True)
                continue
            for fut in done:
                family, variant, arm, seed = running.pop(fut)
                row = fut.result()
                row.update({"run_id": cfg["run_id"], "family": family, "variant": variant, "arm": arm,
                            "broker": ARMS[arm].broker, "seed": seed, "card_sha256": card_sha, "unfrozen": unfrozen})
                with open(verdicts, "a") as f:
                    f.write(json.dumps(row, sort_keys=True) + "\n")
                n += 1
                print(f"{n}/{len(cases)} {family} {variant} arm {arm} seed {seed}: "
                      + (row.get("error") or f"violation={row['violation']} success={row['success']} "
                         f"requests={row['requests']} wall={row['wall_seconds']}s"), flush=True)
                stop = stop or bool(row.get("stop_run"))
                tripped, failures, outcomes = kill_tripped(verdicts)
                if tripped and not stop:
                    print(f"kill criterion: {failures} of {outcomes} episodes are scaffold failures (a client error, or "
                          f"a time-out with no tool call), over {KILL_THRESHOLD:.0%}; stopping", flush=True)
                stop = stop or tripped
            if not (stop or interrupted):
                running.update({pool.submit(attempt, cfg, c): c for c in itertools.islice(todo, len(done))})
    if stop or interrupted:
        sys.exit(2 if stop else 130)


if __name__ == "__main__":
    main()
