# The envelope: guards, preflight, launch, and the execution ledger

Read this before you write a job script, submit, launch, or write an `execution.tsv` row. It is the full text behind the core's guard and lifecycle rules.

## Guards are structure, not prose

- `guard/budget.card` and every path in `guard/watch.list` live on the protected branch, and the human changes them. `guard/run <command>` runs the protected branch's copy of each script, so an edit on your branch has no effect and trips a ripple. The `guard-fence` check blocks the merge of any change to `guard/`, `.github/workflows/`, the top-level `AGENTS.md` and `CLAUDE.md`, watched paths, or an existing question card, and of any report evidence row whose backticked artifact path is not committed on the branch. For output too large to commit, cite the committed manifest that hashes it.
- Submit only through `guard/run preflight <run_dir> <job.sh> [options]`. It fails when guard files differ from `origin/main`, the question card is uncommitted or edited, the date is past `stop_date`, `--time` or `--nodes` is missing or over its cap, spent plus queued plus projected core-hours exceed the budget minus the verification reserve, concurrency would exceed its cap, or `guard/run ripples` for the run exits 1, unless `HPC_SPEND_RESERVE=1`. It stamps `--job-name=<run_id>` and forces `--account` to the card's account. Verifier jobs set `HPC_SPEND_RESERVE=1`.
- Call `guard/run manifest "$RUN_DIR" "$0" "$@"` at the top of every job script. It records commit, dirty count, modules, container, lockfile hashes, input size and mtime (hashes with `HPC_HASH_INPUTS=1`), and the command, and it never overwrites.
- Run `guard/run ripples <run_dir>` at every wake. Exit 1 means stop new submissions.
- Run frozen code from `cwd=$(guard/run code <repo> <commit>)` and pass the printed absolute path as the job's working directory. Never build worktree paths by hand.
- On a launch host (one that `guard/budget.card`'s `launch_hosts` names by its short hostname, as `hostname -s` prints it there, not an ssh alias), start compute only with `guard/run launch <run_dir> --time=T --gpus=<i,j|none> --mem=<GB> [--shm=DIR] [--cwd=DIR] -- <command>`. It applies preflight's gates, refuses while ripples exits 1, caps GPU-hours, memory (anonymous memory plus the declared shm dirs) and walltime, and starts a supervisor that stops the job gently (INT, then TERM, then KILL) when a cap is reached or the host runs out of memory. It prints the job id alone on stdout. Check on jobs with `guard/run launch --list <run_dir>` and stop one with `guard/run launch --stop <job_id> --reason=<why>`. Only that supervisor and `--stop` ever stop a job; ripples reports and never stops anything.

When a guard blocks you, the block is the answer. Report it. Do not route around it.

## Execution ledger (run lifecycle step 4)

Submit through preflight, or through launch on a launch host. Wake on events and run ripples at each wake. The card holds the design; execution facts (host, GPUs, memory stop, stage length, a resume checkpoint, a restart) go in `runs/<run_id>/execution.tsv` as committed rows `id ts field value why evidence` with ids `x1`, `x2`, ... in order. A resource stop (OUT_OF_MEMORY, HOST_OUT_OF_MEMORY, NODE_FAIL, PREEMPTED, SUPERVISOR_FAILED, CANCELLED, LAUNCH_FAILED: contention or infrastructure, including a run you stopped to free memory) continues with a `restart` or `resume` row citing the job id, which also counts as handling it under `max_handled_failures`. A science stop (FAILED, TIMEOUT) goes to the human; a ledger row cannot clear it. The report's `## Execution history` cites every row. The ledger records how the run executes, never what came of it: job outcomes, such as a job that finished or failed or a score, go in the report. `runs/_template/execution.tsv` lists the fields. Check the ledger with `guard fence --ledger runs/<run_id>/execution.tsv` before each commit. A wrong row of your own stays, because the ledger is append-only: append `void <id>` naming it, in a pull request that changes only run records. A row that changes a question card key is design, and only a new card changes it.

## The budget card

`guard/budget.card` on the protected branch, human-owned:

```
account: <allocation>
start_date: YYYY-MM-DD
stop_date: YYYY-MM-DD
max_core_hours: 0
verification_reserve_core_hours: 0
cores_per_node: 0
max_nodes_per_job: 0
max_walltime_minutes: 0
max_concurrent_jobs: 0
quota_pct_cmd: <site command that prints percent used>
slurm_bin: /usr/bin
max_handled_failures: 2
launch_hosts: none
max_gpu_hours: 0
host_max_walltime_minutes: 720
host_max_mem_gb: 64
host_min_available_gb: 32
host_stop_grace_seconds: 60
host_state_dir: ~/.local/state/guard/launches
explore_max_gpus: 1
default_run_gpu_hours: 0
default_run_core_hours: 0
stray_ignore: none
```
