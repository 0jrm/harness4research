"""Breadth-first explicit-state model checking: every reachable state, the shortest trace to the first bad one."""

from collections import deque
from typing import Callable, Hashable, Iterable

State = Hashable
Step = tuple[str, State]


def find_violation(
    init: State, steps: Callable[[State], Iterable[Step]], bad: Callable[[State], str | None]
) -> tuple[list[str], str] | None:
    parent: dict[State, tuple[State, str] | None] = {init: None}
    queue = deque([init])
    while queue:
        state = queue.popleft()
        why = bad(state)
        if why:
            trace = []
            while parent[state]:
                state, label = parent[state]
                trace.append(label)
            return trace[::-1], why
        for label, nxt in steps(state):
            if nxt not in parent:
                parent[nxt] = (state, label)
                queue.append(nxt)
    return None
