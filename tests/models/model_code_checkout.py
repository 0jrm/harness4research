"""`guard/run code` from concurrent jobs: every caller gets the checkout, and a crashed caller blocks nobody.

Each caller takes the lock, then looks at the path: ready means print it, absent means `git worktree add`, which
writes a partial checkout under git's own repo lock and then completes it; a partial checkout it did not make is
refused, never reset. Any caller may crash at any step. Exiting, or crashing, releases a flock; a mkdir lock stays.

Incident p2-l1b-fair-obs-0402c/1 (jobs 13239051/52) is the run without a lock: two adds collided on git's lock
and both jobs failed. A mkdir lock fixes that and hangs every later caller once a holder dies, which the gom-da
job scripts' stale-lock timeouts work around. The checker must find both failures; flock must hold.
"""

import sys
from dataclasses import dataclass, replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mc import find_violation  # noqa: E402

CALLERS = 3
DONE = ("printed", "refused", "crashed")


@dataclass(frozen=True)
class World:
    callers: tuple[str, ...]
    checkout: str = "absent"
    git_lock: bool = False
    lock_holder: int | None = None
    lock_kind: str = "flock"


def model(lock_kind: str):
    def set_caller(w: World, i: int, pc: str, **kw) -> World:
        return replace(w, callers=w.callers[:i] + (pc,) + w.callers[i + 1 :], **kw)

    def exit_(w: World, i: int, pc: str, **kw) -> World:
        releases = w.lock_holder == i and (lock_kind == "flock" or pc != "crashed")
        return set_caller(w, i, pc, lock_holder=None if releases else w.lock_holder, **kw)

    def steps(w: World):
        for i, pc in enumerate(w.callers):
            if pc in DONE:
                continue
            yield f"caller {i} crashes at {pc}", exit_(w, i, "crashed", git_lock=w.git_lock and pc != "adding")
            if pc == "start":
                if lock_kind == "none":
                    yield f"caller {i} starts", set_caller(w, i, "locked")
                elif w.lock_holder is None:
                    yield f"caller {i} takes the lock", set_caller(w, i, "locked", lock_holder=i)
            elif pc == "locked":
                if w.checkout == "ready":
                    yield f"caller {i} finds the checkout", exit_(w, i, "printed")
                elif w.checkout == "partial":
                    yield f"caller {i} refuses a partial checkout", exit_(w, i, "refused")
                else:
                    yield f"caller {i} finds no checkout", set_caller(w, i, "absent")
            elif pc == "absent":
                if w.git_lock:
                    yield f"caller {i} collides on git's repo lock", exit_(w, i, "refused")
                else:
                    yield f"caller {i} starts git worktree add", set_caller(w, i, "adding", git_lock=True, checkout="partial")
            elif pc == "adding":
                yield f"caller {i} completes the add", exit_(w, i, "printed", git_lock=False, checkout="ready")

    return World(callers=("start",) * CALLERS, lock_kind=lock_kind), steps


def failure(lock_kind: str):
    init, steps = model(lock_kind)

    def bad(w: World) -> str | None:
        if "crashed" not in w.callers and "refused" in w.callers:
            return "a caller failed although no caller crashed"
        live = any(pc not in DONE for pc in w.callers)
        if live and all(" crashes at " in label for label, _ in steps(w)):
            return "callers wait forever on a lock a crashed caller still holds"
        return None

    return find_violation(init, steps, bad)


def main() -> int:
    current = failure("flock")
    if current:
        trace, why = current
        print("code checkout: lib/guard/code.sh's flock breaks:", why, *trace, sep="\n  ")
        return 1
    for kind, past in {"none": "incident 0402c/1", "mkdir": "the stale mkdir lock"}.items():
        if not failure(kind):
            print(f"code checkout: the model finds no failure without flock ({kind}), so it no longer replays {past}")
            return 1
    print("code checkout: flock holds; no lock and a mkdir lock both fail")
    return 0


if __name__ == "__main__":
    sys.exit(main())
