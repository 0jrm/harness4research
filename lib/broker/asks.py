"""guard ask: a question for the human with a default and a deadline (owner, addendum A11), and the broker's own
asks, the ones with an effect (design-v8 sections 3 and 6).

    {"verb": "ask", "action": "add", "question": Q, "default": D, "deadline": "5m|30m|2h", "cwd": C}
    {"verb": "ask", "action": "show", "id": ID, "cwd": C}

The agent's ask is a needs-you item titled with the question, in the broker's own queue (records/needs-you.tsv in its
state, which the agent's sandbox cannot see), and a row of records/asks.jsonl. A person closes the item outside the
sandbox (guard needs-you done a3 [--note ANSWER], or dismiss for no). If nobody has when the deadline passes, the
default is the answer, and the record says it was taken unattended. The question and the default are text a person
reads; nothing parses them (A10). The deadline is one of DEADLINES.

An ask with an effect is made by the broker only, through create_effect(), with the default no and a deadline from the
card. The wire verb carries no effect field, so the agent cannot make one, set its default or answer it. When a person
answers it yes, settle() calls redecide(broker, effect) of the module EFFECT_MODULE names, which decides again at that
moment against the pinned script_sha256 and spec and acts on a run decision; a refusal then becomes the ask's answer.
There is one open effect ask per run id.

asks.jsonl holds one event per row; fold() folds them into one AskRecord dict per ask (design-v8 section 3):

    asked     id question default deadline due_ts asked_ts session [effect]
    answered  id answer by(human|unattended)
    told      id                       the agent has seen the outcome in a report()

The first outcome of an ask is final. Every function here that reads or writes the store expects broker.lock held by
the caller; handle() and the attend thread take it, and redecide() is called with it held, so it must not take it
again. broker.clock (default time.time) is the clock, so a test moves time."""
import importlib
import json
import os
import re
import shlex
import threading
import time
import traceback

import needs_you
import refusals
from broker.records import Refused

DEADLINES = {"5m": 300, "30m": 1800, "2h": 7200}
EFFECT_MODULE = {"submit": "run", "holdout_more": "holdout"}
ATTEND_SECONDS = 5
OFFER = re.compile(r"\[([^\[\]|\s]+(?:\|[^\[\]|\s]+)+)\]")
ADD_KEYS = {"verb", "action", "question", "default", "deadline", "cwd"}
SHOW_KEYS = {"verb", "action", "id", "cwd"}
ASKED = ("id", "question", "default", "deadline", "due_ts", "asked_ts", "session", "effect")


def now(broker):
    return getattr(broker, "clock", time.time)()


def clock(ts):
    return time.strftime("%H:%M UTC", time.gmtime(ts))


# the record ---------------------------------------------------------------------------------------------------------
def path(broker):
    return os.path.join(broker.records.dir, "asks.jsonl")


def rows(broker):
    if not os.path.exists(path(broker)):
        return []
    with open(path(broker)) as f:
        return [json.loads(line) for line in f if line.strip()]


def write(broker, new):
    ts = now(broker)
    with open(path(broker), "a") as f:
        for r in new:
            f.write(json.dumps({"ts": ts, **r}) + "\n")


def fold(events):
    """The asks, by id, as AskRecord dicts, and the ids the agent has been told the outcome of."""
    asks, told = {}, set()
    for r in events:
        a = asks.get(r["id"])
        if r["event"] == "asked" and a is None:
            asks[r["id"]] = {k: r[k] for k in ASKED if k in r}
        elif a is not None and r["event"] == "answered" and "answer" not in a:
            a.update(answer=r["answer"], answered_by=r["by"], answered_ts=r["ts"])
        elif a is not None and r["event"] == "told":
            told.add(r["id"])
    return asks, told


def pending(a):
    return "answer" not in a


def open_asks(broker, run_id=None):
    """The asks nobody has answered, oldest first; with run_id, only the effect asks of that run."""
    return [a for a in fold(rows(broker))[0].values() if pending(a)
            and (run_id is None or (a.get("effect") or {}).get("run_id") == run_id)]


def effect_asks(broker, run_id):
    """The open asks with an effect on run_id, which may be None; an agent's ask has no effect and is never one."""
    return [a for a in open_asks(broker) if a.get("effect") and a["effect"].get("run_id") == run_id]


def open_effect(broker, run_id):
    return next(iter(effect_asks(broker, run_id)), None)


# the queue ----------------------------------------------------------------------------------------------------------
def queue_item(broker, question, why, source, commands_for):
    """The id of a new needs-you item titled question, in the broker's queue; its id is a<n>, so that guard needs-you
    can show and close the broker's asks beside the project's own n<n> items. commands_for(id) is its command lines."""
    made = {}

    def new(items):
        n = max((int(it.id[1:]) for it in items if it.id[0] == "a" and it.id[1:].isdigit()), default=0) + 1
        made["id"] = f"a{n}"
        return needs_you.Item(id=made["id"], ts=needs_you.now(), state="open", kind="approve",
                              title=needs_you.cell("title", question), why=needs_you.cell("why", why, part=True),
                              expect="", worry="", undo="", note="", source=needs_you.cell("source", source),
                              paths=[], commands=commands_for(made["id"]))

    needs_you.transact(broker.records.queue, new)
    return made["id"]


def answer_commands(ident):
    return [f"# answer: guard needs-you done {ident} --note ANSWER   (no note means yes)",
            f"# or no: guard needs-you dismiss {ident}"]


def create_effect(broker, kind, run_id, question, script_sha256=None, spec=None, deadline=None):
    """The broker's ask for an effect, default no; the open one when the run already has one. The caller holds
    broker.lock. deadline is a key of DEADLINES, the card's ask_deadline."""
    if kind not in EFFECT_MODULE:
        raise ValueError(f"effect kind {kind!r} is not one of {tuple(EFFECT_MODULE)}")
    deadline = deadline if deadline in DEADLINES else "30m"
    found = next((a for a in effect_asks(broker, run_id) if a["effect"]["kind"] == kind), None)
    if found:
        return found
    due = now(broker) + DEADLINES[deadline]
    ident = queue_item(broker, question, f"the broker queued this; nothing happens unless you answer yes by "
                                         f"{clock(due)}, and the default is no", f"broker: {kind}", answer_commands)
    effect = {"kind": kind, "run_id": run_id, "script_sha256": script_sha256, "spec": spec}
    write(broker, [{"event": "asked", "id": ident, "question": question, "default": "no", "deadline": deadline,
                    "due_ts": due, "asked_ts": now(broker), "session": broker.cfg["session"], "effect": effect}])
    return fold(rows(broker))[0][ident]


# the answer ---------------------------------------------------------------------------------------------------------
def redecide(broker, effect):
    """The reply of the effect's module deciding again, or X00 when this harness has none."""
    name = EFFECT_MODULE[effect["kind"]]
    try:
        module = importlib.import_module(f"broker.{name}")
    except ModuleNotFoundError as e:
        if e.name != f"broker.{name}":
            raise
        module = None
    if not hasattr(module, "redecide"):
        return refusals.reply(refusals.refuse("X00", verb=f"an answer of yes to a {effect['kind']} ask"))
    try:
        return module.redecide(broker, effect)
    except Refused as e:
        return {"rc": 1, "err": f"guard broker: refused: {e}\n"}


def human_answer(a, it):
    """The answer text and, for an effect ask, whether it is a yes: done is yes unless its note starts with no."""
    note = (it.note or "").strip()
    yes = it.state == "done" and not note.lower().startswith("no")
    if a.get("effect"):
        return "yes" if yes else "no" + (f": {note}" if note else ""), yes
    return (note or "yes") if it.state == "done" else "no" + (f": {note}" if note else ""), yes


def settle(broker):
    """Records the answers and unattended defaults now due, and returns the asks by id."""
    asks, _ = fold(rows(broker))
    items = {it.id: it for it in needs_you.read(broker.records.queue)}
    due = []
    for a in asks.values():
        if not pending(a):
            continue
        it = items.get(a["id"])
        if it and it.state in ("done", "dismissed"):
            said, yes = human_answer(a, it)
            if a.get("effect") and yes:
                reply = redecide(broker, a["effect"])
                text = ((reply.get("out") or "").strip().splitlines() or ["done"])[0] if reply.get("rc") == 0 \
                    else (reply.get("err") or reply.get("out") or "refused").strip()
                said = f"yes: {text}" if reply.get("rc") == 0 else text
            due.append({"event": "answered", "id": a["id"], "answer": said, "by": "human"})
        elif now(broker) >= a["due_ts"]:
            due.append({"event": "answered", "id": a["id"], "answer": a["default"], "by": "unattended"})
    write(broker, due)
    return fold(rows(broker))[0]


def line(a, at):
    """The one line the agent sees about an ask."""
    if pending(a):
        left = max(1, round((a["due_ts"] - at) / 60))
        return (f"ask {a['id']} waits for the human, {left} min left; then the default: {a['default']}. "
                "Do other work; guard status shows the answer")
    if a["answered_by"] == "human":
        return f"ask {a['id']} answered by the human: {a['answer'].splitlines()[0]}. Act on it."
    return (f"ask {a['id']}: nobody answered by {clock(a['due_ts'])}, so the default was taken unattended: "
            f"{a['default']}. Proceed with it.")


def short(a, at):
    """line() for guard status: one line of at most 190 characters, the question trimmed."""
    if pending(a):
        left = max(1, round((a["due_ts"] - at) / 60))
        return f"ask {a['id']} waits for a person, {left} min left, then {a['default']}: {a['question']}"[:190]
    if a["answered_by"] == "human":
        return f"ask {a['id']} answered by a person: {a['answer'].splitlines()[0]}"[:190]
    return f"ask {a['id']}: nobody answered, the default was taken unattended: {a['default']}"[:190]


def report(broker, render=line):
    """The lines guard status shows: every open ask, and every outcome the agent has not seen, which this marks seen.
    The caller holds broker.lock; render is line or short."""
    asks = settle(broker)
    told = fold(rows(broker))[1]
    fresh = [a["id"] for a in asks.values() if not pending(a) and a["id"] not in told]
    write(broker, [{"event": "told", "id": ident} for ident in fresh])
    return [render(a, now(broker)) for a in asks.values() if pending(a) or a["id"] in fresh]


# the verb -----------------------------------------------------------------------------------------------------------
class Refusal(Exception):
    """A refusal to print as it is; handle() turns it into the reply."""

    def __init__(self, refusal):
        super().__init__(refusal.reason)
        self.refusal = refusal


def refused(code, **fmt):
    return Refusal(refusals.refuse(code, **fmt))


def offered(question):
    return OFFER.findall(question)[0].split("|") if OFFER.search(question) else []


def plain(text):
    """text with what line 2 of a refusal cannot hold, a bracket, an angle bracket or an ellipsis, made plain."""
    return re.sub(r"\.{3,}", ".", text.translate(str.maketrans("[]<>", "()()")))


def nearest(text):
    """The deadline of DEADLINES closest to what the agent wrote, read as minutes or hours; the shortest otherwise."""
    try:
        seconds = float(text[:-1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[text[-1]]
    except (ValueError, KeyError, IndexError):
        return next(iter(DEADLINES))
    return min(DEADLINES, key=lambda k: abs(DEADLINES[k] - seconds))


def retyped(question, default, deadline):
    """guard ask with the question made plain; a default that is not yes or no becomes no, since plain() drops the
    brackets that offered it."""
    q = plain(question)
    return shlex.join(["guard", "ask", q, "--default", default if default in ("yes", "no") else "no",
                       "--deadline", deadline if deadline in DEADLINES else nearest(deadline)])


def checked(req):
    """The ask's question, default and deadline, or the refusal naming the first that is missing or not offered."""
    text = {k: (req.get(k).strip() if isinstance(req.get(k), str) else "") for k in ("question", "default", "deadline")}
    q, d, t = text["question"], text["default"], text["deadline"]
    if not q or set(req) - ADD_KEYS:
        raise refused("A01")
    words = offered(q)
    if d not in ("yes", "no", *words):
        raise refused("A02", words="|".join(words) or "yes|no", next=retyped(q, "no", t))
    if t not in DEADLINES:
        raise refused("A03", next=retyped(q, d, t))
    return q, d, t


def add(broker, req):
    q, d, t = checked(req)
    for a in open_asks(broker):
        if a["question"] == q and not a.get("effect"):
            return line(a, now(broker)) + "\n"
    due = now(broker) + DEADLINES[t]
    try:
        ident = queue_item(broker, q, f"the agent asked, and takes this default if nobody answers by {clock(due)}: {d}",
                           f"sandbox {broker.cfg['session']}: guard ask", answer_commands)
    except needs_you.Refused:
        raise refused("A01")
    write(broker, [{"event": "asked", "id": ident, "question": q, "default": d, "deadline": t, "due_ts": due,
                    "asked_ts": now(broker), "session": broker.cfg["session"]}])
    return line(settle(broker)[ident], now(broker)) + "\n"


def show(broker, req):
    if set(req) - SHOW_KEYS or not isinstance(req.get("id"), str):
        raise refused("A01")
    asks = settle(broker)
    if req["id"] not in asks:
        raise refused("A04", id=req["id"], open=" ".join(a["id"] for a in asks.values() if pending(a)) or "none")
    write(broker, [{"event": "told", "id": req["id"]}] if not pending(asks[req["id"]]) else [])
    return line(asks[req["id"]], now(broker)) + "\n"


def handle(request, broker):
    """The reply to one ask request. The scheduler's store is not touched; the attend thread starts with the first ask."""
    start(broker)
    with broker.lock:
        try:
            action = request.get("action")
            if action not in ("add", "show"):
                raise refused("A01")
            return {"rc": 0, "out": (add if action == "add" else show)(broker, request)}
        except Refusal as e:
            return refusals.reply(e.refusal)


# the loop -----------------------------------------------------------------------------------------------------------
def load_approver(mode):
    """The scripted approver (eval/broker/approver.py, on sys.path where the evaluation's broker runs) for the card's
    or config's approver, or None for never."""
    if mode in (None, "never"):
        return None
    return importlib.import_module("approver").make(mode)


def attend(broker):
    """Every few seconds: the scripted approver, if the config names one, then the answers and unattended defaults."""
    approver = load_approver(broker.cfg.get("approver"))
    while True:
        time.sleep(ATTEND_SECONDS)
        with broker.lock:
            try:
                if approver:
                    approver(broker, now(broker))
                settle(broker)
            except Exception:  # the next round tries again; daemon.log keeps the trace
                traceback.print_exc()


def start(broker):
    """One attend thread per serving broker. Local mode answers one command and exits, so it settles on each call."""
    if broker.cfg.get("session") == "local" or getattr(broker, "attending", None):
        return
    broker.attending = threading.Thread(target=attend, args=(broker,), daemon=True)
    broker.attending.start()
