## What runs

Phase 1 of [plan-v8.md](plan-v8.md), on skynet: our vLLM on GPU 1 (tmux h4r-vllm) and the experiment queues (tmux
h4r-exp, h4r-exp2, h4r-exp3), each experiment from its `exp/<id>` branch. Running E2b; queued E6b, E11, E4b, E9.
Verdicts: E8 and E5 confirmed, A2 a valid control, E2, E3 and E6 inconclusive, E4 killed; E1r and E7 preliminary
killed, records pending.

## Releases

v6.2 (7126a73) and v7.0 (4281354) are tagged. RCC's reinstall on v6.2 is checkpoint 0 (n50), still open; its move to
v7.0 is checkpoint 3 (n57), when the owner asks. The redesign ships as v8.

## Deviations from the plan

- The audit gate flips rows on mars, `main` included; run gates on skynet or the laptop.
- W1.4's laptop check ran on a scratch clone: this checkout's `.claude/settings.local.json` holds the agent's GitHub
  token, which a sandboxed session would see (n58).
