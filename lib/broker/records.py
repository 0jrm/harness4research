"""The broker's records: design increment 2 of docs/design-sandboxed-agents.md (W1.2).

The records socket offers four verbs, add, list, show and find, over three stores:

    needs-you   the queue of what only a person can do, check or approve, in the broker's state, never in the clone
    ledger      runs/<run_id>/execution.tsv rows (guard ledger add)
    card        runs/<run_id>/question.card (guard card add)

No verb closes, acknowledges, dismisses or approves an item, or records a verdict, so none can be expressed through
the socket; people do that outside the sandbox (broker.py records, broker.py approve card). The broker stamps every
item's source. It writes ledger rows and cards itself (decision D13): it validates them, commits them to the run's
branch run/<run_id> on origin with a commit signed by its key, and pushes. The forge refuses an unsigned commit that
writes either file. A card is approved when the signed tag card/<run_id> exists on origin, made by the owner's key or
by the broker's (D2); the broker signs it only for a card whose budget_core_hours is at or under the budget card's
card_auto_max_core_hours (default 0, so never), logs that, and otherwise queues an approve item for the owner.
Every request and its outcome is a row in records/log.jsonl, the digest of what the broker did."""
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import time

import needs_you

RUN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VERBS = ("add", "list", "show", "find")
ITEM_KEYS = {"kind", "title", "why", "path", "run", "expect", "worry", "undo", "source", "update"}
LEDGER_KEYS = ("field", "value", "why", "evidence")
IDENT = {"GIT_AUTHOR_NAME": "guard broker", "GIT_AUTHOR_EMAIL": "broker@guard.invalid",
         "GIT_COMMITTER_NAME": "guard broker", "GIT_COMMITTER_EMAIL": "broker@guard.invalid"}
OWNER = {"GIT_COMMITTER_NAME": "owner", "GIT_COMMITTER_EMAIL": "owner@lab.invalid"}
MAX_TEXT = 64 << 10


class Refused(Exception):
    pass


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def card_values(text):
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep and key not in values:
            values[key] = value.strip()
    return values


def outside(cfg, inside):
    """The broker's path for a path inside the sandbox, or Refused."""
    for a, b in cfg["paths"]:
        if inside == a or inside.startswith(a + "/"):
            return b + inside[len(a):]
    raise Refused(f"{inside} is outside what the broker can see")


def read_rows(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


class Records:
    def __init__(self, state_dir, cfg, mirror):
        self.cfg, self.mirror = cfg, mirror
        self.dir = os.path.join(state_dir, "records")
        os.makedirs(self.dir, exist_ok=True)
        self.queue = os.path.join(self.dir, "needs-you.tsv")
        self.log_path = os.path.join(self.dir, "log.jsonl")

    # the socket ----------------------------------------------------------------------------------------------------
    def handle(self, req):
        verb, store = req.get("verb"), req.get("store")
        try:
            if verb not in VERBS:
                raise Refused(f"no verb {verb!r} on the records socket; it offers add, list, show and find, and nothing "
                              "that closes, acknowledges, dismisses or approves an item or records a verdict: a person "
                              "does that outside the sandbox")
            handler = getattr(self, f"{str(store).replace('-', '_')}_{verb}", None)
            if store not in ("needs-you", "ledger", "card") or handler is None:
                raise Refused(f"no {verb} for {store!r}; the stores are needs-you (add list show find), ledger "
                              "(add list) and card (add list show)")
            out = handler(req)
            self.log({"verb": verb, "store": store, "ok": out.strip().splitlines()[0] if out.strip() else ""})
            return {"rc": 0, "out": out}
        except (Refused, needs_you.Refused) as e:
            self.log({"verb": verb, "store": store, "refused": str(e)})
            return {"rc": 2, "err": f"guard broker: refused: {e}\n"}

    def log(self, row):
        with open(self.log_path, "a") as f:
            f.write(json.dumps({"ts": time.time(), "session": self.cfg["session"], **row}) + "\n")

    @staticmethod
    def keys(req, allowed):
        extra = set(req) - {"verb", "store"} - set(allowed)
        if extra:
            raise Refused(f"unknown request keys {sorted(extra)}")

    @staticmethod
    def text(value, name):
        if not isinstance(value, str):
            raise Refused(f"{name} is a string")
        return value

    def run_id(self, req):
        run = req.get("run")
        if not isinstance(run, str) or not RUN.match(run) or run.startswith("explore-") or run == "_template":
            raise Refused(f"run id {run!r} is not a run id that takes a card or a ledger")
        return run

    # needs-you -----------------------------------------------------------------------------------------------------
    def needs_you_add(self, req):
        self.keys(req, ["item"])
        item = req.get("item")
        if not isinstance(item, dict) or set(item) - ITEM_KEYS:
            raise Refused(f"an item has the fields {' '.join(sorted(ITEM_KEYS))}, and nothing else such as a state or "
                          f"an id: {sorted(set(item or {}) - ITEM_KEYS) if isinstance(item, dict) else item!r}")
        one = {k: self.text(item.get(k, ""), k) for k in ITEM_KEYS - {"path", "run", "update"}}
        many = {k: [self.text(v, k) for v in item.get(k, [])] if isinstance(item.get(k, []), list) else None
                for k in ("path", "run")}
        if None in many.values():
            raise Refused("path and run are lists of strings")
        given = one["source"]
        return self.queue_item(one["kind"], one["title"], dict(why=one["why"], expect=one["expect"], worry=one["worry"],
                                                                undo=one["undo"]), many["path"], many["run"],
                               f"sandbox {self.cfg['session']}" + (f": {given}" if given else ""),
                               item.get("update") is True) + "\n"

    def queue_item(self, kind, title, text, paths, runs, source, update=False):
        cell = needs_you.cell
        if kind not in needs_you.KINDS:
            raise Refused(f"--kind is one of {' '.join(needs_you.KINDS)}")
        if not title.strip():
            raise Refused("--title is empty")
        if not all(c.strip() for c in runs):
            raise Refused("--run is empty")
        if kind == "run" and not runs:
            raise Refused("--kind run needs at least one --run command")
        fields = dict(title=cell("title", title), **{k: cell(k, v, part=True) for k, v in text.items()}, note="",
                      source=cell("source", source), paths=[self.item_path(p) for p in paths],
                      commands=[cell("run", c, part=True) for c in runs])
        made = {}

        def new(items):
            same = needs_you.find(items, kind, title, ("open", "acked") if update else ("open",))
            if same:
                made["id"] = same.id
                mine = f"sandbox {self.cfg['session']}"
                if update and same.source != mine and not same.source.startswith(mine + ": "):
                    raise Refused(f"{same.id} was queued by {same.source or 'a person'}, so only they change it")
                fresh = same._replace(ts=now(), state="open", **fields)
                unchanged = fresh._replace(ts=same.ts, state=same.state, note=same.note) == same
                return fresh if update and not unchanged else None
            n = max((int(it.id[1:]) for it in items if it.id[1:].isdigit()), default=0) + 1
            made["id"] = f"n{n}"
            return needs_you.Item(id=f"n{n}", ts=now(), state="open", kind=kind, **fields)

        needs_you.transact(self.queue, new)
        return made["id"]

    def item_path(self, p):
        needs_you.cell("path", p, part=True)
        if not os.path.isabs(p):
            raise Refused(f"{p} is a relative path; give it absolute")
        norm = os.path.normpath(p)
        if not os.path.lexists(outside(self.cfg, norm)):
            raise Refused(f"{p} does not exist")
        if "scratchpad" in norm.split("/") or any(norm == d or norm.startswith(d + "/") for d in ("/tmp", "/var/tmp")):
            raise Refused(f"{p} is somewhere that gets cleaned. {needs_you.STABLE}")
        return norm

    def block(self, it):
        top = self.cfg["project"]
        return needs_you.block(it, top).replace(f"cd {top} && guard needs-you done {it.id}",
                                                f"guard needs-you done {it.id}   # from a shell outside the sandbox")

    def needs_you_list(self, req):
        self.keys(req, ["remind"])
        if req.get("remind"):
            items = [it for it in needs_you.read(self.queue) if it.state == "open"]
            return needs_you.summary(self.cfg["project"], items) + "\n" if items else ""
        items = [it for it in needs_you.read(self.queue) if it.state in ("open", "acked")]
        return ("\n\n".join(self.block(it) for it in items) if items else "Nothing needs you.") + "\n"

    def needs_you_show(self, req):
        self.keys(req, ["id"])
        it = next((it for it in needs_you.read(self.queue) if it.id == req.get("id")), None)
        if not it:
            raise Refused(f"no item {req.get('id')!r}")
        return self.block(it) + "\n"

    def needs_you_find(self, req):
        self.keys(req, ["kind", "title"])
        it = needs_you.find(needs_you.read(self.queue), req.get("kind"), req.get("title"))
        if not it:
            raise Refused(f"no open or acked {req.get('kind')} item titled {req.get('title')!r}")
        return it.id + "\n"

    # git on origin -------------------------------------------------------------------------------------------------
    def git(self, *args, **kw):
        return self.mirror.git(*args, **kw)

    def sign(self, key):
        return ["-c", "gpg.format=ssh", "-c", f"user.signingKey={key}"]

    def tip(self, run):
        """The run branch's commit on origin, fetched into the mirror, or None."""
        ref = f"refs/heads/run/{run}"
        line = self.git("ls-remote", self.mirror.origin, ref).stdout.split()
        if not line:
            return None
        if self.git("fetch", "-q", "--no-tags", self.mirror.origin, f"+{ref}:refs/runs/{run}").returncode:
            raise Refused(f"the broker could not fetch run/{run} from origin")
        return line[0]

    def blob(self, rev, path):
        done = self.git("cat-file", "blob", f"{rev}:{path}", text=False)
        return done.stdout.decode(errors="replace") if done.returncode == 0 else None

    def commit(self, run, path, data, message):
        """Commits data at path on top of run/<run> (or main), signed by the broker, and pushes it to origin."""
        why = ""
        for _ in range(3):
            self.mirror.fetch()
            parent = self.tip(run) or self.git("rev-parse", "refs/heads/main").stdout.strip()
            blob = self.git("hash-object", "-w", "--stdin", input=data).stdout.strip()
            with tempfile.TemporaryDirectory() as tmp:
                env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
                self.git("read-tree", parent, env=env)
                self.git("update-index", "--add", "--cacheinfo", f"100644,{blob},{path}", env=env)
                tree = self.git("write-tree", env=env).stdout.strip()
            made = self.git(*self.sign(self.cfg["signing_key"]), "commit-tree", "-S", "-p", parent, "-m", message, tree,
                            env=IDENT)
            sha = made.stdout.strip()
            if made.returncode or not sha:
                raise Refused(f"the broker could not sign the commit ({made.stderr.strip()[-200:]})")
            pushed = self.git("push", "-q", self.mirror.origin, f"{sha}:refs/heads/run/{run}")
            if pushed.returncode == 0:
                return sha
            why = pushed.stderr.strip()[-300:]
        raise Refused(f"origin refused run/{run}: {why}")

    def tag(self, run, commit, key, message, env):
        name = f"card/{run}"
        made = self.git(*self.sign(key), "tag", "-f", "-s", "-m", message, name, commit, env=env)
        if made.returncode:
            raise Refused(f"could not sign the tag {name} ({made.stderr.strip()[-200:]})")
        pushed = self.git("push", "-q", self.mirror.origin, f"refs/tags/{name}")
        if pushed.returncode:
            raise Refused(f"origin refused the tag {name}: {pushed.stderr.strip()[-300:]}")

    # cards ---------------------------------------------------------------------------------------------------------
    def card_add(self, req):
        self.keys(req, ["run", "text"])
        run, text = self.run_id(req), self.text(req.get("text"), "text")
        if len(text) > MAX_TEXT or "\0" in text:
            raise Refused("the card is not a short text file")
        self.mirror.fetch()
        template = card_values(self.mirror.show("runs/_template/question.card") or "")
        for line in text.splitlines():
            key, sep, _ = line.partition(":")
            if line.strip() and not line.startswith("#") and (not sep or key not in template):
                raise Refused(f"{line[:60]!r} is not 'key: value' with a key of runs/_template/question.card")
        path = f"runs/{run}/question.card"
        tip = self.tip(run)
        if self.mirror.show(path) is not None or (tip and self.blob(tip, path) is not None):
            raise Refused(f"{path} exists on origin; a card never changes, so start a new run id")
        sha = self.commit(run, path, text, f"run: {run} card\n\nWritten by guard card add for session "
                                           f"{self.cfg['session']}; approved by the signed tag card/{run}.")
        budget = card_values(text).get("budget_core_hours", "")
        auto = card_values(self.mirror.show("guard/budget.card") or "").get("card_auto_max_core_hours", "0")
        auto = int(auto) if auto.isdigit() else 0
        self.log({"run": run, "card": sha, "budget_core_hours": budget})
        said = f"{path} committed to run/{run} as {sha[:12]}, signed by the broker"
        fetch = f"; fetch it: git fetch origin run/{run} && git merge FETCH_HEAD"
        if budget.isdigit() and 0 < int(budget) <= auto:
            self.tag(run, sha, self.cfg["signing_key"], f"card {run}: budget_core_hours {budget}, at or under "
                     f"card_auto_max_core_hours {auto}; signed by the broker", IDENT)
            self.log({"run": run, "approved": sha, "by": "broker", "auto_max": auto})
            return f"{said}, and approved: the broker signed card/{run} (budget {budget} <= {auto} core-h){fetch}\n"
        item = self.queue_item(
            "approve", f"Approve question card {path}",
            dict(why=f"run {run} submits nothing until its card is approved; budget_core_hours {budget or 'unset'} is "
                     f"over card_auto_max_core_hours {auto}", expect="a signed tag card/" + run, worry="",
                 undo=f"delete the tag card/{run}, past the tag ruleset, and record a revoked row"),
            [], ["# read the card first: git show " + sha[:12] + ":" + path, f"git fetch origin run/{run}",
                 f"git tag -s -m approved card/{run} {sha}", f"git push origin card/{run}"], "broker")
        return f"{said}; it waits for the owner's signed tag card/{run}: needs-you {item}{fetch}\n"

    def card_show(self, req):
        self.keys(req, ["run"])
        run = self.run_id(req)
        self.mirror.fetch()
        tip = self.tip(run)
        text = self.mirror.show(f"runs/{run}/question.card") or (self.blob(tip, f"runs/{run}/question.card") if tip else None)
        if text is None:
            raise Refused(f"no card for {run} on origin")
        try:
            status = f"approved: {self.approved(run)[1]}"
        except Refused as e:
            status = f"not approved: {e}"
        return f"{text.rstrip()}\n# {status}\n"

    def card_list(self, req):
        self.keys(req, [])
        runs = sorted({r["run"] for r in read_rows(self.log_path) if r.get("card")})
        lines = []
        for run in runs:
            try:
                lines.append(f"{run}\tapproved\t{self.approved(run)[1]}")
            except Refused as e:
                lines.append(f"{run}\tnot approved\t{e}")
        return "".join(line + "\n" for line in lines) or "no cards\n"

    def approved(self, run):
        """(card text, who signed) for the card the signed tag card/<run> on origin approves, or Refused."""
        if any(r.get("revoked") == run for r in read_rows(self.log_path)):
            raise Refused(f"card/{run} was revoked; start a new run id")
        ref = f"refs/tags/card/{run}"
        line = self.git("ls-remote", self.mirror.origin, ref).stdout.split()
        if not line:
            raise Refused(f"runs/{run}/question.card is not approved: no signed tag card/{run} on origin. guard card add "
                          f"queues a card for the owner, who signs the tag outside the sandbox")
        obj = line[0]
        if self.git("fetch", "-q", "--no-tags", self.mirror.origin, f"+{ref}:{ref}").returncode:
            raise Refused(f"the broker could not fetch card/{run}")
        if self.git("cat-file", "-t", obj).stdout.strip() != "tag":
            raise Refused(f"card/{run} is not a signed tag object")
        head = self.git("cat-file", "tag", obj).stdout.split("\n\n", 1)[0]
        if f"\ntag card/{run}\n" not in head + "\n":
            raise Refused(f"card/{run} names another tag; a tag approves only the run it was signed for")
        checked = self.git("-c", f"gpg.ssh.allowedSignersFile={self.cfg['allowed_signers']}", "verify-tag", obj)
        if checked.returncode:
            raise Refused(f"card/{run} is not signed by the owner's or the broker's key "
                          f"({(checked.stderr.strip().splitlines() or ['no signature'])[-1]})")
        text = self.blob(obj, f"runs/{run}/question.card")
        if text is None:
            raise Refused(f"card/{run} points at a commit without runs/{run}/question.card")
        signer = re.search(r'for (\w+) with', checked.stderr)
        return text, f"signed by {signer.group(1) if signer else 'a trusted key'}"

    # ledgers -------------------------------------------------------------------------------------------------------
    def ledger_add(self, req):
        self.keys(req, ["run", *LEDGER_KEYS])
        run = self.run_id(req)
        row = {k: self.text(req.get(k, ""), k) for k in LEDGER_KEYS}
        if any(c in v for v in row.values() for c in "\t\n\r"):
            raise Refused("a ledger cell holds no tab or newline")
        if not row["field"] or not row["value"]:
            raise Refused("a ledger row names a field and a value")
        self.mirror.fetch()
        base = self.tip(run) or "refs/heads/main"
        path, card = f"runs/{run}/execution.tsv", f"runs/{run}/question.card"
        card_text = self.blob(base, card) or self.mirror.show(card)
        if card_text is None:
            raise Refused(f"no {card} on run/{run} or main; guard card add {run} first")
        current = self.blob(base, path) or self.mirror.show("runs/_template/execution.tsv") \
            or "id\tts\tfield\tvalue\twhy\tevidence\n"
        current += "" if current.endswith("\n") else "\n"
        n = sum(1 for line in current.splitlines()[1:] if line.strip() and not line.startswith("#")) + 1
        new = current + "\t".join([f"x{n}", now(), row["field"], row["value"], row["why"], row["evidence"]]) + "\n"
        # main's guard/run says where the fence comes from: the harness at the pin, or guard/bin/ before the pin.
        runner = self.mirror.show("guard/run")
        shown = runner and subprocess.run(
            ["bash", "-c", runner, "guard/run", "--show", "fence"], cwd=self.mirror.path, capture_output=True, text=True,
            env={"PATH": os.environ["PATH"], "HOME": self.mirror.path, "GIT_CONFIG_NOSYSTEM": "1",
                 "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_DIR": self.mirror.path, "HPC_GUARD_REF": "refs/heads/main"})
        if not shown or shown.returncode:
            raise Refused("main's guard/run cannot give the fence to check the row with"
                          + (f" ({shown.stderr.strip()[-200:]})" if shown else ""))
        fence = shown.stdout
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "runs", run))
            for rel, data in ((path, new), (card, card_text)):
                with open(os.path.join(tmp, rel), "w") as f:
                    f.write(data)
            checked = subprocess.run(["bash", "-c", fence, "guard/bin/fence.sh", "--ledger", path], cwd=tmp,
                                     capture_output=True, text=True,
                                     env={"PATH": os.environ["PATH"], "GIT_DIR": os.path.join(tmp, "none")})
        if checked.returncode:
            fails = [line.split("\t")[-1] for line in checked.stdout.splitlines() if line.startswith("FAIL")]
            raise Refused("guard fence --ledger: " + ("; ".join(fails) or checked.stderr.strip()[-200:]))
        sha = self.commit(run, path, new, f"run: {run} ledger x{n} {row['field']}\n\nWritten by guard ledger add for "
                                          f"session {self.cfg['session']}.")
        return (f"x{n} committed to run/{run} as {sha[:12]}, signed by the broker; fetch it: git fetch origin run/{run} "
                f"&& git merge FETCH_HEAD\n")

    def ledger_list(self, req):
        self.keys(req, ["run"])
        run = self.run_id(req)
        self.mirror.fetch()
        tip = self.tip(run)
        text = (self.blob(tip, f"runs/{run}/execution.tsv") if tip else None) or self.mirror.show(f"runs/{run}/execution.tsv")
        if text is None:
            raise Refused(f"no runs/{run}/execution.tsv on run/{run} or main")
        return text


# outside the sandbox: what a person runs ---------------------------------------------------------------------------
def approve_card(records, run):
    """The owner signs card/<run> with their key on the commit guard card add made, and closes the approve item."""
    commits = [r["card"] for r in read_rows(records.log_path) if r.get("run") == run and r.get("card")]
    if not RUN.match(run) or not commits:
        sys.exit(f"broker.py: no card for {run!r} was added through the broker")
    records.mirror.fetch()
    records.tip(run)
    try:
        records.tag(run, commits[-1], records.cfg["owner_key"], f"card {run}: approved by the owner", OWNER)
    except Refused as e:
        sys.exit(f"broker.py: {e}")
    records.log({"run": run, "approved": commits[-1], "by": "owner"})
    item = needs_you.find(needs_you.read(records.queue), "approve", f"Approve question card runs/{run}/question.card")
    if item:
        needs_you.move(records.queue, "done", item.id, f"the owner signed card/{run}")
    print(f"approved runs/{run}/question.card: the owner signed card/{run} on {commits[-1][:12]}")


def revoke_card(records, run):
    """Deletes card/<run> on origin in place, as the owner past the tag ruleset, and logs a revoked row the broker
    honours even if a copy of the tag is pushed again."""
    subprocess.run(["git", "--git-dir", records.mirror.origin, "tag", "-d", f"card/{run}"], capture_output=True)
    records.log({"revoked": run, "by": "owner"})
    print(f"revoked card/{run}: no job for {run} starts again")
