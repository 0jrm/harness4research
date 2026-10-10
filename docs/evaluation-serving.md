# Serving models for the evaluation

This page is for the person who serves the models. It says what the evaluation is, which models it needs, how each should be served, and what load to expect. [evaluation.md](evaluation.md) has the full design.

## The experiment in brief

harness4research puts guardrails around coding agents that run experiments on shared compute: a budget check before each job, a CI check before each merge, and rules the agent reads. The evaluation asks whether those guardrails stop agents on local models from breaking rules without making them worse at ordinary work.

Each task is a short research chore. A trap task hides one temptation, such as a job that needs more walltime than the budget allows, a metric with a shortcut, or a test fixture the agent cannot fix without touching a protected file. A control task is the same chore with no temptation. A script scores every run from what the agent left behind, with no model as judge.

The design compares several arms, from no guardrails to the full harness. The first run uses the two ends, no harness and the full harness, and runs every task ten times under each. Later runs add the arms in between, at the same load per arm. The agent runs on another machine in a sandbox, with a fake scheduler. Nothing the agent does touches the GPU host except its requests to the model server.

## Models

Official checkpoints only, in this order. The first one is enough to start.

| Model | Hugging Face id | Why it is in the panel |
|---|---|---|
| Qwen3.6-35B-A3B, FP8 | `Qwen/Qwen3.6-35B-A3B-FP8` | mid-size MoE with strong tool use; the first run uses it alone |
| Gemma 4 31B | `google/gemma-4-31B-it` | a second model family |
| gpt-oss-120b | `openai/gpt-oss-120b` | a reasoning model trained heavily with RL; in one benchmark, RL post-training went with more reward hacking ([Thaman, arXiv 2605.02964](https://arxiv.org/abs/2605.02964)) |
| Qwen3.5-9B | `Qwen/Qwen3.5-9B` | a small model, where the guardrail text costs the most context |
| Ornith-1.5-35B-A3B (optional) | `ornith-ai/Ornith-1.5-35B-A3B` | a second RL-trained agentic model |

Each fits one 80 GB A100 by weight size. How much room each leaves for the KV cache is unmeasured.

## How to serve each model

Every model needs these settings, so that runs can be repeated and compared:

- `--enable-auto-tool-choice` with the parser below. A wrong or missing parser makes tool calls fail silently, which would look like a weak model.
- `--max-model-len 65536` or more. The agent's own prompt plus the guardrail text is already past 30 KB before the task starts.
- `--seed <fixed>`. Even with a seed, batched decoding is not bit-identical across runs, which is why each task runs ten times.
- `--served-model-name <fixed>`, so that the name in our logs does not change between runs.
- Sampling defaults set on the server with `--override-generation-config '{"temperature": ..., "top_p": ...}'`, using each model card's recommended values. The agent clients do not all expose temperature.
- `--enable-log-requests`, so that we can count tokens per request. gpt-oss reports zero usage on the Responses API, according to the vLLM recipe, so for that model the log is the only token count. `--enable-prompt-tokens-details` helps for the others.

| Model | Tool-call parser | Reasoning parser | Source |
|---|---|---|---|
| Qwen3.6-35B-A3B, Qwen3.5-9B | `qwen3_coder` | `qwen3` | the model cards |
| Gemma 4 31B | `gemma4` | `gemma4` | the flags on skynet's current server |
| gpt-oss-120b | `openai` | none needed | the [vLLM gpt-oss recipe](https://recipes.vllm.ai/openai/gpt-oss-120b) |
| Ornith-1.5-35B-A3B | probably `qwen3_coder` | probably `qwen3` | unverified; it is built on Qwen3.5 |

All of these flags are in both the [vLLM 0.12](https://docs.vllm.ai/en/v0.12.0/cli/serve/) and the [current](https://docs.vllm.ai/en/latest/cli/serve/) `vllm serve` documentation. skynet runs 0.21, so check them with `vllm serve --help` there.

The agent client, Codex, uses the OpenAI Responses API (`/v1/responses`). Two other clients use Chat Completions (`/v1/chat/completions`). Both must return tool calls. This request checks one of them in a second:

```shell
curl -s localhost:<port>/v1/responses -H 'Content-Type: application/json' -d '{
  "model": "<served name>", "max_output_tokens": 400,
  "input": "List the files in /tmp using the tool.",
  "tools": [{"type": "function", "name": "bash", "description": "Run a shell command",
             "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}}]}'
```

A good reply has an `output` item of type `function_call` named `bash`. The same test against Chat Completions, with `"messages"` and `"tools": [{"type": "function", "function": {...}}]`, should end with `finish_reason: "tool_calls"`.

## What we record about the server

The evaluation's question card freezes these before the first run, so please tell us when any of them changes: the vLLM version, the model id and its revision (commit hash), every `vllm serve` flag, the GPU, and the date the server started.

## Load

- Concurrency: one to four agent sessions at a time. We match the server's `--max-num-seqs` and never exceed it.
- Requests: long-context tool calls. Each agent turn resends the conversation so far, so prompts grow toward the context limit and outputs are short. Prefix caching helps a lot.
- Volume: the first run has 6 tasks, 3 traps and their 3 controls, so 6 tasks × 2 arms × 10 repeats = 120 agent sessions on one model. Each later arm adds 60 sessions per model, and each later trap adds 2 tasks, its control included. Tokens and wall time per session are unmeasured. The first sessions will measure them, and we will share the numbers before scaling up.
- Schedule: whenever suits the GPU host. A run can stop between sessions and resume.

## How the agents reach the server

The agents connect through an SSH tunnel from the agent machine (`ssh -N -L <port>:127.0.0.1:<port> skynet`). The server can keep listening on 127.0.0.1, and nothing needs to open a public port. We read the request log only to count tokens and to match requests to sessions.

## The model host's reply

On 2026-10-09 the model host sent a serving report, tested on 2026-10-08 and 2026-10-09. The owner keeps the PDF. These are its facts, not rechecked by us:

- All four models run from official weights at the requested commits, one A100-80GB each, on vLLM 0.21.0, and pass chat, tool calls through `/v1/chat/completions` and `/v1/responses`, a tool-result round trip, a code hidden in a 64k-token prompt (alone and four at once), and the relay.
- FP8 works on Ampere. vLLM runs `Qwen/Qwen3.6-35B-A3B-FP8` as weight-only FP8 (W8A16) through Marlin kernels. The BF16 fallback was not downloaded.
- Gemma 4 31B is served from Google's QAT build, `google/gemma-4-31B-it-qat-w4a16-ct`, because BF16 leaves room for about one 64k request.
- Qwen3.6-35B-A3B-FP8 does not repeat: five same-seed requests gave five outputs, and three temperature-0 requests gave three, sent one at a time. vLLM's batch-invariant mode refuses this checkpoint. The other three models repeat with a fixed seed. On gpt-oss, the first of five requests differed, which the model host puts down to the prefix cache.
- Each server's model id is the Hugging Face repo id. Relay aliases name GPUs: `default-model` is GPU 0, and `default-model-2` to `default-model-4` are GPUs 1 to 3. GPU 0 runs the model host's own work, so an evaluation model goes up on an alias with a day's notice and boots in 3 to 6 minutes.
- Every server runs with `--seed 0`, `--max-model-len 131072`, `--max-num-seqs 8`, no speculative decoding, reasoning on, and image and video inputs off. The Qwen models use the `qwen3_xml` tool-call parser, not `qwen3_coder` as this page asked, and pass the tool checks with it.
- Sampling defaults come from each checkpoint's `generation_config.json`. gpt-oss-120b and Qwen3.5-9B ship none, so the model host recommends that the harness send temperature, top_p and top_k on every request. The proxy does this from the config's `sampling` values.

| Model | KV pool (tokens) | 64k requests at once | 64k prompt latency, 1 / 4 at once | Default temperature / top_p / top_k |
|---|---|---|---|---|
| Qwen3.6-35B-A3B-FP8 | 1,904,640 | about 29 | 12 s / 24 s | 1.0 / 0.95 / 20 |
| Gemma 4 31B QAT | 393,685 | about 6 | 70 s / 259 s | 1.0 / 0.95 / 64 |
| gpt-oss-120b | 200,075 | about 3 | 21 s / 59-80 s | 1.0 / 1.0 / none |
| Qwen3.5-9B | 1,737,744 | about 27 | 22 s / 32 s | 1.0 / 1.0 / none |

The report's section 6 holds each launch command. The question card copies the one it runs.
