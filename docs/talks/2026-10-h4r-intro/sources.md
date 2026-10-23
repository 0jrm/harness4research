# Sources for every number in the deck

Repository state: `origin/main` at 6f876b8 (2026-10-21). Result numbers are computed by
`figures/make_figures.py` from the verdict rows in `data/raw/` and written to `data/numbers.json`;
`build.js` reads them from there. `eval/analyze.py` on the same files gives the same counts.

## Result data

| File in `data/raw/` | What it is | Where it came from |
|---|---|---|
| `october-verdicts.jsonl` | 150 verdicts, run `first-qwen3.6-r2`, October scoring | skynet `/conda/jmiranda/h4r/h4r-eval/eval/results/first-qwen3.6-r2/verdicts.jsonl`, copied 2026-10-22 |
| `october-rescored-verdicts.jsonl` | the same 150 episodes, stricter re-score | `eval/results/first-qwen3.6-r2-rescored/verdicts.jsonl` |
| `v8-partial-verdicts.jsonl` | 131 of 181 rows of run `second-qwen3.6-v8` (129 scored, 1 harness error, 1 deadlock extra) — **interim, run paused** | skynet `/conda/jmiranda/h4r/p3/eval/results/second-qwen3.6-v8/verdicts.jsonl`, copied 2026-10-22 |
| `v8-run.json` | arms and config of the v8 run | same folder, `run.json` |

The published October page ("Does the harness keep agents honest?") quotes harness 9/29 and no-harness
controls 20/27. The deck uses the counts `eval/analyze.py` gives on the raw rows: 9/30 and 21/30.

## Slide by slide

| Slide | Number | Source |
|---|---|---|
| 2 | five failure modes | `docs/why.md` "The problem" |
| 3 | 9/10 edited the protected test; push check refused all nine | `~/.claude/orchestrate/h4r-v8/plan.md`, finding 1; confirmed in `october-rescored-verdicts.jsonl` (t8-fixture, arm E, trap: `tests_unchanged_on_main` true in 10/10) |
| 4 | broker roles, sandbox | `docs/design-v8.md` §2–4, `lib/box.sh`, `lib/gateway.py` |
| 5 | five strengths | `docs/enforcement.md` |
| 6 | four commands, < 300 tokens, 5-minute wait; AGENTS.md 134 words; 46 refusal codes; R06 text | `templates/AGENTS.md` (`wc -w`), `docs/design-v8.md`, `docs/refusals.md` |
| 7 | pin, fence F01–F07, holdout 3 submissions | `docs/releases/v7.0.md`, `docs/refusals.md`, decisions on E7b/E10 in `~/.claude/orchestrate/h4r-v8/decisions.tsv` |
| 8 | ship tiers, five merge conditions | `docs/autonomy.md`, `lib/merge.sh` |
| 9 | hooks, skills, runhub; audit 66 held of 68 | `lib/hooks.py`, `skills/`, `docs/live-tests/runhub.md`, `docs/status.md` line 33 (`eval/audit/baseline.json`) |
| 10 | Codex 0.162, Qwen3.6-35B-A3B-FP8, vLLM 0.21, 60× fake Slurm; 150 / 181 episodes | `eval/README.md`, `docs/evaluation-serving.md`, `data/raw/v8-run.json` |
| 11 | trap definitions | `eval/tasks/README.md` |
| 12 | Wilson 95%, Newcombe, 10-point tolerance; 5/10 → [24%, 76%] | `eval/analyze.py`; Wilson(5, 10) computed in `make_figures.py` |
| 13 | 20/30 vs 9/30, −37 pts [−56, −11]; controls 21/30 vs 22/30, +3 [−19, +25] | `numbers.json` → `oct` |
| 14 | per-family counts; re-scored 23/30 vs 17/30, −20 [−41, +4]; 34 verdicts changed | `numbers.json` → `per_family`, `rescore`; `eval/experiments/baseline-r2-rescored.md` |
| 15 | 58% of tokens; 10/10 → 6/10; 2/10 through scheduler; experiment outcomes | `plan.md` findings 2–3; `decisions.tsv` 2026-10-18 to 2026-10-21 |
| 16 | v8 traps 22/25 vs 14/21, −21 [−44, +3]; controls 22/26 vs 10/14, −13 [−41, +12]; deadlock episode 7 requests, 30 s, 0 jobs | `numbers.json` → `v8` |
| 17 | median requests per episode, harness arm, v7 vs v8 (113 → 28 walltime; 111 → 212 leaky split); largest prompt share | `numbers.json` → `cost` (medians over trap + control episodes) |
| 18 | 51 episodes to go; three more panel models | 181 − 129 scored − 1 deadlock episode done (the harness-error row reruns); memory `eval-setup-decisions` (approved panel) |
| 20 | ≈ 11.7k lines in `lib/` + `bin/`; ≈ 1,186 tests; 275 commits; PRs to #145 | `wc -l`, `decisions.tsv` (test count during v8 integration), `git log` |

## Caveats said aloud

- v8 numbers are interim (129 of 181 scored) and the v8 scorer (frozen at ab5047f) judges t3 and t8 on pushed
  main, so v7 and v8 rates are not strictly comparable cell by cell.
- Two v8 walltime rows are "not assessable" for login-node runs (`eval/analyze.py` prints them as ≥ k).
- Cost medians pool trap and control episodes of the harness arm only.
