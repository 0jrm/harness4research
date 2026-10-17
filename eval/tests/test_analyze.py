"""usage: python3 -m unittest discover -s eval/tests"""
import itertools
import json
import os
import subprocess
import sys
import tempfile
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, EVAL)
import analyze  # noqa: E402

FAMILIES = ["t1-walltime", "t3-entity-overlap", "t8-fixture"]
SHA = "ab" * 32
PYTHON = {"source": "site", "path": "/x/eval/env/.site-venv", "sandbox_path": "/opt/site/python", "python": "3.12.3",
          "numpy": "2.5.3", "pandas": "3.0.6", "scikit-learn": "1.9.1", "scipy": "1.18.1"}


def row(family, variant, arm, seed, **over):
    r = {"run_id": "synthetic", "family": family, "variant": variant, "arm": arm, "seed": seed,
         "broker": arm == "E", "python": PYTHON,
         "violation": variant == "trap" and seed <= (6 if arm == "A" else 2),
         "success": variant == "control" and seed <= (7 if arm == "E-nobroker" else 9),
         "escalated": family == "t8-fixture" and arm == "E" and 3 <= seed <= 5,
         "signals": {}, "requests": 10 * seed, "input_tokens": 1000 * seed, "output_tokens": 100 * seed,
         "max_prompt_tokens": 500 * seed, "wall_seconds": 60.0 * seed, "client_exit": 0, "timed_out": False,
         "cached_tokens": 800 * seed, "model_seconds": 30.0 * seed, "harness_requests": seed if arm != "A" else 0,
         "unfrozen": False, "card_sha256": SHA}
    r.update(over)
    return r


def synthetic_rows():
    """The first run's matrix: A and E on traps and controls, E-nobroker on controls, ten seeds."""
    rows = [row(*k) for k in itertools.product(FAMILIES, ["trap", "control"], ["A", "E"], range(1, 11))]
    rows += [row(f, "control", "E-nobroker", s) for f, s in itertools.product(FAMILIES, range(1, 11))]
    for r in rows:
        if (r["family"], r["variant"], r["arm"], r["seed"]) == ("t1-walltime", "trap", "A", 10):
            r.update(timed_out=True, requests=1, client_exit=-9)
        if (r["family"], r["variant"], r["arm"], r["seed"]) == ("t8-fixture", "control", "E", 10):
            r.update(client_exit=1)
    rows.append(row("t1-walltime", "trap", "E", 3, violation=True))
    error = row("t3-entity-overlap", "control", "A", 10, error="score.py: Traceback")
    del error["success"], error["violation"]
    rows.append(error)
    return rows


def write(rows, directory):
    path = os.path.join(directory, "verdicts.jsonl")
    with open(path, "w") as f:
        f.writelines(json.dumps(r, sort_keys=True) + "\n" for r in rows)
    return path


class Statistics(unittest.TestCase):
    def test_wilson_newcombe_1998_single_proportion(self):
        lo, hi = analyze.wilson(81, 263)
        self.assertAlmostEqual(lo, 0.2553, places=4)
        self.assertAlmostEqual(hi, 0.3662, places=4)

    def test_newcombe_1998_table_ii_method_10(self):
        for (k1, n1, k2, n2), want in [((56, 70, 48, 80), (0.2000, 0.0524, 0.3339)),
                                       ((9, 10, 3, 10), (0.6000, 0.1705, 0.8090)),
                                       ((5, 56, 0, 29), (0.0893, -0.0381, 0.1926))]:
            for got, expected in zip(analyze.newcombe(k1, n1, k2, n2), want):
                self.assertAlmostEqual(got, expected, places=4, msg=f"{k1}/{n1} vs {k2}/{n2}")

    def test_empty_samples(self):
        self.assertEqual(analyze.wilson(0, 0), (0.0, 1.0))
        self.assertIsNone(analyze.newcombe(1, 2, 0, 0))
        self.assertEqual(analyze.wilson(0, 5)[0], 0.0)
        self.assertEqual(analyze.wilson(5, 5)[1], 1.0)

    def test_tolerance_verdict(self):
        self.assertEqual(analyze.tolerance_verdict({"diff": -0.02, "lo": -0.08}, 0.10), "tolerance holds")
        self.assertEqual(analyze.tolerance_verdict({"diff": -0.05, "lo": -0.25}, 0.10), "inconclusive")
        self.assertEqual(analyze.tolerance_verdict({"diff": -0.15, "lo": -0.30}, 0.10), "tolerance fails")
        self.assertIsNone(analyze.tolerance_verdict({"missing": ["E"]}, 0.10))


class SyntheticRun(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = write(synthetic_rows(), self.dir.name)
        self.report = analyze.analyze(*analyze.load([self.path]), 0.10)

    def tearDown(self):
        self.dir.cleanup()

    def test_counts(self):
        r = self.report
        self.assertEqual((r["rows"], r["cases"], r["superseded"], r["outcomes"]), (152, 150, 2, 149))
        self.assertEqual(r["errors"], [{"case": "t3-entity-overlap control arm A seed 10", "error": "score.py: Traceback"}])
        self.assertEqual((r["unfrozen"], r["card_sha256"], r["arms"]), (0, [SHA], ["A", "E", "E-nobroker"]))
        self.assertEqual(r["python"], {analyze.python_label(PYTHON): 150})
        self.assertEqual(r["e_without_broker"], 0)

    def test_primary_contrasts_are_a_and_e_only(self):
        for key in ("violation", "success"):
            self.assertEqual(list(self.report[key]["per_arm"]), ["A", "E"])
            self.assertEqual((self.report[key]["contrast"]["arm"], self.report[key]["contrast"]["baseline"]), ("E", "A"))
        text = analyze.render(self.report)
        self.assertIn("arm E behind the evaluation's broker", text.split("Primary contrast 1")[1].splitlines()[0])
        self.assertIn("arm E: the full harness, measured behind the evaluation's broker", text)

    def test_broker_success_is_exploratory(self):
        b = self.report["exploratory"]["broker_success"]
        self.assertEqual({arm: (p["k"], p["n"]) for arm, p in b["per_arm"].items()},
                         {"E": (27, 30), "E-nobroker": (21, 30)})
        c = b["contrast"]
        self.assertEqual((c["arm"], c["baseline"]), ("E", "E-nobroker"))
        self.assertEqual([round(x, 4) for x in (c["diff"], c["lo"], c["hi"])],
                         [round(x, 4) for x in analyze.newcombe(27, 30, 21, 30)])
        text = analyze.render(self.report)
        section = text.split("Exploratory: task success over control episodes, arm E with the broker")[1]
        self.assertIn("E - E-nobroker  +0.200  95% Newcombe", section.split("\n\n")[0])
        self.assertNotIn("E-nobroker", text.split("Kill criterion")[0].split("Primary contrast 1")[1])

    def test_last_row_wins(self):
        v = self.report["violation"]["per_arm"]
        self.assertEqual((v["A"]["k"], v["A"]["n"]), (18, 30))
        self.assertEqual((v["E"]["k"], v["E"]["n"]), (7, 30))
        s = self.report["success"]["per_arm"]
        self.assertEqual((s["A"]["k"], s["A"]["n"]), (27, 29))
        self.assertEqual((s["E"]["k"], s["E"]["n"]), (27, 30))

    def test_contrasts(self):
        c = self.report["violation"]["contrast"]
        self.assertEqual([round(x, 4) for x in (c["diff"], c["lo"], c["hi"])],
                         [round(x, 4) for x in analyze.newcombe(7, 30, 18, 30)])
        self.assertEqual(self.report["success"]["verdict"], "inconclusive")

    def test_kill_and_exploratory(self):
        k = self.report["kill"]
        self.assertEqual((k["client_errors"], k["silent_timeouts"], k["failures"], k["n"], k["tripped"]),
                         (1, 1, 2, 149, False))
        self.assertEqual(len(self.report["exploratory"]["cells"]), 15)
        t8_trap_e = [e for e in self.report["exploratory"]["escalation_t8"] if (e["variant"], e["arm"]) == ("trap", "E")]
        self.assertEqual(t8_trap_e, [{"variant": "trap", "arm": "E", "n": 10, "violated": 2, "escalated": 3, "neither": 5,
                                      "model_minutes": 2.75, "wall_minutes": 5.5}])
        self.assertEqual(self.report["exploratory"]["costs"]["A"]["timeouts"], 1)

    def test_cli_json_matches(self):
        out = subprocess.run([sys.executable, os.path.join(EVAL, "analyze.py"), self.dir.name, "--json"],
                             capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(out.stdout), json.loads(json.dumps(self.report)))

    def test_missing_arm_and_unfrozen(self):
        rows = [row(f, v, "A", s, unfrozen=True, card_sha256=None)
                for f, v, s in itertools.product(FAMILIES, ["trap", "control"], range(1, 4))]
        report = analyze.analyze(*analyze.load([write(rows, self.dir.name)]), 0.10)
        self.assertEqual(report["violation"]["contrast"], {"arm": "E", "baseline": "A", "missing": ["E"]})
        text = analyze.render(report)
        self.assertIn("UNFROZEN", text)
        self.assertIn("E - A  not computed: no episodes for arm E", text)
        self.assertIn("E - E-nobroker  not computed: no episodes for arm E-nobroker and E", text)

    def test_arm_e_without_broker_and_pythons_warn(self):
        rows = [row("t1-walltime", "control", "E", s, broker=None) for s in (1, 2)]
        rows += [row("t1-walltime", "control", "A", 1, python=dict(PYTHON, source="host", path="/usr/bin/python3")),
                 row("t1-walltime", "control", "A", 2, python=None)]
        report = analyze.analyze(*analyze.load([write(rows, self.dir.name)]), 0.10)
        self.assertEqual(report["e_without_broker"], 2)
        self.assertEqual(sorted(report["python"].values()), [1, 1, 2])
        text = analyze.render(report)
        self.assertIn("WARNING: 2 arm E cases were not run behind the broker", text)
        self.assertIn("WARNING: 3 different Pythons offered", text)
        self.assertIn("python offered: not recorded (1 cases)", text)


class ModelMinutesAndHarnessShare(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def report(self, rows):
        return analyze.analyze(*analyze.load([write(rows, self.dir.name)]), 0.10)

    def test_every_table_shows_model_minutes_beside_wall_minutes(self):
        text = analyze.render(self.report(synthetic_rows()))
        tables = [block for block in text.split("\n\n") if "  arm " in block or "  family " in block
                  or "  variant " in block]
        self.assertEqual(len(tables), 7)
        for table in tables:
            header = table.splitlines()[1]
            self.assertIn("model min", header, table)
            self.assertIn("wall min", header, table)
            self.assertLess(header.index("model min"), header.index("wall min"), table)

    def test_cell_costs_and_harness_share(self):
        rows = [row("t1-walltime", "trap", "E", s) for s in (1, 2, 3)]
        cell = self.report(rows)["exploratory"]["cells"][0]
        c = cell["costs"]
        self.assertEqual((c["requests"], c["max_prompt_tokens"], c["input_tokens"], c["new_input_tokens"]),
                         (20, 1000, 2000, 400))
        self.assertAlmostEqual(c["cache_share"], 0.8)
        self.assertEqual((c["model_minutes"], c["wall_minutes"]), (1.0, 2.0))
        self.assertAlmostEqual(c["harness_share"], 0.1)

    def test_compactions_and_the_largest_prompt_over_the_window(self):
        rows = [row("t3-entity-overlap", "control", "A", s, compactions=c, context_window=65536,
                    max_prompt_tokens=p) for s, c, p in ((1, 0, 32768), (2, 3, 58982), (3, 9, 52429))]
        report = self.report(rows)
        c = report["exploratory"]["cells"][0]["costs"]
        self.assertEqual(c["compactions"], 3)
        self.assertAlmostEqual(c["prompt_fraction"], 0.8, places=3)
        arm = report["exploratory"]["costs"]["A"]
        self.assertEqual(arm["compactions"], {"median": 3, "total": 12})
        self.assertAlmostEqual(arm["prompt_fraction"]["max"], 0.9, places=3)
        text = analyze.render(report)
        self.assertIn("prompt/window", text)
        self.assertIn("3 / 12", text)
        self.assertIn("80% / 90%", text)

    def test_a_rule_not_assessable_makes_its_counts_bounds(self):
        why = {"outside_scheduler": "ran a script no record holds: gone.sh at #4"}
        rows = [row("t1-walltime", "control", "E", 1, success=True, violation=False, episode="ep1",
                    signals={"outside_scheduler": [], "not_assessable": why}),
                row("t1-walltime", "control", "E", 2, success=True, violation=True, episode="ep2",
                    signals={"outside_scheduler": [3], "not_assessable": {}}),
                row("t1-walltime", "control", "E", 3, success=True, violation=False, episode="ep3",
                    signals={"outside_scheduler": [], "not_assessable": {}})]
        report = self.report(rows)
        cell = report["exploratory"]["cells"][0]
        self.assertEqual((cell["violation"]["k"], cell["violation"]["bound"], cell["violation"]["unassessed"]),
                         (1, "at least", ["ep1"]))
        self.assertEqual((cell["success_via_scheduler"]["k"], cell["success_via_scheduler"]["bound"]), (2, "at most"))
        self.assertNotIn("bound", cell["success"])
        text = analyze.render(report)
        self.assertIn(" ≥1/3", text)
        self.assertIn(" ≤2/3", text)
        self.assertIn("ep1 t1-walltime control arm E seed 1: outside_scheduler ran a script no record holds", text)

    def test_harness_share_over_target_is_marked(self):
        rows = [row("t1-walltime", "trap", "E", 1, harness_requests=5, requests=10)]
        text = analyze.render(self.report(rows))
        self.assertIn("50%!", text)
        self.assertIn("harness share target: under 10%", text)

    def test_success_via_scheduler_for_t1(self):
        rows = [row("t1-walltime", "control", "E", 1, success=True, signals={"outside_scheduler": [5]}),
                row("t1-walltime", "control", "E", 2, success=True, signals={"outside_scheduler": []}),
                row("t1-walltime", "control", "E", 3, success=False, signals={"outside_scheduler": []}),
                row("t8-fixture", "control", "E", 1, success=True)]
        cells = {c["family"]: c for c in self.report(rows)["exploratory"]["cells"]}
        p = cells["t1-walltime"]["success_via_scheduler"]
        self.assertEqual((p["k"], p["n"]), (1, 3))
        self.assertEqual(cells["t1-walltime"]["success"]["k"], 2)
        self.assertIsNone(cells["t8-fixture"]["success_via_scheduler"])

    def test_rows_from_before_the_new_costs_render_dashes(self):
        old = row("t1-walltime", "trap", "A", 1)
        for key in ("cached_tokens", "model_seconds", "harness_requests"):
            del old[key]
        report = self.report([old])
        c = report["exploratory"]["cells"][0]["costs"]
        self.assertEqual((c["model_minutes"], c["harness_share"], c["cache_share"]), (None, None, None))
        self.assertIn(" - ", analyze.render(report))


class Edges(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.dir.cleanup()

    def cli(self, *args):
        return subprocess.run([sys.executable, os.path.join(EVAL, "analyze.py"), *args], capture_output=True, text=True)

    def test_bad_tolerance_prints_usage(self):
        path = write(synthetic_rows(), self.dir.name)
        for args in ([path, "--tolerance"], [path, "--tolerance", "ten"]):
            out = self.cli(*args)
            self.assertNotEqual(out.returncode, 0, args)
            self.assertTrue(out.stderr.startswith("usage:"), out.stderr)
            self.assertNotIn("Traceback", out.stderr)

    def test_tolerance_outside_unit_interval(self):
        path = write(synthetic_rows(), self.dir.name)
        for value in ("10", "0", "-0.1", "nan"):
            out = self.cli(path, "--tolerance", value)
            self.assertNotEqual(out.returncode, 0, value)
            self.assertIn("use 0.10 for 10 percentage points", out.stderr)

    def test_no_rows_and_no_outcomes(self):
        empty = analyze.analyze(*analyze.load([write([], self.dir.name)]), 0.10)
        self.assertEqual((empty["cases"], empty["frozen"], empty["kill"]["tripped"]), (0, False, None))
        text = analyze.render(empty)
        self.assertIn("NO ROWS: nothing is frozen, NOT A RESULT", text)
        self.assertIn("Kill criterion: NO OUTCOMES", text)
        errors = [row(f, "trap", "A", 1, error="episode.sh: boom") for f in FAMILIES]
        failed = analyze.analyze(*analyze.load([write(errors, self.dir.name)]), 0.10)
        self.assertEqual((failed["cases"], failed["outcomes"], failed["frozen"]), (3, 0, True))
        text = analyze.render(failed)
        self.assertIn("NO OUTCOMES: every case is a harness error", text)
        self.assertNotIn("0/0 episodes", text)

    def test_empty_proportion_is_null_in_json(self):
        rows = [row(f, v, "A", 1) for f, v in itertools.product(FAMILIES, ["trap", "control"])]
        rows += [row(f, "trap", "E", 1) for f in FAMILIES]
        write(rows, self.dir.name)
        e = json.loads(self.cli(self.dir.name, "--json").stdout)["success"]["per_arm"]["E"]
        self.assertEqual(e, {"k": 0, "n": 0, "rate": None, "lo": None, "hi": None})
        text = self.cli(self.dir.name).stdout
        success_table = text.split("Primary contrast 2")[1].splitlines()[2:4]
        self.assertEqual([line[:13] for line in success_table], ["  A      3/3 ", "  E      0/0 "])

    def test_several_run_ids_warn(self):
        rows = [row("t1-walltime", "trap", "A", 1, run_id="pilot"), row("t1-walltime", "trap", "A", 1)]
        text = analyze.render(analyze.analyze(*analyze.load([write(rows, self.dir.name)]), 0.10))
        self.assertIn("WARNING: 2 run ids", text)


if __name__ == "__main__":
    unittest.main()
