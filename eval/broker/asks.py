"""guard ask: a question for the human that carries a conservative default and a deadline (owner, addendum A11).

    guard ask "<question>" --default <the safe option> --deadline 5m|30m|2h
    guard ask --status <id>

The ask queues a needs-you approve item titled with the question and returns at once. The answer is the item's note
when a person closes it (broker.py records done <state_dir> <id> --note <answer>; dismiss means no). If nobody has
answered when the deadline passes, the default is taken, and the record says it was taken unattended. Asking the same
question again, or --status, prints where it stands. The question and the default are text a person reads and nothing
parses; the deadline parses, so it is one of DEADLINES (decision A10).

records/asks.jsonl holds the record, one event per row:

    asked     id question default deadline due      the agent asked; due is the epoch second of the deadline
    answered  id answer                             a person (or the scripted approver) closed the item first
    default   id default unattended=true            the deadline passed with the item still open
    told      id                                    the agent has seen the default line

The first outcome of an ask is final: a late answer to a defaulted ask changes nothing here."""
import json
import os
import shlex
import time
from typing import NamedTuple, Optional

DEADLINES = {"5m": 300, "30m": 1800, "2h": 7200}
CODES = {"question": "H4R-A01", "default": "H4R-A02", "deadline": "H4R-A03", "status": "H4R-A04"}


class Refusal(Exception):
    """A refusal the agent sees as it is: the code and the reason, then the exact next command."""

    def __init__(self, code, reason, next_command):
        super().__init__(f"{CODES[code]} guard ask: refused: {reason}\n{next_command}\n")


class Ask(NamedTuple):
    id: str
    question: str
    default: str
    deadline: str
    due: float
    outcome: Optional[str] = None
    answer: str = ""
    told: bool = False


def fold(rows):
    """The asks, by id, from the event rows."""
    asks = {}
    for r in rows:
        a = asks.get(r["id"])
        if r["event"] == "asked" and a is None:
            asks[r["id"]] = Ask(r["id"], r["question"], r["default"], r["deadline"], r["due"])
        elif a and a.outcome is None and r["event"] in ("answered", "default"):
            asks[r["id"]] = a._replace(outcome=r["event"], answer=r.get("answer", a.default))
        elif a and r["event"] == "told":
            asks[r["id"]] = a._replace(told=True)
    return asks


def settle(asks, items, now):
    """The outcome rows due now: an answer for each pending ask whose item a person closed, else the default for each
    pending ask past its deadline."""
    state = {it.id: it for it in items}
    rows = []
    for a in asks.values():
        if a.outcome:
            continue
        it = state.get(a.id)
        if it and it.state in ("done", "dismissed"):
            answer = (it.note or "yes") if it.state == "done" else "no" + (f": {it.note}" if it.note else "")
            rows.append({"event": "answered", "id": a.id, "answer": answer})
        elif now >= a.due:
            rows.append({"event": "default", "id": a.id, "default": a.default, "answer": a.default, "unattended": True})
    return rows


def clock(ts):
    return time.strftime("%H:%M UTC", time.gmtime(ts))


def line(a, now):
    """The one line the agent sees about an ask."""
    if a.outcome == "answered":
        return f"ask {a.id} answered by the human: {a.answer}. Act on it."
    if a.outcome == "default":
        return (f"ask {a.id}: nobody answered by {clock(a.due)}, so the default was taken unattended: {a.default}. "
                "Proceed with it.")
    left = max(1, round((a.due - now) / 60))
    return (f"ask {a.id} waits for the human, {left} min left; then the default: {a.default}. Do other work meanwhile, "
            f"or wait; check with: guard ask --status {a.id}")


def checked(question, default, deadline):
    """The ask's three values, or the Refusal naming the first one missing or not offered."""
    q = question.strip() if isinstance(question, str) else ""
    d = default.strip() if isinstance(default, str) else ""
    t = deadline.strip() if isinstance(deadline, str) else ""
    fix = shlex.join(["guard", "ask", q or "YOUR QUESTION", "--default", d or "THE SAFE OPTION",
                      "--deadline", t if t in DEADLINES else nearest(t)])
    if not q:
        raise Refusal("question", "say the question", fix)
    if not d:
        raise Refusal("default", "name the default, the safe option taken if nobody answers by the deadline", fix)
    if t not in DEADLINES:
        raise Refusal("deadline", f"--deadline takes {', '.join(DEADLINES)}, not {t or 'nothing'}", fix)
    return q, d, t


def nearest(text):
    """The offered deadline closest to what the agent wrote, read as minutes or hours; the shortest otherwise."""
    try:
        seconds = float(text[:-1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[text[-1]]
    except (ValueError, KeyError, IndexError):
        return next(iter(DEADLINES))
    return min(DEADLINES, key=lambda k: abs(DEADLINES[k] - seconds))


class Store:
    """records/asks.jsonl, appended to under the broker's lock."""

    def __init__(self, records_dir):
        self.path = os.path.join(records_dir, "asks.jsonl")

    def rows(self):
        if not os.path.exists(self.path):
            return []
        with open(self.path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def asks(self):
        return fold(self.rows())

    def write(self, rows, now):
        if rows:
            with open(self.path, "a") as f:
                for r in rows:
                    f.write(json.dumps({"ts": now, **r}) + "\n")
