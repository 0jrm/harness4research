# harness4research

Guardrails for AI agents that run computational science on shared clusters. One command adds them to a research repository, and they apply to Claude Code, Cursor, Codex, and any other agent, because they live in git, in GitHub's merge check, and in the cluster scheduler instead of in any one tool.

## Quickstart

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

### 4. Protect the default branch

The `guard-fence / fence` check exists only after the merge in step 3, and GitHub offers it in the ruleset form only after it has run once. Open any small pull request first, then:

1. On GitHub, open the repository and go to **Settings → Rules → Rulesets → New ruleset → New branch ruleset**.
2. Set **Enforcement status** to **Active**. Under **Target branches**, choose **Add target → Include default branch**.
3. Select **Require a pull request before merging**.
4. Select **Require status checks to pass**, choose **Add checks**, type `fence`, and pick `guard-fence / fence`.
5. Under **Bypass list**, add **Repository admin** and nobody else. Save.

### 5. Give agents weaker credentials

If an agent runs with your `gh` login or SSH key, it can use your bypass. Give it its own token:

1. On GitHub, go to **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. Under **Repository access**, choose **Only select repositories** and pick the guarded repositories.
3. Under **Permissions**, set **Contents** and **Pull requests** to **Read and write**. Leave **Administration** at **No access**.
4. Run agents with that token as `GH_TOKEN`, an HTTPS remote, and no `SSH_AUTH_SOCK`.

To check it, open a pull request that edits `guard/budget.card`, so the fence fails, and run `GH_TOKEN=<agent token> gh pr merge <number> --admin --merge`. GitHub must refuse. Close the pull request afterwards.

### 6. Cap the cluster account

Ask your cluster admins for a Slurm sub-account with a hard core-hour cap, and put it in `guard/budget.card` as `account`. Preflight forces every job onto it, and the scheduler enforces the cap even for jobs submitted without preflight. Email template: [docs/cluster-subaccount-request.md](docs/cluster-subaccount-request.md). [docs/enforcement.md](docs/enforcement.md) explains why steps 4 to 6 matter.

From then on, agents submit jobs with `guard/run preflight`, check on them with `guard/run ripples`, and start each experiment with a committed question card. The skill tells them how.

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
| `guard atlas [repo] [--out f.html \| --serve PORT\|SOCKET] [--runs GLOB] [--title NAME] [--head-only]` | anywhere with the repo | read-only chart: hosts and fences, budget, ripples matrix, card map, per-run lifeline and receipts. Reads HEAD plus uncommitted run files; `--json` writes the data the page is drawn from ([docs/atlas-json.md](docs/atlas-json.md)); `--serve` re-surveys on reload at most every `--every` seconds; give it a socket path (contains `/`) instead of a port on a shared login node, since the socket is 0600 and `ssh -L 8765:/path/to/sock host` forwards it |
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
