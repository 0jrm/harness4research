#!/usr/bin/env python3
"""usage: eval/driver/check_seed.py --upstream URL --alias NAME

Settles two of the question card's unverified claims against the model server: whether /v1/responses honours a
per-request seed, and whether two requests with the same seed sent at the same time come back identical. It
sends one short prompt at temperature 1: twice in turn with seed 7, twice at once with seed 7, and once with
seed 8, and prints one line per comparison. Standard library only.
"""
import argparse
import json
import threading
import urllib.request

PROMPT = "Write five random English words, separated by spaces, and nothing else."


def ask(upstream, alias, seed):
    body = {"model": alias, "input": PROMPT, "temperature": 1.0, "max_output_tokens": 400, "seed": seed}
    req = urllib.request.Request(upstream.rstrip("/") + "/v1/responses", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        reply = json.load(r)
    texts = [c.get("text", "") for item in reply.get("output", []) if item.get("type") == "message"
             for c in item.get("content", [])]
    return " ".join(texts).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--alias", required=True)
    a = ap.parse_args()
    first, second = ask(a.upstream, a.alias, 7), ask(a.upstream, a.alias, 7)
    together = [None, None]
    threads = [threading.Thread(target=lambda i=i: together.__setitem__(i, ask(a.upstream, a.alias, 7))) for i in (0, 1)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    other = ask(a.upstream, a.alias, 8)
    print(f"seed 7, one after the other, identical: {'yes' if first == second else 'no'}")
    print(f"seed 7, at the same time, identical:    {'yes' if together[0] == together[1] else 'no'}")
    print(f"seed 7 and seed 8 differ:               {'yes' if first != other else 'no'}")
    print(f"samples: {first!r} | {together[0]!r} | {other!r}")


if __name__ == "__main__":
    main()
