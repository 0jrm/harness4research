# Guard reference

How the guard's optional keys and features behave. What stays stable across releases is in [compatibility.md](compatibility.md).

## Optional budget keys

Optional budget keys, each with a working default: `merge_policy`, `slurm_bin` (default `/usr/bin`, where the broker runs `sbatch`, `squeue` and `sacct` from), `partitions` (a list; `guard run` refuses another with H4R-R17), `extra_sbatch` (options appended to every submission), `default_run_core_hours` and `default_run_gpu_hours` (a per-run cap, `0` meaning none; a job over it is queued for a person, not refused), and the schema 8 keys:

- `compute` (default `none`): entrypoints that run only inside a job. A listed program started on a login node with neither `SLURM_JOB_ID` nor `GUARD_JOB_ID` set prints H4R-C01. The gate is a guide, not a wall.
- `holdout_max_submissions` (default `3`): how many `guard holdout score` calls a session has in a project that sealed a holdout.
- `ask_deadline` (default `30m`): when a question the broker opens, such as an over-budget job, takes its default answer `no`.
- `approval` (`auto` or `queue`, default `auto`): `queue` makes every job a question for a person before it runs.
- `broker_key`: the broker's public key, one `key.pub` line. The fence trusts a cited receipt id only when its commit on `guard/receipts` is signed by this key. A `<...>` placeholder makes it refuse every id with `no broker_key on main`.

Keys schema 8 no longer reads, such as `explore_max_nodes` and `checks`, may stay on a card; nothing reads them ([compatibility.md](compatibility.md#removed-in-schema-8)).

## Launch hosts

Launch hosts are off until a human sets `launch_hosts` on the protected branch, as a space-separated list of short hostnames exactly as `hostname -s` prints them on each host. On a listed host, `guard run` launches the job under the host supervisor instead of Slurm: `--time` and `--mem` pass through (a missing `--mem` becomes `host_max_mem_gb`), `--gpus` is a count the broker turns into free device indices, `--cpus-per-task` enters the price, and `--nodes`, `--partition`, `--array`, `--dependency` and `--ntasks` refuse with H4R-R13. The job runs boxed: a cleared environment, the project read-write, no home, no network, the chosen GPUs, and `GUARD_JOB_ID` set. `host_state_dir` must survive a reboot: keep the default under `~/.local/state` and never point it at a tmpfs such as `/tmp` on a host where `/tmp` is RAM-backed, or every record and the GPU-hour count vanish. The keys `launch_hosts`, `max_gpu_hours`, `host_max_walltime_minutes`, `host_max_mem_gb`, `host_min_available_gb`, `host_stop_grace_seconds`, `host_state_dir` and `stray_ignore` have working defaults. `max_gpu_hours: 0`, the template value, refuses every GPU job until a person raises it.

## The execution envelope

The question card holds the design, and the broker writes it once. Execution facts go in `runs/<id>/execution.tsv`, one row each with `guard ledger add <id> <field> <value> --why W --evidence E` (`guard ledger list <id>` prints it): behind the broker the row is committed to `run/<id>`, signed, after the fence's ledger check; without one it is appended to the working tree's file, checked the same way, for you to commit. A `restart` or `resume` row may cite a resource stop (OUT_OF_MEMORY, HOST_OUT_OF_MEMORY, NODE_FAIL, PREEMPTED, SUPERVISOR_FAILED, CANCELLED, LAUNCH_FAILED), never a science stop (FAILED, TIMEOUT), which needs `--cause` on the next `guard run`; the lists only grow. The fence rules `execution-ledger` and `execution-history` follow the ratchet.

## Merge policy

`merge_policy` in `guard/budget.card` decides whether `guard merge` may merge a pull request without a human. `autonomous`, the template value and the default when the key is missing, lets it merge once its other gates pass. Any other value, such as `semi-manual`, makes it refuse and queue the merge for a human. `guard merge` reads the key from the pull request's base branch, so an agent cannot change it on its own branch. A repository without a guard reads `merge_policy` from the user config instead (`guard config`). No other script reads the key. `guard merge` refuses every merge without a ruleset, so when GitHub offers the repository no rulesets, as for a private repository on the free plan, `guard init` and `guard init --update` set `merge_policy: semi-manual` and say why, and `guard doctor` fails while the key stays `autonomous` there.

## Where each command runs

Commands differ in what they need from the host. At a site with login and compute nodes, run each one where its needs are met.

| Command | Needs | Runs on |
|---|---|---|
| `guard run`, `guard wait`, `guard status` | the broker, or in local mode git and the Slurm clients (`sbatch`, `squeue`, `sacct`), which reach the controller and the accounting database | a login node, a compute node, or a host in `launch_hosts` |
| `guard/run fence` | git | anywhere |
| `guard review`, `guard ship` | `gh`, the internet, and the reviewer CLI (`claude` or `cursor-agent`) logged in on this host | a host with internet access, such as a login node |
| `guard merge`, `guard doctor` | `gh` and the internet | a host with internet access |

Some sites route shell commands to a compute allocation through a shell hook, and their compute nodes have no internet access. There, run `guard review` and `guard ship` on a login node. On a compute node without network, the reviewer CLI cannot reach its service. At FSU RCC, `cursor-agent` reported `Authentication required` there, although its login was valid.

The reviewer CLIs run on Node.js, which reserves large regions of virtual address space for WebAssembly memory. A soft `ulimit -v` below about 8 GB makes it fail with `RangeError: WebAssembly.instantiate(): Out of memory`. FSU RCC's login nodes set the soft limit to 6 GB. Read the limits with `ulimit -Sv` and `ulimit -Hv`. `guard review`, `guard ship` and `guard doctor`'s reviewer check raise the soft limit to the hard one for the reviewer, so a soft limit alone stops nothing. A person still has to act when the hard limit is below about 8 GB: only an administrator can raise it, so ask the site or run them on another host. An install from before this change, such as v7.0, does not raise it; there, run `ulimit -v unlimited` in the shell first.

Login nodes can also cap the number of processes per user. FSU RCC's cap is 200. A default OpenBLAS or OpenMP thread pool starts one thread per core and can reach that cap. Set `OPENBLAS_NUM_THREADS=1` and `OMP_NUM_THREADS=1` for work on such a node.
