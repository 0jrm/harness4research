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
               "context_window": 65536, "timeout_minutes": 30, "parallel": 4, "disable_features": [...]},
  "matrix": {"families": ["t1-walltime"], "variants": ["trap", "control"], "arms": ["A", "E"], "seeds": [1, 2],
             "order_seed": 20261010}                 the cases run in an order shuffled with this seed, so that
}                                                      arm and family do not move with the time of day or the server

Before the first episode it checks the question card, refuses one that is not frozen, and writes run.json in
results_dir with the card's sha256 and commit, the harness commit and the config; a resumed run must match it.
--unfrozen skips the check for a smoke run and says so in run.json and in every verdict.

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

When the model check fails, the run submits no new episode, records the running ones as they finish, and exits 2.
An interrupt (Ctrl-C, SIGTERM or SIGHUP) does the same and exits 130; a second one quits at once, leaving the
running episodes unrecorded and their processes alive.

Each verdict line holds the scorer's verdict plus the costs: requests, input and output tokens, the largest
prompt, wall seconds, the client's exit code, and whether the episode hit its time limit.
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
RELAY_PORT = 18080   # inside each sandbox's own network namespace, so every episode can use it
MAX_HOME_GB = 5      # an episode whose home grows past this is killed, checked every 2 s; the tasks need megabytes
MIN_FREE_GB = 100    # below this much free under episodes_dir, no episode starts and running ones are killed


def expand(path):
    return os.path.abspath(os.path.expanduser(path))


def git(*args):
    out = subprocess.run(["git", "-C", os.path.dirname(HERE), *args], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


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


def costs(log_path):
    reqs = inp = out = biggest = 0
    if os.path.exists(log_path):
        with open(log_path) as f:
            for line in f:
                e = json.loads(line)
                if e["method"] != "POST":
                    continue
                reqs += 1
                u = e.get("usage") or {}
                i = u.get("input_tokens", u.get("prompt_tokens", 0)) or 0
                inp += i
                out += u.get("output_tokens", u.get("completion_tokens", 0)) or 0
                biggest = max(biggest, i)
    return {"requests": reqs, "input_tokens": inp, "output_tokens": out, "max_prompt_tokens": biggest}


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


def run_episode(cfg, ep, family, variant, arm, seed):
    model, scaffold = cfg["model"], cfg["scaffold"]
    os.makedirs(os.path.dirname(ep), exist_ok=True)
    if disk_free_gb(ep) < MIN_FREE_GB:
        return {"episode": ep, "error": f"disk: {disk_free_gb(ep):.0f} GiB free under episodes_dir, below "
                f"{MIN_FREE_GB}", "stop_run": True}
    built = subprocess.run([os.path.join(HERE, "episode.sh"), family, variant, arm, ep, "--seed", str(seed)],
                           capture_output=True, text=True)
    if built.returncode:
        subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
        return {"episode": ep, "error": "episode.sh: " + built.stderr.strip()[-300:]}
    meta = json.load(open(os.path.join(ep, "meta.json")))
    meta["run_id"] = cfg["run_id"]
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
        f.write(f"{release} /opt/codex\n{os.path.join(HERE, 'driver', 'netrelay.py')} /opt/model/netrelay.py\n")
    with open(os.path.join(ep, "sandbox", "path"), "w") as f:
        f.write("/opt/codex/bin\n")
    os.makedirs(os.path.join(ep, "home", ".codex"), exist_ok=True)
    with open(os.path.join(ep, "home", ".codex", "config.toml"), "w") as f:
        f.write(codex_config(scaffold, RELAY_PORT, model["alias"]))
    prompt = open(os.path.join(ep, "prompt.md")).read()
    relay = (f"python3 /opt/model/netrelay.py {RELAY_PORT} /run/model/proxy.sock & "
             f"until (exec 3<>/dev/tcp/127.0.0.1/{RELAY_PORT}) 2>/dev/null; do sleep 0.1; done; exec \"$@\"")
    cmd = [os.path.join(HERE, "env", "sandbox.sh"), ep, "--", "bash", "-c", relay, "relay", "codex", "exec", "--json", "--skip-git-repo-check",
           "--dangerously-bypass-approvals-and-sandbox", "-C", f"/home/agent/{meta['project']}", prompt]
    started = time.time()
    timed_out = disk_kill = None
    limit = started + scaffold["timeout_minutes"] * 60
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
    row = {"episode": os.path.basename(ep), **served.record(), "client_exit": rc, "timed_out": bool(timed_out),
           "disk_kill": disk_kill,
           "wall_seconds": wall, **costs(log)}
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
    if not unfrozen:
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
    else:
        with open(run_json, "w") as f:
            json.dump({"run_id": cfg["run_id"], "question_card": cfg.get("question_card"), "card_sha256": card_sha,
                       "card_commit": card_commit, "unfrozen": unfrozen, "harness_commit": git("rev-parse", "HEAD"),
                       "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **served.record(),
                       "config": cfg}, f, indent=1)
    verdicts = os.path.join(results, "verdicts.jsonl")
    latest = {}
    if os.path.exists(verdicts):
        with open(verdicts) as f:
            for line in f:
                r = json.loads(line)
                latest[(r["family"], r["variant"], r["arm"], r["seed"])] = r
    m = cfg["matrix"]
    every = list(itertools.product(m["families"], m["variants"], m["arms"], m["seeds"]))
    random.Random(m["order_seed"]).shuffle(every)
    cases = [c for c in every if c not in latest or "error" in latest[c]]
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
                            "seed": seed, "card_sha256": card_sha, "unfrozen": unfrozen})
                with open(verdicts, "a") as f:
                    f.write(json.dumps(row, sort_keys=True) + "\n")
                n += 1
                print(f"{n}/{len(cases)} {family} {variant} arm {arm} seed {seed}: "
                      + (row.get("error") or f"violation={row['violation']} success={row['success']} "
                         f"requests={row['requests']} wall={row['wall_seconds']}s"), flush=True)
                stop = stop or bool(row.get("stop_run"))
            if not (stop or interrupted):
                running.update({pool.submit(attempt, cfg, c): c for c in itertools.islice(todo, len(done))})
    if stop or interrupted:
        sys.exit(2 if stop else 130)


if __name__ == "__main__":
    main()
