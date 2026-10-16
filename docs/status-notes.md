## What runs

Nothing. Our vLLM server on skynet has been stopped since 2026-10-14, and the plan runs no model before W1.4. The evaluation's environment, weights and clone stay on `/conda/jmiranda/h4r`. The history before this plan is in [archive/status-2026-10-14.md](archive/status-2026-10-14.md).

## Deviations from the plan

- W0.2: the CI job's script merged (#108); the workflow job waits for the owner's push (n47).
- W0.4's check "arm-E input tokens per turn below pilot 4" needs a model run, and the plan runs none before W1.4. The four skill cores went from 7028 to 3519 words and `templates/AGENTS.md` from 288 to 250; W5 measures the tokens.
- W3 and W4 ran before W1.2 merged, in parallel worktrees: they share no files with it.
