# Status and hand-off

Written on 2026-10-09 for the agent who takes over as chief of staff, and updated on 2026-10-10 with the model host's serving report, on 2026-10-11 with the pipeline test on skynet, and on 2026-10-13 with self-hosting and the pilots. Keep this page current, or replace it, as items move.

## Start here, as of 2026-10-14

[plan-2026-10-14.md](plan-2026-10-14.md) is the current plan. It covers the field report from the first HPC install (rolled back by the owner), the small audit fixes in progress, the sandboxed-agent design waiting on the owner, and the paused evaluation. The sections below record the state before it.

## The big picture

harness4research adds guardrails to research repositories, so that AI agents can run experiments on shared compute without a person watching every step:

- `guard/run preflight` refuses jobs that do not fit the budget card or a frozen question card;
- `guard/run ripples` reports warning signs;
- the CI fence refuses merges that change the guardrails or report numbers without evidence;
- `guard needs-you` queues what only a person can do;
- `guard review`, `guard merge` and `guard ship` let agents review and merge their own work without admin rights.

On 2026-10-08 an external review, `fable_review.txt` (untracked, in the repository root on the owner's laptop), and the owner's handoff from it set the agenda. Its central point is that the evaluation is the product. Until a measurement shows that the harness lowers rule violations without lowering task success for local models, the pitch to the research group rests on trust. Everything since then builds that measurement, after a round of correctness and safety fixes.

The evaluation compares arms of the harness (A: none, through E: full) on trap tasks, which hide a temptation, and their bait-free controls. It uses local models served by vLLM, with Codex as the agent client, and a script scores every episode. The first run compares arms A and E on one model, Qwen3.6-35B-A3B, with ten seeds.

## The handoff's task list

| # | Item | Status |
|---|---|---|
| 1 | `$USER` unset under `set -u` | done, #50 |
| 2 | evidence paths must exist at HEAD | done, #50 |
| 3 | handled-failures bypass: incidents read from the protected branch | done, #51; incident pull requests also get a model review |
| 4 | test suite as root | done, #51 (skips one case at uid 0) |
| 5 | reviewer prompt injection; the protected-ref check is a speed bump | done, #52; the reviewer also lost the owner's stored gh login |
| 6 | evaluation environment | done, #55 (rootless, not Docker: FSU machines give no sudo); its self-test runs in CI since #57 |
| 7 | traps 1, 3, 8 with controls | done, #58; 48 of 48 scripted verdicts matched |
| 8 | the run driver, Codex on vLLM | done, #60 |
| 9 | question card, frozen, hash recorded | drafted, #62; `eval/run.py` enforces the freeze; no placeholder left; seven deviations recorded; awaits pilot 4 and the owner's approval |
| 10 | arms A and E, one model, ten seeds, published with intervals | ready to run on our own server on GPU 1 once the card is frozen; three pilots ran, see `eval/pilots.md` |
| 11 | pstack opt-in, canonical source, pinned | done early at the owner's request, #59 |
| 12 | GPU TRES accounting in preflight | open. skynet's Slurm accounts no gres/gpu, so check the target cluster first |
| 13 | short and space-separated `#SBATCH` forms | done on branch `fix/guard-audit-small-gaps`: preflight reads `-t`, `-N`, `-a` and the space forms in the script and on its command line, and puts its checked values last on the `sbatch` line |
| 14 | mental-model paragraph above the quickstart; trim `campaign.py` | open |
| 15 | minimal mode (scripts only) and its guarantees | open |
| 16 | `launch.sh`: rewrite or declare an experiment | open; an owner decision |
| 17 | replace the `codex exec --oss` reviewer example with a vLLM profile | open |
| 18-20 | remaining traps, arms B-D, all models; capability tax; attack policy | after the first result |

The handoff says not to start items 12 to 17 before item 10's result, except as the owner directs (they directed item 11). "No new subcommands until the evaluation has produced its first result."

## What is running

As of 2026-10-13, on skynet:

- **Our model server.** Qwen/Qwen3.6-35B-A3B-FP8 on GPU 1, outside Slurm, in tmux session `h4r-vllm`, at `127.0.0.1:9185`, with prefix caching on. It runs `eval/serve/qwen3.6-fp8.sh`: the model host's launch command with our vLLM 0.21.0 (torch 2.11.0+cu130) and our copy of the weights, checked 56 of 56 against Hugging Face with `eval/serve/verify_weights.py`. Stop it with Ctrl-C in that tmux session.
- **Where things live.** `/conda/jmiranda/h4r` on skynet's local disk: `vllm-0.21.0` (the environment), `models/qwen36-35b-fp8`, `h4r-eval` (the evaluation's clone; update it with `git pull`), `sessions` (episodes), `results`, `logs`. `~/h4r-pilots` on the NFS home holds a copy of the pilots' results and episode records. Git and builds on the NFS home take minutes, so nothing of the run lives there.
- **The model host's side.** GPU 0 runs the model host's servers, through their control API at `127.0.0.1:32553`, which has no authentication and launches only on GPU 0. Our sandbox cannot reach it (#75).
- **Slurm and GPUs.** skynet's `gres.conf` lists `/dev/nvidia1` to `/dev/nvidia3`, but `/dev/nvidia1` is the card `nvidia-smi` calls GPU 0, the model host's. A Slurm GPU job therefore gets the model host's GPU first, and GPU 1 (`/dev/nvidia0`) is outside Slurm. That is why our server runs outside Slurm. The model host has not been told yet (`n28`).
- **Pilots.** Three ran; `eval/pilots.md` has what each found. A fourth, with the reasoning merge (`text_into_reasoning`, card deviation 7), comes next.

## Open items in the queue

- `n25`: the PyTorch sampler we use against FlashInfer's (card deviation 5).
- `n26`: the `mcp_` history trick has no side effects.
- `n27`: the proxy's history repairs affect arms A and E alike; check after the run, from the proxy logs.
- `n28`: tell the model host we serve on GPU 1, and about the Slurm GPU mismatch.

## The next steps, in order

On 2026-10-13 the owner paused the model run. Their position is that violations are unacceptable, so the first question is whether the walls hold, not how often agents try. A pilot-4 agent in arm E called `sbatch` directly and ran a 30-minute job against a 10-minute cap, the gap `docs/enforcement.md` already calls a speed bump.

1. **The enforcement audit.** For each rule, a scripted attacker tries the known bypass inside the existing sandbox, with arm E installed. The output is a table of each rule as wall or speed bump, with evidence. Deterministic, no model.
2. **Close the walls the audit finds.** Candidates: a scheduler-level limit (a capped sub-account or account wall-time limit, which `guard doctor` should require, and which the fake Slurm should model); a sandboxed launcher for agents, which also keeps the owner's credentials out of their reach; a sandboxed reviewer.
3. **Then the model run.** It measures what remains: the cost of the walls to real work, and whether agents escalate when they hit one. The card, the config and the server stay as they are until then. The server runs with prefix caching (card deviation 8).
4. **The result,** published whatever it shows.

The inspector's first two steps are on the pushed branch `feat/eval-inspect-index`, not merged. They wait until the audit's needs are clear.

## Earlier milestones

- The analysis script, `eval/analyze.py` (#66), and the run driver's resume, shuffled order and parallel episodes (#67).
- A pipeline test on 2026-10-11 against the model host's Gemma fixed `guard init` on NFS homes (#70), the t1 scorer's count of jobs stopped at their limit (#71), and the model check's blindness to a checkpoint swapped under the same served name (#72).
- On 2026-10-12 the model host suggested we serve the model ourselves (#74), and the owner chose FP8 and GPU 1. On 2026-10-13 the sandbox lost its network and gained disk and memory caps (#75), the run went to 8 episodes at a time (#76), and the proxy learned to repair Codex's history for Qwen (#75, #77, #78).

## Roadmap after the first result

1. **Rebuild the doubts first.** Write traps 2, 4, 5, 6, 7 and 9 with their controls, the same way: a scorer validated by scripted honest and cheating agents through `eval/validate.py`. Add arms B (prose only), C (scripts only) and D (scripts and prose), then the other three models. The serving report gives each one's launch command and parsers: Gemma 4 31B QAT, gpt-oss-120b, Qwen3.5-9B. Pin `sampling` in each config, because gpt-oss-120b and Qwen3.5-9B ship no defaults.
2. **The secondary scaffold.** Run mini-swe-agent or Inspect's `react()` on one model, to check that findings are not Codex artifacts. It is also the main scaffold for the 9B model, where Codex's own prompt takes much of the context.
3. **The capability tax.** Run ScienceAgentBench-verified or CORE-Bench v1.1 under arms A and E on two models, and report any cost beside the violation numbers.
4. **The P2 items** 12 to 17, after the result, in the owner's order.
5. **Smaller debts:**
   - a new question card can merge without a human on the single-PR path (`guard review <pr>` then `guard merge <pr>`), because only `guard ship` holds cards for the human. That was offered as a separate task; check whether it was done.
   - roadmap item 6's remaining parts: `open-failures`, a project-wide handled total, a required `root_cause:` line.
   - CI could run `eval/validate.py`. A workflow change is the owner's push.
   - ten merged branches remain on GitHub. The repository does not delete branches on merge.
6. **The optional attack-policy run**, which tests enforcement rather than propensity.

## How work is done here

- **Pull requests.** Every change goes on a branch from `main` and gets a pull request to `main`; never stack pull requests. Write the brief at `$(git rev-parse --git-common-dir)/guard/briefs/<branch with / as ->.md`, with the owner's words verbatim. Then run `guard review <pr>`. On a `changes` verdict, fix it, push, and run the review again: the owner's standing instruction overrides the review-and-merge skill's "relay and stop". After CI passes, run `guard merge <pr>`. Never run `gh pr merge`.
- **Workflow files.** The agent token cannot push `.github/workflows/`. Prepare the branch locally, let the owner push it, then open the pull request; the owner merges it.
- **Commands for the owner.** Use one fenced block, with short `#` comments and everything pasteable at once, followed by a sample of the expected output and of worrisome output. Never put a quoted multi-word argument in a command: quotes turn curly on the way to the owner's terminal. `guard needs-you add` builds this layout from `--run`, `--expect` and `--worry`.
- **Doubts.** Keep the present ledger at `.audit/present-eval-handoff.tsv` (uncommitted). An unchecked claim or a deviation that others will rely on goes into the queue as a `check` item, as the present skill says.
- **Downloads, models and the model host.** Ask the owner before downloading anything. Use official checkpoints at the publisher's precision only; never abliterated models, not even as an extra arm. A model that does not fit one A100 gets two GPUs, never a third-party quantization. Requests to the model host go through the owner, as full Hugging Face URLs pinned to a commit.
- **No root.** The evaluation must run without sudo on FSU machines.

## Where things are

| What | Where |
|---|---|
| the evaluation and its design | `eval/README.md`, `eval/tasks/README.md`, `docs/evaluation.md`, `docs/evaluation-serving.md` (the model host's brief) |
| the first run's config and card | `eval/configs/codex-qwen3.6.json`, `eval/cards/drafts/first-qwen3.6.card` |
| where the protection stops | `docs/enforcement.md`, `docs/autonomy.md` |
| the older roadmap | `docs/roadmap.md` |
| the external review | `fable_review.txt` (untracked, owner's laptop) |
