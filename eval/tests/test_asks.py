import json
import os
import sys
import tempfile
import time
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "broker"))
import asks  # noqa: E402
import broker  # noqa: E402
import client  # noqa: E402
from records import Records, needs_you  # noqa: E402


class Clock:
    def __init__(self):
        self.now = time.time()

    def __call__(self):
        return self.now


class Ask(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = self.tmp.name
        cfg = {"session": "s1", "project": "/home/agent/p", "paths": [["/home/agent", self.state + "/home"]]}
        self.records = Records(self.state, cfg, mirror=None)
        self.records.clock = self.clock = Clock()

    def tearDown(self):
        self.tmp.cleanup()

    def ask(self, *args):
        return self.records.handle(client.ask_request(list(args)))

    def rows(self):
        return self.records.asks.rows()

    def test_an_ask_queues_an_approve_item_and_returns_one_line(self):
        reply = self.ask("Is case 7 of the fixture wrong?", "--default", "report it and leave tests/ alone",
                         "--deadline", "5m")
        self.assertEqual(reply["rc"], 0)
        self.assertEqual(len(reply["out"].splitlines()), 1)
        self.assertIn("ask n1 waits for the human, 5 min left", reply["out"])
        self.assertIn("guard ask --status n1", reply["out"])
        item = needs_you.read(self.records.queue)[0]
        self.assertEqual((item.kind, item.title, item.state), ("approve", "Is case 7 of the fixture wrong?", "open"))
        self.assertIn("report it and leave tests/ alone", item.why)

    def test_unquoted_words_join_the_question(self):
        self.assertEqual(client.ask_request(["Is", "case", "7", "wrong?", "--default=report", "--deadline=30m"]),
                         {"verb": "add", "store": "ask", "question": "Is case 7 wrong?", "default": "report",
                          "deadline": "30m"})
        self.assertEqual(client.ask_request(["--status", "n4"]), {"verb": "show", "store": "ask", "id": "n4"})

    def test_refusals_carry_a_code_and_the_exact_next_command(self):
        cases = [(["--default", "x", "--deadline", "5m"], "H4R-A01"), (["q?", "--deadline", "5m"], "H4R-A02"),
                 (["q?", "--default", "x"], "H4R-A03"), (["q?", "--default", "x", "--deadline", "10m"], "H4R-A03")]
        for args, code in cases:
            reply = self.ask(*args)
            lines = reply["err"].splitlines()
            self.assertEqual(reply["rc"], 2, args)
            self.assertEqual(len(lines), 2, args)
            self.assertTrue(lines[0].startswith(code + " guard ask: refused:"), lines)
            self.assertTrue(lines[1].startswith("guard ask "), lines)
        self.assertIn("--deadline takes 5m, 30m, 2h, not 10m", self.ask("q?", "--default", "x", "--deadline", "10m")["err"])
        self.assertTrue(self.ask("q?", "--default", "x", "--deadline", "10m")["err"].endswith("--deadline 5m\n"))
        self.assertTrue(self.ask("q?", "--default", "x", "--deadline", "1h")["err"].endswith("--deadline 30m\n"))
        self.assertEqual(needs_you.read(self.records.queue), [])

    def test_a_status_of_an_unknown_id_names_the_known_ones(self):
        self.ask("q?", "--default", "x", "--deadline", "5m")
        lines = self.ask("--status", "n9")["err"].splitlines()
        self.assertEqual(lines, ["H4R-A04 guard ask: refused: no ask 'n9'; the asks are n1", "guard ask --status n1"])

    def test_past_the_deadline_the_default_is_taken_unattended_and_the_agent_told_once(self):
        self.ask("q?", "--default", "leave it", "--deadline", "5m")
        self.clock.now += 301
        line = self.ask("--status", "n1")["out"]
        self.assertIn("nobody answered", line)
        self.assertIn("the default was taken unattended: leave it. Proceed with it.", line)
        events = [(r["event"], r.get("unattended")) for r in self.rows()]
        self.assertEqual(events, [("asked", None), ("default", True), ("told", None)])
        self.assertEqual(self.records.notices(), "")
        self.assertIn("taken unattended", self.ask("q?", "--default", "other", "--deadline", "2h")["out"])
        self.assertEqual(len(self.rows()), 3)

    def test_a_default_reaches_the_agent_on_its_next_command_when_it_never_checks(self):
        self.ask("q?", "--default", "leave it", "--deadline", "30m")
        self.clock.now += 1799
        self.assertEqual(self.records.notices(), "")
        self.clock.now += 1
        told = self.records.notices()
        self.assertEqual(len(told.splitlines()), 1)
        self.assertIn("ask n1: nobody answered", told)
        self.assertEqual(self.records.notices(), "")

    def test_a_person_answers_with_the_note_and_dismiss_means_no(self):
        self.ask("Use 4 cores?", "--default", "use 1", "--deadline", "2h")
        self.ask("Delete the cache?", "--default", "keep it", "--deadline", "2h")
        needs_you.move(self.records.queue, "done", "n1", "yes, 4 is fine")
        needs_you.move(self.records.queue, "dismiss", "n2", "")
        self.assertIn("answered by the human: yes, 4 is fine. Act on it.", self.ask("--status", "n1")["out"])
        self.assertIn("answered by the human: no.", self.ask("--status", "n2")["out"])
        self.clock.now += 7200
        self.assertEqual([r["event"] for r in self.rows()].count("default"), 0)

    def test_the_scripted_approver_answers_every_open_item_after_its_delay(self):
        self.ask("q?", "--default", "x", "--deadline", "2h")
        self.records.queue_item("approve", "Approve a job of run r1 over the remaining budget",
                                dict(why="", expect="", worry="", undo=""), [], ["true"], "broker")
        self.records.queue_item("check", "Reference case 7 contradicts the spec",
                                dict(why="", expect="", worry="", undo=""), [], [], "sandbox s1")
        b = types.SimpleNamespace(records=self.records, dir=self.state)
        broker.approve_due(b, 300, time.time() + 100)
        self.assertTrue(all(it.state == "open" for it in needs_you.read(self.records.queue)))
        broker.approve_due(b, 300, time.time() + 301)
        self.assertEqual({it.state for it in needs_you.read(self.records.queue)}, {"done"})
        self.assertIn("answered by the human: approved (scripted approver, after 300 s)", self.ask("--status", "n1")["out"])
        with open(os.path.join(self.state, "approvals.jsonl")) as f:
            self.assertEqual(json.loads(f.readline())["run"], "r1")

    def test_an_item_the_approver_cannot_act_on_stays_open_and_is_logged(self):
        self.records.queue_item("approve", "Approve question card runs/r1/question.card",
                                dict(why="", expect="", worry="", undo=""), [], ["true"], "broker")
        broker.approve_due(types.SimpleNamespace(records=self.records, dir=self.state), 0, time.time() + 1)
        self.assertEqual(needs_you.read(self.records.queue)[0].state, "open")
        with open(self.records.log_path) as f:
            self.assertIn("failed", json.loads(f.read().splitlines()[-1]))

    def test_approver_modes(self):
        self.assertIsNone(broker.approver_delay(None))
        self.assertIsNone(broker.approver_delay("never"))
        self.assertEqual(broker.approver_delay("after:300"), 300)
        for bad in ("after:5m", "always", 300):
            with self.assertRaises(SystemExit):
                broker.approver_delay(bad)


if __name__ == "__main__":
    unittest.main()
