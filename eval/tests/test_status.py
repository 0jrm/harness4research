import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "broker"))
import client  # noqa: E402
import status  # noqa: E402

QUIET = {"jobs": [], "waits": [], "blocked": [], "refusal": None,
         "budget": {"spent": 12, "queued": 0, "max": 100, "reserve": 10},
         "git": {"branch": "main", "changed": 0, "ahead": 0, "behind": 0}}


def tokens(text):
    return len(text) / 4


class Render(unittest.TestCase):
    def test_quiet_project_names_every_part(self):
        text = status.render(QUIET)
        for part in ("running: nothing", "blocked: nothing", "last refusal: none",
                     "budget: 12 of 100 core-h spent, 0 queued, 78 left above the 10 reserve",
                     "git: main, 0 changed files, 0 commits ahead of origin/main, 0 behind",
                     "next: none: the work is on main"):
            self.assertIn(part, text)
        self.assertEqual(len(text.splitlines()), 6)

    def test_worst_case_stays_under_300_tokens(self):
        long = "x" * 5000
        f = {"jobs": [{"id": str(i), "run": long, "state": "RUNNING", "elapsed": "0:01", "limit": "0:30"}
                      for i in range(200)],
             "waits": [str(i) for i in range(200)], "blocked": [f"needs-you n{i} (check): {long}" for i in range(200)],
             "refusal": {"ago_min": 1, "where": "scheduler", "why": long},
             "budget": {"spent": 10 ** 9, "queued": 10 ** 9, "max": 10 ** 9, "reserve": 10 ** 9},
             "git": {"branch": long, "changed": 10 ** 6, "ahead": 10 ** 6, "behind": 10 ** 6}}
        text = status.render(f)
        self.assertLessEqual(tokens(text), 300)
        self.assertEqual(status.listed(["a"] * 400), "a; a; a; and 397 more")
        self.assertTrue(text.splitlines()[-1].startswith("next: "))

    def test_unknown_budget_and_no_project(self):
        text = status.render({**QUIET, "budget": None, "git": None})
        self.assertIn("budget: unknown", text)
        self.assertIn("next: cd to the project, then guard status", text)


class NextCommand(unittest.TestCase):
    def next(self, **kw):
        return status.next_command({**QUIET, **kw})

    def test_order(self):
        live = [{"id": "7", "run": "a", "state": "RUNNING", "elapsed": "1:00", "limit": "30:00"}]
        failed = [{"id": "8", "run": "a", "state": "FAILED", "elapsed": "1:00", "limit": "30:00"}]
        dirty = {"branch": "main", "changed": 2, "ahead": 1, "behind": 0}
        self.assertEqual(self.next(blocked=["needs-you n1 (approve): card a"], jobs=live, git=dirty),
                         "do other work, or stop: needs-you n1 (approve) waits on a person")
        self.assertEqual(self.next(jobs=live, git=dirty), "do other work, then guard status again; do not poll")
        self.assertEqual(self.next(waits=["42"]), "do other work, then guard status again; do not poll")
        self.assertIn("runs/a/incidents/8.md", self.next(jobs=failed, git=dirty))
        self.assertEqual(self.next(git=dirty), "git add -A && git commit -m 'what changed'")
        self.assertEqual(self.next(git={**dirty, "changed": 0}), "git push origin HEAD:main")
        self.assertEqual(self.next(git={**dirty, "changed": 0, "ahead": 0, "behind": 3}), "git pull --rebase origin main")

    def test_cancelled_by_names_its_state_first(self):
        jobs = [{"id": "9", "run": "a", "state": "CANCELLED by 1000", "elapsed": "0:10", "limit": "30:00"}]
        self.assertIn("job 9", self.next(jobs=jobs))


class Capped(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.old = os.environ.get("HOME")
        os.environ["HOME"] = self.home

    def tearDown(self):
        os.environ["HOME"] = self.old

    def test_forty_lines_pass_unchanged(self):
        out = "".join(f"{i}\n" for i in range(30))
        err = "".join(f"e{i}\n" for i in range(10))
        self.assertEqual(client.capped(out, err), (out, err))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".cache", "guard")))

    def test_more_goes_to_a_file_and_the_last_ten_lines(self):
        out = "".join(f"line {i}\n" for i in range(100))
        shown, err = client.capped(out, "refused: why\n")
        lines = shown.splitlines()
        self.assertEqual(err, "")
        self.assertEqual(len(lines), 11)
        self.assertTrue(lines[0].startswith("101 lines, all in "))
        self.assertEqual(lines[1:], [f"line {i}" for i in range(91, 100)] + ["refused: why"])
        path = lines[0].split(" all in ")[1].split(";")[0]
        self.assertEqual(open(path).read(), out + "refused: why\n")


if __name__ == "__main__":
    unittest.main()
