"""The host-memory election of lib/guard/launch.sh: under lasting pressure, exactly one launch stops per cause.

Two supervisors share a host. Each running supervisor polls once per tick and, under pressure, writes its beat.
After two low polls it runs elected(): it ignores beats older than FRESH ticks and launches that wrote `end`,
yields to any fresh beat that says `stopping`, and otherwise elects the largest charge. The elected one runs the
ladder for LADDER ticks while its processes exit and its charge falls, then writes `end`, which ends the pressure.

a17da7e added both halves of today's design. Before it the ladder wrote no beat, so a ladder longer than FRESH
ticks went stale and the next supervisor elected itself. Beats alone are not enough either: the stopping launch's
falling charge would hand the election to the next one. The checker must find a double stop without either half.
"""

import sys
from dataclasses import dataclass, replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from mc import find_violation  # noqa: E402

FRESH = 3
LADDER = 5
HORIZON = 12
CHARGE = (400, 200)


@dataclass(frozen=True)
class Launch:
    phase: str = "running"
    charge: int = 0
    low: int = 0
    beat: int = 0
    stopping: bool = False
    ladder_left: int = 0
    acted: bool = False


@dataclass(frozen=True)
class Host:
    now: int
    pressure: bool
    launches: tuple[Launch, ...]
    stops: int
    yield_to_stopping: bool


def elected(host: Host, me: int) -> bool:
    live = [
        (i, l)
        for i, l in enumerate(host.launches)
        if l.phase != "ended" and host.now - l.beat <= FRESH
    ]
    if host.yield_to_stopping and any(l.stopping for _, l in live):
        return False
    return max(live, key=lambda il: (il[1].charge, -il[0]))[0] == me


def model(beats_while_stopping: bool, yield_to_stopping: bool):
    def with_launch(host: Host, i: int, launch: Launch, **kw) -> Host:
        launches = host.launches[:i] + (launch,) + host.launches[i + 1 :]
        return replace(host, launches=launches, **kw)

    def steps(host: Host):
        for i, l in enumerate(host.launches):
            if l.acted or l.phase == "ended":
                continue
            if l.phase == "running":
                low = l.low + 1 if host.pressure else 0
                polled = replace(l, low=low, beat=host.now if host.pressure else l.beat, acted=True)
                after = with_launch(host, i, polled)
                if low >= 2 and elected(after, i):
                    stop = replace(polled, phase="stopping", ladder_left=LADDER, stopping=beats_while_stopping)
                    yield f"t={host.now} launch {i} poll, elected, starts the ladder", with_launch(
                        host, i, stop, stops=host.stops + 1
                    )
                else:
                    yield f"t={host.now} launch {i} poll (low={low})", after
            elif l.ladder_left > 0:
                beat = host.now if beats_while_stopping else l.beat
                yield f"t={host.now} launch {i} ladder wait", with_launch(
                    host, i, replace(l, ladder_left=l.ladder_left - 1, beat=beat, charge=0, acted=True)
                )
            else:
                yield f"t={host.now} launch {i} writes end", with_launch(
                    host, i, replace(l, phase="ended", acted=True), pressure=False
                )
        if host.now < HORIZON and all(l.acted or l.phase == "ended" for l in host.launches):
            yield "tick", replace(
                host, now=host.now + 1, launches=tuple(replace(l, acted=False) for l in host.launches)
            )

    launches = tuple(Launch(charge=c) for c in CHARGE)
    init = Host(now=0, pressure=True, launches=launches, stops=0, yield_to_stopping=yield_to_stopping)
    return init, steps


def two_stops_for_one_cause(host: Host) -> str | None:
    return f"{host.stops} launches stopped for one host-memory cause" if host.stops > 1 else None


def check(beats_while_stopping: bool, yield_to_stopping: bool):
    init, steps = model(beats_while_stopping, yield_to_stopping)
    return find_violation(init, steps, two_stops_for_one_cause)


def main() -> int:
    current = check(beats_while_stopping=True, yield_to_stopping=True)
    if current:
        trace, why = current
        print("election: launch.sh as it is now violates one-stop-per-cause:", why, *trace, sep="\n  ")
        return 1
    for name, flags in {"before a17da7e": (False, False), "beats without the stopping yield": (True, False)}.items():
        if not check(*flags):
            print(f"election: the model finds no double stop {name}, so it cannot be trusted to guard a17da7e")
            return 1
    print("election: one stop per cause holds; it fails before a17da7e and with beats but no stopping yield")
    return 0


if __name__ == "__main__":
    sys.exit(main())
