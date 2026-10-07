# Compatibility contract

A guarded project must keep working when its harness clone is newer or older than the release that installed it, and after it runs `guard init --update`. This page lists what stays stable, how a release is versioned, how an update merges, and what a harness maintainer may change.

## What stays stable

Stable means additions only. Nothing on this list is renamed or removed.

| Surface | Stable part |
|---|---|
| Paths | `guard/run`, `guard/bin/{preflight,ripples,manifest,fence,code,launch}.sh`, `guard/budget.card`, `guard/watch.list`, `guard/VERSION`, `runs/_template/{question.card,report.md}`, `runs/<id>/{question.card,report.md,execution.tsv,checks/*,incidents/*.md}` |
| Workflow | `.github/workflows/guard-fence.yml`, workflow name `guard-fence`, job id `fence`. Rulesets require the check `guard-fence / fence`, so a renamed job leaves every pull request waiting. |
| Calling convention | `guard/run <command> args` runs the base branch's script as `bash -c "$script" guard/bin/<command>.sh args` from the repository top, with `HPC_CALLER_DIR` set to the directory the caller ran it from. Any `guard/run` must run any script version, because agent branches carry an older working-tree `guard/run`. |
| Environment | `HPC_GUARD_REF`, `HPC_GUARD_LOCAL`, `HPC_SPEND_RESERVE`, `HPC_LOCK_FILES`, `HPC_HASH_INPUTS`, `HPC_CODE_ROOT`, `HPC_RIPPLES_TSV`, `HPC_CALLER_DIR` (set by `guard/run`), and `HPC_JOB_ID` and `HPC_RUN_DIR`, which launch sets for its job and the manifest reads |
| Exit codes | 64 is a usage error everywhere. Preflight exits 2 when it refuses, otherwise with sbatch's code. Ripples exits 0, or 1 to stop submissions. The fence exits 0 or 1. `code` exits 2 when it refuses. Launch exits 2 when it refuses or its job does not start, and 0 once the job runs. `guard/run` exits 2 when the script is missing on the base branch or does not parse. `guard init --update` exits 3 when it proposes conflicts. |
| Output | Ripples and the fence print `STATUS<TAB>check<TAB>detail`. When its stdout is a terminal, ripples prints the same lines as an aligned table instead, coloured unless `NO_COLOR` is set or `TERM` is `dumb`. A program that reads the output through a pipe or a file gets the TSV, and one that reads through a terminal (`ssh -t`, a pty) sets `HPC_RIPPLES_TSV=1` to get it. Ripples statuses are PASS, RIPPLE, HANDLED, UNCHECKED. Fence statuses are PASS, FAIL, WARN. Check names are never removed; a check that cannot run says UNCHECKED. Preflight keeps the `PREFLIGHT OK:` and `PREFLIGHT FAIL:` prefixes. Launch keeps `LAUNCH OK:` and `LAUNCH FAIL:` and prints the job id alone on stdout. |
| Card format | Flat `key: value` lines. The first match wins. `<...>` means unset. Manifests and incidents use the same format, and incidents keep `job: <id>`. |
| Launch records | `<host_state_dir>/<job id>/{request,start,beat,end,stop}` in the card format. Keys are only added. A job id is `<host>-<UTC %Y%m%dT%H%M%SZ>`. State words come from Slurm where Slurm has the word (COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY, CANCELLED, PREEMPTED, NODE_FAIL, RUNNING, PENDING), plus HOST_OUT_OF_MEMORY, SUPERVISOR_FAILED and LAUNCH_FAILED. |
| Execution ledger | `runs/<id>/execution.tsv`, tab-separated, header `id ts field value why evidence`, ids `x1`, `x2`, ... in order, append-only. Fields are `host`, `gpus`, `start`, `concurrency`, `workers`, `staging`, `mem_stop_gb`, `stage_minutes`, `resume`, `restart`; the list only grows. |
| Required budget keys | `account`, `start_date`, `stop_date`, `max_core_hours`, `verification_reserve_core_hours`, `cores_per_node`, `max_nodes_per_job`, `max_walltime_minutes`, `max_concurrent_jobs`. No key is ever added to this list. |
| Fence rules | A rule judges files the pull request adds. It judges a modified file only if the file's merge-base copy already passed the rule. No rule scans the whole tree. |

Free to change: the detail column, message wording after the fixed prefixes, internal code, and template comments.

Optional budget keys, each with a working default the scripts share: `explore_max_nodes`, `explore_max_walltime_minutes`, `max_handled_failures`, `merge_policy`, and the launch and envelope keys below.

## Launch hosts

Launch is off until a human sets `launch_hosts` on the protected branch, as a space-separated list of short hostnames exactly as `hostname -s` prints them on each host (an ssh alias is refused, and the refusal names the real name). `host_state_dir` must survive a reboot: keep the default under `~/.local/state` and never point it at a tmpfs such as `/tmp` on a host where `/tmp` is RAM-backed, or every record and the GPU-hour count vanish. Its keys, `launch_hosts`, `max_gpu_hours`, `host_max_walltime_minutes`, `host_max_mem_gb`, `host_min_available_gb`, `host_stop_grace_seconds`, `host_state_dir`, `explore_max_gpus`, and `stray_ignore`, have working template values, so the update inserts them and the required list does not grow. With `launch_hosts: none`, ripples prints the same lines as before and preflight is byte-identical. Once a project opts in, the five host checks, `gpu-hours`, `host-supervision`, `host-memory`, `host-strays` and `host-log-errors`, print on every host, as UNCHECKED where they cannot look, and the job checks (`job-states`, `walltime-headroom`, `retries`, `handled-failures`) cover launched jobs through the same incident rules.

## The execution envelope

The question card holds the design and stays frozen. Its optional keys `budget_gpu_hours`, `budget_core_hours` and `deadline` cap one run; `default_run_gpu_hours` and `default_run_core_hours` in `guard/budget.card` are the workspace defaults, `0` meaning no per-run cap. Execution facts go in `runs/<id>/execution.tsv`. A `restart` or `resume` row may cite a resource stop (OUT_OF_MEMORY, HOST_OUT_OF_MEMORY, NODE_FAIL, PREEMPTED, SUPERVISOR_FAILED, CANCELLED, LAUNCH_FAILED), never a science stop (FAILED, TIMEOUT); the lists only grow. Ripples prints `execution-within-envelope` only for a run that has a ledger at HEAD. The fence rules `execution-ledger` and `execution-history` follow the ratchet.

## Merge policy

`merge_policy` in `guard/budget.card` decides whether `guard merge` may merge a pull request without a human. `autonomous`, the template value and the default when the key is missing, lets it merge once its other gates pass. Any other value, such as `semi-manual`, makes it refuse and queue the merge for a human. `guard merge` reads the key from the pull request's base branch, so an agent cannot change it on its own branch. A repository without a guard reads `merge_policy` from the user config instead (`guard config`). No other script reads the key, and `guard init --update` inserts it.

## Card lineage

The question card's optional keys `supersedes` and `spawned_from` name the run id a card replaces or grew out of. The value `none` declares that the card has no parent; a `<...>` placeholder or a missing line leaves it unset. No script requires either key, so a card without them passes preflight, ripples and the fence as before. The atlas draws the question map from them. The fence rule `card-lineage` prints WARN, which does not fail the fence, when a card the pull request adds sets neither key and its id extends another carded run id by name. It judges added cards only, so an existing card never warns.

## Versions

`SCHEMA` at the repository root holds one integer. A commit without the file is schema 1. A release raises it when it adds a command, a check name, a status, a card key, a run-file key, or a fence rule. Bug fixes do not raise it. The skill states the schema it describes, and a test keeps the two equal.

Releases are annotated tags `vS.N`, where S is the schema. `v1.0` is the oldest release whose `guard init` works. `tests/oldest-supported` names the oldest release the upgrade tests build from.

`guard init` writes `guard/VERSION` in the project:

```text
schema: 5
installer: <full commit of the harness that wrote this file>
release: <git describe of that commit>
pstack: <commit>
installed: YYYY-MM-DD
```

A file without a `schema:` line was written by schema 1. Every release since `v1.0` writes `installer:`.

## How an update merges

`guard init <repo> --update` reads `guard/VERSION` from the project's default branch and proposes the result on a new branch, `guard/update`, in a separate worktree.

- It refuses when this harness does not contain the installer commit, or when the project's schema is newer, and says to pull the harness. `--force` proposes anyway.
- Each installer-owned file goes through `git merge-file`, with the template at the installer commit as the base. That covers the six scripts, `guard/run`, `guard/README.md`, and the workflow. A human's edit survives. An edit on lines the harness also changed becomes conflict markers, and the command exits 3.
- A template key that is new since the install is inserted next to its template neighbours. A budget key whose template value is a placeholder is listed, not inserted, because preflight refuses placeholders. A key that the template already had at install time and the project lacks stays out, because a human removed it.
- With no usable installer commit, each file merges against an empty base. That is clean when the file already matches the template and a whole-file conflict otherwise.
- `watch.list`, `FACTS.md`, and `AGENTS.md` are never touched. When `templates/AGENTS.md` changed since the install, the output prints the command to compare it.

`guard/run` refuses a base-branch script that has conflict markers or does not parse, so a conflicted file merged by mistake stops the guard instead of running half a script.

Rollback is a revert of the update pull request. `guard/run` reads the base branch, so every branch and clone runs the old scripts after its next fetch. The revert also restores the old `guard/VERSION`, so the next update finds the right base.

## Rules for the harness maintainer

- Add, never rename or remove, anything in the stable table.
- A new budget key is optional, and the script's default equals the template's value.
- A new fence rule follows the ratchet in the stable table.
- Keep template edits in small hunks and never re-indent unchanged lines. A re-indented line conflicts with every project that edited it.
- When a site difference is a value, add a card key with a default, as `quota_pct_cmd` does, instead of asking humans to edit a script.
- Raise `SCHEMA` and the schema the skill states together.
- Tag each release. The upgrade tests build a project from every tag since `tests/oldest-supported` and fail when no tags are present.

## Checking which side is behind

Inside a project, `guard version` prints this harness's release and schema, the project's schema and installer commit, and one verdict:

| Verdict | Meaning | Action |
|---|---|---|
| `current` | the project was installed by this harness's templates | none |
| `project older` | the project's schema is lower, or the templates changed since its install | `guard init <repo> --update` |
| `harness older or on another branch` | this harness lacks the installer commit, or knows a lower schema | `git -C <harness> pull` |
| `install commit unknown` | `guard/VERSION` has no usable installer commit | `guard init <repo> --update --force` |
