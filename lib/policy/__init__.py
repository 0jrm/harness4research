"""The policy pipeline's shapes (design-v8 section 3), pure: nothing here reads a file or opens a socket.

    invocation.parse(request, script, session, ts) -> Invocation, SbatchSpec
    backend(limits, view)                          -> "slurm" | "host"         (decide.py, U2)
    cost.cost(spec, limits, backend)               -> Cost
    decide(inv, spec, cost, limits, view)          -> Decision                 (decide.py, U2)

Field order is the serialized order: dataclasses.asdict() of any shape is one JSON object."""
from dataclasses import dataclass, field
from typing import Optional

BACKENDS = ("slurm", "host")


@dataclass(frozen=True)
class Request:
    """What the agent typed, launcher stripped; nothing else crosses the socket."""
    verb: str
    run_dir: str
    why: str
    cause: Optional[str] = None
    options: tuple = ()
    script: str = ""
    args: tuple = ()
    cwd: str = ""


@dataclass(frozen=True)
class Invocation:
    """The broker's view of a Request."""
    run_id: str
    why: str
    cause: Optional[str]
    options: tuple
    script: str
    script_sha256: str
    args: tuple
    cwd: str
    session: str
    ts: float


@dataclass(frozen=True)
class SbatchSpec:
    """argv over #SBATCH lines; the allowlist of the v7 broker's FIELDS. array keeps its raw index list."""
    time_min: int
    nodes: int = 1
    tasks: Optional[int] = None
    cpus_per_task: Optional[int] = None
    mem_gb: Optional[int] = None
    gpus: int = 0
    array: Optional[str] = None
    array_n: int = 1
    partition: Optional[str] = None
    dependency: Optional[str] = None
    output: Optional[str] = None


@dataclass(frozen=True)
class Limits:
    """guard/budget.card on the broker's mirror of main, never the checkout."""
    account: str
    start_date: str
    stop_date: str
    cores_per_node: int
    max_walltime_minutes: int
    max_nodes_per_job: int
    max_concurrent_jobs: int
    max_core_hours: int
    partitions: tuple = ()
    extra_sbatch: str = ""
    verification_reserve_core_hours: int = 0
    default_run_core_hours: int = 0
    default_run_gpu_hours: float = 0
    max_gpu_hours: float = 0
    compute: tuple = ()
    holdout_max_submissions: int = 3
    ask_deadline: str = "30m"
    approval: str = "auto"
    launch_hosts: tuple = ()
    host_max_walltime_minutes: int = 720
    host_max_mem_gb: float = 64
    host_min_available_gb: float = 32
    host_stop_grace_seconds: int = 60
    host_state_dir: str = "~/.local/state/guard/launches"


@dataclass(frozen=True)
class Cost:
    backend: str
    minutes: int
    nodes: int
    cores: int
    gpus: int
    tasks: Optional[int]
    core_hours: float
    gpu_hours: float


@dataclass(frozen=True)
class JobRow:
    """The job log's row: today's ledger.jsonl row plus backend, why, cost and the invocation key R11 compares."""
    seq: int
    job_id: Optional[str]
    run_id: str
    backend: str
    state: str                     # intent | submitted | failed | lost
    submitted_ts: float
    why: str
    cost: Optional[Cost]
    comment: str
    script_sha256: str
    options: tuple = ()


@dataclass(frozen=True)
class HostView:
    name: str
    in_launch_hosts: bool
    available_gb: float
    gpus_free: tuple = ()
    bwrap: bool = False
    live_launches: tuple = ()


@dataclass(frozen=True)
class LedgerView:
    """Everything decide() needs, gathered by the broker (sacct, squeue, the mirror, host.py)."""
    spent_core_hours: float
    queued_core_hours: float
    spent_gpu_hours: float
    live_jobs: tuple = ()          # JobRow
    run_jobs: dict = field(default_factory=dict)   # run_id -> (JobRow, ...)
    last_failed_job: Optional[JobRow] = None
    changed_paths_vs_main: tuple = ()
    script_exists: bool = True
    run_dir_in_project: bool = True
    open_asks: tuple = ()          # AskRecord rows (U4) as dicts
    host: Optional[HostView] = None


@dataclass(frozen=True)
class Decision:
    verdict: str                   # run | queue | refuse
    backend: str
    code: Optional[str] = None
    reason: Optional[str] = None
    next: Optional[str] = None
    job_id: Optional[str] = None
    ask_id: Optional[str] = None
