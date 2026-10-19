# Compatibility contract

A guarded project must keep working when its harness clone is newer or older than the release that installed it, and after it runs `guard init --update`. This page lists what stays stable, how a release is versioned, what an update changes, and what a harness maintainer may change.

## What stays stable

Stable means additions only. Nothing on this list is renamed or removed, except once, in schema 8: the owner broke the contract a single time to retire the agent-written card and the v7 agent commands (design-v8, decision 1). [Removed in schema 8](#removed-in-schema-8) lists every removal.

| Surface | Stable part |
|---|---|
| Paths | `guard/run`, `guard/budget.card` with its `harness:` pin, `guard/watch.list`, `guard/VERSION`, `guard/harness-<pin>.sh` (offline projects), `runs/_template/{report.md,execution.tsv}`, `runs/<id>/{question.card,report.md,execution.tsv,checks/*,incidents/*.md}` (since schema 8 only the broker writes `question.card`, on `run/<id>`), the ref `guard/receipts` with its `receipts.jsonl` |
| Workflow | `.github/workflows/guard-fence.yml`, workflow name `guard-fence`, job id `fence`. From schema 8 the job also fetches `refs/heads/guard/receipts` for the fence's F04. Rulesets require the check `guard-fence / fence`, so a renamed job leaves every pull request waiting. The job reads `harness:` from the base branch's `guard/budget.card` and runs `guard/run fence` with `HPC_HARNESS` at a checkout of `0jrm/harness4research` at the pin, or from `guard/harness-<pin>.sh` when the base branch has it; a card without the pin runs `guard/bin/fence.sh`. |
| Calling convention | `guard/run <command> args`, for the commands `manifest`, `fence`, `code` and `receipts-check`, runs `lib/guard/<command>.sh` from the harness at the base branch's pin (or from `guard/harness-<pin>.sh`) as `bash -c "$script" guard/bin/<command>.sh args` from the repository top, with `HPC_CALLER_DIR` set to the directory the caller ran it from. Any `guard/run` must run any script version, because agent branches carry an older working-tree `guard/run`. |
| Environment | `HPC_HARNESS` (the harness clone the shim runs from), `HPC_GUARD_REF`, `HPC_GUARD_LOCAL`, `HPC_LOCK_FILES`, `HPC_HASH_INPUTS`, `HPC_CODE_ROOT`, `HPC_REVIEWER_PROBE_SECONDS` (read by `guard doctor`), `HPC_CALLER_DIR` (set by `guard/run`), `HPC_JOB_ID` and `HPC_RUN_DIR`, which a host job has and the manifest reads, and `GUARD_JOB_ID`, which every job `guard run` starts has |
| Exit codes | 64 is a usage error everywhere. A refusal exits 2, or 3 when the job was queued for a person; `guard wait` exits 124 when the job still runs. The fence exits 0 or 1. `code` exits 2 when it refuses. `guard/run` exits 2 when the script is missing on the base branch or does not parse. |
| Output | Every refusal is two lines, `H4R-<code> <reason>` and a command to run as it is; codes are never renumbered or reused ([refusals.md](refusals.md)). The fence prints `STATUS<TAB>check<TAB>detail`, the code the first token of a FAIL's detail. Fence statuses are PASS, FAIL, WARN. Check names are never removed; a check that cannot run says UNCHECKED. |
| Card format | Flat `key: value` lines. The first match wins. `<...>` means unset. Manifests and incidents use the same format, and incidents keep `job: <id>`. |
| Host job records | `<host_state_dir>/<job id>/{request,start,beat,end,stop}` in the card format. Keys are only added. A job id is `<host>-<UTC %Y%m%dT%H%M%SZ>`. State words come from Slurm where Slurm has the word (COMPLETED, FAILED, TIMEOUT, OUT_OF_MEMORY, CANCELLED, PREEMPTED, NODE_FAIL, RUNNING, PENDING), plus HOST_OUT_OF_MEMORY, SUPERVISOR_FAILED and LAUNCH_FAILED. |
| Execution envelope | `runs/<id>/execution.tsv`, tab-separated, header `id ts field value why evidence`, ids `x1`, `x2`, ... in order, append-only. Fields are `host`, `gpus`, `start`, `concurrency`, `workers`, `staging`, `mem_stop_gb`, `stage_minutes`, `resume`, `restart`; the list only grows. A line starting with `#` is a comment. A `void <id>` row retracts an earlier row whose field is not a question card key, in a pull request that changes only run records. `guard/run fence --ledger <file>` checks a ledger before it is committed. |
| Required budget keys | `account`, `start_date`, `stop_date`, `max_core_hours`, `verification_reserve_core_hours`, `cores_per_node`, `max_nodes_per_job`, `max_walltime_minutes`, `max_concurrent_jobs`. No key is ever added to this list. |
| Optional keys | Budget card: `harness` (the pin), `quota_pct_cmd`, `slurm_bin`, `partitions`, `extra_sbatch`, `merge_policy`, `launch_hosts`, `max_gpu_hours`, `host_max_walltime_minutes`, `host_max_mem_gb`, `host_min_available_gb`, `host_stop_grace_seconds`, `host_state_dir`, `stray_ignore`, `default_run_gpu_hours`, `default_run_core_hours`, and since schema 8 `compute`, `holdout_max_submissions`, `ask_deadline`, `approval` and `broker_key` (the broker's public key; a placeholder makes the fence refuse every receipt id). Question card, written by the broker: `why`, `command`, `backend`, `minutes`, `nodes`, `cores`, `gpus`, `tasks`, `core_hours`, `gpu_hours`, `session`, `written_by`. Each has a working default, so a card without it works; what each does is in [guard-reference.md](guard-reference.md). |
| Check names | The host checks `gpu-hours`, `host-supervision`, `host-memory`, `host-strays`, `host-log-errors`, the envelope check `execution-within-envelope`, and the fence rules `execution-ledger`, `execution-history`. Schema 8 removed the rest of v7's ripples statuses and four fence rules ([below](#removed-in-schema-8)); no other check name is removed. |
| Fence rules | A rule judges files the pull request adds. It judges a modified file only if the file's merge-base copy already passed the rule. No rule scans the whole tree. |

Free to change: the detail column, message wording after the fixed prefixes, internal code, and template comments.

Optional budget keys and how the scripts use them are in [guard-reference.md](guard-reference.md); each key has a working default, so a card without it works.

## Versions

`SCHEMA` at the repository root holds one integer. A commit without the file is schema 1. A release raises it when it adds a command, a check name, a status, a card key, a run-file key, or a fence rule. Bug fixes do not raise it. The skill states the schema it describes, and a test keeps the two equal.

Releases are annotated tags `vS.N`, where S is the schema. Schema 7 (v7.0) is the first where a project holds no scripts: `guard/bin/` is gone, and `guard/run` runs the harness at the pin. Schema 8 (v8.0) replaces the agent's commands with `guard run`, `wait`, `ask`, `status` and `holdout`. A schema 7 project moves once with `guard init --update`; a project older than schema 7 moves with v7.0's `--update` first, and this harness's `--update` prints that command and stops.

`guard init` writes `guard/VERSION` in the project:

```text
schema: 8
installer: <full commit of the harness that wrote this file>
release: <git describe of that commit>
pstack: <commit>
installed: YYYY-MM-DD
```

A file without a `schema:` line was written by schema 1. Every release since `v1.0` writes `installer:`.

## What an update changes

`guard init <repo> --update` reads `guard/budget.card` and `guard/VERSION` from the project's default branch and proposes the result on a new branch, `guard/update`, in a separate worktree.

- It refuses when this harness lacks the project's pin or is behind it, and when the project's schema is newer; it says to pull the harness. `--force` proposes this harness's pin anyway. A project below schema 7, or without a pin, is sent to v7.0 first.
- A pinned project whose pin has the same `lib/guard/` and `templates/` as this harness is current, and nothing is proposed. Otherwise the update changes one line, `harness:`, to this harness's pin. An offline project also gets `guard/harness-<new pin>.sh` in place of the old pin's file. `--online` or `--offline` switches the mode.
- A schema 7 project gets the schema 8 migration once:

  | File | Change | Kept |
  |---|---|---|
  | `guard/budget.card` | `harness:` moves to this harness's pin; `compute: none`, `holdout_max_submissions: 3`, `ask_deadline: 30m`, `approval: auto` and `broker_key:` (this host's broker `key.pub`, or a placeholder) are appended after a comment block | every existing line and value, including keys schema 8 no longer reads |
  | `guard/harness-<pin>.sh` (offline projects) | replaced by the new pin's file | |
  | `guard/run` | the schema 8 shim: `fence`, `code`, `manifest`, `receipts-check`; `preflight`, `ripples` and `launch` print H4R-R09 with the `guard run` line | |
  | `.github/workflows/guard-fence.yml` | the schema 8 file, which fetches `guard/receipts`; name and job unchanged | |
  | `runs/_template/question.card` | deleted | `report.md`, `execution.tsv` |
  | `AGENTS.md` | with a `## Project landmines` heading, the lines above it become the template's; without one, `AGENTS.md` is untouched and `guard/AGENTS.proposed.md` is written | the heading and every line under it |
  | `guard/VERSION` | `schema: 8`, new `installer:` and `release:` lines | |

  A migrated card keeps `max_gpu_hours: 0`, so every GPU job on a launch host refuses (H4R-R13) until a person raises it. The commit body and the output say so.
- No other file changes: `watch.list`, `guard/README.md`, `runs/_template/report.md` and `execution.tsv`, `FACTS.md` and `CLAUDE.md` stay as they are. On a pin move without a migration, when `templates/AGENTS.md` changed since the install, the output prints the command to compare it.

`guard/run` refuses a base-branch script that has conflict markers or does not parse, so a conflicted file merged by mistake stops the guard instead of running half a script.

Rollback is a revert of the update pull request. `guard/run` reads the base branch, so every branch and clone runs the old pin's scripts after its next fetch. Reverting the schema 8 migration also needs a harness clone at v7.0 for the `guard` command, since this harness's `guard run` reads the schema 8 card keys.

## Removed in schema 8

The one break of the contract (design-v8, decision 1). Each item is gone, not stubbed, except that the four v7 agent commands print H4R-R09 with the `guard run` line to use instead (decision 16). Existing `runs/<id>/question.card` files on `main` stay as history; the fence's F03 judges added files only.

| Kind | Removed | Replaced by |
|---|---|---|
| Path | `runs/_template/question.card`, the agent-written card | the broker writes `runs/<id>/question.card` on `run/<id>` when `guard run` submits |
| Command | `preflight`, `ripples`, `launch`, `card` as agent commands (`guard <command>` and `guard/run <command>`) | `guard run`, `guard wait`, `guard status` |
| Command | `guard/run --show <command>` | nothing; `guard/run --show receipts-check` alone stays, for the fence |
| Command | `approve card`, `revoke card`, `approve reserve`; the signed tag `card/<id>` as an agent step | the broker's ask that H4R-R08 opens, answered with `guard needs-you` |
| Socket verb | `submit` | `run` |
| Budget key | `explore_max_nodes`, `explore_max_walltime_minutes`, `explore_max_gpus`, `max_handled_failures`, `card_auto_max_core_hours`, `card_on_main`, `checks` | the per-job limits and `guard run`'s refusals; a migrated card keeps the lines, which nothing reads |
| Question card key | `budget_core_hours`, `budget_gpu_hours`, `deadline`, `supersedes`, `spawned_from` | the broker prices every job; nothing the agent states enters a decision |
| Fence rule | `setting-key`, `hypothesis-line`, `no-exploration-reports`, `card-lineage` | F03: an added card is one only the broker writes |
| Status | the ripples statuses `RIPPLE`, `HANDLED` | `guard status` and the refusal codes |
| Output prefix | `PREFLIGHT OK:`, `PREFLIGHT FAIL:`, `LAUNCH OK:`, `LAUNCH FAIL:` | `job <id> submitted for run <run_id>: ...` and `H4R-<code>` |
| Environment | `HPC_SPEND_RESERVE`, `HPC_RIPPLES_TSV` | the ask H4R-R08 opens; `guard status` |
| Exemption | the `explore-` run id | none; every run is priced the same way |

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
