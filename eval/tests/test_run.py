"""usage: python3 -m unittest discover -s eval/tests

The driver without a model: the matrix it builds, the resume key, the Python it records, and a dry run of main
against a stub of the vLLM server's /v1/models with --limit 0, which starts no episode."""
import collections
import http.server
import itertools
import json
import os
import random
import subprocess
import sys
import tempfile
import threading
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, EVAL)
import run  # noqa: E402

CONFIG = os.path.join(EVAL, "configs", "codex-qwen3.6.json")


def first_run_matrix():
    with open(CONFIG) as f:
        return json.load(f)["matrix"]


class Matrix(unittest.TestCase):
    def test_first_run_has_150_cases(self):
        every = run.matrix_cases(first_run_matrix())
        self.assertEqual(len(every), 150)
        self.assertEqual(len(set(every)), 150)
        per = collections.Counter((arm, variant) for _, variant, arm, _ in every)
        self.assertEqual(per, {("A", "trap"): 30, ("A", "control"): 30, ("E", "trap"): 30, ("E", "control"): 30,
                               ("E-nobroker", "control"): 30})
        self.assertEqual({s for *_, s in every}, set(range(1, 11)))

    def test_arms_build_the_right_episodes(self):
        self.assertEqual(run.ARMS["A"], run.Arm("A", broker=False))
        self.assertEqual(run.ARMS["E"], run.Arm("E", broker=True))
        self.assertEqual(run.ARMS["E-nobroker"], run.Arm("E", broker=False))

    def test_order_is_shuffled_and_fixed_by_order_seed(self):
        m = first_run_matrix()
        self.assertEqual(run.matrix_cases(m), run.matrix_cases(m))
        unshuffled = sorted(run.matrix_cases(m))
        self.assertNotEqual(run.matrix_cases(m), unshuffled)
        self.assertNotEqual(run.matrix_cases(dict(m, order_seed=m["order_seed"] + 1)), run.matrix_cases(m))
        arms_first_30 = {arm for _, _, arm, _ in run.matrix_cases(m)[:30]}
        self.assertEqual(arms_first_30, {"A", "E", "E-nobroker"})

    def test_without_arm_variants_the_order_is_the_old_one(self):
        m = {"families": ["t1-walltime", "t8-fixture"], "variants": ["trap", "control"], "arms": ["A", "E"],
             "seeds": [1, 2, 3], "order_seed": 20261010}
        old = list(itertools.product(m["families"], m["variants"], m["arms"], m["seeds"]))
        random.Random(m["order_seed"]).shuffle(old)
        self.assertEqual(run.matrix_cases(m), old)

    def test_bad_matrix_exits(self):
        m = first_run_matrix()
        for bad, says in ((dict(m, arms=["A", "B"]), "unknown arm B"),
                          (dict(m, arm_variants={"E-nobroker": ["probe"]}), "arm_variants names E-nobroker"),
                          (dict(m, arms=["A", "E"]), "arm_variants names E-nobroker")):
            with self.assertRaises(SystemExit) as e:
                run.matrix_cases(bad)
            self.assertIn(says, str(e.exception))


class Resume(unittest.TestCase):
    def test_key_holds_the_arm(self):
        self.assertEqual(run.case_key({"family": "f", "variant": "control", "arm": "E-nobroker", "seed": 3, "x": 1}),
                         ("f", "control", "E-nobroker", 3))

    def test_cases_left(self):
        every = run.matrix_cases(first_run_matrix())
        done_e = next(c for c in every if c[1:3] == ("control", "E"))
        nobroker = (done_e[0], "control", "E-nobroker", done_e[3])
        errored = next(c for c in every if c[2] == "A")
        rows = [dict(zip(("family", "variant", "arm", "seed"), done_e), success=True),
                dict(zip(("family", "variant", "arm", "seed"), errored), success=True),
                dict(zip(("family", "variant", "arm", "seed"), errored), error="upstream: 502 down")]
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "verdicts.jsonl")
            self.assertEqual(run.cases_left(every, path), every)
            with open(path, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in rows)
            left = run.cases_left(every, path)
        self.assertEqual(len(left), 149)
        self.assertNotIn(done_e, left)
        self.assertIn(nobroker, left)
        self.assertIn(errored, left)
        self.assertEqual(left, [c for c in every if c != done_e])


class Python(unittest.TestCase):
    def test_host_when_there_is_no_venv(self):
        p = run.offered_python(os.path.join(tempfile.gettempdir(), "no-such-venv"))
        self.assertEqual(p["source"], "host")
        self.assertTrue(p["path"].endswith("/python3"), p)
        self.assertRegex(p["python"], r"^3\.\d+")
        self.assertEqual(set(run.SITE_PACKAGES) - set(p), set())

    def test_site_venv(self):
        with tempfile.TemporaryDirectory() as d:
            venv = os.path.join(d, ".site-venv")
            subprocess.run([sys.executable, "-m", "venv", "--without-pip", venv], check=True)
            p = run.offered_python(venv)
        self.assertEqual((p["source"], p["path"], p["sandbox_path"]), ("site", venv, "/opt/site/python"))
        self.assertEqual([p[n] for n in run.SITE_PACKAGES], [None] * 4)

    def test_a_frozen_run_needs_the_pinned_site_venv(self):
        with self.assertRaises(SystemExit) as e:
            run.require_site_python({"source": "host", "path": "/usr/bin/python3"})
        self.assertIn("eval/env/site-python.sh", str(e.exception))
        with open(os.path.join(EVAL, "env", "site-requirements.txt")) as f:
            pins = dict(line.strip().split("==") for line in f if "==" in line)
        site = {"source": "site", "path": "/v", **{n: pins[n] for n in run.SITE_PACKAGES}}
        self.assertIsNone(run.require_site_python(site))
        with self.assertRaises(SystemExit) as e:
            run.require_site_python(dict(site, numpy="1.0"))
        self.assertIn(f"numpy 1.0 (pinned {pins['numpy']})", str(e.exception))


class StubServer(http.server.BaseHTTPRequestHandler):
    """/v1/models as a vLLM server answers it, for the config's alias, root and context length."""
    model = {}

    def do_GET(self):
        body = json.dumps({"data": [self.model]}).encode() if self.path == "/v1/models" else b"{}"
        self.send_response(200 if self.path == "/v1/models" else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class DryRun(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        with open(CONFIG) as f:
            cfg = json.load(f)
        m = cfg["model"]
        StubServer.model = {"id": m["alias"], "root": m["expect_root"], "max_model_len": m["expect_max_model_len"]}
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubServer)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        m["upstream"] = f"http://127.0.0.1:{self.server.server_port}"
        cfg["results_dir"] = os.path.join(self.dir.name, "results")
        cfg["episodes_dir"] = os.path.join(self.dir.name, "sessions")
        self.config = os.path.join(self.dir.name, "config.json")
        with open(self.config, "w") as f:
            json.dump(cfg, f)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.dir.cleanup()

    def driver(self, *args):
        return subprocess.run([sys.executable, os.path.join(EVAL, "run.py"), self.config, *args],
                              capture_output=True, text=True, timeout=60)

    def test_limit_0_writes_run_json_and_starts_nothing(self):
        out = self.driver("--unfrozen", "--limit", "0")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("skipping 0 of 150 cases", out.stdout)
        with open(os.path.join(self.dir.name, "results", "run.json")) as f:
            run_json = json.load(f)
        self.assertTrue(run_json["unfrozen"])
        self.assertEqual(run_json["python"], run.offered_python())
        self.assertEqual(run_json["arms"], {"A": {"harness": "A", "broker": False},
                                            "E": {"harness": "E", "broker": True},
                                            "E-nobroker": {"harness": "E", "broker": False}})
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "sessions")))
        every = run.matrix_cases(run_json["config"]["matrix"])
        with open(os.path.join(self.dir.name, "results", "verdicts.jsonl"), "w") as f:
            for c in every[:5]:
                f.write(json.dumps(dict(zip(("family", "variant", "arm", "seed"), c), success=True)) + "\n")
        again = self.driver("--unfrozen", "--limit", "0")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("skipping 5 of 150 cases", again.stdout)

    def test_resume_refuses_another_python(self):
        os.makedirs(os.path.join(self.dir.name, "results"))
        with open(os.path.join(self.dir.name, "results", "run.json"), "w") as f:
            json.dump({"card_sha256": None, "python": {"source": "site", "path": "/elsewhere"}}, f)
        out = self.driver("--unfrozen", "--limit", "0")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("was started with the Python", out.stderr)

    @unittest.skipIf(os.path.isdir(run.SITE_VENV), "this checkout has eval/env/.site-venv")
    def test_frozen_run_without_site_venv_refuses(self):
        out = self.driver("--limit", "0")
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("eval/env/site-python.sh", out.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.dir.name, "results")))


class TimeoutByFamily(unittest.TestCase):
    def test_family_override_and_default(self):
        scaffold = {"timeout_minutes": 30, "timeout_minutes_by_family": {"t3-entity-overlap": 180}}
        self.assertEqual(run.timeout_minutes(scaffold, "t3-entity-overlap"), 180)
        self.assertEqual(run.timeout_minutes(scaffold, "t1-walltime"), 30)
        self.assertEqual(run.timeout_minutes({"timeout_minutes": 30}, "t3-entity-overlap"), 30)


class KillCriterion(unittest.TestCase):
    def rows(self, path, n_fail, n_ok, error=0):
        with open(path, "w") as f:
            for i in range(n_fail):
                f.write(json.dumps({"family": "t", "variant": "control", "arm": "A", "seed": i, "timed_out": True,
                                    "requests": 0, "client_exit": -9}) + "\n")
            for i in range(n_ok):
                f.write(json.dumps({"family": "t", "variant": "control", "arm": "E", "seed": i, "timed_out": False,
                                    "requests": 12, "client_exit": 0}) + "\n")
            for i in range(error):
                f.write(json.dumps({"family": "t", "variant": "trap", "arm": "A", "seed": i, "error": "x"}) + "\n")

    def test_trips_past_threshold_and_minimum(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "v.jsonl")
            self.rows(p, 3, 7)
            self.assertEqual(run.kill_tripped(p), (True, 3, 10))
            self.rows(p, 2, 8)
            self.assertEqual(run.kill_tripped(p), (False, 2, 10))
            self.rows(p, 5, 3)
            self.assertEqual(run.kill_tripped(p)[0], False)
            self.rows(p, 2, 8, error=5)
            self.assertEqual(run.kill_tripped(p), (False, 2, 10))


if __name__ == "__main__":
    unittest.main()
