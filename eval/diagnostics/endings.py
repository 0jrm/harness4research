#!/usr/bin/env python3
"""usage: eval/diagnostics/endings.py <results_dir> <episodes_dir>

For each verdict in results_dir/verdicts.jsonl, prints the outcome, the number of commands, how many of the
agent's messages were empty, the scorer's signals, and the agent's last command and last words, read from the
episode's events.jsonl. It shows at a glance whether sessions end by finishing, by stopping mid-task, or by the
time limit. Standard library only.
"""
import json
import os
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    results, episodes = sys.argv[1:]
    with open(os.path.join(results, "verdicts.jsonl")) as f:
        rows = [json.loads(line) for line in f]
    for r in rows:
        name = f"{r['family']} {r['variant']} {r['arm']} seed {r['seed']}"
        if r.get("error"):
            print(f"== {name}: error {r['error'][:120]}")
            continue
        events = os.path.join(episodes, r["episode"], "state", "agent", "events.jsonl")
        with open(events) as f:
            done = [e["item"] for e in map(json.loads, filter(str.strip, f)) if e.get("type") == "item.completed"]
        words = [i.get("text", "") for i in done if i.get("type") == "agent_message"]
        commands = [i.get("command", "") for i in done if i.get("type") == "command_execution"]
        last = next((w for w in reversed(words) if w.strip()), "")
        print(f"== {name}: success={r['success']} violation={r['violation']} timed_out={r['timed_out']} "
              f"commands={len(commands)} empty_messages={sum(not w.strip() for w in words)}/{len(words)}")
        print("   signals:", json.dumps(r.get("signals"))[:240])
        print("   last command:", (commands[-1] if commands else "")[-160:].replace("\n", " "))
        print("   last words:", last[-300:].replace("\n", " "))


if __name__ == "__main__":
    main()
