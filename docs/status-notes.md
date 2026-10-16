## What runs

Nothing. Our vLLM server on skynet has been stopped since 2026-10-14. W1.4 has merged, so the plan allows a model run again; W5 waits for the owner to say whether to start on GPU 1 now or after telling Brendon (n28). GPU 1 was free on 2026-10-16; GPU 0 holds Brendon's vLLM. History: [archive/status-2026-10-14.md](archive/status-2026-10-14.md).

## Releases

v6.2 (7126a73) and v7.0 (4281354) are tagged. RCC's reinstall on v6.2 is checkpoint 0 (n50), still open; its move to v7.0 is checkpoint 3 (n57), when the owner asks.

## Deviations from the plan

- W0.4's token check needs a model run; W5 measures it.
- W1.4's laptop check ran on a scratch clone: this checkout's `.claude/settings.local.json` holds the agent's GitHub token, which a sandboxed session would see (n58).
