#!/usr/bin/env python3
"""usage: eval/diagnostics/replay.py <episode_dir>... [--upstream URL] [--samples N]

Replays the last request an episode sent to the model, under variants of its history, and counts how many of N
replies contain a tool call. An agent that stops right after announcing a step ends its session, so this measures
how much each part of the history drives that. Variants: as logged; assistant text removed; reasoning removed; and
the proxy's own repair (driver/proxy.py text_into_reasoning) applied to the logged request. The seed is dropped
so the samples differ. Standard library only.
"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("proxy", os.path.join(HERE, "..", "driver", "proxy.py"))
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


def is_text(item):
    return item.get("type") == "message" and item.get("role") == "assistant"


VARIANTS = {
    "as logged": lambda items: items,
    "no assistant text": lambda items: [i for i in items if not is_text(i)],
    "no reasoning": lambda items: [i for i in items if i.get("type") != "reasoning"],
    "proxy repair": proxy.text_into_reasoning,
}


def calls_a_tool(upstream, body):
    req = urllib.request.Request(upstream.rstrip("/") + "/v1/responses", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return any(o["type"] == "function_call" for o in json.load(r)["output"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    ap.add_argument("episodes", nargs="+")
    ap.add_argument("--upstream", default="http://127.0.0.1:9185")
    ap.add_argument("--samples", type=int, default=8)
    a = ap.parse_args()
    for ep in a.episodes:
        with open(os.path.join(ep, "state", "model", "requests.jsonl")) as f:
            last = json.loads(f.readlines()[-1])["request"]
        base = dict(last, stream=False)
        base.pop("seed", None)
        counts = []
        for name, make in VARIANTS.items():
            body = dict(base, input=make(base["input"]))
            with concurrent.futures.ThreadPoolExecutor(a.samples) as pool:
                hits = sum(pool.map(lambda _: calls_a_tool(a.upstream, body), range(a.samples)))
            counts.append(f"{name} {hits}/{a.samples}")
        print(os.path.basename(ep.rstrip("/")), "|", " | ".join(counts), flush=True)


if __name__ == "__main__":
    main()
