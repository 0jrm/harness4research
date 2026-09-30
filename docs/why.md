# Why this exists and what it costs

## The problem

An AI agent on a shared cluster can burn an allocation in a night, fill a shared disk, delete files it thinks are stale, or report a result that its own files do not support. Each of these has happened to someone. An AI research system once tried to raise its own timeout instead of making its code faster. The failures come from missing safeguards more often than from bad intent.

## The idea

Make agent mistakes cheap, visible, and reversible, and put every rule where all agents must pass: git, the GitHub merge button, and the cluster scheduler. Rules placed there work the same for Claude Code, Cursor, Codex, and tools that do not exist yet. [enforcement.md](enforcement.md) describes each layer. [park-failures.md](../skills/safe-autonomous-hpc-science/references/park-failures.md) maps each rule to the failure it prevents.

## Alternatives considered

| Option | Why not |
|---|---|
| Trust the agent | Unverified results in a thesis, and no record of where a number came from |
| One long rulebook | Studies of `AGENTS.md` files find that unnecessary instructions lower agent success and raise cost; rules in text do not stop an agent that decides the limit is the problem |
| Each tool's permission settings | Three formats that drift apart, and agents often run with them off |
| Separate OS user or container | Correct in principle, and it broke runhub in practice; heavy to keep on a laptop and a cluster |
| Approve every action | Defeats unattended runs, and people stop reading approval prompts within days |

## Costs

- Tokens. `AGENTS.md` stays short and loads every session. The skill loads only for experiment work. Independent review of question cards and results adds roughly 15 to 30 percent to an experiment's model usage.
- Compute. A verification reserve of 10 to 15 percent of the budget, and a baseline rerun plus a small run before each full run, about 5 to 10 percent more.
- Your time. About an hour to install and configure, and five minutes per question card. Warning thresholds fire falsely until you tune them.

Runs named `explore-*` need no question card. Preflight caps them at one node, one hour, and one task by default, and the fence keeps their results out of reports until a carded run reproduces them.

## What you get

- A doomed full-scale run is caught at the small run, at a small fraction of its cost.
- Every reported number names its file, job, and commit.
- Agents are interchangeable, because the rules live outside them.
- Stale documents stop accumulating. The fence blocks unproven reports, and `FACTS.md` holds only lines you merged.

## Known limits

- An agent with your credentials can bypass the speed bumps. The walls need the steps in [enforcement.md](enforcement.md).
- A reviewing model shares blind spots with the model it reviews. Your spot checks still matter.
- The scripts target Slurm and GitHub. PBS and Flux need small ports in `guard/bin/`.
