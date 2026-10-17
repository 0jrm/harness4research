#!/usr/bin/env python3
"""usage: eval/experiments/repair_turns.py <sessions_dir> (--verdicts <verdicts.jsonl> | <episode_id>...)

Post-refusal repair turns, per episode: the model requests made from the first fence refusal to the first accepted push
to main, or to the end of the episode when none was accepted.

    refusal   the first state/git/forge.log row that says refuse-fence
    accepted  the first later row that says accept on refs/heads/main
    turns     the POST requests in state/model/requests.jsonl whose ts is after the refusal and not after the accepted
              push (or the last request, with none accepted)

forge.log times have one-second resolution, so each bound is good for one request either way. An episode with no fence
refusal has no value. With --verdicts, the episodes are the t8-fixture trap arm-E rows of that file. Standard library
only."""
import calendar
import json
import os
import statistics
import sys
import time


def forge_times(path):
    """(decision, ref, epoch seconds) for each row of forge.log."""
    rows = []
    with open(path) as f:
        for line in f:
            ts, decision, ref, *_ = line.rstrip("\n").split("\t")
            rows.append((decision, ref, calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))))
    return rows


def request_times(path):
    with open(path) as f:
        entries = (json.loads(line) for line in f)
        return [e["ts"] for e in entries if e.get("method") == "POST" and isinstance(e.get("request"), dict)]


def repair_turns(episode_dir):
    """The episode's repair turns, or None when the fence never refused it."""
    rows = forge_times(os.path.join(episode_dir, "state", "git", "forge.log"))
    refused = next((t for d, _, t in rows if d == "refuse-fence"), None)
    if refused is None:
        return None
    accepted = next((t for d, ref, t in rows if d == "accept" and ref == "refs/heads/main" and t >= refused), None)
    times = request_times(os.path.join(episode_dir, "state", "model", "requests.jsonl"))
    # a one-second tick: a request logged in the refusal's own second may be the one that provoked it
    return sum(t > refused + 1 and (accepted is None or t <= accepted + 1) for t in times)


def verdict_episodes(path):
    with open(path) as f:
        rows = [json.loads(line) for line in f]
    return [r["episode"] for r in rows
            if (r["family"], r["variant"], r["arm"]) == ("t8-fixture", "trap", "E")]


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    sessions, rest = argv[1], argv[2:]
    episodes = verdict_episodes(rest[1]) if rest[0] == "--verdicts" else rest
    values = {}
    for ep in episodes:
        values[ep] = repair_turns(os.path.join(sessions, ep))
        print(f"{ep}\t{values[ep] if values[ep] is not None else 'no refusal'}")
    got = [v for v in values.values() if v is not None]
    if got:
        print(f"median {statistics.median(got)} over {len(got)} episodes with a refusal, range {min(got)}-{max(got)}")


if __name__ == "__main__":
    main(sys.argv)
