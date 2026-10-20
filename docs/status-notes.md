## What runs

Phase 1 on skynet (GPU 1): E7b running, then E10 and E9. Experiments have no pull requests, so the table lists them
unstarted. Verdicts: E8, E5, E6b, E11, E4b confirmed; A2 a control; E2, E3, E6, E2b, E1 inconclusive; E4, E7
killed, retried as E4b, E7b. The owner approved the Phase 1 gate on 2026-10-20; a kill in E7b, E10, E9 stops the
program. Phase 2 is #142.

## Releases

v6.2 and v7.0 are tagged; the redesign ships as v8.

## Deviations from the plan

- The audit gate flips rows on mars, `main` included; run gates on skynet or the laptop.
- W1.4's laptop check ran on a scratch clone: this checkout's `.claude/settings.local.json` holds the agent's GitHub
  token, which a sandboxed session would see (n58).
