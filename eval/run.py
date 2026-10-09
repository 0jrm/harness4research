#!/usr/bin/env python3
"""usage: eval/run.py <config.json> [--limit N] [--keep]

Runs the evaluation one episode at a time: build the episode, check the model, start the logging proxy, run the
agent client in the sandbox with the task's prompt, stop everything, score it, and append the verdict. The
scaffold is a config value; this version knows `codex`. The config is the question card's machine part:

{
  "run_id": "smoke-1",
  "episodes_dir": "~/.cache/hpc-sessions",            episode directories, named at random so nothing in a path
                                                       names the task, arm or seed (the mount table shows paths)
  "results_dir": "eval/results/smoke-1",              verdicts.jsonl and episodes.tsv
  "model": {"upstream": "http://127.0.0.1:19090",     the model server, here an ssh tunnel to the relay
            "alias": "default-model",                 the name the proxy pins every request to
            "expect_upstream_model": "gemma4-26B-mtp", the run stops if the alias serves anything else
            "seed_base": 1000},                       each episode's requests carry seed_base + its seed
  "scaffold": {"name": "codex", "release_dir": "~/.codex/packages/standalone/releases/<version>",
               "context_window": 65536, "timeout_minutes": 30, "disable_features": [...]},
  "matrix": {"families": ["t1-walltime"], "variants": ["trap", "control"], "arms": ["A", "E"], "seeds": [1, 2]}
}

Each verdict line holds the scorer's verdict plus the costs: requests, input and output tokens, the largest
prompt, wall seconds, the client's exit code, and whether the episode hit its time limit.
"""
import itertools
import json
import os
import secrets
import signal
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def expand(path):
    return os.path.abspath(os.path.expanduser(path))


def model_check(model):
    """The upstream model the alias serves now, from the relay's /v1/models."""
    with urllib.request.urlopen(model["upstream"].rstrip("/") + "/v1/models", timeout=30) as r:
        listing = json.load(r)
    for m in listing.get("data", []):
        if m.get("id") == model["alias"]:
            return (m.get("relay") or {}).get("upstream_model") or m.get("root") or m.get("id")
    return None


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


def run_episode(cfg, family, variant, arm, seed, keep):
    model, scaffold = cfg["model"], cfg["scaffold"]
    ep = os.path.join(expand(cfg["episodes_dir"]), secrets.token_hex(6))
    os.makedirs(os.path.dirname(ep), exist_ok=True)
    built = subprocess.run([os.path.join(HERE, "episode.sh"), family, variant, arm, ep, "--seed", str(seed)],
                           capture_output=True, text=True)
    if built.returncode:
        return {"episode": ep, "error": "episode.sh: " + built.stderr.strip()[-300:]}
    meta = json.load(open(os.path.join(ep, "meta.json")))
    served = model_check(model)
    if served != model["expect_upstream_model"]:
        subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
        return {"episode": ep, "error": f"model check: {model['alias']} serves {served}, not {model['expect_upstream_model']}",
                "stop_run": True}
    os.makedirs(os.path.join(ep, "state", "model"))
    os.makedirs(os.path.join(ep, "state", "agent"))
    port_file = os.path.join(ep, "state", "model", "port")
    log = os.path.join(ep, "state", "model", "requests.jsonl")
    proxy = subprocess.Popen([sys.executable, os.path.join(HERE, "driver", "proxy.py"), "--upstream", model["upstream"],
                              "--alias", model["alias"], "--seed", str(model["seed_base"] + seed), "--log", log,
                              "--port-file", port_file], start_new_session=True)
    for _ in range(100):
        if os.path.exists(port_file) and open(port_file).read().strip():
            break
        time.sleep(0.05)
    port = int(open(port_file).read())
    release = expand(scaffold["release_dir"])
    with open(os.path.join(ep, "sandbox", "binds"), "w") as f:
        f.write(f"{release} /opt/codex\n")
    with open(os.path.join(ep, "sandbox", "path"), "w") as f:
        f.write("/opt/codex/bin\n")
    os.makedirs(os.path.join(ep, "home", ".codex"), exist_ok=True)
    with open(os.path.join(ep, "home", ".codex", "config.toml"), "w") as f:
        f.write(codex_config(scaffold, port, model["alias"]))
    prompt = open(os.path.join(ep, "prompt.md")).read()
    cmd = [os.path.join(HERE, "env", "sandbox.sh"), ep, "--", "codex", "exec", "--json", "--skip-git-repo-check",
           "--dangerously-bypass-approvals-and-sandbox", "-C", f"/home/agent/{meta['project']}", prompt]
    started = time.time()
    timed_out = False
    with open(os.path.join(ep, "state", "agent", "events.jsonl"), "w") as out, \
         open(os.path.join(ep, "state", "agent", "stderr.log"), "w") as err:
        agent = subprocess.Popen(cmd, stdout=out, stderr=err, stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            rc = agent.wait(timeout=scaffold["timeout_minutes"] * 60)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(agent.pid, signal.SIGKILL)
            rc = agent.wait()
    wall = round(time.time() - started, 1)
    os.killpg(proxy.pid, signal.SIGTERM)
    proxy.wait()
    subprocess.run([os.path.join(HERE, "env", "down.sh"), ep])
    scored = subprocess.run([sys.executable, os.path.join(HERE, "score.py"), ep], capture_output=True, text=True)
    row = {"episode": os.path.basename(ep), "served": served, "client_exit": rc, "timed_out": timed_out,
           "wall_seconds": wall, **costs(log)}
    if scored.returncode:
        row["error"] = "score.py: " + scored.stderr.strip()[-300:]
    else:
        row.update(json.loads(scored.stdout))
    with open(os.path.join(ep, "verdict.json"), "w") as f:
        json.dump(row, f, indent=1)
    return row


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    cfg = json.load(open(args[0]))
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else None
    keep = "--keep" in args
    results = expand(cfg["results_dir"])
    os.makedirs(results, exist_ok=True)
    m = cfg["matrix"]
    cases = list(itertools.product(m["families"], m["variants"], m["arms"], m["seeds"]))
    for n, (family, variant, arm, seed) in enumerate(cases[:limit] if limit else cases, 1):
        row = run_episode(cfg, family, variant, arm, seed, keep)
        row.update({"run_id": cfg["run_id"], "family": family, "variant": variant, "arm": arm, "seed": seed})
        with open(os.path.join(results, "verdicts.jsonl"), "a") as f:
            f.write(json.dumps(row, sort_keys=True) + "\n")
        print(f"{n}/{len(cases)} {family} {variant} arm {arm} seed {seed}: "
              + (row.get("error") or f"violation={row['violation']} success={row['success']} "
                 f"requests={row['requests']} wall={row['wall_seconds']}s"), flush=True)
        if row.get("stop_run"):
            sys.exit(2)


if __name__ == "__main__":
    main()
