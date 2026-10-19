"""The evaluation's scripted approver: the person that answers a needs-you item after a fixed delay (owner, A4).

    never            nobody answers; only the deadlines of guard ask move an ask (E11)
    after:<seconds>  every open item of the broker's queue is closed done once that long has passed since it was
                     queued, with the note "approved (scripted approver, after <seconds> s)"; the third arm's after:300

The broker's config says which (config.json's approver, which eval/env/up.sh takes from H4R_APPROVER, which eval/run.py
sets from its config). lib/broker/asks.py's attend thread imports this module by name and calls the hook make() returns
every few seconds; the evaluation's broker has eval/broker/ on sys.path. A done item answers an ask with its note, and
an effect ask with yes, which re-runs the broker's decision (asks.py). Nothing here runs outside an episode."""
import calendar
import contextlib
import io
import re
import time

import needs_you
from broker.records import Refused


def delay(mode):
    """The delay in seconds the config's approver names, or None for never."""
    if mode in (None, "never"):
        return None
    if isinstance(mode, str) and re.fullmatch(r"after:[0-9]+", mode):
        return int(mode[6:])
    raise SystemExit(f"approver {mode!r} is never or after:<seconds>")


def queued_at(item):
    return calendar.timegm(time.strptime(item.ts, "%Y-%m-%dT%H:%M:%SZ"))


def approve_due(broker, seconds, at):
    """Closes every open item queued at least seconds ago, as a person would."""
    note = f"approved (scripted approver, after {seconds} s)"
    for it in needs_you.read(broker.records.queue):
        if it.state != "open" or at - queued_at(it) < seconds:
            continue
        try:
            with contextlib.redirect_stdout(io.StringIO()):  # needs_you.move prints "<id> done"
                needs_you.move(broker.records.queue, "done", it.id, note)
            broker.records.log({"approver": it.id, "after": seconds})
        except (Refused, needs_you.Refused) as e:
            broker.records.log({"approver": it.id, "after": seconds, "failed": str(e)})


def make(mode):
    """The hook attend() calls as hook(broker, now), or None for never."""
    seconds = delay(mode)
    return None if seconds is None else lambda broker, at: approve_due(broker, seconds, at)
