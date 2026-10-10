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


def row(family, variant, arm, seed, **over):
    r = {"run_id": "synthetic", "family": family, "variant": variant, "arm": arm, "seed": seed,
         "violation": variant == "trap" and seed <= (6 if arm == "A" else 2),
         "success": variant == "control" and seed <= 9,
         "escalated": family == "t8-fixture" and arm == "E" and 3 <= seed <= 5,
         "signals": {}, "requests": 10 * seed, "input_tokens": 1000 * seed, "output_tokens": 100 * seed,
         "max_prompt_tokens": 500 * seed, "wall_seconds": 60.0 * seed, "client_exit": 0, "timed_out": False,
         "unfrozen": False, "card_sha256": SHA}
    r.update(over)
    return r


def synthetic_rows():
    rows = [row(*k) for k in itertools.product(FAMILIES, ["trap", "control"], ["A", "E"], range(1, 11))]
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
        self.assertEqual((r["rows"], r["cases"], r["superseded"], r["outcomes"]), (122, 120, 2, 119))
        self.assertEqual(r["errors"], [{"case": "t3-entity-overlap control arm A seed 10", "error": "score.py: Traceback"}])
        self.assertEqual((r["unfrozen"], r["card_sha256"], r["arms"]), (0, [SHA], ["A", "E"]))

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
                         (1, 1, 2, 119, False))
        self.assertEqual(len(self.report["exploratory"]["cells"]), 12)
        t8_trap_e = [e for e in self.report["exploratory"]["escalation_t8"] if (e["variant"], e["arm"]) == ("trap", "E")]
        self.assertEqual(t8_trap_e, [{"variant": "trap", "arm": "E", "n": 10, "violated": 2, "escalated": 3, "neither": 5}])
        self.assertEqual(self.report["exploratory"]["costs"]["A"]["timeouts"], 1)

    def test_cli_json_matches(self):
        out = subprocess.run([sys.executable, os.path.join(EVAL, "analyze.py"), self.dir.name, "--json"],
                             capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(out.stdout), json.loads(json.dumps(self.report)))

    def test_missing_arm_and_unfrozen(self):
        rows = [row(f, v, "A", s, unfrozen=True, card_sha256=None)
                for f, v, s in itertools.product(FAMILIES, ["trap", "control"], range(1, 4))]
        report = analyze.analyze(*analyze.load([write(rows, self.dir.name)]), 0.10)
        self.assertEqual(report["violation"]["contrast"], {"missing": ["E"]})
        text = analyze.render(report)
        self.assertIn("UNFROZEN", text)
        self.assertIn("not computed: no episodes for arm E", text)


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
