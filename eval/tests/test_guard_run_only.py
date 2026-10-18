"""guard run as the only way in (E2b): the old path's refusal names the guard run command, and guard run takes a
leading launcher and corrects what the agent typed."""
import contextlib
import io
import os
import shlex
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "broker"))
import client  # noqa: E402


def refusal(*args):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = client.main(*args)
    return rc, err.getvalue().splitlines()


class GuardRunOnly(unittest.TestCase):
    def setUp(self):
        self.old, self.tmp = os.getcwd(), tempfile.TemporaryDirectory()
        os.chdir(self.tmp.name)
        with open("job.sh", "w") as f:
            f.write("#!/bin/bash\n#SBATCH --time=00:10:00\nsrun python3 sim.py\n")
        open("sim.py", "w").close()

    def tearDown(self):
        os.chdir(self.old)
        self.tmp.cleanup()

    def assertOldPath(self, args, what, command):
        rc, lines = refusal(*args)
        self.assertEqual(rc, 2)
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[0].startswith(f"H4R-R09 {what}: refused: "), lines[0])
        self.assertEqual(lines[1], command)
        request = client.run_request(shlex.split(lines[1])[2:])
        self.assertEqual(request["script"], "job.sh")

    def test_sbatch_names_the_same_submission(self):
        self.assertOldPath(("sbatch", ["--time=5", "job.sh"]), "sbatch",
                           "guard run runs/job --why 'Run job.sh for run job.' -- --time=5 job.sh")
        self.assertOldPath(("sbatch", ["--comment=run:x1", "--parsable", "-t", "5", "job.sh", "a"]), "sbatch",
                           "guard run runs/x1 --why 'Run job.sh for run x1.' -- -t 5 job.sh a")

    def test_preflight_and_launch(self):
        self.assertOldPath(("client.py", ["guard/run", "preflight", "runs/ocean-1", "job.sh", "--time=00:30:00"]),
                           "guard/run preflight",
                           "guard run runs/ocean-1 --why 'Run job.sh for run ocean-1.' -- --time=00:30:00 job.sh")
        self.assertOldPath(("client.py", ["guard/run", "launch", "runs/r", "--time=10", "--gpus=0,1", "--mem=4", "--",
                                          "python3", "sim.py"]), "guard/run launch",
                           "guard run runs/r --why 'Run job.sh for run r.' -- --time=10 --gpus=2 --mem=4G job.sh")

    def test_card_add_reuses_the_cards_question(self):
        with open("c.card", "w") as f:
            f.write("question: Does the run finish in jobs?\n")
        self.assertOldPath(("guard", ["card", "add", "ocean-1", "c.card"]), "guard card add",
                           "guard run runs/ocean-1 --why 'Does the run finish in jobs?' -- job.sh")

    def test_guard_run_drops_a_leading_launcher(self):
        for launcher in (["sbatch"], ["bash"], ["sh"], ["srun"], ["srun", "bash"]):
            request = client.run_request(["runs/x", "--why", "w", "--", *launcher, "job.sh"])
            self.assertEqual((request["script"], request["options"]), ("job.sh", []))

    def test_usage_refusal_prints_the_corrected_command(self):
        cases = {("runs/x", "--why", "w", "job.sh"): "guard run runs/x --why w -- job.sh",
                 ("runs/x", "--", "job.sh"): "guard run runs/x --why 'Run job.sh for run x.' -- job.sh",
                 ("runs/x", "--why", "w", "--cause", "c", "--", "--foo", "job.sh"):
                     "guard run runs/x --why w --cause c -- job.sh",
                 ("runs/x", "--why", "w", "--", "python3", "sim.py"): "guard run runs/x --why w -- job.sh"}
        for typed, corrected in cases.items():
            rc, lines = refusal("guard", ["run", *typed])
            self.assertEqual((rc, len(lines), lines[0][:8], lines[1]), (2, 2, "H4R-R01 ", corrected), typed)


if __name__ == "__main__":
    unittest.main()
