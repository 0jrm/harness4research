## What runs

Phase 1 of [plan-v8.md](plan-v8.md), on skynet: our vLLM on GPU 1 (tmux h4r-vllm) and the experiment queue, each
experiment from its `exp/<id>` branch and its record on `rec/<id>` or `exp/<id>`. The experiments have no pull
requests, so the table above shows them as not started; their verdicts are here. Running E7b; queued E10, E9.
Verdicts: E8, E5, E6b, E11 and E4b confirmed; A2 a valid control; E2, E3, E6, E2b (healthy rerun) and E1 (healthy
rerun, E1h) inconclusive; E4 and E7 killed, retried as E4b and E7b. The owner kept E3's undo line and approved the
Phase 1 gate on 2026-10-20, with the rule that a kill in E7b, E10 or E9 stops the program and comes back with
numbers. Phase 2 is pull request #142; its replay over the October streams passed (148 of 150 episodes; the other two
have no requests). Phase 3 waits for GPU 1 after E9.

## Releases

v6.2 (7126a73) and v7.0 (4281354) are tagged. RCC's reinstall on v6.2 is checkpoint 0 (n50), still open; its move to
v7.0 is checkpoint 3 (n57), when the owner asks. The redesign ships as v8.

## Deviations from the plan

- The audit gate flips rows on mars, `main` included; run gates on skynet or the laptop.
- W1.4's laptop check ran on a scratch clone: this checkout's `.claude/settings.local.json` holds the agent's GitHub
  token, which a sandboxed session would see (n58).
