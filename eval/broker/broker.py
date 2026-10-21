#!/usr/bin/env python3
"""The evaluation's broker: lib/broker/ with the forge (forge.py) added, for an episode's state directory.

    broker.py setup <state_dir>                         # once: the broker's signing key (guard broker setup)
    broker.py serve <state_dir> <config.json>
    broker.py approve card <state_dir> <run_id>         # the owner signs card/<run_id> (git tag -s)
    broker.py revoke card <state_dir> <run_id>          # the owner deletes card/<run_id>; a revoked row
    broker.py records ack|done|dismiss <state_dir> <id> [--note N]   # only a person closes a needs-you item
    broker.py review <state_dir> <pr>                   # guard review, the reviewer in its own sandbox (forge.py)
    broker.py merge <state_dir> <pr>                    # guard merge: only a verdict the broker recorded merges
    broker.py ship <state_dir>                          # guard ship: review, then merge what is approved

The verbs, the job log and the records are lib/broker/scheduler.py's and records.py's; config.json's keys are listed
there."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "..", "lib"))
import _path  # noqa: E402,F401
from broker import scheduler, server  # noqa: E402
from broker.records import Refused, approve_card, needs_you, revoke_card  # noqa: E402
from forge import Forge  # noqa: E402


def with_forge(b):
    b.forge = Forge(b.dir, b.cfg, b.mirror, b.records)
    return b


def serve(state_dir, config_path):
    with open(config_path) as f:
        cfg = json.load(f)
    for key, name in (("gh_token_file", "GH_TOKEN"), ("model_key_file", "ANTHROPIC_API_KEY")):
        if cfg.get(key):  # held here, as a real broker holds them; every subprocess gets an explicit environment
            with open(cfg[key]) as f:
                os.environ[name] = f.read().strip()
    b = with_forge(scheduler.Broker(state_dir, cfg))
    server.serve(b, os.path.join(b.dir, "sock"))


def outside_forge(state_dir):
    records = scheduler.outside_records(state_dir)
    return Forge(state_dir, records.cfg, records.mirror, records)


def main(argv):
    if len(argv) == 3 and argv[1] == "setup":
        return scheduler.setup(argv[2])
    if len(argv) == 4 and argv[1] == "serve":
        return serve(argv[2], argv[3])
    if len(argv) == 5 and argv[1:3] in (["approve", "card"], ["revoke", "card"]):
        return (approve_card if argv[1] == "approve" else revoke_card)(scheduler.outside_records(argv[3]), argv[4])
    if len(argv) == 4 and argv[1] in ("review", "merge") or len(argv) == 3 and argv[1] == "ship":
        forge = outside_forge(argv[2])
        try:
            sys.exit(forge.ship() if argv[1] == "ship" else getattr(forge, argv[1])(argv[3]))
        except Refused as e:
            print(f"guard {argv[1]}: refused: {e}", file=sys.stderr)
            sys.exit(2)
    if len(argv) in (5, 7) and argv[1] == "records" and argv[2] in needs_you.MOVES \
            and (len(argv) == 5 or argv[5] == "--note"):
        try:
            return needs_you.move(scheduler.outside_records(argv[3]).queue, argv[2], argv[4],
                                  argv[6] if len(argv) == 7 else "")
        except needs_you.Refused as e:
            sys.exit(f"broker.py: {e}")
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
