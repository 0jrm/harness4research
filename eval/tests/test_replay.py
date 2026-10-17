"""The replay bench's pure parts: reading the recorded calls as steps, substituting ids, and classifying refusals."""
import os
import sys
import tempfile
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, EVAL)
import modellog  # noqa: E402
import replay  # noqa: E402


def ran(body, exit=0, wall=0.5, session=None):
    state = f"Process running with session ID {session}" if session else f"Process exited with code {exit}"
    return f"Chunk ID: ab12cd\nWall time: {wall:.4f} seconds\n{state}\nOriginal token count: 3\nOutput:\n{body}"


class Extraction(unittest.TestCase):
    def test_header(self):
        self.assertEqual(replay.parse_output(ran("hi\n", exit=2, wall=1.5)), replay.Recorded(2, None, 1.5, "hi\n"))
        self.assertEqual(replay.parse_output(ran("", session=4711, wall=10)), replay.Recorded(None, "4711", 10.0, ""))
        self.assertIsNone(replay.parse_output("unsupported call: apply_patch"))
        self.assertIsNone(replay.parse_output(None))

    def test_steps_keep_only_calls_codex_ran(self):
        calls = [
            modellog.Call(1, "exec_command", {"cmd": "python3 train.py", "workdir": "/home/agent/p"},
                          ran("", session=77, wall=10)),
            modellog.Call(2, "write_stdin", {"session_id": 77, "chars": ""}, ran("done\n", exit=0, wall=3)),
            modellog.Call(3, "apply_patch", {"command": "*** Begin Patch"}, "unsupported call: apply_patch"),
            modellog.Call(4, "write_stdin", {"session_id": 9}, "write_stdin failed: Unknown process id 9"),
            modellog.Call(5, "exec_command", {"cmd": "rm -rf x"}, 'exec_command failed: CreateProcess { message: "Rejected'),
            modellog.Call(6, "exec_command", {"cmd": ["git", "status"], "login": False, "tty": True}, ran("clean\n")),
            modellog.Call(7, "exec_command", {"cmd": "ls"}, None),
        ]
        got = replay.steps(calls)
        self.assertEqual([(s.number, s.op, s.text, s.session) for s in got],
                         [(1, "exec", "python3 train.py", "77"), (2, "poll", "", "77"), (6, "exec", "git status", "x6")])
        self.assertEqual(got[0].workdir, "/home/agent/p")
        self.assertEqual((got[2].login, got[2].tty), (False, True))

    def test_waits(self):
        exec_done, exec_running, poll_running, poll_done = replay.steps([
            modellog.Call(1, "exec_command", {"cmd": "a"}, ran("", exit=0, wall=1)),
            modellog.Call(2, "exec_command", {"cmd": "b"}, ran("", session=5, wall=30)),
            modellog.Call(3, "write_stdin", {"session_id": 5}, ran("", session=5, wall=30)),
            modellog.Call(4, "write_stdin", {"session_id": 5}, ran("", exit=0, wall=200)),
        ])
        self.assertEqual(replay.wait_for(exec_done), 1 + replay.SLACK)
        self.assertEqual(replay.wait_for(exec_running), 30)
        self.assertEqual(replay.wait_for(poll_running), replay.POLL_WAIT)
        self.assertEqual(replay.wait_for(poll_done), replay.EXEC_CAP)


class Substitution(unittest.TestCase):
    def test_job_ids_pair_in_order_within_a_command(self):
        ids = replay.Ids()
        ids.learn("Submitted batch job 1000\nSubmitted batch job 1001\n", "Submitted batch job 1003\nSubmitted batch job 1004\n")
        self.assertEqual(ids.substitute("sacct -j 1000,1001 && cat slurm-1001.out"),
                         ("sacct -j 1003,1004 && cat slurm-1004.out", []))

    def test_guard_job_line_counts_as_a_submission(self):
        self.assertEqual(replay.job_ids("guard: job 1002, run r1: 1 task(s) x 1 node(s)\nSubmitted batch job 1002\n"),
                         ["1002"])

    def test_a_job_the_replay_never_got_is_flagged(self):
        ids = replay.Ids()
        ids.learn("Submitted batch job 1000\n", "guard broker: refused: card\n")
        self.assertEqual(ids.substitute("scancel 1000"), ("scancel 1000", ["unmapped-job-id"]))
        self.assertEqual(ids.substitute("sleep 1001"), ("sleep 1001", []))

    def test_hashes_pair_by_line_and_match_by_prefix(self):
        ids = replay.Ids([("31448c1d0718c89e6ad83d93696f5099c7bd86ef", "9f0f53bb52e46f9556d39fe6b9beabd7f2022f4c")])
        ids.learn("[main 2dfd82e] add card\n", "[main 54bb5c5] add card\n")
        self.assertEqual(ids.substitute("git tag card/r 31448c1 && git show 2dfd82e"),
                         ("git tag card/r 9f0f53b && git show 54bb5c5", []))

    def test_a_hash_the_record_printed_but_the_replay_did_not_is_flagged(self):
        ids = replay.Ids()
        ids.learn("abc1234 first\n", "")
        self.assertEqual(ids.substitute("git checkout abc1234"), ("git checkout abc1234", ["unmapped-hash"]))
        self.assertEqual(ids.substitute("echo deadbee7f"), ("echo deadbee7f", []))

    def test_hash_pairs_skip_lines_that_differ_or_repeat(self):
        self.assertEqual(replay.hash_pairs("a1b2c3d x\nb1b2c3d y\nc1b2c3d y\n", "f1f2f3f x\n0a0b0c0 y\n"),
                         [("a1b2c3d", "f1f2f3f")])


class Classifier(unittest.TestCase):
    def test_kinds_are_anchored_and_counted_once(self):
        out = ("PREFLIGHT FAIL: runs/r/question.card is not committed; commit it first\n"
               "PREFLIGHT FAIL: ripples reports job-states 1000:TIMEOUT\n"
               "guard broker: refused: runs/r/question.card is not approved: no signed tag card/r on origin.\n"
               "guard broker: refused: no verb 'done' on the records socket\n"
               "12:  fail() { echo \"PREFLIGHT FAIL: $*\" >&2; exit 1; }\n"
               "sbatch: error: Invalid user for SlurmUser slurm, ignored\n"
               "remote: main is a protected branch: the guard-fence check failed.\n"
               "remote: FAIL\twatched-paths\ta human merges changes to: tests/x\n")
        self.assertEqual(sorted(replay.classify(out)), ["broker", "card", "preflight", "remote", "ripples"])

    def test_counts_leave_pushes_to_forge_log_and_unseen_commands_out(self):
        with tempfile.TemporaryDirectory() as ep:
            os.makedirs(os.path.join(ep, "state", "git"))
            with open(os.path.join(ep, "state", "git", "forge.log"), "w") as f:
                f.write("t\taccept\trefs/heads/guard/init\t0\t1\nt\trefuse-fence\trefs/heads/main\t1\t2\n"
                        "t\trefuse-tag\trefs/tags/card/r\t0\t2\nt\trefuse-tag\trefs/tags/card/r\t0\t3\n")
            pushes, cross = replay.log_refusals(ep)
        self.assertEqual(dict(pushes), {"push-fence": 1, "push-tag": 2})
        self.assertEqual(cross, {"records_refused": 0, "gh_refused": 0, "ledger_failed": 0})
        commands = [{"recorded_exit": 1, "refusals": {"remote": "x", "card": "y"}},
                    {"recorded_exit": 0, "refusals": {"card": "z"}},
                    {"recorded_exit": None, "refusals": {"preflight": "w"}}]
        self.assertEqual(replay.counts(commands, "refusals", pushes), {"card": 2, "push-fence": 1, "push-tag": 2})
        self.assertEqual(replay.unobserved(commands), {"preflight": 1})


if __name__ == "__main__":
    unittest.main()
