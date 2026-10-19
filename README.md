# harness4research

harness4research keeps an auditable record of what AI agents run on a research repository and on shared compute, and refuses at the point of action: a job over its budget or outside the scheduler, a merge that changes the guardrails, a number reported without evidence. Each refusal names the command to run instead, and a queue holds the steps only a person can take. The rules live in git, GitHub, and the scheduler, so they apply the same way to Claude Code, Codex, Cursor, and agents on local models.

What it does not check, it does not prevent. In our benchmark of a local model, rule-breaking fell where a check exists and not elsewhere ([re-scored results](eval/experiments/baseline-r2-rescored.md)). The [enforcement audit](docs/enforcement-audit.md) attacks each rule with a script: 66 held, 2 bypassed of 68 rows.

## Who it is for

It is for research groups whose agents write code, submit jobs, and report results. The scripts support these places to run compute:

- A Slurm cluster. `guard run` prices each job and submits it through `sbatch`.
- A GPU box without a scheduler. On a host named in `launch_hosts`, the same `guard run` line runs the job, boxed, under a supervisor that enforces its limits.
- A cloud instance, such as one on AWS, works as a GPU box without a scheduler. This is not tested yet.
- Another HPC scheduler, such as PBS or Flux. Not supported yet. The broker's scheduler calls need a small port in `lib/broker/`.

## Try it in two minutes

The walkthrough builds a guarded throwaway project and takes one experiment through the guard. It uses a fake `sbatch`, so it needs no cluster and no GitHub account, only bash, git, and python3.

```shell
git clone https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/examples/quickstart/run.sh ~/guard-quickstart
```

You see numbered steps. In one, the agent raises its own walltime cap, and `guard run` refuses the job with two lines: a code and its reason, then the command to run instead:

```text
H4R-R06 guard/budget.card differ from main and the human owns them
git checkout origin/main -- guard/budget.card
```

After the agent runs that line, `guard run` writes the run's question card, prices the job and submits it, and `guard wait` follows it to `COMPLETED`. The fence passes the report because every number names its file. The summary ends with the paths to the question card, the report, and the manifest, and with a `guard atlas` command that draws the project as one page. [examples/quickstart/README.md](examples/quickstart/README.md) explains each step.

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
| `guard init <repo> --update [--force]` | your machine | propose the new `harness:` pin, or once, the move from schema 7 to schema 8 |
| `guard version` | anywhere | this harness's release and schema; inside a project, which side is behind |
| `guard archive <repo>` | your machine | tag every remote branch |
| `guard doctor [repo]` | your machine, the agent's shell, the cluster | read-only checklist of the setup: pass, FAIL, or cannot check from here, with a remedy for each; exit 1 when an item fails |
| `guard atlas [repo] [--out f.html \| --serve PORT\|SOCKET]` | anywhere with the repo | read-only page of runs, jobs, question cards, receipts, and what needs you ([docs/atlas.md](docs/atlas.md)) |
| `guard enter <dir> [--agent NAME] [--no-tty] -- <cmd...>` | your machine, a login node | runs any agent (or `bash`, to look at a tree an agent wrote) in a sandbox built by `lib/box.sh`: `<dir>` read-write and a home of the agent's own, both at their real paths; no network, `~/.ssh`, `~/.config/gh`, `~/.config/guard`, ssh-agent or munge; `sbatch` and friends reach the scheduler only through the broker, and the session's allowlist only through its proxy: `net_allow:` in `guard/budget.card` on `main` (PyPI and conda when the card does not say, D4) plus the profile's `net:` hosts. With `--no-tty`, a profile's `model:` line sends the model through the broker's gateway, which adds the key from `~/.config/guard/models/` outside the sandbox (D3). A pre-flight probe checks those walls from inside first and starts nothing if one fails. Profiles in `~/.config/guard/agents/` list binaries and config to copy; a CLI login is bound only without `--no-tty` |
| `guard broker setup` | once per host | the broker's state and signing key in `~/.local/state/guard/`, the default profiles for claude, codex and cursor-agent, the model upstreams for anthropic and openai in `~/.config/guard/models/` (put each key beside its file, mode 0600), and a sandbox self-test |
| `guard broker status \| stop` | that host | whether the broker answers, its sessions with the limits each got (a scope's wall or prlimit's speed bump), live jobs and recent refusals (exit 1 when down); `stop` ends it, and every session's sockets then refuse. `guard enter` starts it under `systemd-run --user` where a user manager answers, else in tmux; `GUARD_BROKER_LAUNCH=tmux` picks tmux, as on skynet (D7) |
| `guard needs-you [add \| show \| ack \| done \| dismiss]` | any git repository | the queue of what only you can do, check, or approve, shared by every worktree in `<git common dir>/guard/needs-you.tsv`; `add` refuses a relative, missing, or temporary path |
| `guard needs-you --remind` | any git repository | one line per open item, and nothing when the queue is empty |
| `guard hooks install claude [--user \| --project] [--dry-run]` | your machine | add Claude Code hooks that show open needs-you items at session start and on every prompt; keeps your other settings |
| `guard config [list \| get KEY \| set KEY VALUE]` | anywhere | your settings in `~/.config/guard/config`: `reviewer` (`proprietary` or `local`), `reviewer_cmd_proprietary`, `reviewer_cmd_local`, `reviewer_model`, `review_rounds`, `review_small_lines`, `review_batch_max`, `ship_interval_hours`, and `merge_policy` for repositories without a guard |
| `guard pr open --title T --request F --plan F --test CMD --body F [--scope F] [--item ID]` | the repository | writes the branch's brief in `.git/guard/briefs/` from the user's words, pushes the branch, and opens its pull request, titled `[ID] T` with `--item`; refuses a body that repeats a line of the request |
| `guard review <pr>` | the repository | runs the reviewer in a fresh worktree against the brief in `.git/guard/briefs/`; it may commit small fixes, which this command pushes; records the verdict in `.git/guard/reviews.tsv` and comments it on the pull request; exit 0 on approve |
| `guard merge <pr>` | the repository | squash-merges at the reviewed head only when `merge_policy` is `autonomous`, the gh login is not an admin, a ruleset requires a pull request (and `guard-fence / fence` in a guarded project), the pull request is ready, every check passed, and the review approved; otherwise queues the merge for a human |
| `guard review --batch` | the repository | sorts every open pull request into a tier and reviews the ones without a verdict at their head: records approve without a model, small ones share one read-only reviewer session, large ones get `guard review <pr>`, and new question cards and guard changes go to you as 🩺 items ([docs/autonomy.md](docs/autonomy.md#tiers-and-batches)) |
| `guard merge --batch` | the repository | runs `guard merge` on every pull request approved at its head, lowest number first, and queues one item for the ones it refuses |
| `guard ship [--now]` | the repository | `guard review --batch`, then `guard merge --batch`, at once when a records pull request has passed every check, and otherwise once `review_batch_max` pull requests wait or the oldest is `ship_interval_hours` old; until then it refreshes the question card digest and says when the batch is due |
| `guard run runs/<id> --why S [--cause C] -- <sbatch options> <script> [args]` | the agent's shell | price and submit a job, or launch it on a host in `launch_hosts`; or refuse with the command to run instead |
| `guard wait <job_id> \| -- <command>` | the agent's shell | wait, and return every 5 minutes with the last 20 lines; `guard wait --stop <host job>` stops a host job |
| `guard ask Q --default D --deadline 5m\|30m\|2h` | the agent's shell | a question for a person, answered by its default when nobody answers in time |
| `guard status` | the agent's shell | what runs, what is blocked, the last refusal, the budget, the branch, and the next command |
| `guard/run manifest <run_dir> "$0" "$@"` | inside a job | provenance record |
| `guard/run fence [base] [head]` | anywhere, CI | merge inspector |
| `guard/run fence --ledger <runs/<id>/execution.tsv>` | anywhere | checks one execution ledger by the fence's rules before you commit it |
| `guard/run code <repo> <commit>` | cluster | absolute path of a clean worktree at that commit |

`guard manifest`, `guard fence` and `guard code` on PATH run the enclosing project's `guard/run` from its protected branch, and refuse outside a guarded project. Every refusal is two lines, a code and a command; [docs/refusals.md](docs/refusals.md) lists them. `guard preflight`, `ripples`, `launch` and `card`, gone in schema 8, print H4R-R09 with the `guard run` line to use instead.

## What `init` adds to a repository

```text
AGENTS.md                         short list of landmines every agent reads (CLAUDE.md points to it)
FACTS.md                          verified facts only, each with evidence that guard review checks
guard/budget.card                 computing budget, per-job limits, merge_policy, and the harness: pin
guard/watch.list                  verifier, test, and threshold paths agents may not edit
guard/run                         runs the script of the pinned harness release: manifest, fence, code, receipts-check
guard/harness-<pin>.sh            offline only: the pinned release's scripts, for a host that cannot reach the harness
guard/SURVEY.md                   the survey, for the cleanup
.github/workflows/guard-fence.yml runs the fence on every pull request, from the harness release guard/budget.card pins
runs/_template/                   report and execution ledger templates
```

`init` never touches your checked-out tree, never overwrites a file, and never pushes. `guard archive <repo>` tags every branch before a cleanup and prints, without running, the commands to publish the tags and delete merged branches.

## Updating a guarded project

Pull the harness, then propose the update:

```shell
git -C ~/harness4research pull --recurse-submodules
guard init ~/path/to/your-repo --update
```

The update arrives on branch `guard/update` in a new worktree, like `init`. For a pinned project it changes one line, the `harness:` pin in `guard/budget.card`; an offline project also gets the new release's `guard/harness-<pin>.sh` in place of the old one. A schema 7 project gets the move to schema 8 once: the new card keys appended, `guard/run` and the fence workflow replaced, `runs/_template/question.card` deleted, `AGENTS.md` above its `## Project landmines` heading replaced, and `guard/VERSION` rewritten ([release notes](docs/releases/v8.0.md)). Your card values, `watch.list`, and the landmines stay as they are. A project older than schema 7 moves with v7.0 first; the update prints the command.

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

- [docs/README.md](docs/README.md): every page under `docs/` in one line, including the current plan, its status, and the rules for agents working here
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

bash 4 or later and git 2.30 or later on your machine and the cluster. python3 for `guard needs-you`, `guard hooks`, `guard atlas`, and the walkthrough. Slurm on the cluster. GitHub for the fence, and `gh` for the printed pull request commands, `guard review`, and `guard merge`. `guard review` also needs a reviewer: Claude Code or Cursor's agent CLI, or a command you name. `tests/run.sh` needs python3 with PyYAML, jq, and the repository's full history, since it guards a project with v6.1 and migrates it: clone without `--depth`, or run `git fetch --unshallow`. `eval/env/selftest.sh` and `eval/audit/run.py` need bubblewrap with unprivileged user namespaces. Each checks what it needs first and, when something is missing, prints one line with the fix and exits 64.

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
