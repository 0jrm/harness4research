# Status

As of 2026-10-16. The plan is [plan-2026-10-16.md](plan-2026-10-16.md), the owner's decisions are in [decisions-2026-10-16.md](decisions-2026-10-16.md), and the standing rules in [rules.md](rules.md). The history before this plan, including the evaluation's setup on skynet and the pilots, is in [archive/status-2026-10-14.md](archive/status-2026-10-14.md) and [archive/plan-2026-10-14.md](archive/plan-2026-10-14.md).

## Plan items

| item | state |
|---|---|
| W0.1 audit gate, baseline | merged, #107 |
| W0.2 CI gate job | script merged (#108); the workflow job waits for the owner's push (n47) |
| W0.3 prerequisite checks | in review |
| W0.4 word budgets, rules | this change |
| W0.5 `guard pr open`, v6.2 | next |
| W1.1 broker increment 1 | in progress in its own session |
| W1.2 to W5 | in order, after these |

## Audit

29 held, 15 bypassed, 0 not applicable: `eval/audit/baseline.json`, from the laptop on 2026-10-16. `eval/audit/run.py --gate eval/audit/baseline.json` fails a pull request that turns a held row back.

## What runs

Nothing. Our vLLM server on skynet has been stopped since 2026-10-14, and the plan runs no model before W1.4. The evaluation's environment, weights and clone stay on `/conda/jmiranda/h4r`.

## The owner's queue

- n25 to n27: checks the evaluation left (the sampler, the `mcp_` history trick, the history repairs across arms).
- n28: the owner's message to the model host about GPU 1 and the Slurm GPU mismatch.
- n43: tag release v6.1. n44: approve pinning the evaluation's Python on skynet.
- n45, n46: done once #107 and #108 merged; the owner closes them.
- n47: push the W0.2 workflow job.

## Deviations from the plan

- W0.4's check "arm-E input tokens per turn below pilot 4" needs a model run, and the plan runs none before W1.4. The words every arm E turn carries from this repository fall with `templates/AGENTS.md` (288 to 250) and the four skill cores (7028 to under 3600, read when the agent opens a skill). W5 measures the tokens.

## Where things are

| what | where |
|---|---|
| the evaluation | `eval/README.md`, `docs/evaluation.md`, `eval/pilots.md` |
| how the rules are enforced | `docs/enforcement.md`, `docs/enforcement-audit.md` |
| the sandbox and broker design | `docs/design-sandboxed-agents.md` |
| every page in one line | `docs/README.md` |
