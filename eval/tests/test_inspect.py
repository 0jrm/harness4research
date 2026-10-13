"""usage: python3 -m unittest discover -s eval/tests -p test_inspect.py

The fixture is pilot 4's episode c90ce138e1a6 (t1-walltime trap, arm E), cut to its first 13 requests: every text
over 100 characters is shortened the same way wherever it recurs, except call arguments and commands; the replies
keep only their output_item.done and response.completed events; the Codex events, scheduler audit, job ledger and
forge log stop at the last of those requests; verdict.json's requests and tokens are recomputed for the cut. It has
no hidden/ and no git repositories.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

EVAL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(EVAL, "inspect"))
import index  # noqa: E402

FIXTURE = os.path.join(EVAL, "tests", "fixtures", "inspect", "c90ce138e1a6")


def items_of(doc):
    return {p["at"]: p["v"] for t in doc["turns"] for p in t["output"] + t["new_input"]}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def copy(self, name="c90ce138e1a6"):
        dst = os.path.join(self.tmp, "sessions", name)
        shutil.copytree(FIXTURE, dst)
        return dst


class EpisodeIndex(Fixture):
    @classmethod
    def setUpClass(cls):
        cls.doc = index.episode_index(FIXTURE)
        cls.items = items_of(cls.doc)

    def test_every_check_passes(self):
        self.assertEqual([(c["name"], c["ok"]) for c in self.doc["checks"]],
                         [(c["name"], True) for c in self.doc["checks"]])
        self.assertEqual(len(self.doc["turns"]), 13)

    def test_each_request_keeps_only_its_new_items(self):
        lines = [e for _, e in index.jsonl(os.path.join(FIXTURE, index.REQUESTS))]
        for t, line, before in zip(self.doc["turns"], lines, [None] + lines):
            self.assertFalse(t["history_rewritten"])
            self.assertEqual(t["kept"], len(before["request"]["input"]) if before else 0)
            self.assertEqual([p["v"] for p in t["new_input"]], line["request"]["input"][t["kept"]:])
        second = [p["v"]["type"] for p in self.doc["turns"][1]["new_input"]]
        self.assertEqual(second, ["reasoning", "function_call", "function_call",
                                  "function_call_output", "function_call_output"])

    def test_streamed_replies_join_later_requests_by_call_id(self):
        for c in self.doc["calls"][:-1]:
            call, echo, out = self.items[c["call"]], self.items[c["echo"]], self.items[c["output"]]
            self.assertTrue(call["call_id"].startswith("call_"), c["id"])
            self.assertEqual((echo["call_id"], echo["name"], echo["arguments"]),
                             (call["call_id"], call["name"], call["arguments"]))
            self.assertEqual(out["call_id"], call["call_id"])
            self.assertEqual(c["output_turn"], c["turn"] + 1)
        sent = {p["v"].get("call_id") for t in self.doc["turns"] for p in t["new_input"]}
        for t in self.doc["turns"]:
            self.assertTrue(t["output"][0]["at"].endswith("/item"))
            completed = next(e for e in index.sse_data(index.resolve(f"{index.REQUESTS}:{t['n']}#/response", FIXTURE))
                             if e.get("type") == "response.completed")["response"]["output"]
            ids = {i["call_id"] for i in completed if i["type"] == "function_call"}
            self.assertTrue(all(i.startswith("chatcmpl-tool-") for i in ids), "completed renames every call")
            self.assertFalse(ids & sent, "Codex sends back the streamed ids, never the completed ones")
            self.assertEqual(index.said(i for i in completed), index.said(p["v"] for p in t["output"]))
            self.assertNotIn("completed", t)
        last = self.doc["calls"][-1]
        self.assertEqual((last["turn"], last["echo"], last["state"]), (13, None, "unanswered: no request followed"))

    def test_a_completed_event_that_disagrees_with_the_stream_is_shown(self):
        ep = self.copy()
        path = os.path.join(ep, index.REQUESTS)
        lines = [e for _, e in index.jsonl(path)]
        events = lines[1]["response"].split("\n")
        k = next(i for i, line in enumerate(events) if '"response.completed"' in line)
        completed = json.loads(events[k][5:])
        call = next(i for i in completed["response"]["output"] if i["type"] == "function_call")
        call["arguments"] = call["arguments"].replace("config.json", "config.jsn")
        events[k] = "data: " + json.dumps(completed)
        lines[1]["response"] = "\n".join(events)
        with open(path, "w") as f:
            f.writelines(json.dumps(line) + "\n" for line in lines)
        doc = index.episode_index(ep)
        self.assertEqual([t["n"] for t in doc["turns"] if "completed" in t], [2])
        check = doc["checks"][-1]
        self.assertEqual((check["ok"], check["detail"]),
                         (False, "the client received other text or arguments in turns 2"))
        streamed = items_of(doc)[next(c["call"] for c in doc["calls"] if c["turn"] == 2)]
        self.assertIn("config.json", streamed["arguments"])

    def test_calls_join_codex_commands_in_order_and_rejections_have_none(self):
        events = [e for _, e in index.jsonl(os.path.join(FIXTURE, index.EVENTS))]
        ran = [e["item"]["command"] for e in events
               if e["type"] == "item.completed" and e["item"]["type"] == "command_execution"]
        joined = [c["command"]["v"]["command"] for c in self.doc["calls"] if c["command"]]
        self.assertEqual(joined, ran)
        for c in self.doc["calls"]:
            if c["command"]:
                self.assertEqual(index.command_of(c["command"]["v"]["command"]),
                                 index.arguments(self.items[c["call"]])["cmd"])
        rejected = [c for c in self.doc["calls"] if c["rejected"]]
        self.assertEqual([c["id"] for c in rejected], ["1.0"])
        self.assertTrue(self.items[rejected[0]["output"]]["output"].startswith("`justification` requires"))

    def test_inferred_repairs_match_the_request_as_sent(self):
        for t in self.doc["turns"]:
            self.assertEqual(t["repairs"]["how"], "inferred")
            sent = index.resolve(t["repairs"]["at"], FIXTURE)
            self.assertEqual(t["repairs"]["v"].get("mcp_merge", 0),
                             sum(1 for i in sent if str(i.get("id", "")).startswith("mcp_")))
            self.assertIn("fold_developer", t["repairs"]["v"])
            self.assertIsNone(t["repairs"]["v"]["fold_developer"])
        self.assertEqual(self.doc["turns"][-1]["repairs"]["v"], {"fold_developer": None, "text_into_reasoning": 12,
                                                                 "mcp_merge": 12})

    def test_logged_repairs_are_read_from_the_log(self):
        ep = self.copy()
        path = os.path.join(ep, index.REQUESTS)
        lines = [e for _, e in index.jsonl(path)]
        for n, line in enumerate(lines):
            line["repairs"] = {"fold_developer": 1, "text_into_reasoning": n, "mcp_merge": n}
        with open(path, "w") as f:
            f.writelines(json.dumps(line) + "\n" for line in lines)
        doc = index.episode_index(ep)
        for n, t in enumerate(doc["turns"]):
            self.assertEqual(t["repairs"], {"v": {"fold_developer": 1, "text_into_reasoning": n, "mcp_merge": n},
                                            "at": f"{index.REQUESTS}:{n + 1}#/repairs", "how": "logged"})
            self.assertTrue(index.holds(t["repairs"], ep))

    def test_every_pointer_resolves_to_the_value_shown(self):
        found = list(index.pointers(self.doc))
        self.assertGreater(len(found), 200)
        bad = [p["at"] for p in found if not index.holds(p, FIXTURE)]
        self.assertEqual(bad, [])
        reply = self.doc["turns"][0]["output"][0]
        self.assertRegex(reply["at"], r"^state/model/requests\.jsonl:1#/response/sse:\d+/item$")

    def test_scheduler_jobs_and_verdict_lines(self):
        self.assertEqual([(j["job"]["v"]["id"], j["turn"]) for j in self.doc["jobs"]], [("1000", 12)])
        vias = [(s["row"]["v"]["cmd"], s["via"]["v"], s["turn"]) for s in self.doc["scheduler"]]
        self.assertEqual(vias[0], ("sbatch", "direct", 7))
        self.assertIn(("sbatch", "preflight", 12), vias)
        decides = [d["v"].split("=")[0].strip() for d in self.doc["scorer"]["decides"]]
        self.assertEqual(decides, ["violation", "success"])
        over = next(s for s in self.doc["scorer"]["signals"] if s["name"] == "over_cap_request")
        self.assertIn("timelimit_min", over["source"])
        self.assertIn('"over_cap_request"', over["line"]["v"])

    def test_a_running_episode_indexes_from_what_exists(self):
        ep = self.copy()
        os.remove(os.path.join(ep, "verdict.json"))
        path = os.path.join(ep, index.REQUESTS)
        text = index.read_text(path)
        cut = text.rstrip("\n").rfind("\n") + 1
        with open(path, "w") as f:
            f.write(text[:cut] + text[cut:cut + 500])
        doc = index.episode_index(ep)
        self.assertEqual((doc["state"], len(doc["turns"])), ("running", 12))
        self.assertEqual([c["ok"] for c in doc["checks"]], [None, None, None, True, True, True])
        self.assertEqual(doc["calls"][-1]["state"], "unanswered: no request followed")
        self.assertIsNone(doc["identity"]["verdict"])


class Work(Fixture):
    """The agent owns its clone's .git/config, which can name commands git runs; the index must not run them."""

    def git(self, *args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True,
                              env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}).stdout

    def test_work_lists_changes_without_reading_the_agents_git_config(self):
        ep = self.copy()
        meta = index.read_json(os.path.join(ep, "meta.json"))
        project = os.path.join(ep, "home", meta["project"])
        protected = os.path.join(ep, index.PROTECTED)
        os.makedirs(project)
        self.git("init", "-q", "-b", "main", cwd=project)
        for name in ("README.md", "sim.py"):
            with open(os.path.join(project, name), "w") as f:
                f.write(name + "\n")
        self.git("add", ".", cwd=project)
        self.git("commit", "-qm", "start", cwd=project)
        start = self.git("rev-parse", "HEAD", cwd=project).strip()
        self.git("init", "-q", "--bare", protected, cwd=ep)
        self.git("push", "-q", protected, "main", cwd=project)
        with open(os.path.join(ep, "state/git/start-commit"), "w") as f:
            f.write(start + "\n")
        with open(os.path.join(project, "REPORT.md"), "w") as f:
            f.write("pushed\n")
        self.git("add", "REPORT.md", cwd=project)
        self.git("commit", "-qm", "report", cwd=project)
        self.git("push", "-q", protected, "main", cwd=project)
        with open(os.path.join(project, "sim.py"), "a") as f:
            f.write("edited\n")
        with open(os.path.join(project, "notes.txt"), "w") as f:
            f.write("untracked\n")
        canary = os.path.join(self.tmp, "fsmonitor-ran")
        self.git("config", "core.fsmonitor", f"touch {canary}; false", cwd=project)

        work = index.episode_index(ep)["work"]
        self.assertFalse(os.path.exists(canary), "the index ran the agent's core.fsmonitor")
        self.assertEqual([(p["ref"], p["paths"]["v"]) for p in work["pushed"]], [("refs/heads/main", ["REPORT.md"])])
        self.assertEqual(work["worktree"]["v"], ["REPORT.md", "notes.txt", "sim.py"])
        for p in [work["start"], work["worktree"], *(q["paths"] for q in work["pushed"])]:
            self.assertTrue(index.holds(p, ep), p["at"])
        self.assertFalse(os.path.exists(canary))
        subprocess.run(["git", "status"], cwd=project, capture_output=True)
        self.assertTrue(os.path.exists(canary), "git status in the clone runs it, so the canary works")


if __name__ == "__main__":
    unittest.main()
