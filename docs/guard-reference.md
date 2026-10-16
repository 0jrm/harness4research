# Guard reference

How the guard's optional keys and features behave. What stays stable across releases is in [compatibility.md](compatibility.md).

## Optional budget keys

Optional budget keys, each with a working default the scripts share: `explore_max_nodes`, `explore_max_walltime_minutes`, `max_handled_failures`, `merge_policy`, `slurm_bin` (default `/usr/bin`, the directory preflight runs `squeue` and `sacct` from), `card_on_main` (default `no`; `yes` makes preflight refuse a run other than `explore-*` until its question card is on the protected branch, as committed on the submitting branch, which only a person merges), `checks` (unset by default; `waived <reason>` lets every run of the project submit without domain checks), and the launch and envelope keys below.

Preflight refuses a run other than `explore-*` while the protected branch has no executable file in `runs/<id>/checks/`, unless the question card or the budget card says `checks: waived <reason>`. The question card's `checks` key is optional, and its placeholder means no waiver.

## Launch hosts

Launch is off until a human sets `launch_hosts` on the protected branch, as a space-separated list of short hostnames exactly as `hostname -s` prints them on each host (an ssh alias is refused, and the refusal names the real name). `host_state_dir` must survive a reboot: keep the default under `~/.local/state` and never point it at a tmpfs such as `/tmp` on a host where `/tmp` is RAM-backed, or every record and the GPU-hour count vanish. Its keys, `launch_hosts`, `max_gpu_hours`, `host_max_walltime_minutes`, `host_max_mem_gb`, `host_min_available_gb`, `host_stop_grace_seconds`, `host_state_dir`, `explore_max_gpus`, and `stray_ignore`, have working defaults, so a card without them works and the required list does not grow. With `launch_hosts: none`, ripples prints the same lines as before and preflight is byte-identical. Once a project opts in, the five host checks, `gpu-hours`, `host-supervision`, `host-memory`, `host-strays` and `host-log-errors`, print on every host, as UNCHECKED where they cannot look, and the job checks (`job-states`, `walltime-headroom`, `retries`, `handled-failures`) cover launched jobs through the same incident rules.

## The execution envelope

The question card holds the design and stays frozen. Its optional keys `budget_gpu_hours`, `budget_core_hours` and `deadline` cap one run; `default_run_gpu_hours` and `default_run_core_hours` in `guard/budget.card` are the workspace defaults, `0` meaning no per-run cap. Execution facts go in `runs/<id>/execution.tsv`. A `restart` or `resume` row may cite a resource stop (OUT_OF_MEMORY, HOST_OUT_OF_MEMORY, NODE_FAIL, PREEMPTED, SUPERVISOR_FAILED, CANCELLED, LAUNCH_FAILED), never a science stop (FAILED, TIMEOUT); the lists only grow. Ripples prints `execution-within-envelope` only for a run that has a ledger at HEAD. The fence rules `execution-ledger` and `execution-history` follow the ratchet.

## Merge policy

`merge_policy` in `guard/budget.card` decides whether `guard merge` may merge a pull request without a human. `autonomous`, the template value and the default when the key is missing, lets it merge once its other gates pass. Any other value, such as `semi-manual`, makes it refuse and queue the merge for a human. `guard merge` reads the key from the pull request's base branch, so an agent cannot change it on its own branch. A repository without a guard reads `merge_policy` from the user config instead (`guard config`). No other script reads the key. `guard merge` refuses every merge without a ruleset, so when GitHub offers the repository no rulesets, as for a private repository on the free plan, `guard init` and `guard init --update` set `merge_policy: semi-manual` and say why, and `guard doctor` fails while the key stays `autonomous` there.

## Card lineage

The question card's optional keys `supersedes` and `spawned_from` name the run id a card replaces or grew out of. The value `none` declares that the card has no parent; a `<...>` placeholder or a missing line leaves it unset. No script requires either key, so a card without them passes preflight, ripples and the fence as before. The atlas draws the question map from them. The fence rule `card-lineage` prints WARN, which does not fail the fence, when a card the pull request adds sets neither key and its id extends another carded run id by name. It judges added cards only, so an existing card never warns.

## Where each command runs

Commands differ in what they need from the host. At a site with login and compute nodes, run each one where its needs are met.

| Command | Needs | Runs on |
|---|---|---|
| `guard/run preflight`, `guard/run ripples` | git and the Slurm clients (`sbatch`, `squeue`, `sacct`), which reach the controller and the accounting database | a login node or a compute node |
| `guard/run fence` | git | anywhere |
| `guard review`, `guard ship` | `gh`, the internet, and the reviewer CLI (`claude` or `cursor-agent`) logged in on this host | a host with internet access, such as a login node |
| `guard merge`, `guard doctor` | `gh` and the internet | a host with internet access |

Some sites route shell commands to a compute allocation through a shell hook, and their compute nodes have no internet access. There, run `guard review` and `guard ship` on a login node. On a compute node without network, the reviewer CLI cannot reach its service. At FSU RCC, `cursor-agent` reported `Authentication required` there, although its login was valid.

The reviewer CLIs run on Node.js, which reserves large regions of virtual address space for WebAssembly memory. A soft `ulimit -v` below about 8 GB makes it fail with `RangeError: WebAssembly.instantiate(): Out of memory`. FSU RCC's login nodes set the soft limit to 6 GB. Read the limits with `ulimit -Sv` and `ulimit -Hv`. When the hard limit allows it, raise the soft limit in the shell that runs `guard review` or `guard ship`, with `ulimit -v unlimited`.

Login nodes can also cap the number of processes per user. FSU RCC's cap is 200. A default OpenBLAS or OpenMP thread pool starts one thread per core and can reach that cap. Set `OPENBLAS_NUM_THREADS=1` and `OMP_NUM_THREADS=1` for work on such a node.
