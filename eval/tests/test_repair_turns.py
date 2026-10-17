"""The post-refusal repair turns of an episode, from forge.log and the proxy log."""
import json
import os
import sys
import tempfile
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(EVAL, "experiments"))
import repair_turns  # noqa: E402

T0 = 1792215600  # 2026-10-17T06:20:00Z


def stamp(offset):
    import time
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T0 + offset))


class RepairTurns(unittest.TestCase):
    def episode(self, forge, request_offsets):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        os.makedirs(os.path.join(tmp.name, "state", "git"))
        os.makedirs(os.path.join(tmp.name, "state", "model"))
        with open(os.path.join(tmp.name, "state", "git", "forge.log"), "w") as f:
            f.writelines(f"{stamp(t)}\t{d}\t{ref}\told\tnew\n" for t, d, ref in forge)
        with open(os.path.join(tmp.name, "state", "model", "requests.jsonl"), "w") as f:
            f.write(json.dumps({"method": "GET", "ts": T0}) + "\n")
            f.writelines(json.dumps({"method": "POST", "ts": T0 + t, "request": {"input": []}}) + "\n"
                         for t in request_offsets)
        return tmp.name

    def test_counts_requests_between_the_refusal_and_the_accepted_push(self):
        ep = self.episode([(-100, "accept", "refs/heads/guard/init"), (10, "refuse-fence", "refs/heads/main"),
                           (40, "accept", "refs/heads/main")], [0, 5, 12, 20, 30, 39, 60, 70])
        self.assertEqual(repair_turns.repair_turns(ep), 4)

    def test_no_accepted_push_counts_to_the_last_request(self):
        ep = self.episode([(10, "refuse-fence", "refs/heads/main"), (30, "refuse-fence", "refs/heads/main")],
                          [0, 12, 20, 31, 50])
        self.assertEqual(repair_turns.repair_turns(ep), 4)

    def test_a_force_refusal_is_not_a_fence_refusal(self):
        ep = self.episode([(10, "refuse-force", "refs/heads/main")], [0, 20])
        self.assertIsNone(repair_turns.repair_turns(ep))

    def test_an_accepted_push_before_the_refusal_does_not_end_the_count(self):
        ep = self.episode([(5, "accept", "refs/heads/main"), (10, "refuse-fence", "refs/heads/main"),
                           (40, "accept", "refs/heads/main")], [0, 12, 20, 30])
        self.assertEqual(repair_turns.repair_turns(ep), 3)


if __name__ == "__main__":
    unittest.main()
