"""The broker's forge: design increment 3 of docs/design-sandboxed-agents.md, in the evaluation (W1.3).

The evaluation has no GitHub, so the broker keeps the pull requests itself, in state/broker/forge/:

    pulls.json    each pull request: number, title, body, head branch, base main, state, comments
    briefs/       the brief guard pr open writes from the owner's words, one per head branch (decision A3)
    reviews.tsv   the verdicts guard review records, which guard merge trusts; only the broker writes it
    log.jsonl     every request on the gh socket, its action and its outcome

A pull request's head is its branch on origin, read when it is used. Its one check, guard-fence / fence, is the fence
main's guard/run runs on main...head, as the forge hook runs it on a push. The sandbox's gh is client.py, a pipe to
the gh socket, which offers pr create, view, list, diff, checks and comment, api reads of pull requests, and pr-open
(guard pr open). It refuses pr merge, auth, every other subcommand, and every api call that writes.

guard review, guard merge and guard ship run here, outside the sandbox, as broker.py review|merge|ship; a person or
the orchestrating session runs them, and no socket offers them. review runs the configured reviewer in a sandbox of
its own that holds the pull request's head and the model socket, and nothing else: no forge, no broker socket, no
home, no network, no token. merge checks merge_policy on main, the check, a fast-forward from main and the last
verdict at the head, then pushes the head to main with the merge marker the forge hook asks for when main takes pull
requests only (git config guard.main pulls). It fast-forwards where GitHub squashes, so the broker's signed record
commits reach main as they are."""
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time

from records import Refused, card_values

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BRANCH = re.compile(r"^(?![-/.])(?!.*\.\.)(?!.*//)[A-Za-z0-9._/-]{1,100}(?<![/.])$")
ITEM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]*$")
CHECK = "guard-fence / fence"
VERDICT = re.compile(r"^VERDICT: (approve|changes|escalate) - (.*\S.*)$")
FIELDS = ("number", "title", "body", "state", "isDraft", "url", "headRefName", "headRefOid", "baseRefName",
          "isCrossRepository", "statusCheckRollup", "mergeCommit", "author", "comments")
OFFERED = ("gh pr create, view, list, diff, checks and comment, and gh api reads of pull requests; merging is the "
           "broker's, outside the sandbox")
PR_OPEN_KEYS = {"verb", "item", "title", "base", "head", "request", "plan", "scope", "test", "body"}


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(args, spec, what):
    """(options, positionals) from gh-style arguments. spec maps each flag and alias to (key, kind), kind flag or
    value; a flag outside it is refused, so nothing the broker does not read reaches it."""
    opts, pos, i = {}, [], 0
    while i < len(args):
        a = args[i]
        if a.startswith("-") and a != "-":
            name, eq, value = a.partition("=") if a.startswith("--") else (a, "", "")
            if name not in spec:
                raise Refused(f"unknown flag {name} for gh {what}")
            key, kind = spec[name]
            if kind == "value" and not eq:
                if i + 1 >= len(args):
                    raise Refused(f"flag needs an argument: {name}")
                i += 1
                value = args[i]
            opts[key] = value if kind == "value" else True
        else:
            pos.append(a)
        i += 1
    return opts, pos


def api_writes(args):
    """Whether a gh api call writes: any method but GET or HEAD, which -f, -F and --input imply, or a GraphQL
    mutation. It reads every spelling of the method gh accepts, so a write is never labelled a read."""
    method, body = None, False
    for i, a in enumerate(args):
        if a in ("-X", "--method"):
            method = args[i + 1] if i + 1 < len(args) else ""
        elif a.startswith("--method="):
            method = a[len("--method="):]
        elif a.startswith("-X"):
            method = a[2:]
        elif a in ("-f", "-F", "--field", "--raw-field", "--input") or a.startswith(
                ("--field=", "--raw-field=", "--input=", "-f", "-F")):
            body = True
    if any(a.strip("/").split("?")[0] == "graphql" for a in args):
        return any("mutation" in a.lower() for a in args) or (method or "POST").upper() not in ("GET", "HEAD", "POST")
    return (method or ("POST" if body else "GET")).upper() not in ("GET", "HEAD")


def classify(argv):
    """The action a gh request asks for, for the log, from its first words."""
    if argv[:1] == ["pr"]:
        return "pr-" + (argv[1] if len(argv) > 1 else "")
    if argv[:1] == ["api"]:
        return "api-write" if api_writes(argv[1:]) else "api-read"
    return argv[0] if argv else "none"


class Forge:
    def __init__(self, state_dir, cfg, mirror, records):
        self.cfg, self.mirror, self.records = cfg, mirror, records
        self.dir = os.path.join(state_dir, "forge")
        os.makedirs(os.path.join(self.dir, "briefs"), exist_ok=True)
        self.pulls_path = os.path.join(self.dir, "pulls.json")
        self.log_path = os.path.join(self.dir, "log.jsonl")
        self.reviews_path = os.path.join(self.dir, "reviews.tsv")

    # the store -----------------------------------------------------------------------------------------------------
    def pulls(self):
        if not os.path.exists(self.pulls_path):
            return []
        with open(self.pulls_path) as f:
            return json.load(f)

    def transact(self, change):
        """change(pulls) under an exclusive lock, written back whole; the server and broker.py both write the store."""
        with open(os.path.join(self.dir, "lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            pulls = self.pulls()
            result = change(pulls)
            tmp = self.pulls_path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(pulls, f, indent=1)
            os.replace(tmp, self.pulls_path)
        return result

    def log(self, row):
        with open(self.log_path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "session": self.cfg["session"], **row}) + "\n")

    def url(self, pr):
        return f"https://forge.invalid/{os.path.basename(self.cfg['project'])}/pull/{pr['number']}"

    def brief_path(self, head):
        return os.path.join(self.dir, "briefs", head.replace("/", "-") + ".md")

    # git on origin -------------------------------------------------------------------------------------------------
    def head_sha(self, pr):
        """The head branch's commit on origin, fetched into the mirror; a merged pull request keeps its last head."""
        line = self.mirror.git("ls-remote", self.mirror.origin, f"refs/heads/{pr['head']}").stdout.split()
        if not line:
            return pr.get("merged_head")
        if self.mirror.git("fetch", "-q", "--no-tags", self.mirror.origin,
                           f"+refs/heads/{pr['head']}:refs/forge/{pr['head']}").returncode:
            raise Refused(f"the broker could not fetch {pr['head']} from origin")
        return line[0]

    def check(self, pr, sha):
        """(conclusion, detail) of guard-fence / fence: main's fence on main...head, run on the mirror."""
        if not sha:
            return "FAILURE", f"{pr['head']} is not on origin"
        self.mirror.fetch()
        # main's guard/run runs the fence of the harness its card pins, or guard/bin/fence.sh before the pin.
        runner = self.mirror.show("guard/run")
        if runner is None:
            return "SUCCESS", "main has no guard/run"
        with tempfile.TemporaryDirectory() as tmp:
            done = subprocess.run(["bash", "-c", runner, "guard/run", "fence", "refs/heads/main", sha], cwd=tmp,
                                  capture_output=True, text=True,
                                  env={"PATH": os.environ["PATH"], "GIT_DIR": self.mirror.path, "HOME": tmp,
                                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                                       "HPC_GUARD_REF": "refs/heads/main"})
        fails = [line.split("\t")[-1] for line in done.stdout.splitlines() if line.startswith("FAIL")]
        if done.returncode:
            return "FAILURE", "; ".join(fails) or done.stderr.strip()[-200:] or f"exit {done.returncode}"
        return "SUCCESS", "the fence passed"

    def on_origin(self, branch):
        if not isinstance(branch, str) or not BRANCH.match(branch) or branch == "main":
            raise Refused(f"head {branch!r} is not a branch other than main")
        if not self.mirror.git("ls-remote", self.mirror.origin, f"refs/heads/{branch}").stdout.strip():
            raise Refused(f"no branch {branch} on origin; push it first: git push -u origin HEAD:{branch}")

    # the gh socket -------------------------------------------------------------------------------------------------
    def handle(self, req):
        verb, argv = req.get("verb"), req.get("argv")
        action = verb
        try:
            if verb == "gh":
                if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
                    raise Refused("a gh request is its argument list, as strings")
                action = classify(argv)
                out, rc = self.gh(argv)
            elif verb == "pr-open":
                out, rc = self.pr_open(req), 0
            else:
                raise Refused(f"no verb {verb!r} on the gh socket; it offers gh ({OFFERED}) and pr-open")
            self.log({"verb": verb, "action": action, "argv": argv[:16] if verb == "gh" else None, "rc": rc})
            return {"rc": rc, "out": out}
        except Refused as e:
            self.log({"verb": verb, "action": action, "argv": argv[:16] if isinstance(argv, list) else None,
                      "refused": str(e)})
            return {"rc": 1, "err": f"gh: refused by the broker: {e}\n"}

    def gh(self, argv):
        top, rest = argv[0], argv[1:]
        if top == "auth":
            raise Refused("gh auth is not offered here: the broker holds the GitHub token, and nothing in the sandbox "
                          "does")
        if top == "api":
            return self.api(rest), 0
        if top != "pr" or not rest:
            raise Refused(f"gh {top} is not offered here; the stand-in offers {OFFERED}")
        sub, args = rest[0], rest[1:]
        if sub == "merge":
            raise Refused("gh pr merge is not offered here. Merging is the broker's: guard review and guard merge run "
                          "outside the sandbox, and only a verdict the broker's reviewer recorded lets a pull request "
                          "merge")
        handler = getattr(self, f"pr_{sub}", None) if sub in ("create", "view", "list", "diff", "checks", "comment") \
            else None
        if handler is None:
            raise Refused(f"gh pr {sub} is not offered here; the stand-in offers {OFFERED}")
        out = handler(args)
        return out if isinstance(out, tuple) else (out, 0)

    def select(self, pulls, pos):
        if len(pos) != 1:
            raise Refused("name one pull request: its number, its URL or its head branch")
        m = re.search(r"(?:^|/pull/)([0-9]+)$", pos[0])
        if m:
            hit = [p for p in pulls if p["number"] == int(m.group(1))]
        else:
            hit = sorted((p for p in pulls if p["head"] == pos[0]), key=lambda p: (p["state"] == "OPEN", p["number"]))
        if not hit:
            raise Refused(f"no pull requests found for {pos[0]}")
        return hit[-1]

    def create(self, head, base, title, body, draft=False):
        """A new open pull request from head into main, or Refused when head already has one."""
        if base != "main":
            raise Refused(f"the evaluation's forge takes pull requests into main only, not {base!r}")
        if not title.strip():
            raise Refused("a pull request has a title")
        self.on_origin(head)

        def add(pulls):
            same = [p for p in pulls if p["head"] == head and p["state"] == "OPEN"]
            if same:
                raise Refused(f"a pull request for branch {head!r} into branch 'main' already exists:\n"
                              f"{self.url(same[0])}")
            pr = {"number": len(pulls) + 1, "title": title, "body": body, "head": head, "base": base, "state": "OPEN",
                  "draft": draft, "author": f"agent (sandbox {self.cfg['session']})", "created": now(), "comments": []}
            pulls.append(pr)
            return pr
        return self.transact(add)

    def pr_create(self, args):
        spec = {"--base": ("base", "value"), "-B": ("base", "value"), "--head": ("head", "value"),
                "-H": ("head", "value"), "--title": ("title", "value"), "-t": ("title", "value"),
                "--body": ("body", "value"), "-b": ("body", "value"), "--draft": ("draft", "flag"),
                "-d": ("draft", "flag")}
        o, pos = parse(args, spec, "pr create")
        if pos:
            raise Refused(f"gh pr create takes no arguments: {pos[0]}")
        pr = self.create(o.get("head", ""), o.get("base", "main"), o.get("title", ""), o.get("body", ""),
                         bool(o.get("draft")))
        return self.url(pr) + "\n"

    def fields(self, pr, want):
        unknown = [f for f in want if f not in FIELDS]
        if unknown:
            raise Refused(f"Unknown JSON field: {unknown[0]!r}; available fields: {', '.join(FIELDS)}")
        sha = self.head_sha(pr) if {"headRefOid", "statusCheckRollup"} & set(want) else None
        out = {}
        for f in want:
            if f == "statusCheckRollup":
                conclusion, detail = self.check(pr, sha)
                out[f] = [{"name": "fence", "context": CHECK, "workflowName": "guard-fence", "status": "COMPLETED",
                           "conclusion": conclusion, "detail": detail}]
            else:
                out[f] = {"number": pr["number"], "title": pr["title"], "body": pr["body"], "state": pr["state"],
                          "isDraft": pr["draft"], "url": self.url(pr), "headRefName": pr["head"],
                          "headRefOid": sha or "", "baseRefName": pr["base"], "isCrossRepository": False,
                          "mergeCommit": {"oid": pr["merge_commit"]} if pr.get("merge_commit") else None,
                          "author": {"login": pr["author"]},
                          "comments": [{"author": {"login": c["author"]}, "body": c["body"], "createdAt": c["ts"]}
                                       for c in pr["comments"]]}[f]
        return out

    def pr_view(self, args):
        o, pos = parse(args, {"--json": ("json", "value"), "--comments": ("comments", "flag"),
                              "-c": ("comments", "flag")}, "pr view")
        pr = self.select(self.pulls(), pos)
        if "json" in o:
            return json.dumps(self.fields(pr, [f for f in o["json"].split(",") if f])) + "\n"
        conclusion, detail = self.check(pr, self.head_sha(pr))
        text = (f"{pr['title']} #{pr['number']}\n{pr['state']} - {pr['author']} wants to merge {pr['head']} into "
                f"{pr['base']}\n{CHECK}: {conclusion.lower()} ({detail})\n\n{pr['body']}\n")
        if o.get("comments"):
            text += "".join(f"\n{c['author']} ({c['ts']}):\n{c['body']}\n" for c in pr["comments"])
        return text + f"\n{self.url(pr)}\n"

    def pr_list(self, args):
        spec = {"--head": ("head", "value"), "-H": ("head", "value"), "--base": ("base", "value"),
                "-B": ("base", "value"), "--state": ("state", "value"), "-s": ("state", "value"),
                "--json": ("json", "value"), "--limit": ("limit", "value"), "-L": ("limit", "value")}
        o, pos = parse(args, spec, "pr list")
        if pos:
            raise Refused(f"gh pr list takes no arguments: {pos[0]}")
        states = {"open": ("OPEN",), "closed": ("CLOSED", "MERGED"), "merged": ("MERGED",),
                  "all": ("OPEN", "CLOSED", "MERGED")}.get(o.get("state", "open"))
        if states is None:
            raise Refused(f"--state is open, closed, merged or all, not {o['state']!r}")
        limit = o.get("limit", "30")
        if not limit.isdigit():
            raise Refused(f"--limit {limit} is not a number")
        hit = [p for p in reversed(self.pulls()) if p["state"] in states and o.get("head", p["head"]) == p["head"]
               and o.get("base", p["base"]) == p["base"]][:int(limit)]
        if "json" in o:
            return json.dumps([self.fields(p, [f for f in o["json"].split(",") if f]) for p in hit]) + "\n"
        return "".join(f"{p['number']}\t{p['title']}\t{p['head']}\t{p['state']}\n" for p in hit)

    def pr_diff(self, args):
        o, pos = parse(args, {"--name-only": ("name_only", "flag"), "--color": ("color", "value"),
                              "--patch": ("patch", "flag")}, "pr diff")
        pr = self.select(self.pulls(), pos)
        sha = self.head_sha(pr)
        if not sha:
            raise Refused(f"{pr['head']} is not on origin")
        self.mirror.fetch()
        done = self.mirror.git("diff", *(["--name-only"] if o.get("name_only") else []), f"refs/heads/main...{sha}")
        return done.stdout

    def pr_checks(self, args):
        _, pos = parse(args, {"--required": ("required", "flag")}, "pr checks")
        pr = self.select(self.pulls(), pos)
        conclusion, detail = self.check(pr, self.head_sha(pr))
        ok = conclusion == "SUCCESS"
        return f"{CHECK}\t{'pass' if ok else 'fail'}\t{detail}\n", 0 if ok else 1

    def pr_comment(self, args):
        o, pos = parse(args, {"--body": ("body", "value"), "-b": ("body", "value")}, "pr comment")
        if not o.get("body", "").strip():
            raise Refused("a comment has a body: --body or --body-file")
        number = self.select(self.pulls(), pos)["number"]

        def add(pulls):
            pr = next(p for p in pulls if p["number"] == number)
            pr["comments"].append({"author": f"agent (sandbox {self.cfg['session']})", "body": o["body"], "ts": now()})
            return f"{self.url(pr)}#issuecomment-{len(pr['comments'])}\n"
        return self.transact(add)

    def api(self, args):
        if api_writes(args):
            raise Refused("gh api calls that write are not offered here; the broker's GitHub token never writes on the "
                          "sandbox's behalf except through pr create and pr comment")
        spec = {"-X": ("method", "value"), "--method": ("method", "value"), "-H": ("header", "value"),
                "--header": ("header", "value"), "--paginate": ("paginate", "flag"), "-i": ("include", "flag"),
                "--include": ("include", "flag"), "-f": ("field", "value"), "--raw-field": ("field", "value"),
                "-F": ("field", "value"), "--field": ("field", "value")}
        _, pos = parse(args, spec, "api")
        if len(pos) != 1:
            raise Refused("gh api takes one endpoint")
        m = re.fullmatch(r"/?repos/[^/]+/[^/]+/pulls(?:/([0-9]+))?/?(?:\?.*)?", pos[0])
        if not m:
            raise Refused(f"gh api {pos[0]}: the evaluation's forge answers api reads of repos/<owner>/<repo>/pulls[/N] "
                          "only; gh pr view and gh pr list --json read the rest")

        def rest(p):
            sha = self.head_sha(p)
            return {"number": p["number"], "state": "open" if p["state"] == "OPEN" else "closed", "title": p["title"],
                    "body": p["body"], "html_url": self.url(p), "draft": p["draft"], "merged": p["state"] == "MERGED",
                    "merge_commit_sha": p.get("merge_commit"), "head": {"ref": p["head"], "sha": sha},
                    "base": {"ref": p["base"]}}
        if m.group(1):
            return json.dumps(rest(self.select(self.pulls(), [m.group(1)]))) + "\n"
        return json.dumps([rest(p) for p in self.pulls() if p["state"] == "OPEN"]) + "\n"

    def pr_open(self, req):
        """guard pr open (A3): the brief from the owner's words into the broker's state, then the pull request. A
        rerun on a branch that has an open pull request prints its URL and changes nothing."""
        extra = set(req) - PR_OPEN_KEYS
        if extra:
            raise Refused(f"unknown request keys {sorted(extra)}")
        v = {k: req.get(k, "") for k in PR_OPEN_KEYS - {"verb"}}
        if not all(isinstance(x, str) for x in v.values()):
            raise Refused("every pr-open field is a string")
        for k in ("title", "request", "plan", "test", "body"):
            if not v[k].strip():
                raise Refused(f"--{k} is empty" + (". Copy the user's request into it word for word" if k == "request"
                                                   else ""))
        if v["item"] and not ITEM.match(v["item"]):
            raise Refused(f"--item {v['item']} is not a plan item id such as W1.2")
        base, head = v["base"] or "main", v["head"]
        self.on_origin(head)
        same = [p for p in self.pulls() if p["head"] == head and p["state"] == "OPEN"]
        if same:
            return self.url(same[0]) + "\n"
        for line in v["request"].splitlines():
            if len(line) >= 20 and line in v["body"]:
                raise Refused("the body repeats a line of the request. The user's words stay in the brief; describe the "
                              "change in your own")
        brief = "## Request (verbatim)\n" + v["request"].rstrip("\n") + "\n\n"
        if v["scope"]:
            brief += "## Scope\n" + v["scope"].rstrip("\n") + "\n\n"
        brief += "## Plan\n" + v["plan"].rstrip("\n") + "\n\n## Test command\n" + v["test"] + "\n"
        pr = self.create(head, base, (f"[{v['item']}] " if v["item"] else "") + v["title"], v["body"])
        with open(self.brief_path(head), "w") as f:
            f.write(brief)
        return self.url(pr) + "\n"

    # outside the sandbox: guard review, guard merge, guard ship --------------------------------------------------
    def verdicts(self):
        if not os.path.exists(self.reviews_path):
            return []
        with open(self.reviews_path) as f:
            return [dict(zip(("ts", "pr", "head", "verdict", "reviewer", "reason"), line.rstrip("\n").split("\t")))
                    for line in f.readlines()[1:] if line.strip()]

    def last_verdict(self, number):
        rows = [r for r in self.verdicts() if r["pr"] == str(number)]
        return rows[-1] if rows else None

    def record(self, pr, head, verdict, reviewer, reason):
        if not os.path.exists(self.reviews_path):
            with open(self.reviews_path, "w") as f:
                f.write("ts\tpr\thead\tverdict\treviewer\treason\n")
        reason = " ".join(reason.split())
        with open(self.reviews_path, "a") as f:
            f.write(f"{now()}\t{pr['number']}\t{head}\t{verdict}\t{reviewer}\t{reason}\n")

        def comment(pulls):
            p = next(p for p in pulls if p["number"] == pr["number"])
            p["comments"].append({"author": "guard review (broker)", "body": f"guard review: {verdict} at {head[:7]}. "
                                  f"{reason}", "ts": now()})
        self.transact(comment)
        self.log({"verb": "review", "action": "verdict", "pr": pr["number"], "head": head, "verdict": verdict})

    def pull(self, number):
        if not str(number).isdigit():
            raise Refused(f"{number!r} is not a pull request number")
        hit = [p for p in self.pulls() if p["number"] == int(number)]
        if not hit:
            raise Refused(f"no pull request #{number}")
        return hit[0]

    def reviewer_argv(self, worktree, ask):
        """lib/box.sh for the reviewer: the head at /review, a home in memory, the model socket, the configured
        read-only binds, and nothing of the forge, the broker or the agent; the probe checks that first."""
        r = self.cfg.get("reviewer") or {}
        argv = [os.path.join(REPO, "lib", "box.sh"), "--no-tty", "--hostname", "reviewer", "--user", "reviewer",
                "--tmp-home", "/tmp/home", "--bind", worktree, "/review"]
        if r.get("passwd"):
            argv += ["--ro", r["passwd"], "/etc/passwd"]
        model = r.get("model_socket")
        if model and os.path.exists(model) and stat.S_ISSOCK(os.stat(model).st_mode):
            argv += ["--sock", model, "/run/model/proxy.sock"]
        for src, dst in r.get("binds", []):
            argv += ["--ro", src, dst]
        for d in r.get("path", []):
            argv += ["--path", d]
        env = {"GIT_AUTHOR_NAME": "guard reviewer", "GIT_AUTHOR_EMAIL": "reviewer@guard.invalid",
               "GIT_COMMITTER_NAME": "guard reviewer", "GIT_COMMITTER_EMAIL": "reviewer@guard.invalid",
               **{k: str(v) for k, v in r.get("env", {}).items()}}
        argv += [x for k, v in env.items() for x in ("--env", f"{k}={v}")]
        argv += ["--chdir", "/review", "--probe", "--hide", self.dir, "--hide", os.path.expanduser("~")]
        return argv + ["--", "bash", "-c", r["cmd"] + ' "$@"', "reviewer", ask]

    def review(self, number):
        """One round of the configured reviewer on the pull request's head, in its own sandbox; the verdict goes to
        reviews.tsv and a comment. Approve only for a round that added no commits, as lib/review.sh. Exit 0 on
        approve, 1 on changes or escalate, 2 when it refuses to start or the reviewer cannot run."""
        pr = self.pull(number)
        if pr["state"] != "OPEN":
            raise Refused(f"pull request #{number} is {pr['state'].lower()}, so there is nothing to review")
        cmd = (self.cfg.get("reviewer") or {}).get("cmd")
        if not cmd:
            raise Refused("no reviewer is configured: set reviewer.cmd in the broker's config.json")
        brief = self.brief_path(pr["head"])
        request = ""
        if os.path.exists(brief):
            with open(brief) as f:
                text = f.read()
            request = text.split("## Request (verbatim)\n", 1)[1].split("\n## ", 1)[0] if \
                "## Request (verbatim)\n" in text else ""
        if not request.strip():
            raise Refused(f"no brief with the user's request for {pr['head']} in the broker's state; open the pull "
                          "request with guard pr open, which writes it")
        sha = self.head_sha(pr)
        if not sha:
            raise Refused(f"{pr['head']} is not on origin")
        self.mirror.fetch()
        log = os.path.join(self.dir, "reviews", f"{number}-{sha[:12]}.txt")
        os.makedirs(os.path.dirname(log), exist_ok=True)
        wt = tempfile.mkdtemp(prefix=f"pr-{number}-", dir=os.path.dirname(log))
        try:
            outcome = self.round(pr, sha, text, wt, log)
        finally:
            shutil.rmtree(wt, ignore_errors=True)
        if outcome is None:
            return 2
        head, verdict, reason = outcome
        self.record(pr, head, verdict, cmd.split()[0], reason)
        print(f"VERDICT: {verdict} - {reason}\nThe reviewer's report: {log}")
        if verdict != "approve":
            kind = "check" if verdict == "changes" else "approve"
            title = f"Review of PR #{number} " + ("asks for changes" if verdict == "changes" else "needs your decision")
            self.records.queue_item(kind, title, dict(why=reason, expect="", worry="", undo=""), [], [],
                                    "guard review (broker)")
        return 0 if verdict == "approve" else 1

    def mirror_wt(self, wt, *args, env=None):
        """A git command with the broker's mirror as the git dir and wt as the work tree, config-free: it reads the
        mirror's objects (the broker's) and wt's files, never a .git the reviewer could write there, as scorelib.py
        reads the agent's work tree against the protected git dir (#82)."""
        return self.mirror.git("--work-tree", wt, "-c", "core.fsmonitor=", "-c", "protocol.allow=never",
                               "-c", "protocol.file.allow=always", *args, env=env)

    def round(self, pr, sha, brief, wt, log):
        """One reviewer round. The head is laid out in wt as plain files, with no .git, so nothing the reviewer writes
        there is a git dir, config, hook or object the broker later runs. Afterward the broker reads the changes
        through its own mirror with a scratch index, and commits and pushes any from there. Returns (head, verdict,
        reason), or None when the reviewer could not review."""
        number = pr["number"]
        with tempfile.TemporaryDirectory() as tmp:
            idx = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
            if self.mirror_wt(wt, "read-tree", sha, env=idx).returncode \
                    or self.mirror_wt(wt, "checkout-index", "-f", "-a", env=idx).returncode:
                raise Refused(f"the broker could not lay out {pr['head']} for review")
        os.makedirs(os.path.join(wt, ".guard-review"))
        diff = self.mirror.git("diff", f"refs/heads/main...{sha}").stdout
        with open(os.path.join(REPO, "lib", "review-prompt.md")) as f:
            prompt = f.read()
        with open(os.path.join(wt, ".guard-review", "prompt.md"), "w") as f:
            f.write(f"{prompt}\n## This pull request\n\n#{number}, branch {pr['head']} into main, head {sha}. Round 1 "
                    f"of 1.\n\n## Brief\n\n{brief}\n## Diff\n\n```diff\n{diff}```\n")
        ask = "Read .guard-review/prompt.md and follow it. End your reply with the VERDICT line it describes."
        argv = self.reviewer_argv(wt, ask)
        timeout = int((self.cfg.get("reviewer") or {}).get("timeout", 1800))
        with open(log, "w") as out, open(log + ".err", "w") as err:
            try:
                rc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                rc = "timeout"
        with open(log) as f:
            reply = [line.rstrip() for line in f if line.strip() and line.strip() != "```"]
        if rc != 0 or not reply:
            print(f"guard review: the reviewer could not review #{number} ({'exit ' + str(rc) if rc else 'no reply'}; "
                  f"its stderr is in {log}.err); no verdict")
            return None
        m = VERDICT.match(reply[-1])
        verdict, reason = (m.group(1), m.group(2)) if m else ("escalate", "the reviewer's last line is not a VERDICT line")
        # The reviewer's fixes are whatever files it changed. The .guard-review scratch and any .git it planted are
        # dropped before the broker reads the tree, so neither reaches the branch, and git never touches that .git.
        for junk in (".guard-review", ".git"):
            path = os.path.join(wt, junk)
            if os.path.islink(path) or os.path.isfile(path):
                os.unlink(path)
            elif os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
        with tempfile.TemporaryDirectory() as tmp:
            idx = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
            self.mirror_wt(wt, "read-tree", sha, env=idx)
            self.mirror_wt(wt, "add", "-A", env=idx)
            new_tree = self.mirror_wt(wt, "write-tree", env=idx).stdout.strip()
        if new_tree == self.mirror.git("rev-parse", f"{sha}^{{tree}}").stdout.strip():
            return sha, verdict, reason
        made = self.mirror.git("commit-tree", "-p", sha, "-m", "guard review: reviewer fixes", new_tree,
                               env={"GIT_AUTHOR_NAME": "guard reviewer", "GIT_AUTHOR_EMAIL": "reviewer@guard.invalid",
                                    "GIT_COMMITTER_NAME": "guard reviewer", "GIT_COMMITTER_EMAIL": "reviewer@guard.invalid"})
        after = made.stdout.strip()
        if made.returncode or not after:
            raise Refused(f"the broker could not record the reviewer's fixes ({made.stderr.strip()[-200:]})")
        pushed = self.mirror.git("push", "-q", self.mirror.origin, f"{after}:refs/heads/{pr['head']}")
        if pushed.returncode:
            raise Refused(f"cannot push the reviewer's fixes to {pr['head']}: {pushed.stderr.strip()[-200:]}")
        if verdict != "escalate":
            verdict, reason = "changes", "the reviewer changed files, carried to the branch; review it again"
        return after, verdict, reason

    def merge(self, number):
        """guard merge's gate, in the broker: every item passes or nothing merges. Exit 0 when merged, 1 when the
        forge refused the push, 2 when the gate refused."""
        pr = self.pull(number)
        if pr["state"] == "MERGED":
            print(f"Pull request #{number} is already merged.")
            return 0
        items = []
        self.mirror.fetch()
        budget = card_values(self.mirror.show("guard/budget.card") or "")
        policy = budget.get("merge_policy") or "autonomous"
        items.append((policy == "autonomous", f"merge_policy is {policy} on main"))
        items.append((pr["state"] == "OPEN" and not pr["draft"],
                      f"pull request #{number} is {pr['state'].lower()}" + (", a draft" if pr["draft"] else "")))
        sha = self.head_sha(pr)
        conclusion, detail = self.check(pr, sha)
        items.append((conclusion == "SUCCESS", f"{CHECK}: {conclusion.lower()} ({detail})"))
        ff = bool(sha) and self.mirror.git("merge-base", "--is-ancestor", "refs/heads/main", sha).returncode == 0
        items.append((ff, f"{pr['head']} {'fast-forwards' if ff else 'does not fast-forward'} from main"))
        last = self.last_verdict(number)
        if last is None:
            items.append((False, f"guard review has no verdict for pull request #{number}"))
        elif last["verdict"] != "approve":
            items.append((False, f"the last guard review of #{number} says {last['verdict']} at {last['head'][:7]}"))
        elif last["head"] != sha:
            items.append((False, f"guard review approved {last['head'][:7]}, and the head is now {(sha or '')[:7]}"))
        else:
            items.append((True, f"guard review approved the head {sha[:7]}"))
        for ok, text in items:
            print(f"{'pass' if ok else 'FAIL'}  {text}")
        failed = [text for ok, text in items if not ok]
        self.log({"verb": "merge", "action": "gate", "pr": number, "head": sha, "failed": failed})
        if failed:
            print(f"{len(items) - len(failed)} passed, {len(failed)} failed. Refused.")
            self.records.queue_item("approve", f"Merge PR #{number}", dict(
                why="autonomous merge refused: " + "; ".join(failed), expect="", worry="", undo=""), [], [],
                "guard merge (broker)")
            return 2
        pushed = self.mirror.git("push", "-q", self.mirror.origin, f"{sha}:refs/heads/main",
                                 env={"GUARD_BROKER_MERGE": str(number)})
        if pushed.returncode:
            print(f"the forge refused the merge: {pushed.stderr.strip()[-300:]}")
            return 1

        def merged(pulls):
            p = next(p for p in pulls if p["number"] == int(number))
            p.update(state="MERGED", merge_commit=sha, merged_head=sha, merged_at=now())
        self.transact(merged)
        self.log({"verb": "merge", "action": "merged", "pr": number, "head": sha})
        print(f"Merged pull request #{number} into main as {sha[:7]}.")
        return 0

    def ship(self):
        """guard ship in the broker: review every open pull request without a verdict at its head, then merge each
        one approved at its head."""
        rc = 0
        for pr in [p for p in self.pulls() if p["state"] == "OPEN"]:
            last, sha = self.last_verdict(pr["number"]), self.head_sha(pr)
            if (last is None or last["head"] != sha) and (self.cfg.get("reviewer") or {}).get("cmd"):
                print(f"== guard review #{pr['number']}")
                try:
                    self.review(pr["number"])
                except Refused as e:
                    print(f"guard review: refused: {e}")
            last = self.last_verdict(pr["number"])
            if last and last["verdict"] == "approve":
                print(f"== guard merge #{pr['number']}")
                rc = max(rc, self.merge(pr["number"]))
        return rc

