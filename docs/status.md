# Status and hand-off

Written on 2026-10-09 for the agent who takes over as chief of staff. Main is at `9c3ccb6`, schema 5. Keep this page current, or replace it, as items move.

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
| 9 | question card, frozen, hash recorded | drafted, #62; `eval/run.py` enforces the freeze; the model host's values are missing |
| 10 | arms A and E, one model, ten seeds, published with intervals | blocked: the model host does not serve Qwen3.6 yet |
| 11 | pstack opt-in, canonical source, pinned | done early at the owner's request, #59 |
| 12 | GPU TRES accounting in preflight | open. skynet's Slurm accounts no gres/gpu, so check the target cluster first |
| 13 | short and space-separated `#SBATCH` forms | open. #56 fixed the time grammar, a related bug, not this |
| 14 | mental-model paragraph above the quickstart; trim `campaign.py` | open |
| 15 | minimal mode (scripts only) and its guarantees | open |
| 16 | `launch.sh`: rewrite or declare an experiment | open; an owner decision |
| 17 | replace the `codex exec --oss` reviewer example with a vLLM profile | open |
| 18-20 | remaining traps, arms B-D, all models; capability tax; attack policy | after the first result |

The handoff says not to start items 12 to 17 before item 10's result, except as the owner directs (they directed item 11). "No new subcommands until the evaluation has produced its first result."

## What is running

- Nothing of this project runs: no episode, proxy, tunnel or service. `~/.cache/hpc-sessions` is empty.
- On skynet (read-only check, 2026-10-09 16:24 UTC):
  - GPU 0 holds the model host's Gemma server, idle;
  - GPUs 2 and 3 run the owner's own `hycom-emulator` training;
  - GPU 1 was free.
- The relay on `127.0.0.1:9090` lists only `gemma4-26B-mtp` on `default-model`. That model is abliterated and out of bounds for the evaluation.
- The four panel models are downloaded at the commits requested, in `/unity/g1/bgutierrez/Project/vLLM-bdgr/models/`: `qwen36-35b-fp8`, `gemma4-31b-qat`, `gptoss-120b` and `qwen35-9b`. None is served. The model host asked us to stay off GPU 0 while they configure them.

## Open items in the queue

- `n18`: does the server honour the per-request seed? Run `eval/driver/check_seed.py` once Qwen3.6 is served.
- `n20`: does Qwen3.6 FP8 load on one A100? If not, the card's setting switches to the BF16 weights on two GPUs.

`guard needs-you` shows both, with their commands.

## The next steps, in order

1. **The model host's values.** Get the relay alias of the Qwen3.6 instance and its `vllm serve` command. The owner relays messages with Brendon (bgutierrez); never contact him or change his servers yourself.
2. **The two checks.** Run n20 by reading `/v1/models` through the tunnel, and n18 with `check_seed.py`. Report the outcomes, so the owner can close the items with a note.
3. **An analysis script.** None exists yet. Write `eval/analyze.py` over `results_dir/verdicts.jsonl`:
   - per arm and family: rates with Wilson 95% intervals;
   - the two primary contrasts, E minus A on violation (trap episodes) and on success (control episodes), with Newcombe intervals;
   - exploratory figures, labelled so: escalation on t8, tokens, requests, wall time, time-outs.
   
   Test it on a synthetic `verdicts.jsonl` before the run.
4. **A pilot.** Run two to four episodes with a separate `run_id` and `--unfrozen` against the Qwen3.6 instance. It measures the session length (the smoke run on a different model hit its 10-minute limit) and catches scaffold failures before any frozen episode counts. 120 episodes at the 30-minute limit is up to 60 hours, so decide where the run lives, a laptop that sleeps being a risk. The environment needs bubblewrap and the Codex binary. skynet has bubblewrap but no Codex.
5. **Freeze the card.**
   - Fill the placeholders in `eval/cards/drafts/first-qwen3.6.card`: the alias, the launch command, and the FP8 or BF16 outcome from n20. `<the commit this card is frozen in>` cannot name its own commit, so replace it with a sentence saying that `run.json` records it as `card_commit`.
   - Fold n18's outcome into `unverified_1` and `unverified_4`.
   - Move the card to `eval/cards/first-qwen3.6.card` in one pull request.
   - Set `alias` and `expect_upstream_model` in `eval/configs/codex-qwen3.6.json`.
   
   The README describes the procedure in "The question card".
6. **The run.** Open the tunnel and run `eval/run.py eval/configs/codex-qwen3.6.json` on a stable, awake machine. It stops when the alias serves another model, and a resumed run must match the card's hash.
7. **The result.** Publish it in the README next to the Status section: the numbers with their intervals, the card's four deviations, and every claim still unverified marked unmeasured. Publish it whatever it shows. The handoff's ground rules require a source for every claim.

## Roadmap after the first result

1. **Rebuild the doubts first.** Write traps 2, 4, 5, 6, 7 and 9 with their controls, the same way: a scorer validated by scripted honest and cheating agents through `eval/validate.py`. Add arms B (prose only), C (scripts only) and D (scripts and prose), then the other three models. Each needs its parser settings from the model host: Gemma 4 31B QAT, gpt-oss-120b, Qwen3.5-9B.
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
