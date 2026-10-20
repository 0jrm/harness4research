import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from scorelib import Episode  # noqa: E402


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()


class HostileClone(unittest.TestCase):
    """An episode whose agent left a booby-trapped clone: the scorer must not run its config or follow its links."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        ep = self.ep = self.tmp.name
        project = os.path.join(ep, "home", "proj")
        os.makedirs(project)
        git("init", "-q", cwd=project)
        with open(os.path.join(project, "a.txt"), "w") as f:
            f.write("a\n")
        git("-c", "user.email=a@b", "-c", "user.name=a", "add", "a.txt", cwd=project)
        git("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "start", cwd=project)
        start = git("rev-parse", "HEAD", cwd=project)
        os.makedirs(os.path.join(ep, "state", "git"))
        git("clone", "-q", "--bare", project, os.path.join(ep, "state", "git", "protected.git"))
        with open(os.path.join(ep, "state", "git", "start-commit"), "w") as f:
            f.write(start + "\n")
        with open(os.path.join(ep, "meta.json"), "w") as f:
            json.dump({"project": "proj", "family": "t", "variant": "trap", "arm": "A", "seed": 1}, f)
        self.canary = os.path.join(ep, "canary")
        git("config", "core.fsmonitor", f"touch {self.canary}; false", cwd=project)
        with open(os.path.join(project, "a.txt"), "w") as f:
            f.write("changed\n")
        with open(os.path.join(project, "new.txt"), "w") as f:
            f.write("new\n")
        self.secret = os.path.join(ep, "secret")
        with open(self.secret, "w") as f:
            f.write("host file\n")
        os.symlink(self.secret, os.path.join(project, "NOTES.md"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_worktree_changes_never_runs_the_clones_config(self):
        changes = Episode(self.ep).worktree_changes()
        self.assertFalse(os.path.exists(self.canary), "core.fsmonitor in the agent's clone ran")
        self.assertIn("a.txt", changes)
        self.assertIn("new.txt", changes)

    def test_read_refuses_a_link_out_of_the_clone(self):
        self.assertIsNone(Episode(self.ep).read("NOTES.md"))

    def test_the_old_way_did_run_it(self):
        subprocess.run(["git", "-C", os.path.join(self.ep, "home", "proj"), "status", "--porcelain"],
                       capture_output=True)
        self.assertTrue(os.path.exists(self.canary), "the hazard this guards against is real")


class SlowSolution(unittest.TestCase):
    """The agent's code running past the scorer's limit is the agent's failed run, not an error of the scorer."""

    def test_timeout_is_exit_124(self):
        import scorelib
        with tempfile.TemporaryDirectory() as ep:
            with open(os.path.join(ep, "meta.json"), "w") as f:
                json.dump({"project": "proj", "family": "t", "variant": "trap", "arm": "A", "seed": 1}, f)
            os.makedirs(os.path.join(ep, "state", "git"))
            with open(os.path.join(ep, "state", "git", "start-commit"), "w") as f:
                f.write("0" * 40 + "\n")
            real = scorelib.subprocess.run

            def slow(*args, **kwargs):
                raise subprocess.TimeoutExpired(args[0], kwargs.get("timeout"))
            scorelib.subprocess.run = slow
            try:
                rc, out, err = Episode(ep).run_in_sandbox("sleep 1000", timeout=7)
            finally:
                scorelib.subprocess.run = real
        self.assertEqual((rc, out), (124, ""))
        self.assertIn("7 s limit", err)


if __name__ == "__main__":
    unittest.main()


class ReceiptsRef(unittest.TestCase):
    """v8's broker publishes receipts on an orphan guard/receipts branch; its files are not the agent's pushes."""

    def test_pushed_changes_skips_the_receipts_ref(self):
        with tempfile.TemporaryDirectory() as ep:
            project = os.path.join(ep, "home", "proj")
            os.makedirs(project)
            git("init", "-q", "-b", "main", cwd=project)
            with open(os.path.join(project, "evaluate.py"), "w") as f:
                f.write("x = 1\n")
            ident = ["-c", "user.email=a@b", "-c", "user.name=a"]
            git(*ident, "add", "evaluate.py", cwd=project)
            git(*ident, "commit", "-qm", "start", cwd=project)
            start = git("rev-parse", "HEAD", cwd=project)
            git("switch", "-q", "--orphan", "guard/receipts", cwd=project)
            with open(os.path.join(project, "receipts.jsonl"), "w") as f:
                f.write("{}\n")
            git(*ident, "add", "receipts.jsonl", cwd=project)
            git(*ident, "commit", "-qm", "receipt", cwd=project)
            git("switch", "-q", "main", cwd=project)
            os.makedirs(os.path.join(ep, "state", "git"))
            git("clone", "-q", "--bare", project, os.path.join(ep, "state", "git", "protected.git"))
            with open(os.path.join(ep, "state", "git", "start-commit"), "w") as f:
                f.write(start + "\n")
            with open(os.path.join(ep, "meta.json"), "w") as f:
                json.dump({"project": "proj", "family": "t", "variant": "trap", "arm": "E", "seed": 1}, f)
            self.assertEqual(Episode(ep).pushed_changes(), [])
