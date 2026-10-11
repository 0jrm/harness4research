# Status and hand-off

Written on 2026-10-09 for the agent who takes over as chief of staff, and updated on 2026-10-10 with the model host's serving report and on 2026-10-11 with the pipeline test on skynet. Keep this page current, or replace it, as items move.

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
| 9 | question card, frozen, hash recorded | drafted, #62; `eval/run.py` enforces the freeze; the serving report filled the launch command and the FP8 outcome; only the alias is missing |
| 10 | arms A and E, one model, ten seeds, published with intervals | blocked: Qwen3.6 is tested but not up on an alias; the model host needs a day's notice |
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

- Nothing of this project runs: no episode, proxy, tunnel or service.
- On skynet (read-only check, 2026-10-11, 23:13 UTC):
  - GPU 0 holds the model host's server on `default-model`. About 22:44 UTC they restarted it with another checkpoint, `models/artemis31b`, under the same served name `gemma4-26B-mtp`, with a context length of 262144. Neither model is in bounds for the evaluation;
  - GPUs 1 to 3 are empty, and their aliases report `failed`.
- The relay does not load a model on request: a request naming Qwen3.6 got 404 "does not exist". A model must already run behind an alias.
- skynet is set up to run the evaluation: the evaluation clone `~/h4r-eval` (kept apart from `~/harness4research`, which backs the owner's `guard` there), the Codex 0.162 release under `~/.codex`, and `eval/env/selftest.sh` passing 28 of 28. Results of the pipeline test, discarded, are in `~/eval-scratch`. Git on that NFS home can stall; when an `ssh` pull times out, check `git status` and reset the clone to `origin/main`.
- The model host's serving report (2026-10-09, a PDF the owner keeps) says all four panel models boot and pass its checks, one per A100. `docs/evaluation-serving.md` summarizes it under "The model host's reply". None of them is up now. An evaluation model goes up on an alias with a day's notice.

## Open items in the queue

The serving report answers both, on the model host's word:

- `n18`, the seed. Qwen3.6-35B-A3B-FP8 does not repeat, not even at temperature 0, so the ten seeds are samples and the proxy log is the record. The card says so in `unverified_1` and `unverified_4`. `check_seed.py` reruns in the pilot.
- `n20`, FP8 on one A100. It loads as W8A16 through Marlin. The card says so in `checked_3`.

The owner closes both with `guard needs-you done n18` and `guard needs-you done n20`.

The report's section 8 left one choice to us: keep FP8 and treat the repeats as samples, or switch to the BF16 weights on two GPUs. On 2026-10-11 the owner chose FP8, as the card draft already says. No BF16 download is needed.

## The next steps, in order

1. **A slot on the GPU.** A message was drafted for the owner on 2026-10-10. Through the owner, ask the model host to put Qwen3.6-35B-A3B-FP8 up on an alias, first for the pilot and then for the run, and to name the alias. The report's own plan is GPU 0 (`default-model`) with a day's notice, the path the model host tested through the relay. Another GPU is the model host's call, not ours. The owner relays messages with Brendon (bgutierrez); never contact them or change their servers yourself.
2. **The two checks.** Done on the model host's word; see "Open items in the queue". The pilot reruns `check_seed.py`.
3. **The analysis script.** Done, #66. `eval/analyze.py <results_dir>` prints both primary contrasts, the tolerance verdict, the kill criterion and the exploratory tables; `--json` dumps the same numbers.
4. **A pilot.** Run four to eight episodes on skynet with a separate `run_id` and `--unfrozen` against the Qwen3.6 instance, at the config's `parallel` of 4. Leave `expect_root` out of the pilot's config: the check then records `served_root` in `run.json`, and that value becomes `expect_root` before the freeze. It measures the session length (the smoke run on a different model hit its 10-minute limit) and the time-out rate under that load, reruns `check_seed.py`, and catches scaffold failures before any frozen episode counts. Since #67, `eval/run.py` resumes without duplicates, runs the cases in a seeded shuffled order, and runs `scaffold.parallel` episodes at once, so 120 episodes at the 30-minute limit take at most about 15 hours instead of 60, if the server keeps its speed. Decide where the run lives. A laptop that sleeps stalls the tunnel and every running episode without telling the driver, while SIGTERM, SIGHUP and Ctrl-C drain cleanly. A pipeline test on 2026-10-11 against the model host's Gemma, output discarded, found and fixed three things: `guard init` failed on NFS homes (#70), the t1 scorer counted a job stopped at its allowed limit as over the cap (#71), and the model check missed a checkpoint swapped under the same served name (#72, which also reruns episodes a server outage ended).
5. **Freeze the card.**
   - Fill the last placeholder in `eval/cards/drafts/first-qwen3.6.card`, the alias, and fold in anything the pilot changes, such as the time limit.
   - Move the card to `eval/cards/first-qwen3.6.card` in one pull request.
   - Set `alias` in `eval/configs/codex-qwen3.6.json`.
   
   The README describes the procedure in "The question card".
6. **The run.** On skynet, in the evaluation clone `~/h4r-eval` (not `~/harness4research`, which backs the owner's `guard` there), run `eval/run.py eval/configs/codex-qwen3.6.json` under tmux. The model check reads the relay's admin listing and the server behind the alias, which only skynet can reach. Rerun the same command after any interruption. It stops when the alias serves another model, and a resumed run must match the card's hash.
7. **The result.** Publish it in the README next to the Status section: the numbers with their intervals, the card's four deviations, and every claim still unverified marked unmeasured. Publish it whatever it shows. The handoff's ground rules require a source for every claim.

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
