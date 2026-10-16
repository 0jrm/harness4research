# Compatibility contract

A guarded project must keep working when its harness clone is newer or older than the release that installed it, and after it runs `guard init --update`. This page lists what stays stable, how a release is versioned, what an update changes, and what a harness maintainer may change.

## What stays stable

Stable means additions only. Nothing on this list is renamed or removed.

| Surface | Stable part |
|---|---|
| Paths | `guard/run`, `guard/budget.card` with its `harness:` pin, `guard/watch.list`, `guard/VERSION`, `guard/harness-<pin>.sh` (offline projects), `runs/_template/{question.card,report.md,execution.tsv}`, `runs/<id>/{question.card,report.md,execution.tsv,checks/*,incidents/*.md}` |
| Workflow | `.github/workflows/guard-fence.yml`, workflow name `guard-fence`, job id `fence`. Rulesets require the check `guard-fence / fence`, so a renamed job leaves every pull request waiting. The job reads `harness:` from the base branch's `guard/budget.card` and runs `guard/run fence` with `HPC_HARNESS` at a checkout of `0jrm/harness4research` at the pin, or from `guard/harness-<pin>.sh` when the base branch has it; a card without the pin runs `guard/bin/fence.sh`. |
| Calling convention | `guard/run <command> args`, for the commands `preflight`, `ripples`, `manifest`, `fence`, `code` and `launch`, runs `lib/guard/<command>.sh` from the harness at the base branch's pin (or from `guard/harness-<pin>.sh`) as `bash -c "$script" guard/bin/<command>.sh args` from the repository top, with `HPC_CALLER_DIR` set to the directory the caller ran it from. Any `guard/run` must run any script version, because agent branches carry an older working-tree `guard/run`. |
| Environment | `HPC_HARNESS` (the harness clone the shim runs from), `HPC_GUARD_REF`, `HPC_GUARD_LOCAL`, `HPC_SPEND_RESERVE`, `HPC_LOCK_FILES`, `HPC_HASH_INPUTS`, `HPC_CODE_ROOT`, `HPC_RIPPLES_TSV`, `HPC_REVIEWER_PROBE_SECONDS` (read by `guard doctor`), `HPC_CALLER_DIR` (set by `guard/run`), and `HPC_JOB_ID` and `HPC_RUN_DIR`, which launch sets for its job and the manifest reads |
| Exit codes | 64 is a usage error everywhere. Preflight exits 2 when it refuses, otherwise with sbatch's code. Ripples exits 0, or 1 to stop submissions. The fence exits 0 or 1. `code` exits 2 when it refuses. Launch exits 2 when it refuses or its job does not start, and 0 once the job runs. `guard/run` exits 2 when the script is missing on the base branch or does not parse. |
| Output | Ripples and the fence print `STATUS<TAB>check<TAB>detail`. When its stdout is a terminal, ripples prints the same lines as an aligned table instead, coloured unless `NO_COLOR` is set or `TERM` is `dumb`. A program that reads the output through a pipe or a file gets the TSV, and one that reads through a terminal (`ssh -t`, a pty) sets `HPC_RIPPLES_TSV=1` to get it. Ripples statuses are PASS, RIPPLE, HANDLED, UNCHECKED. Fence statuses are PASS, FAIL, WARN. Check names are never removed; a check that cannot run says UNCHECKED. Preflight keeps the `PREFLIGHT OK:` and `PREFLIGHT FAIL:` prefixes. Launch keeps `LAUNCH OK:` and `LAUNCH FAIL:` and prints the job id alone on stdout. |
| Card format | Flat `key: value` lines. The first match wins. `<...>` means unset. Manifests and incidents use the same format, and incidents keep `job: <id>`. |
| Launch records | `<host_state_dir>/<job id>/{request,start,beat,end,stop}` in the card format. Keys are only added. A job id is `<host>-<UTC %Y%m%dT%H%M%SZ>`. State words come from Slurm where Slurm has the word (COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY, CANCELLED, PREEMPTED, NODE_FAIL, RUNNING, PENDING), plus HOST_OUT_OF_MEMORY, SUPERVISOR_FAILED and LAUNCH_FAILED. |
| Execution ledger | `runs/<id>/execution.tsv`, tab-separated, header `id ts field value why evidence`, ids `x1`, `x2`, ... in order, append-only. Fields are `host`, `gpus`, `start`, `concurrency`, `workers`, `staging`, `mem_stop_gb`, `stage_minutes`, `resume`, `restart`; the list only grows. A line starting with `#` is a comment. A `void <id>` row retracts an earlier row whose field is not a question card key, in a pull request that changes only run records. `guard/run fence --ledger <file>` checks a ledger before it is committed. |
| Required budget keys | `account`, `start_date`, `stop_date`, `max_core_hours`, `verification_reserve_core_hours`, `cores_per_node`, `max_nodes_per_job`, `max_walltime_minutes`, `max_concurrent_jobs`. No key is ever added to this list. |
| Optional keys | Budget card: `harness` (the pin), `quota_pct_cmd`, `slurm_bin`, `explore_max_nodes`, `explore_max_walltime_minutes`, `explore_max_gpus`, `max_handled_failures`, `merge_policy`, `card_on_main`, `checks`, `launch_hosts`, `max_gpu_hours`, `host_max_walltime_minutes`, `host_max_mem_gb`, `host_min_available_gb`, `host_stop_grace_seconds`, `host_state_dir`, `stray_ignore`, `default_run_gpu_hours`, `default_run_core_hours`. Question card: `budget_gpu_hours`, `budget_core_hours`, `deadline`, `supersedes`, `spawned_from`, `checks`. Each has a working default, so a card without it works; what each does is in [guard-reference.md](guard-reference.md). |
| Check names | Besides the original checks, the host and envelope checks `gpu-hours`, `host-supervision`, `host-memory`, `host-strays`, `host-log-errors`, `execution-within-envelope`, and the fence rules `execution-ledger`, `execution-history`, `card-lineage`. A check name is never removed. |
| Fence rules | A rule judges files the pull request adds. It judges a modified file only if the file's merge-base copy already passed the rule. No rule scans the whole tree. |

Free to change: the detail column, message wording after the fixed prefixes, internal code, and template comments.

Optional budget keys and how the scripts use them are in [guard-reference.md](guard-reference.md); each key has a working default, so a card without it works.

## Versions

`SCHEMA` at the repository root holds one integer. A commit without the file is schema 1. A release raises it when it adds a command, a check name, a status, a card key, a run-file key, or a fence rule. Bug fixes do not raise it. The skill states the schema it describes, and a test keeps the two equal.

Releases are annotated tags `vS.N`, where S is the schema. Schema 7 (v7.0) is the first where a project holds no scripts: `guard/bin/` is gone, and `guard/run` runs the harness at the pin. A schema 6 project moves once with `guard init --update`.

`guard init` writes `guard/VERSION` in the project:

```text
schema: 7
harness: <the pin>
installer: <full commit of the harness that wrote this file>
release: <git describe of that commit>
pstack: <commit>
installed: YYYY-MM-DD
```

A file without a `schema:` line was written by schema 1. Every release since `v1.0` writes `installer:`.

## What an update changes

`guard init <repo> --update` reads `guard/budget.card` and `guard/VERSION` from the project's default branch and proposes the result on a new branch, `guard/update`, in a separate worktree.

- It refuses when this harness lacks the project's pin or is behind it, or, for a project without a pin, lacks the installer commit, and when the project's schema is newer; it says to pull the harness. `--force` proposes this harness's pin anyway.
- A pinned project whose pin has the same `lib/guard/` and `templates/` as this harness is current, and nothing is proposed. Otherwise the update changes one line, `harness:`, to this harness's pin. An offline project also gets `guard/harness-<new pin>.sh` in place of the old pin's file. `--online` or `--offline` switches the mode.
- A project without a pin, its scripts in `guard/bin/`, gets the migration once: the `harness:` line is added before `account:`, `guard/bin/` is deleted, `guard/run` and `.github/workflows/guard-fence.yml` are replaced by the templates, and `guard/VERSION` is rewritten; offline, `guard/harness-<pin>.sh` is added. A site edit to `guard/bin/`, `guard/run` or the workflow is dropped, and the pull request's diff shows it.
- No other file changes: card values, `watch.list`, `guard/README.md`, `runs/_template/`, `FACTS.md`, and `AGENTS.md` stay as they are. When `templates/AGENTS.md` changed since the install, the output prints the command to compare it.

`guard/run` refuses a base-branch script that has conflict markers or does not parse, so a conflicted file merged by mistake stops the guard instead of running half a script.

Rollback is a revert of the update pull request. `guard/run` reads the base branch, so every branch and clone runs the old pin's scripts, or after a reverted migration `guard/bin/`, after its next fetch.

## Rules for the harness maintainer

- Add, never rename or remove, anything in the stable table.
- A new budget key is optional, and the script's default equals the template's value.
- A new fence rule follows the ratchet in the stable table.
- When a site difference is a value, add a card key with a default, as `quota_pct_cmd` does, instead of asking humans to edit a script.
- Raise `SCHEMA` and the schema the skill states together.
- Tag each release; a project pins a tag.

## Checking which side is behind

Inside a project, `guard version` prints this harness's release and schema, the project's schema and installer commit, and one verdict:

| Verdict | Meaning | Action |
|---|---|---|
| `current` | the project's pin, or without a pin its install, has this harness's scripts and templates | none |
| `project older` | the project's schema is lower, or the scripts or templates changed since its pin or install | `guard init <repo> --update` |
| `harness older or on another branch` | this harness lacks the pin or the installer commit, or knows a lower schema | `git -C <harness> pull` |
| `install commit unknown` | `guard/VERSION` has no usable installer commit | `guard init <repo> --update --force` |
