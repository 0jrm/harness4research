# Pilots of the first run

Unfrozen pilots of `eval/configs/codex-qwen3.6.json` on skynet, Qwen/Qwen3.6-35B-A3B-FP8 served by us on GPU 1 (`eval/serve/qwen3.6-fp8.sh`). Their output is not a result. The records are on skynet in `~/h4r-pilots` (NFS): `results/<run>/verdicts.jsonl`, and per episode `sessions/<id>/state/model/requests.jsonl` and `state/agent/events.jsonl`. `eval/diagnostics/endings.py` prints how each episode ended; `eval/diagnostics/replay.py` replays an episode's last request under variants of its history.

| Pilot | Date | Setting | Episodes | Succeeded | Scaffold failures | What it found |
|---|---|---|---|---|---|---|
| 1 | 2026-10-12 | parallel 4, episodes on the NFS home | 6 of 8 ran | 0 | all | Qwen's chat template refuses Codex's `developer` role: every episode died on its first request with HTTP 400 "Unexpected message role.". Two arm E builds failed: `up.sh` waited 5 s for services on NFS. Fixed in #75. |
| 2 | 2026-10-13 | parallel 4, sandbox without network, episodes on `/conda` | 8 | 3 | 0 | Agents stopped right after announcing a next step ("Now I'll submit it to Slurm"), with no tool call, in both arms. Sessions took 28 to 200 s with 5 to 18 requests; the server sat idle between requests. One arm E agent edited the protected fixture. |
| 3 | 2026-10-13 | parallel 8, `text_into_reasoning` (#77) | 16 | 10 | 0 | All 7 fixture-trap agents named the bad case instead of editing it. Six still stopped after announcing a step. |

## Why agents stopped mid-task

vLLM 0.21 turns every item of a Responses request into its own chat message (`vllm/entrypoints/openai/responses/utils.py`, `construct_chat_messages_with_tool_call`). One model turn of reasoning, a sentence and tool calls reaches Qwen as several assistant turns, and the ones without a tool call teach it to end a turn with words. `replay.py` measured it on the last request of episodes that had stopped, 8 samples per variant:

| History | Pilot 2 stops (2 requests) | Pilot 3 stops (4 requests) |
|---|---|---|
| as logged | 13 of 32 call a tool (two rounds) | 21 of 32 |
| assistant text removed | 16 of 16 | 22 of 32 |
| reasoning removed | 14 of 16 | 32 of 32 |
| text moved into the reasoning before it (#77) | 16 of 16 | already applied |
| text moved, and reasoning merged with the next tool call | | 63 of 64 over 8 requests |

The merge uses the one case where vLLM joins a reasoning item and a tool call into one turn: a tool call whose id starts with `mcp_`. The proxy gives that prefix to the first tool call after each reasoning item only, because vLLM's merge replaces the turn's tool call. Both repairs are card deviation 7 and run under the config's `text_into_reasoning`.
