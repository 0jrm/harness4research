# The envelope: guards, guard run, and the execution ledger

Read this before you write a job script, submit, or write an `execution.tsv` row. It is the full text behind the core's guard and lifecycle rules.

## Guards are structure, not prose

- `guard/budget.card` and every path in `guard/watch.list` live on the protected branch, and the human changes them. The broker reads the card from there, so an edit on your branch has no effect. The `guard-fence` check blocks the merge of any change to `guard/`, `.github/workflows/`, the top-level `AGENTS.md` and `CLAUDE.md`, watched paths, an added question card, and any report evidence row that cites neither a committed artifact path nor a receipt id (`L` and ten hex digits). For output too large to commit, cite the committed manifest that hashes it.
- Submit only with `guard run runs/<run_id> --why "<one sentence>" -- <sbatch options> <script> [args]`. The broker prices the job from the card and refuses, with the command to run instead, when the job breaks a per-job limit, the date is past `stop_date`, guard files differ from `origin/main`, a failed job of yours has no `--cause`, or the same job already runs. Over the budget it queues the job as a question for a person (exit 3) and `guard status` shows the answer. It writes `runs/<run_id>/question.card` on `run/<run_id>`; never write one yourself.
- Call `guard/run manifest "$RUN_DIR" "$0" "$@"` at the top of every job script. It records commit, dirty count, modules, container, lockfile hashes, input size and mtime (hashes with `HPC_HASH_INPUTS=1`), and the command, and it never overwrites.
- Wait with `guard wait <job_id>`. It returns every 5 minutes with the last 20 log lines; run the `keep waiting` line it prints, or do other work.
- Run frozen code from `cwd=$(guard/run code <repo> <commit>)` and pass the printed absolute path as the job's working directory. Never build worktree paths by hand.
- On a launch host (one that `guard/budget.card`'s `launch_hosts` names by its short hostname), the same `guard run` line launches the job under the host supervisor, boxed, with `--time`, `--gpus` (a count), `--mem` and `--cpus-per-task`. Stop one of yours with `guard wait --stop <job_id>`; only the supervisor and that command stop a host job.

When a guard blocks you, the block is the answer. Run its second line, or report it. Do not route around it.

## Execution ledger (run lifecycle step 4)

The card holds the design; execution facts (host, GPUs, memory stop, stage length, a resume checkpoint, a restart) go in `runs/<run_id>/execution.tsv` as committed rows `id ts field value why evidence` with ids `x1`, `x2`, ... in order. A resource stop (OUT_OF_MEMORY, HOST_OUT_OF_MEMORY, NODE_FAIL, PREEMPTED, SUPERVISOR_FAILED, CANCELLED, LAUNCH_FAILED: contention or infrastructure, including a run you stopped to free memory) continues with a `restart` or `resume` row citing the job id. A science stop (FAILED, TIMEOUT) needs `--cause` on the next `guard run`; a ledger row cannot clear it. The report's `## Execution history` cites every row. The ledger records how the run executes, never what came of it: job outcomes, such as a job that finished or failed or a score, go in the report. `runs/_template/execution.tsv` lists the fields. Check the ledger with `guard fence --ledger runs/<run_id>/execution.tsv` before each commit. A wrong row of your own stays, because the ledger is append-only: append `void <id>` naming it, in a pull request that changes only run records.

## The budget card

`guard/budget.card` on the protected branch, human-owned (the template; `<...>` is unset):

```
account: <slurm account for agent work>
start_date: <YYYY-MM-DD, first day this budget covers>
stop_date: <YYYY-MM-DD, last day agents may submit>
max_core_hours: <total core-hours agents may spend>
verification_reserve_core_hours: <core-hours held back for baselines and verifier jobs>
cores_per_node: <cores per node on the partition you use>
max_nodes_per_job: <nodes>
max_walltime_minutes: <minutes>
max_concurrent_jobs: <jobs>
quota_pct_cmd: <command that prints percent of your scratch quota used>
slurm_bin: /usr/bin
launch_hosts: none
max_gpu_hours: 0
host_max_walltime_minutes: 720
host_max_mem_gb: 64
host_min_available_gb: 32
host_stop_grace_seconds: 60
host_state_dir: ~/.local/state/guard/launches
default_run_gpu_hours: 0
default_run_core_hours: 0
stray_ignore: none
merge_policy: autonomous
compute: none
holdout_max_submissions: 3
ask_deadline: 30m
approval: auto
broker_key: <the broker key.pub; guard init writes it once guard broker setup has run>
```
