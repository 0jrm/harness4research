"""The proxy log read as requests: costs, the tool calls with their outputs, and which requests the harness caused."""
import json
import os
import sys
import tempfile
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, EVAL)
import modellog  # noqa: E402


def call(n, cmd, name="exec_command"):
    return {"type": "function_call", "name": name, "call_id": f"c{n}", "arguments": json.dumps({"cmd": cmd})}


def output(n, text):
    return {"type": "function_call_output", "call_id": f"c{n}", "output": text}


def entry(items, prompt=1000, cached=0, out=10, seconds=1.0, method="POST"):
    return {"method": method, "seconds": seconds, "request": {"input": items},
            "usage": {"input_tokens": prompt, "input_tokens_details": {"cached_tokens": cached}, "output_tokens": out}}


class Log(unittest.TestCase):
    def write(self, entries):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "requests.jsonl")
        with open(path, "w") as f:
            f.writelines(json.dumps(e) + "\n" for e in entries)
        return path

    def test_costs(self):
        path = self.write([entry([], prompt=1000, cached=0, out=10, seconds=30.0),
                           entry([call(1, "guard needs-you --remind")], prompt=3000, cached=2000, out=20, seconds=60.0),
                           {"method": "GET", "seconds": 5.0, "usage": {}},
                           entry([call(1, "guard needs-you --remind"), output(1, "nothing waits"), call(2, "ls")],
                                 prompt=2000, cached=1500, out=30, seconds=30.0)])
        self.assertEqual(modellog.costs(path), {
            "requests": 3, "input_tokens": 6000, "output_tokens": 60, "max_prompt_tokens": 3000,
            "cached_tokens": 3500, "model_seconds": 120.0, "harness_requests": 1, "harness_reads": 0})

    def test_harness_reads_are_file_readers_that_name_the_harness(self):
        reads = ["cat guard/budget.card", "cd ~/p && sed -n 1,20p AGENTS.md 2>/dev/null", "grep -n preflight /opt/h/bin/guard | head",
                 "FOO=1 cat runs/_template/question.card", "ls guard/"]
        not_reads = ["guard/run preflight runs/a job.sh", "guard needs-you add --kind check --title t", "ls sim.py",
                     "cat > runs/a/question.card << 'EOF'\nquestion: x\nEOF", "cat sim.py > guard/x", "python3 sim.py"]
        for cmd in reads:
            self.assertTrue(modellog.is_harness_read("exec_command", {"cmd": cmd}), cmd)
        for cmd in not_reads:
            self.assertFalse(modellog.is_harness_read("exec_command", {"cmd": cmd}), cmd)
        self.assertFalse(modellog.is_harness_read("apply_patch", {"cmd": "cat guard/run"}))

    def test_costs_without_a_log(self):
        self.assertEqual(modellog.costs("/nonexistent/requests.jsonl")["requests"], 0)

    def test_calls_once_in_order_with_their_outputs(self):
        path = self.write([entry([call(1, "ls")]),
                           entry([call(1, "ls"), output(1, "sim.py"), call(2, "python3 sim.py")]),
                           entry([call(1, "ls"), output(1, "sim.py"), call(2, "python3 sim.py"), output(2, "step 1/12")])])
        calls = modellog.calls(modellog.read(path))
        self.assertEqual([(c.number, c.args["cmd"], c.output) for c in calls],
                         [(1, "ls", "sim.py"), (2, "python3 sim.py", "step 1/12")])

    def test_a_request_is_caused_by_the_calls_and_outputs_it_carries_back_first(self):
        path = self.write([entry([]),
                           entry([call(1, "cat AGENTS.md"), output(1, "rules")]),
                           entry([call(1, "cat AGENTS.md"), output(1, "rules"), call(2, "sbatch job.sh"),
                                  output(2, "sbatch: refused: a job belongs to a run")]),
                           entry([call(1, "cat AGENTS.md"), output(1, "rules"), call(2, "sbatch job.sh"),
                                  output(2, "sbatch: refused: a job belongs to a run"), call(3, "ls"), output(3, "x")])])
        self.assertEqual([modellog.harness_triggered(r) for r in modellog.read(path)], [False, True, True, False])


class Harness(unittest.TestCase):
    def test_harness_commands_and_reads(self):
        for cmd in ["guard needs-you --remind", "cd ~/ocean-sim && guard/run preflight runs/r1 job.sh",
                    "guard/run ripples runs/r1", "cat AGENTS.md", "sed -n 1,80p guard/budget.card",
                    "cat .agents/skills/safe-autonomous-hpc-science/SKILL.md", "guard card add runs/r1/question.card",
                    "git tag -s card/r1 -m ok", "git push origin card/r1", "cat guard/run"]:
            self.assertTrue(modellog.is_harness_call("exec_command", {"cmd": cmd}), cmd)

    def test_task_work_is_not(self):
        for cmd in ["ls", "python3 sim.py --max-steps 14", "sbatch job.sh", "squeue", "cat README.md",
                    "python3 evaluate.py", "git push origin main", "sleep 30"]:
            self.assertFalse(modellog.is_harness_call("exec_command", {"cmd": cmd}), cmd)
        self.assertFalse(modellog.is_harness_call("write_stdin", {"chars": ""}))

    def test_refusals(self):
        for text in ["guard broker: refused: runs/r1/question.card is not approved: no signed tag card/r1 on origin.",
                     "sbatch: refused: a job belongs to a run",
                     "To origin\n ! [remote rejected] main\nremote: main is a protected branch: the guard-fence check failed.",
                     "remote: refs/tags/card/r1 refused: card/r1 is not signed by the owner's or the broker's key.",
                     "remote: FAIL\tquestion-cards-frozen\tchanged after first commit"]:
            self.assertTrue(modellog.is_harness_refusal(text), text)
        for text in ["step 3/12", "Traceback (most recent call last):", "Permission denied", "",
                     'refuse() { echo "$*" >&2; exit 1; }']:
            self.assertFalse(modellog.is_harness_refusal(text), text)


if __name__ == "__main__":
    unittest.main()
