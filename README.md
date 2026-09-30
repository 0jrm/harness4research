# harness4research

Guardrails for AI agents that run computational science on shared clusters. One command adds them to a research repository, and they apply to Claude Code, Cursor, Codex, and any other agent, because they live in git, in GitHub's merge check, and in the cluster scheduler instead of in any one tool.

## Quickstart

```shell
git clone --recurse-submodules https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/install.sh
guard survey ~/path/to/your-repo        # read-only report of stale branches, docs, and duplicates
guard init ~/path/to/your-repo          # proposes the guard on a new branch and worktree
```

Then, in the worktree that `init` printed:

1. Read `guard/SURVEY.md`.
2. Fill in `guard/budget.card` and `guard/watch.list`, commit, push, and open the pull request. Merge it yourself.
3. On GitHub, protect the default branch. Require a pull request and the `guard-fence / fence` check.
4. Give agents weaker credentials than yours, and ask your cluster for a capped sub-account. See [docs/enforcement.md](docs/enforcement.md).

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
| `guard init <repo> --update` | your machine | propose refreshed guard scripts |
| `guard archive <repo>` | your machine | tag every remote branch |
| `guard/run preflight <run_dir> <job.sh> [sbatch options]` | cluster | submit or refuse |
| `guard/run ripples <run_dir>` | cluster | warning signs |
| `guard/run manifest <run_dir> "$0" "$@"` | inside a job | provenance record |
| `guard/run fence [base] [head]` | anywhere, CI | merge inspector |

## Documentation

- [docs/why.md](docs/why.md): the problem, alternatives, costs, and limits
- [docs/enforcement.md](docs/enforcement.md): the four layers and the credential gap
- [docs/prompts.md](docs/prompts.md): prompts for the cleanup and the first run
- [docs/live-tests/runhub.md](docs/live-tests/runhub.md) and [docs/live-tests/gom-da-workspace.md](docs/live-tests/gom-da-workspace.md): step-by-step acceptance tests
- [docs/cluster-subaccount-request.md](docs/cluster-subaccount-request.md): email template for a capped account
- [skills/safe-autonomous-hpc-science/SKILL.md](skills/safe-autonomous-hpc-science/SKILL.md): what agents read

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
