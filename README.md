# harness4research

Guardrails for AI agents that run computational science on shared clusters. One command adds them to a research repository, and they apply to Claude Code, Cursor, Codex, and any other agent, because they live in git, in GitHub's merge check, and in the cluster scheduler instead of in any one tool.

An agent works inside a guarded repository the way it always does. Before it submits a job, `guard/run preflight` checks the job against a budget card and a committed question card. While jobs run, `guard/run ripples` reports warning signs, and any ripple stops new submissions. On GitHub, a fence check blocks a merge that edits the guard. [What a ripple is](#what-a-ripple-is) explains the warning signs.

## Quickstart

```shell
git clone --recurse-submodules https://github.com/0jrm/harness4research ~/harness4research && ~/harness4research/install.sh
guard survey ~/path/to/your-repo        # read-only report of stale branches, docs, and duplicates
guard init ~/path/to/your-repo          # proposes the guard on a new branch and worktree
```

`init` prints what to fill in and how to open the pull request. Steps 1 to 3 below give the details. After you merge, [make the guard enforceable](docs/enforceable.md). That page starts with `guard doctor`, which checks the setup and links the fix for each open item.

## Set up a repository, step by step

### 1. Install

```shell
git clone --recurse-submodules https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/install.sh           # add --pstack skip if you already use the pstack plugin
guard version                           # prints this repo's commit and pstack's
```

`install.sh` puts `guard` in `~/.local/bin` and links the skills into `~/.agents/skills`, `~/.claude/skills`, and `~/.cursor/skills`. To check that an agent sees them, open the agent and ask which skills it has. `safe-autonomous-hpc-science` and `present` should be in the list. `/present` asks for a present mid-task. If your agent reads skills from another folder, rerun with `--skills-dir <that folder>`.

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
4. Commit, then push and open the pull request with the two commands `init` printed. Merge it yourself.

Next, [make the guard enforceable](docs/enforceable.md): protect the default branch, give agents weaker credentials, and cap the cluster account.

From then on, agents submit jobs with `guard/run preflight`, check on them with `guard/run ripples`, and start each experiment with a committed question card. The skill tells them how.

## What a ripple is

A ripple is a warning sign about one run. `guard/run ripples <run_dir>` prints one line per check, each with a status:

- `RIPPLE`: something is wrong, such as a failed job, a question card edited after it froze, a guard file changed on the branch, or spend above 80% of the budget. The command exits 1, and preflight refuses new submissions until the cause is handled.
- `HANDLED`: a failure that an incident write-up in `runs/<id>/incidents/`, or a `restart` or `resume` row in `runs/<id>/execution.tsv`, explains.
- `UNCHECKED`: the check could not see its input from this host, for example `sacct` off the cluster. An unchecked line is not a pass.
- `PASS`: the check saw its input and found nothing.

## What `init` adds to a repository

```text
AGENTS.md                         short list of landmines every agent reads (CLAUDE.md points to it)
FACTS.md                          verified facts only, each with evidence; you merge every line
guard/budget.card                 computing budget and per-job limits
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

## How it works

Each rule sits where every agent must pass, and each layer covers a gap in the layer below.

- `AGENTS.md` and the skill tell an honest agent the rules.
- The scripts refuse bad submissions and report edited limits. They always run the protected branch's copy, so an agent that edits them on its own branch changes nothing.
- The CI fence blocks merges that change the guard, workflows, watched paths, or started question cards, or that report numbers without an artifact path.
- A capped cluster sub-account stops overspending by anyone, including an agent that skips the scripts.

The walls are only as strong as the gap between your credentials and the agent's. [docs/enforcement.md](docs/enforcement.md) explains that gap and how to close it. [docs/why.md](docs/why.md) covers the alternatives, the costs in tokens and compute, and what you get for them.

## pstack

[pstack](https://github.com/cursor/plugins/tree/main/pstack) is Lauren Tan's skill stack for rigorous agent engineering. This repository loads the [Claude Code and Codex port](https://github.com/michael-denyer/pstack-claude) as a git submodule at `vendor/pstack`. `install.sh` updates it to the latest upstream commit on every run, or keeps the recorded commit with `--pinned`. It links pstack's skills into `~/.agents/skills`, and it links this repository's skill into `~/.agents/skills`, `~/.claude/skills`, and `~/.cursor/skills` where those tools are installed.

If you use the pstack plugin in Claude Code, Codex, or Cursor, run `install.sh --pstack skip` so each agent loads pstack once. The skill works without pstack, but uses its playbooks when present.

## Commands

| Command | Where | What it does |
|---|---|---|
| `guard survey <repo>` | your machine | read-only inventory |
| `guard init <repo>` | your machine | propose the guard on a new branch |
| `guard init <repo> --update [--force]` | your machine | propose the newer guard as a three-way merge that keeps your edits |
| `guard version` | anywhere | this harness's release and schema; inside a project, which side is behind |
| `guard archive <repo>` | your machine | tag every remote branch |
| `guard doctor [repo]` | your machine, the agent's shell, the cluster | read-only checklist of the Quickstart: pass, FAIL, or cannot check from here, with a remedy for each; exit 1 when an item fails |
| `guard/run preflight <run_dir> <job.sh> [sbatch options]` | cluster | submit or refuse |
| `guard/run ripples <run_dir>` | cluster | warning signs |
| `guard/run manifest <run_dir> "$0" "$@"` | inside a job | provenance record |
| `guard/run fence [base] [head]` | anywhere, CI | merge inspector |
| `guard/run code <repo> <commit>` | cluster | absolute path of a clean worktree at that commit |
| `guard/run launch <run_dir> --time=T --gpus=I,J\|none --mem=GB -- <cmd>` | a host in `launch_hosts` | run a job under a supervisor, or refuse |
| `guard/run launch --stop <job_id> [--reason=<text>]` | that host | stop a launched job gently; `--list [run_dir]` shows them |

`guard preflight`, `guard ripples`, `guard manifest`, `guard fence`, `guard code`, and `guard launch` on PATH run the enclosing project's `guard/run` from its protected branch, and refuse outside a guarded project.

## Updating a guarded project

Pull the harness, then propose the update:

```shell
git -C ~/harness4research pull --recurse-submodules
guard init ~/path/to/your-repo --update
```

The update arrives on branch `guard/update` in a new worktree, like `init`. Each guard script, `guard/run`, `guard/README.md`, and the fence workflow are merged three ways, against the templates that installed your project. Your edits are kept. New budget keys arrive with their defaults. Your card values, `watch.list`, `FACTS.md`, and `AGENTS.md` are not changed. If your edit and the harness changed the same lines, the command exits 3 and lists the files with conflict markers. Resolve them in the worktree before you push. `guard/run` refuses to run a script that still has markers.

Pushing a change to `.github/workflows/` needs a token with the `workflow` scope (`gh auth refresh -s workflow`). To roll back, revert the update pull request. [docs/compatibility.md](docs/compatibility.md) lists what an update may and may not change.

## Documentation

- [docs/why.md](docs/why.md): the problem, alternatives, costs, and limits
- [docs/enforceable.md](docs/enforceable.md): steps 4 to 6, protecting the branch, weaker agent credentials, and a capped account, checked by `guard doctor`
- [docs/enforcement.md](docs/enforcement.md): the four layers and the credential gap
- [docs/prompts.md](docs/prompts.md): prompts for the cleanup and the first run
- [docs/live-tests/runhub.md](docs/live-tests/runhub.md) and [docs/live-tests/gom-da-workspace.md](docs/live-tests/gom-da-workspace.md): step-by-step acceptance tests
- [docs/cluster-subaccount-request.md](docs/cluster-subaccount-request.md): email template for a capped account
- [docs/compatibility.md](docs/compatibility.md): what stays stable across releases, and how an update merges
- [docs/roadmap.md](docs/roadmap.md): the designed next steps, from field feedback
- [skills/safe-autonomous-hpc-science/SKILL.md](skills/safe-autonomous-hpc-science/SKILL.md): what agents read for experiment work
- [skills/present/SKILL.md](skills/present/SKILL.md): the `/present` block a person judges from the chat alone

## Requirements

bash 4 or later and git 2.30 or later on your machine and the cluster. Slurm on the cluster. GitHub for the fence, and `gh` for the printed PR commands. `tests/run.sh` needs python3 with PyYAML.

## Test

```shell
tests/run.sh
```

The suite builds throwaway repositories and a fake Slurm and checks each refusal and warning.

## Uninstall

```shell
find ~/.agents/skills ~/.claude/skills ~/.cursor/skills ~/.local/bin -maxdepth 1 -lname "$HOME/harness4research/*" -delete
```

## License

MIT. pstack is MIT-licensed by its authors and included as a submodule, not copied.
