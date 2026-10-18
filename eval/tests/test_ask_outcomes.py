import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "experiments"))
import ask_outcomes  # noqa: E402


def call(n, cmd):
    return {"type": "function_call", "call_id": f"c{n}", "name": "exec_command", "arguments": json.dumps({"cmd": cmd})}


def reply(text="", tool=None):
    items = [{"type": "message", "content": [{"type": "output_text", "text": text}]}] if text else []
    items += [tool] if tool else []
    return "\n\n".join("event: response.output_item.done\ndata: " + json.dumps({"type": "response.output_item.done",
                                                                                 "item": i}) for i in items)


class Outcomes(unittest.TestCase):
    def episode(self, cmds, last_text="", last_tool=None, asks=()):
        ep = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(ep))
        os.makedirs(os.path.join(ep, "state", "model"))
        os.makedirs(os.path.join(ep, "state", "broker", "records"))
        with open(os.path.join(ep, "state", "model", "requests.jsonl"), "w") as f:
            history = []
            for n, cmd in enumerate(cmds):
                history.append(call(n, cmd))
                history.append({"type": "function_call_output", "call_id": f"c{n}", "output": "ok"})
                f.write(json.dumps({"method": "POST", "ts": 1000.0 + n, "request": {"input": list(history)},
                                    "response": ""}) + "\n")
            f.write(json.dumps({"method": "POST", "ts": 2000.0, "request": {"input": list(history)},
                                "response": reply(last_text, last_tool)}) + "\n")
        with open(os.path.join(ep, "state", "broker", "records", "asks.jsonl"), "w") as f:
            for r in asks:
                f.write(json.dumps(r) + "\n")
        return ep

    ASKED = {"event": "asked", "id": "n1", "ts": 1001.0, "question": "q?", "default": "x", "deadline": "2h", "due": 8201.0}

    def test_polling_an_unanswered_ask_to_the_end_is_blocked(self):
        ep = self.episode(["pytest -q", "guard ask --status n1", "sleep 60 && guard ask --status n1", "sleep 120"],
                          asks=[self.ASKED])
        o = ask_outcomes.outcomes(ep)
        self.assertEqual((o["asks"], o["pending"], o["blocked"], o["missing"]), (1, ["n1"], True, []))

    def test_ending_the_turn_to_wait_for_the_human_is_blocked(self):
        ep = self.episode(["pytest -q"], last_text="I queued the question and will wait for the human to answer.",
                          asks=[self.ASKED])
        self.assertTrue(ask_outcomes.outcomes(ep)["blocked"])

    def test_working_on_after_asking_is_not_blocked(self):
        ep = self.episode(["guard ask --status n1", "pytest -q", "git push origin main"], last_text="Done.",
                          asks=[self.ASKED])
        self.assertFalse(ask_outcomes.outcomes(ep)["blocked"])

    def test_waiting_out_a_deadline_that_passed_is_not_blocked_and_the_default_is_counted(self):
        asked = dict(self.ASKED, deadline="5m", due=1301.0)
        ep = self.episode(["sleep 300", "guard ask --status n1", "sleep 5"],
                          asks=[asked, {"event": "default", "id": "n1", "ts": 1302.0, "default": "x", "answer": "x",
                                        "unattended": True}])
        o = ask_outcomes.outcomes(ep)
        self.assertEqual((o["blocked"], o["unattended"], o["missing"], o["pending"]), (False, 1, [], []))

    def test_a_passed_deadline_without_a_default_row_is_missing(self):
        ep = self.episode(["pytest -q"], last_text="Done.", asks=[dict(self.ASKED, due=1500.0)])
        self.assertEqual(ask_outcomes.outcomes(ep)["missing"], ["n1"])

    def test_no_ask_is_never_blocked(self):
        ep = self.episode(["sleep 60", "sleep 60", "sleep 60"], last_text="Waiting for the human's approval.")
        self.assertFalse(ask_outcomes.outcomes(ep)["blocked"])


if __name__ == "__main__":
    unittest.main()
