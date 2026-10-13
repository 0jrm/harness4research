#!/usr/bin/env python3
"""usage: eval/diagnostics/compare_runs.py <name>=<results_dir>:<episodes_dir> ...

Compares runs side by side from their verdicts and each episode's proxy log: outcomes (succeeded, violated, harness
errors), how sessions ended (finished with a closing message, stopped right after announcing a step, timed out, client
error), requests and tokens per episode, time per episode, and each run's span from its first request to its last.
An episode "stopped" when the client exited 0 before its time limit, did not succeed, and its last words announce a
step ("let me", "now i'll", "i'll", "next", ending in ":" ...). Standard library only.
"""
import json
import os
import re
import statistics
import sys

ANNOUNCES = re.compile(r"(let me|let's|now i'll|i'll|i will|next,|then i|:\s*$)", re.I)


def last_words(ep_dir):
    path = os.path.join(ep_dir, "state", "agent", "events.jsonl")
    if not os.path.exists(path):
        return ""
    with open(path) as f:
        done = [e["item"] for e in map(json.loads, filter(str.strip, f)) if e.get("type") == "item.completed"]
    words = [i.get("text", "") for i in done if i.get("type") == "agent_message"]
    return next((w for w in reversed(words) if w.strip()), "")


def requests(ep_dir):
    path = os.path.join(ep_dir, "state", "model", "requests.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def ending(row, words):
    if row.get("error"):
        return "harness error"
    if row.get("timed_out"):
        return "timed out"
    if row.get("client_exit"):
        return "client error"
    if row.get("success"):
        return "finished"
    return "stopped mid-task" if ANNOUNCES.search(words.strip()[-160:]) else "ended, unsuccessful"


def summarize(results, episodes):
    with open(os.path.join(results, "verdicts.jsonl")) as f:
        rows = list({(r["family"], r["variant"], r["arm"], r["seed"]): r for r in map(json.loads, f)}.values())
    s = {"episodes": len(rows), "endings": {}, "req": [], "inp": [], "out": [], "cached": [], "wall": [], "model_s": [],
         "first": None, "last": None}
    for r in rows:
        ep = os.path.join(episodes, r["episode"])
        end = ending(r, last_words(ep))
        s["endings"][end] = s["endings"].get(end, 0) + 1
        if r.get("error"):
            continue
        reqs = [q for q in requests(ep) if q.get("method") == "POST"]
        usage = [q.get("usage") or {} for q in reqs]
        s["req"].append(len(reqs))
        s["inp"].append(sum(u.get("input_tokens", 0) or 0 for u in usage))
        s["out"].append(sum(u.get("output_tokens", 0) or 0 for u in usage))
        s["cached"].append(sum((u.get("input_tokens_details") or {}).get("cached_tokens", 0) or 0 for u in usage))
        s["wall"].append(r.get("wall_seconds") or 0)
        s["model_s"].append(sum(q.get("seconds", 0) for q in reqs))
        for q in reqs:
            t0, t1 = q["ts"], q["ts"] + q.get("seconds", 0)
            s["first"] = t0 if s["first"] is None else min(s["first"], t0)
            s["last"] = t1 if s["last"] is None else max(s["last"], t1)
    s["succeeded"] = sum(1 for r in rows if r.get("success"))
    s["violated"] = sum(1 for r in rows if r.get("violation"))
    return s


def med(xs):
    return statistics.median(xs) if xs else 0


def main():
    runs = []
    for arg in sys.argv[1:]:
        name, _, dirs = arg.partition("=")
        results, _, episodes = dirs.partition(":")
        if not (name and results and episodes):
            sys.exit(__doc__)
        runs.append((name, summarize(results, episodes)))
    if not runs:
        sys.exit(__doc__)
    cols = [n for n, _ in runs]
    endings = sorted({e for _, s in runs for e in s["endings"]})
    lines = [("episodes", lambda s: s["episodes"]), ("succeeded", lambda s: s["succeeded"]),
             ("violated", lambda s: s["violated"])]
    lines += [(f"  {e}", lambda s, e=e: s["endings"].get(e, 0)) for e in endings]
    lines += [
        ("requests, median / total", lambda s: f"{med(s['req']):g} / {sum(s['req'])}"),
        ("input tokens, median / total", lambda s: f"{med(s['inp']):,.0f} / {sum(s['inp']):,}"),
        ("output tokens, median / total", lambda s: f"{med(s['out']):,.0f} / {sum(s['out']):,}"),
        ("cached input tokens, total", lambda s: f"{sum(s['cached']):,}"),
        ("output per input token", lambda s: f"{sum(s['out']) / sum(s['inp']):.3f}" if sum(s["inp"]) else "-"),
        ("episode seconds, median / max", lambda s: f"{med(s['wall']):.0f} / {max(s['wall'] or [0]):.0f}"),
        ("seconds waiting on the model, share", lambda s: f"{sum(s['model_s']) / sum(s['wall']):.0%}" if sum(s["wall"]) else "-"),
        ("run span, first to last request, min", lambda s: f"{(s['last'] - s['first']) / 60:.1f}" if s["first"] else "-"),
    ]
    width = max(len(label) for label, _ in lines)
    print(" " * width + "  " + "  ".join(f"{c:>18}" for c in cols))
    for label, get in lines:
        print(f"{label:<{width}}  " + "  ".join(f"{str(get(s)):>18}" for _, s in runs))


if __name__ == "__main__":
    main()
