"""Receipts (design-v8 sections 3 and 6, decision 17): every LedgerRow the broker writes is one commit, signed with the
broker's key, appending one line to receipts.jsonl on refs/heads/guard/receipts of origin, so a paper's L<hex> id
dereferences from any clone with git show origin/guard/receipts:receipts.jsonl, and lib/guard/receipts-check.sh
verifies it against broker_key: on the base branch's card.

    receipt_add(broker, kind, run_id, fields) -> LedgerRow   publishes it; local mode appends an l<hex> row instead
    verify(git_dir, ref, signers, known=None) -> bool        the ref is signed by an allowed-signers file, and holds known
    find(broker, id) -> LedgerRow | None
    status_line(broker) -> str                                the line guard status prints for the receipts
    handle(request, broker)                                   the records socket's receipt verb: show

A broker without a signing key (local mode, decision 8) writes l<hex> rows to .git/guard/receipts.jsonl for guard
status only and publishes nothing; F04 refuses those ids by shape. The broker appends only on top of a head that
verifies and that holds the last head it published, so a row someone else wrote is never signed over."""
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import threading
from dataclasses import dataclass, field
from typing import Optional

from broker.records import IDENT, Refused

REF = "refs/heads/guard/receipts"
FILE = "receipts.jsonl"
KINDS = ("holdout", "ask", "refusal", "job")
SIGNED_ID = re.compile(r"^L[0-9a-f]{10}$")
LOCAL_ID = re.compile(r"^l[0-9a-f]{10}$")
CHECK = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "guard", "receipts-check.sh")
LOCK = threading.Lock()


@dataclass(frozen=True)
class LedgerRow:
    """One receipt; field order is the serialized order, so the line starts with its id."""
    id: str
    ts: str
    kind: str
    run_id: Optional[str]
    session: str
    fields: dict = field(default_factory=dict)

    def line(self):
        return json.dumps(dataclasses.asdict(self)) + "\n"


def row_id(prefix, ts, kind, fields):
    digest = hashlib.sha256(json.dumps([ts, kind, fields], sort_keys=True, separators=(",", ":")).encode())
    return prefix + digest.hexdigest()[:10]


def parse(line):
    return LedgerRow(**json.loads(line))


def published(broker):
    return bool(broker.cfg.get("signing_key"))


def local_file(broker):
    """Local mode keeps its broker in <git dir>/guard/broker/, so its receipts sit beside it."""
    top = os.path.dirname(broker.dir) if broker.cfg.get("session") == "local" else broker.dir
    return os.path.join(top, FILE)


def signers_file(broker):
    """An allowed-signers file naming the broker's own public key, the key broker_key: on the card names."""
    with open(broker.cfg["signing_key"] + ".pub") as f:
        key = " ".join(f.read().split()[:2])
    path = os.path.join(broker.dir, "receipts-signers")
    with open(path, "w") as f:
        f.write(f'broker namespaces="git" {key}\n')
    return path


def verify(git_dir, ref, signers, known=None):
    """Whether ref in git_dir is receipts the signers signed, every row by its own commit, and, given known (the last
    head the broker published), whether the ref still holds it: a rewound ref fails."""
    env = {**os.environ, "GIT_DIR": git_dir, "GUARD_RECEIPTS_REF": ref, "GUARD_RECEIPTS_SIGNERS": signers}
    git = lambda *a: subprocess.run(["git", *a], env=env, capture_output=True, text=True)  # noqa: E731
    head = git("rev-parse", "-q", "--verify", f"{ref}^{{commit}}").stdout.strip()
    if not head:
        return False
    if known and git("merge-base", "--is-ancestor", known, head).returncode:
        return False
    rows = git("show", f"{head}:{FILE}").stdout.splitlines()
    checked = int(git("rev-list", "--count", known).stdout) if known else 0  # rows up to known were verified then
    ids = [parse(line).id for line in rows[checked:] if line.strip()]
    return subprocess.run(["bash", CHECK, "HEAD", *ids], env=env, capture_output=True).returncode == 0


class Origin:
    """guard/receipts on origin, through the broker's mirror."""

    def __init__(self, broker):
        self.broker, self.mirror = broker, broker.mirror
        self.last = os.path.join(broker.dir, "receipts-head")

    def git(self, *args, **kw):
        return self.mirror.git(*args, **kw)

    def fetch(self):
        """origin's head of guard/receipts, fetched into the mirror, or None when origin has none."""
        line = self.git("ls-remote", self.mirror.origin, REF).stdout.split()
        if not line:
            return None
        if self.git("fetch", "-q", "--no-tags", self.mirror.origin, f"+{REF}:{REF}").returncode:
            raise Refused("the broker could not fetch guard/receipts from origin")
        return line[0]

    def known(self):
        try:
            with open(self.last) as f:
                return f.read().strip() or None
        except FileNotFoundError:
            return None

    def check(self, head):
        if not verify(self.mirror.path, REF, signers_file(self.broker), self.known()):
            raise Refused(f"guard/receipts on origin at {head[:12]} is not the broker's signed history; a person "
                          f"restores it to {(self.known() or 'nothing')[:12]} outside the sandbox")

    def rows(self, head):
        if head is None:
            return ""
        return self.git("cat-file", "blob", f"{head}:{FILE}").stdout

    def append(self, row):
        why = ""
        for _ in range(3):
            parent = self.fetch()
            if parent is None and self.known():
                raise Refused(f"guard/receipts is gone from origin; the broker last published "
                              f"{self.known()[:12]}, and a person restores it")
            if parent:
                self.check(parent)
            blob = self.git("hash-object", "-w", "--stdin", input=self.rows(parent) + row.line()).stdout.strip()
            tree = self.git("mktree", input=f"100644 blob {blob}\t{FILE}\n").stdout.strip()
            key = self.broker.cfg["signing_key"]
            made = self.git("-c", "gpg.format=ssh", "-c", f"user.signingKey={key}", "commit-tree", "-S",
                            *(["-p", parent] if parent else []), "-m",
                            f"receipt {row.id} {row.kind}" + (f" run {row.run_id}" if row.run_id else ""), tree,
                            env=IDENT)
            sha = made.stdout.strip()
            if made.returncode or not sha:
                raise Refused(f"the broker could not sign the receipt ({made.stderr.strip()[-200:]})")
            pushed = self.git("push", "-q", self.mirror.origin, f"{sha}:{REF}")
            if pushed.returncode == 0:
                self.git("update-ref", REF, sha)
                with open(self.last, "w") as f:
                    f.write(sha + "\n")
                return sha
            why = pushed.stderr.strip()[-300:]
        raise Refused(f"origin refused guard/receipts: {why}")


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def receipt_add(broker, kind, run_id, fields):
    """The receipt for one holdout verdict, ask, refusal or job, published as one signed commit, or, in local mode,
    appended to the local file; returns its LedgerRow."""
    if kind not in KINDS:
        raise ValueError(f"a receipt's kind is one of {', '.join(KINDS)}, not {kind!r}")
    ts = now()
    with LOCK:
        if not published(broker):
            row = LedgerRow(row_id("l", ts, kind, fields), ts, kind, run_id, broker.cfg["session"], fields)
            with open(local_file(broker), "a") as f:
                f.write(row.line())
            return row
        row = LedgerRow(row_id("L", ts, kind, fields), ts, kind, run_id, broker.cfg["session"], fields)
        Origin(broker).append(row)
        return row


def find(broker, rid):
    """The receipt with id rid: an L id from origin's guard/receipts, an l id from the local file; or None."""
    if LOCAL_ID.match(rid):
        lines = open(local_file(broker)).read().splitlines() if os.path.exists(local_file(broker)) else []
    elif SIGNED_ID.match(rid) and published(broker):
        origin = Origin(broker)
        lines = origin.rows(origin.fetch()).splitlines()
    else:
        return None
    return next((parse(line) for line in lines if line.startswith(f'{{"id": "{rid}", ')), None)


def status_line(broker):
    """What guard status says of the receipts: the ref's head, or that this session's are local and unsigned."""
    if not published(broker):
        return "receipts: local, unsigned (l ids, never published)"
    head = Origin(broker).fetch()
    return f"receipts: guard/receipts at {head[:12]}, signed by the broker" if head else "receipts: none published yet"


def handle(request, broker):
    """The records socket's receipt verb. {verb: receipt, action: show, id}: the row, then where it lives."""
    action, rid = request.get("action", "show"), request.get("id")
    if action != "show":
        raise Refused(f"receipt offers show, not {action!r}; the broker alone adds receipts")
    if not isinstance(rid, str):
        raise Refused("receipt show takes an id")
    row = find(broker, rid)
    if row is None:
        raise Refused(f"no receipt {rid}")
    if LOCAL_ID.match(rid):
        where = f"{local_file(broker)}, local and unsigned; F04 refuses it"
    else:
        head = broker.mirror.git("rev-parse", REF).stdout.strip()
        where = f"on guard/receipts at {head[:12]}; git show origin/guard/receipts:{FILE}"
    return {"rc": 0, "out": row.line() + where + "\n"}
