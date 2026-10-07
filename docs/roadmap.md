# Roadmap

This roadmap comes from field feedback on a multi-day ML-training session run under the guard. These parts earned their keep:
- The frozen question cards exposed a changed plan three times.
- Ripples with incident notes turned failures into records instead of retries.
- The handled-failures cap stopped a third rehearsal.
- The preflight walltime cap and the manifest caught real problems.
- The ledger and `/present` let a dead session be rebuilt.

The gaps are below, ordered by what they cost in that session. Every item reaches existing projects through `guard init --update`, so the upgrade strategy in [compatibility.md](compatibility.md) came first.

| # | Item | Status |
|---|---|---|
| 0 | Upgrade strategy and compatibility contract | done, schema 2 |
| 1 | `guard/run launch` for a host without a scheduler | done, schema 3 |
| 2 | Standard check pack, checks run from the protected branch | exit 77 reads UNCHECKED done; the rest next |
| 6 | Close the handled-failures bypass | small, early |
| 5 | Script arguments for preflight | small, early |
| 3 | Link question cards to what ran | after 1 |
| 7 | Skills reach every session | small |
| 4 | The execution envelope: design in the card, execution in `execution.tsv` | done, schema 3 |
| 9 | One checklist per action | remedies on ripples and preflight lines done; the rest later |
| 8 | Continuity across sessions | later, skill only |
| 10 | A needs-you queue of what only the human can do, with Claude Code hooks | this release |
| 11 | `guard review` and `guard merge`, with `merge_policy` | this release, schema 5 |
| 12 | An agent-led onboarding skill, `guard-onboard` | this release, in review |

Each item below gives the smallest design that closes the gap, its effect on existing projects, and its risks. Every new budget key is optional with a default. Every new fence rule follows the ratchet in the contract.

## 1. A launcher for a host without a scheduler

Every GPU-hour, wasted run, and memory blow-up in that session happened on a GPU box with no scheduler. Preflight refuses on such a host today, and the skill says never to bypass the scheduler. Running compute there is therefore a policy change the human opts into.

- **Opt-in.** A human-owned `launch_hosts:` key in `budget.card` names the hosts. Launch refuses everywhere else, so existing projects keep the rule that compute goes through a scheduler.
- **Budget keys.** Launch alone reads `gpu_hours_max`, `max_rss_gb`, and `host_max_walltime_minutes`. The last has a new name so `max_walltime_minutes` keeps its Slurm meaning.
- **Command.** `guard/run launch <run_dir> --time=<min> --gpus=<ids> -- <cmd...>` applies preflight's gates: guard untouched, card frozen, `stop_date`, explore caps. The gate code moves to a `guard/bin/common.sh` that `guard/run` loads from the protected branch. Launch refuses when `nvidia-smi --query-compute-apps` shows the named GPUs busy, or when spent plus running plus projected GPU-hours exceed `gpu_hours_max`.
- **Running the job.**
  1. Launch writes the manifest itself, with job id `<host>-<UTC timestamp>`.
  2. It runs `setsid timeout -k 60 <wall> <cmd>`, with stdout and stderr in the run directory.
  3. A small supervisor writes `launch-<id>.txt` with the process group, host, start, GPUs, wall limit, and card hash.
  4. The supervisor sums RSS over the process group every 15 seconds and kills the group above `max_rss_gb`.
  5. At the end it appends `exit:` and `end:` lines.

  A copy of each record goes to `~/.local/state/guard/launches/`, so every guarded repository on the box sees the others' launches.
- **Ripples on that host.** It reads the launch records and reports:
  - job states, including a dead process group with no exit line, reported as LOST;
  - walltime headroom;
  - GPU-hours against the budget;
  - RSS of live runs;
  - log errors such as tracebacks, CUDA out-of-memory, and `nan`;
  - stray processes: same-user processes on a GPU, or above half of `max_rss_gb`, that belong to no live launch, minus a human-owned `stray_ignore:` pattern.

  The incident pattern widens from numeric job ids so `job: <host>-<timestamp>` counts.
- **What is left out, and why.**
  - `systemd-run --user`: without lingering, the user manager kills its scopes at logout, and it needs cgroup delegation and a D-Bus session that agent sandboxes often lack.
  - `ulimit -v`: CUDA reserves very large virtual address ranges, so a virtual-memory cap kills GPU jobs at start-up.
  - The only hard memory wall on a shared box is an administrator-set `MemoryMax` on the user slice. The docs will carry that request next to the sub-account email.
- **Compatibility.** `launch` is a new command. The host section of ripples runs only when launch records exist, so Slurm projects see no change.
- **Risks.** Launch records live in the working tree, so an agent can delete them and reset the GPU-hour count. On this host the guard is a speed bump, not a bank limit, and `enforcement.md` must say so. Polling can miss a very fast blow-up.

## 2. A standard check pack

Every ripples run printed `UNCHECKED domain-checks`, which trained people to ignore the line. The three failures that hurt were generic and machine-checkable: a loss of 1e8, float64 data, and host RAM.

- **Where checks live.** The pack ships under `guard/checks/`. The installer owns it and the update merges it. Ripples runs it for every run directory.
- **Where checks run from.** Per-run checks in `runs/<id>/checks/` run from the protected branch too. Today they run from the working tree, the one place an unmerged agent edit takes effect.
- **Exit codes.** Exit 77 means "not applicable" and reports UNCHECKED. A check skips itself when its input is missing. `domain-checks` reads UNCHECKED only when no check reached a verdict.
- **Input.** By convention a run writes `runs/<id>/metrics.jsonl` with `step`, `loss`, and optional `epoch` and `dtype` fields. Metrics kept in scratch are named by a `metrics_path:` line in the manifest.
- **The checks.** All use the python3 standard library.
  - `nonfinite` flags NaN or infinite values.
  - `loss-scale` flags a loss above 100 times the first logged loss, or a median after warmup that is not below step 0.
  - `dtype` flags float64 unless the card says float64.

  Thresholds come from optional budget keys. RSS belongs to item 1.
- **How an agent proposes a check.** It opens a separate pull request from a separate branch. That branch cannot trip the run branch's `watched-paths` ripple, and the check does nothing until a human merges it. No extra directory is needed, only a paragraph in the skill and in `guard/README.md`.
- **Compatibility.** A check committed on a branch stops running until it is merged. The update pull request says so.

## 3. Link question cards to what ran

- **Manifest.** It appends three things:
  - `card:`, the git blob hash of the question card;
  - `gpus:`, from `CUDA_VISIBLE_DEVICES` and `nvidia-smi`;
  - one `code: <path> <commit> <dirty count>` line for each repository in `HPC_CODE_REPOS`. This covers a nested clone whose code runs while the run directory lives in the outer repository.
- **Preflight.** It appends `card:<hash>` to its `--comment`. Slurm stores comments only with `AccountingStoreFlags=job_comment`, so preflight probes for it and falls back to the manifest.
- **Fence.** An added card may not keep a `<...>` placeholder in any key.
- **Optional card keys.** A card may set `code_commit:` and `data_path:`.
  - The fence checks that the commit exists.
  - Ripples reports `code-drift` when the code differs between `code_commit` and the manifest's commit, excluding `runs/`. It does not compare the two commits directly, because HEAD moves with every incident commit.
  - Ripples compares `data_path` with the manifest's `input:` lines.
- **Compatibility.** Only appended lines and optional keys.

## 4. The execution envelope

Freezing the card at first launch was dropped. The card stays frozen at first commit and holds only the design; the execution facts that used to force a new run id (host, GPUs, memory limit, a restart after a resource stop such as OOM, a reboot, preemption, a cancelled or never-started launch; a science stop, FAILED or TIMEOUT, still goes to the human) go in `runs/<id>/execution.tsv`, an append-only ledger with a fixed vocabulary. Ripples checks every committed row against the budget card and the launch records, and the fence keeps the ledger append-only and makes the report cite every row. [compatibility.md](compatibility.md) lists the keys and the rules.

## 5. Script arguments for preflight

- **Arguments.** `guard/run preflight <run_dir> <job.sh> [sbatch options] -- [script args]` forwards the arguments as `sbatch <options> <job> <args>`. Preflight reads limits only from the sbatch options. The docs will also say that `--export=ALL,NAME=value` already works.
- **Walltime.** The 60-minute cap that split the jobs was the explore cap. A multi-hour training run is the signal to write a card and chain checkpointed jobs with `--dependency=afterany`. A per-run override, if still wanted, is a human-owned `max_walltime_minutes.<run_id>:` key in `budget.card`, never a question-card key.

## 6. Close the handled-failures bypass

- **`open-failures`.** A new ripples line reports every failed job for the account since `start_date`, across all run ids, that no incident names. It appears in every run's ripples, so an abandoned directory stays visible.
- **`handled-failures-total`.** It counts across the whole project, explore runs included, against an optional `max_handled_failures_total` that defaults to three times `max_handled_failures`.
- **Incidents.** An incident counts as handled only with a `root_cause:` line that is not a placeholder. `fix: <commit>` is optional and must resolve when present. It is not required, because node failures and preemption have no fixing commit.
- **Compatibility.** After the update, `open-failures` can fire on old failures that no incident names. The remedy is to write those incidents, and the update pull request says so.

## 7. Skills reach every session

- **Why `/present` failed.** User-level skills load from any directory on the machine. Project-level skills do not cross a nested repository's root. `/present` lived in the workspace, so a session in the nested clone never saw it.
- **Fix.** The user-level install already exists. It needs a link check: `install.sh` repairs a skill link that points outside its own checkout, such as a link into a removed worktree.
- **Nested clones.**
  - The survey's advice for a nested repository is to open sessions at the outer root, add the inner repository as an extra directory, or guard it with `guard init`.
  - `guard/run` cannot be found from inside a nested clone, so the skill tells the agent to look upward for an enclosing `guard/` before working without one.
- **Vendoring.** Vendoring the skill into each project is deferred. It helps only on hosts where `install.sh` never ran, and it would not have helped here.

## 8. Continuity across sessions

The agent tool keys transcripts and memory by path, outside this repository. The change is to the present skill only:
- the ledger is named after the run id or branch, never a date;
- the ledger is committed at a pause or handoff.

Handoff files belong to pstack's Pause safely playbook.

## 9. One checklist per action

Skill bodies load only when invoked. `AGENTS.md` is the per-turn cost, and it is short. Three changes replace a help command:
- every FAIL and RIPPLE line carries its remedy;
- the skill stops restating what preflight checks;
- `guard/README.md` holds a per-action checklist for human audit. The update now merges that file, so the checklist reaches old projects.

## 10 to 12. Review, merge, and the needs-you queue

These items let an agent take its own change from a branch to a merge, and hand a person only the steps that need one. [autonomy.md](autonomy.md) explains what each command checks and where the protection stops. `merge_policy` is an optional budget key with the default `autonomous`, so existing projects reach it through `guard init --update`.
