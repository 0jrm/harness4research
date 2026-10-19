"""cost(): what a job costs on each backend, and limits(): guard/budget.card's text as Limits.

slurm prices whole nodes (E6b; owner, question 2): core_hours = minutes x array_n / 60 x nodes x cores_per_node.
host prices the cores asked for (owner, question 15): core_hours = minutes / 60 x (cpus_per_task or 1), and
gpu_hours = minutes / 60 x gpus on both."""
import dataclasses

from policy import BACKENDS, Cost, Limits

REQUIRED = ("account", "start_date", "stop_date", "cores_per_node", "max_walltime_minutes", "max_nodes_per_job",
            "max_concurrent_jobs", "max_core_hours")
LISTS = ("partitions", "compute", "launch_hosts")


class CardError(Exception):
    """A key decide() needs is unset or malformed on main; a person fixes the card."""


def cost(spec, limits, backend):
    if backend not in BACKENDS:
        raise ValueError(f"backend {backend!r} is not one of {BACKENDS}")
    if backend == "slurm":
        hours = spec.time_min * spec.array_n / 60
        nodes, cores = spec.nodes, spec.nodes * limits.cores_per_node
    else:
        hours = spec.time_min / 60
        nodes, cores = 1, spec.cpus_per_task or 1
    return Cost(backend=backend, minutes=spec.time_min, nodes=nodes, cores=cores, gpus=spec.gpus, tasks=spec.tasks,
                core_hours=hours * cores, gpu_hours=hours * spec.gpus)


def card_values(text):
    """key: value lines, the first of each key winning, as the v7 broker reads them."""
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition(":")
        if sep and key not in values:
            values[key] = value.strip()
    return values


def limits(text):
    """Limits from the card's text. A value holding < is the template's placeholder, so unset."""
    card = {k: v for k, v in card_values(text).items() if v and "<" not in v}
    missing = [k for k in REQUIRED if k not in card]
    if missing:
        raise CardError(f"guard/budget.card on main has no {', '.join(missing)}; a person sets it")
    out = {}
    for f in dataclasses.fields(Limits):
        if f.name not in card:
            continue
        value = card[f.name]
        if f.name in LISTS:
            words = tuple(value.replace(",", " ").split())
            out[f.name] = () if words == ("none",) else words
        elif f.type in (int, "int"):
            if not value.isdigit():
                raise CardError(f"guard/budget.card {f.name} must be a whole number on main: {value}")
            out[f.name] = int(value)
        elif f.type in (float, "float"):
            try:
                out[f.name] = float(value)
            except ValueError:
                raise CardError(f"guard/budget.card {f.name} must be a number on main: {value}") from None
        else:
            out[f.name] = value
    return Limits(**out)
