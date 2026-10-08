# harness4research

harness4research adds guardrails to a research repository so that AI agents can run experiments on shared compute without a person watching every step. A script checks each job against a budget and a committed question card before it runs, a CI check blocks merges that change the guardrails or that report numbers without evidence, and a queue holds the steps that only a person can take. The rules live in git, GitHub, and the scheduler, so they apply the same way to Claude Code, Codex, Cursor, and agents on local models.

## Who it is for

It is for research groups whose agents write code, submit jobs, and report results. The scripts support these places to run compute:

- A Slurm cluster. `guard/run preflight` submits through `sbatch`.
- A GPU box without a scheduler. `guard/run launch` runs each job under a supervisor that enforces its limits.
- A cloud instance, such as one on AWS, works as a GPU box without a scheduler. This is not tested yet.
- Another HPC scheduler, such as PBS or Flux. Not supported yet. Preflight and ripples need a small port in `guard/bin/`.

## Try it in two minutes

The walkthrough builds a guarded throwaway project and takes one experiment through the guard. It uses a fake `sbatch`, so it needs no cluster and no GitHub account, only bash, git, and python3.

```shell
git clone https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/examples/quickstart/run.sh ~/guard-quickstart
```

You see six numbered steps. In step 3, the agent raises its own walltime cap, and preflight refuses the job:

```text
== 3. A refusal: the agent raises its own walltime cap
PREFLIGHT FAIL: guard/ differs from origin/main: M guard/budget.card; restore it with git restore --source=origin/main --staged --worktree -- guard, commit, and remove any untracked file under guard/
== 4. Preflight, then the job
PREFLIGHT OK: cheap-evo nodes=1 time=5m tasks=1 projected=10 spent=30 queued=3072 available=8500
```

Then the job runs, the fence passes the report because every number names its file, and ripples checks the finished job. The summary ends with the paths to the question card, the report, and the manifest, and with a `guard atlas` command that draws the project as one page. [examples/quickstart/README.md](examples/quickstart/README.md) explains each step.

## Set it up

### 1. Install

```shell
git clone https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/install.sh
guard version
```

If you cloned the repository for the walkthrough, skip the first line. `install.sh` puts `guard` in `~/.local/bin`. It links this repository's skills into `~/.agents/skills`, and also into `~/.claude/skills` and `~/.cursor/skills` when `~/.claude` and `~/.cursor` exist. [pstack](#pstack) is optional, and `--pstack link` adds it. If your agent reads skills from another folder, rerun it with `--skills-dir <that folder>`. To check that an agent sees the skills, open it and ask which skills it has. `safe-autonomous-hpc-science`, `present`, `review-and-merge`, and `guard-onboard` should be in the list.

### Let your agent walk you through steps 2 to 4

Open your agent in the repository you want to guard and ask it to set up harness4research. The `guard-onboard` skill then does these steps with you:

1. It runs `guard version`, `guard doctor`, and `guard survey` and reads their output.
2. It asks only what those commands cannot show: which agents you use, where your compute runs, the merge policy, and the reviewer.
3. It proposes a numbered plan with the exact command for each change.
4. It applies each change that an agent can make, such as `guard init`, `guard config set`, or `guard hooks install claude`, after you confirm it.
5. It queues each step that only you can take, such as creating a token or a ruleset, as a 🩺 item with the click path.
6. It runs `guard doctor` again to show what is still open.

Later, ask it to check your setup, and it reruns the same steps and proposes only what changed. To do the steps yourself, read on.

### 2. Propose the guard

```shell
guard survey ~/path/to/your-repo        # read-only report of stale branches, docs, and duplicates
guard init ~/path/to/your-repo          # proposes the guard on a new branch and worktree
```

`init` creates a worktree next to your repository, `<repo>.guard-init`, on branch `guard/init`, and prints the next commands. Your checked-out tree is not touched. If the repository already has an `AGENTS.md`, `init` leaves it alone and writes its version to `guard/AGENTS.proposed.md`, which you merge into yours or delete before you commit.

### 3. Fill in the guard and merge it

In the worktree:

1. Read `guard/SURVEY.md`. It lists what an agent could mistake for current truth.
2. Replace every `<placeholder>` in `guard/budget.card` with your cluster values. Preflight refuses to submit while any placeholder is left. If the repository submits no jobs, leave them.
3. Add to `guard/watch.list` the files agents must not edit: verifiers, contract tests, thresholds. Use one git pathspec per line. List specific files, not all of `tests/`, or agents cannot add tests.
4. Commit, then push and open the pull request with the two commands `init` printed. Merge it yourself. A change to `guard/` is always a person's merge.

### 4. Make it enforceable, and pick how agents merge

[docs/enforceable.md](docs/enforceable.md) gives the steps: protect the default branch, give agents a token without admin rights, and cap the cluster account. `guard doctor` checks each one.

By default, an agent that finishes a change opens a pull request and runs `guard ship`. Once a batch is due, `guard ship` reviews the open pull requests by tier and merges each one only when the review, the checks, the ruleset, and the agent's credentials all allow it. To click every merge yourself, set `merge_policy: semi-manual` in `guard/budget.card` through a pull request. To review with a local model instead of `claude`, or `cursor-agent` when `claude` is missing or fails, name its command:

```shell
guard config set reviewer local
guard config set reviewer_cmd_local 'codex exec --oss --local-provider ollama -m <model> --sandbox danger-full-access'
```

If you use Claude Code, also run `guard hooks install claude` so it shows open needs-you items at session start and on every prompt. [docs/autonomy.md](docs/autonomy.md) explains review, merge, and the queue.

## Use it with your agent

Every agent reads the rules from `AGENTS.md`, which `guard init` writes. The table shows how each tool finds them and the skills.

| Tool | Instruction file | Skills folder that `install.sh` links | Needs-you reminder |
|---|---|---|---|
| Claude Code | `CLAUDE.md`, which `guard init` writes as `@AGENTS.md` to import it | `~/.claude/skills` | hooks from `guard hooks install claude`, and the `AGENTS.md` line |
| Codex | `AGENTS.md` | `~/.agents/skills` | the `AGENTS.md` line |
| Cursor | `AGENTS.md` and `CLAUDE.md` | `~/.cursor/skills` | the `AGENTS.md` line |
| Local models through Codex (`codex --oss --local-provider ollama` or `lmstudio`) | `AGENTS.md` | `~/.agents/skills` | the `AGENTS.md` line |
| Other local agents | `AGENTS.md`, if the agent reads it | point `install.sh --skills-dir` at its folder | the `AGENTS.md` line, if read |

The `AGENTS.md` line tells the agent to run `guard needs-you --remind` at session start and to show any open items first. How each row was checked:

- Codex: codex-cli 0.145.0, with `codex debug prompt-input` in a guarded project. The prompt included `AGENTS.md` and the skills in `~/.agents/skills`, with the default provider and with `model_provider=ollama`. Whether a local model follows them is not verified.
- Cursor: the `cursor-agent` CLI, version 2026.10.01, listed `AGENTS.md`, `CLAUDE.md`, and skills that exist only in `~/.cursor/skills`. The Cursor editor is not verified.
- Claude Code: a Claude Code session listed skills that exist only in `~/.claude/skills`. The `@AGENTS.md` import in `CLAUDE.md` is not verified in a test run.
- Other local agents: not verified.

## Status

One person uses harness4research so far, and it has had one multi-day field session, an ML-training session whose lessons are in [docs/roadmap.md](docs/roadmap.md). The test suite checks each refusal and warning against a fake Slurm and a fake GitHub. No one has yet measured whether the harness improves agent success or accuracy. [docs/evaluation.md](docs/evaluation.md) proposes how to measure it on local models.

## How it works

Each rule sits where every agent must pass, and each layer covers a gap in the layer below.

- `AGENTS.md` and the skills tell an honest agent the rules.
- The scripts refuse bad submissions and report edited limits. They run the protected branch's copy, so editing them on a branch has no effect by itself. This layer is a speed bump, not a wall: an agent can set `HPC_GUARD_LOCAL=1` or `HPC_GUARD_REF=HEAD`, or move `origin/main` in its clone with `git update-ref`, and run its own copy.
- The CI fence blocks merges that change the guard, workflows, watched paths, or started question cards, or that report numbers without a path to an artifact committed on the branch.
- A capped cluster sub-account stops overspending by anyone, including an agent that skips the scripts.

`guard review` and `guard merge` are quality tools, not one of these layers. The review verdict lives in a local file an agent can write, and text in a pull request can steer the reviewer. The wall behind them is the GitHub ruleset that requires a pull request and the `guard-fence` check.

The walls are only as strong as the gap between your credentials and the agent's. [docs/enforcement.md](docs/enforcement.md) explains that gap and how to close it. [docs/why.md](docs/why.md) covers the alternatives, the costs in tokens and compute, and what you get for them.

## Commands

| Command | Where | What it does |
|---|---|---|
| `guard survey <repo>` | your machine | read-only inventory |
| `guard init <repo>` | your machine | propose the guard on a new branch |
| `guard init <repo> --update [--force]` | your machine | propose the newer guard as a three-way merge that keeps your edits |
| `guard version` | anywhere | this harness's release and schema; inside a project, which side is behind |
| `guard archive <repo>` | your machine | tag every remote branch |
| `guard doctor [repo]` | your machine, the agent's shell, the cluster | read-only checklist of the setup: pass, FAIL, or cannot check from here, with a remedy for each; exit 1 when an item fails |
| `guard atlas [repo] [--out f.html \| --serve PORT\|SOCKET]` | anywhere with the repo | read-only page of runs, ripples, question cards, receipts, and what needs you ([docs/atlas.md](docs/atlas.md)) |
| `guard needs-you [add \| show \| ack \| done \| dismiss]` | any git repository | the queue of what only you can do, check, or approve, shared by every worktree in `<git common dir>/guard/needs-you.tsv`; `add` refuses a relative, missing, or temporary path |
| `guard needs-you --remind` | any git repository | one line per open item, and nothing when the queue is empty |
| `guard hooks install claude [--user \| --project] [--dry-run]` | your machine | add Claude Code hooks that show open needs-you items at session start and on every prompt; keeps your other settings |
| `guard config [list \| get KEY \| set KEY VALUE]` | anywhere | your settings in `~/.config/guard/config`: `reviewer` (`proprietary` or `local`), `reviewer_cmd_proprietary`, `reviewer_cmd_local`, `reviewer_model`, `review_rounds`, `review_small_lines`, `review_batch_max`, `ship_interval_hours`, and `merge_policy` for repositories without a guard |
| `guard review <pr>` | the repository | runs the reviewer in a fresh worktree against the brief in `.git/guard/briefs/`; it may commit small fixes, which this command pushes; records the verdict in `.git/guard/reviews.tsv` and comments it on the pull request; exit 0 on approve |
| `guard merge <pr>` | the repository | squash-merges at the reviewed head only when `merge_policy` is `autonomous`, the gh login is not an admin, a ruleset requires a pull request (and `guard-fence / fence` in a guarded project), the pull request is ready, every check passed, and the review approved; otherwise queues the merge for a human |
| `guard review --batch` | the repository | sorts every open pull request into a tier and reviews the ones without a verdict at their head: records approve without a model, small ones share one read-only reviewer session, large ones get `guard review <pr>`, and new question cards and guard changes go to you as 🩺 items ([docs/autonomy.md](docs/autonomy.md#tiers-and-batches)) |
| `guard merge --batch` | the repository | runs `guard merge` on every pull request approved at its head, lowest number first, and queues one item for the ones it refuses |
| `guard ship [--now]` | the repository | `guard review --batch`, then `guard merge --batch`, once `review_batch_max` pull requests wait or the oldest is `ship_interval_hours` old; until then it refreshes the question card digest and says when the batch is due |
| `guard/run preflight <run_dir> <job.sh> [sbatch options]` | cluster | submit or refuse |
| `guard/run ripples <run_dir>` | cluster | warning signs |
| `guard/run manifest <run_dir> "$0" "$@"` | inside a job | provenance record |
| `guard/run fence [base] [head]` | anywhere, CI | merge inspector |
| `guard/run code <repo> <commit>` | cluster | absolute path of a clean worktree at that commit |
| `guard/run launch <run_dir> --time=T --gpus=I,J\|none --mem=GB -- <cmd>` | a host in `launch_hosts` | run a job under a supervisor, or refuse |
| `guard/run launch --stop <job_id> [--reason=<text>]` | that host | stop a launched job gently; `--list [run_dir]` shows them |

`guard preflight`, `guard ripples`, `guard manifest`, `guard fence`, `guard code`, and `guard launch` on PATH run the enclosing project's `guard/run` from its protected branch, and refuse outside a guarded project.

## What a ripple is

A ripple is a warning sign about one run. `guard/run ripples <run_dir>` prints one line per check, each with a status:

- `RIPPLE`: something is wrong, such as a failed job, a question card edited after it froze, a guard file changed on the branch, or spend above 80% of the budget. The command exits 1, and preflight refuses new submissions until the cause is handled.
- `HANDLED`: a failure that an incident write-up in `runs/<id>/incidents/` on the protected branch, or a `restart` or `resume` row in `runs/<id>/execution.tsv`, explains. An incident counts once its pull request merges, and a model reviews that pull request.
- `UNCHECKED`: the check could not see its input from this host, for example `sacct` off the cluster, a `sacct` that lists no job for the run, or a `quota_pct_cmd` whose path is not mounted here. An unchecked line is not a pass.
- `PASS`: the check saw its input and found nothing.

## What `init` adds to a repository

```text
AGENTS.md                         short list of landmines every agent reads (CLAUDE.md points to it)
FACTS.md                          verified facts only, each with evidence that guard review checks
guard/budget.card                 computing budget, per-job limits, and merge_policy
guard/watch.list                  verifier, test, and threshold paths agents may not edit
guard/run                         runs the protected branch's copy of each script
guard/bin/preflight.sh            submits a job only if it fits the budget and has a frozen question card
guard/bin/ripples.sh              reports warning signs; exit 1 stops new submissions
guard/bin/manifest.sh             records commit, modules, and inputs at the start of each job
guard/bin/fence.sh                the merge inspector, also run by CI
guard/bin/launch.sh               runs a job on a GPU box without a scheduler, under a supervisor that enforces its limits
guard/SURVEY.md                   the survey, for the cleanup
.github/workflows/guard-fence.yml runs the fence on every pull request
runs/_template/                   question card and report templates
```

`init` never touches your checked-out tree, never overwrites a file, and never pushes. `guard archive <repo>` tags every branch before a cleanup and prints, without running, the commands to publish the tags and delete merged branches.

## Updating a guarded project

Pull the harness, then propose the update:

```shell
git -C ~/harness4research pull --recurse-submodules
guard init ~/path/to/your-repo --update
```

The update arrives on branch `guard/update` in a new worktree, like `init`. Each guard script, `guard/run`, `guard/README.md`, and the fence workflow are merged three ways, against the templates that installed your project. Your edits are kept. New budget keys arrive with their defaults. Your card values, `watch.list`, `FACTS.md`, and `AGENTS.md` are not changed. If your edit and the harness changed the same lines, the command exits 3 and lists the files with conflict markers. Resolve them in the worktree before you push. `guard/run` refuses to run a script that still has markers.

Pushing a change to `.github/workflows/` needs a token with the `workflow` scope (`gh auth refresh -s workflow`). To roll back, revert the update pull request. [docs/compatibility.md](docs/compatibility.md) lists what an update may and may not change.

## pstack

[pstack](https://github.com/cursor/plugins/tree/main/pstack) is Lauren Tan's skill stack for rigorous agent engineering, MIT-licensed. It is optional. This repository records its canonical source, [github.com/cursor/plugins](https://github.com/cursor/plugins), as a git submodule at `vendor/cursor-plugins`, pinned to commit `ccb5507` (pstack 0.15.15). It replaces the third-party Claude Code and Codex port that the repository used before.

- In Cursor, install the plugin with `/add-plugin pstack`.
- In Claude Code or Codex, run `install.sh --pstack link`. It fetches the submodule at the pinned commit, links pstack's skills into each skills folder, and links its agents into `~/.claude/agents`. `--latest` takes upstream's newest commit instead.

Checked on 2026-10-08 with Claude Code, from the skill and agent lists in `claude -p`'s start-up message: all 51 skills and both agents load from those folders. `typescript-best-practices` loads only in projects with TypeScript files, as its own `paths` setting asks. The skills are written for Cursor, so some steps name things that Claude Code and Codex lack:

- Cursor's `agent-transcripts` folder (in 8 skills);
- the "Task tool" (7), which is the Agent tool in Claude Code;
- the `generalPurpose` subagent (6), which Claude Code calls `general-purpose`;
- Cursor's built-in `create-skill` (6);
- the `cursor-team-kit` plugin (8);
- grok as a default model.

Whether those steps still work outside Cursor is unmeasured.

Linked skills reach every agent session as instructions, so linking pstack means trusting cursor/plugins at the pinned commit. `--latest` means trusting whatever upstream's main holds that day. Read the upstream diff before moving the pin. The harness's own skills work without pstack, and use its playbooks when present.

## Documentation

- [docs/autonomy.md](docs/autonomy.md): how agents review and merge their own work, the tiers and batches of `guard ship`, the needs-you queue, and where that protection stops
- [docs/evaluation.md](docs/evaluation.md): a proposal to measure whether the harness helps agents on local models
- [docs/why.md](docs/why.md): the problem, alternatives, costs, and limits
- [docs/enforceable.md](docs/enforceable.md): protecting the branch, weaker agent credentials, and a capped account, checked by `guard doctor`
- [docs/enforcement.md](docs/enforcement.md): the four layers and the credential gap
- [docs/atlas.md](docs/atlas.md): drawing and serving a project's atlas page
- [docs/prompts.md](docs/prompts.md): prompts for the cleanup and the first run
- [docs/live-tests/runhub.md](docs/live-tests/runhub.md) and [docs/live-tests/gom-da-workspace.md](docs/live-tests/gom-da-workspace.md): step-by-step acceptance tests
- [docs/cluster-subaccount-request.md](docs/cluster-subaccount-request.md): email template for a capped account
- [docs/compatibility.md](docs/compatibility.md): what stays stable across releases, and how an update merges
- [docs/roadmap.md](docs/roadmap.md): the designed next steps, from field feedback
- [skills/safe-autonomous-hpc-science/SKILL.md](skills/safe-autonomous-hpc-science/SKILL.md): what agents read for experiment work
- [skills/present/SKILL.md](skills/present/SKILL.md): the `/present` block a person judges from the chat alone
- [skills/review-and-merge/SKILL.md](skills/review-and-merge/SKILL.md): how an agent hands a finished change to `guard ship`, or to `guard review` and `guard merge` when it is urgent
- [skills/guard-onboard/SKILL.md](skills/guard-onboard/SKILL.md): the agent-led setup and recheck, from `guard doctor` to a confirmed plan and the human-only 🩺 items

## Requirements

bash 4 or later and git 2.30 or later on your machine and the cluster. python3 for `guard needs-you`, `guard hooks`, `guard atlas`, and the walkthrough. Slurm on the cluster. GitHub for the fence, and `gh` for the printed pull request commands, `guard review`, and `guard merge`. `guard review` also needs a reviewer: Claude Code or Cursor's agent CLI, or a command you name. `tests/run.sh` needs python3 with PyYAML, and jq.

## Test

```shell
tests/run.sh
```

The suite builds throwaway repositories, a fake Slurm, and a fake `gh`, and checks each refusal and warning.

Run as root (uid 0), for example in a container, the suite skips the one case that needs file permissions to refuse a write, and its last line counts it as skipped.

## Uninstall

```shell
find ~/.agents/skills ~/.claude/skills ~/.cursor/skills ~/.local/bin -maxdepth 1 -lname "$HOME/harness4research/*" -delete
```

## License

MIT. pstack is MIT-licensed by its author and referenced as a submodule, not copied.
