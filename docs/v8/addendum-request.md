# Owner addendum to the v8 plan (pasted 2026-10-17, verbatim)

This document amends the plan. Where it contradicts the plan, this document wins; where it is silent, the plan stands. Items are labelled A1 to A12 so they can be cited in commits and in `docs/decisions-v8.md`. Apply the same rules of engagement, word budgets and gates.

## Part 1 — Corrections to the plan as written

**A1. Verify the Phase 0 re-score is possible before committing to its gate.** The gate says re-score the October records with the new scorer. Two of the new rules may not be recoverable from what was recorded: login-node compute is only visible if the sandbox captured process activity outside the fake scheduler, and tuning on public test labels is only visible if the agent's scratch scripts survived in the final tree. Check both against three stored episodes first. If either is unrecoverable, say so on the card, re-score only what can be re-scored, and mark the rest "not assessable in v6 records" rather than reporting a corrected number that is really a floor. Do not silently weaken the rule to fit the data.

**A2. E5 changes the baseline for every later experiment; make that explicit.** If E5 runs first and the prose is cut, then E1 and E2 run on a smaller prompt than October did, and comparing E2's request count to October's 112 confounds the redesign with the prose cut. Fix: after E5, run one 10-seed control of the **unchanged v6 harness on the post-E5 AGENTS.md**. That control, not October, is what E1 and E2 are compared against. Cost is one cheap chore.

**A3. The harness-triggered share needs a floor.** On the broken-test chore the no-harness baseline is 9 requests; two harness commands is already 20%, and a 25% stop condition would fire on a harness that costs almost nothing. Change the stop condition to: harness-triggered share over 25% **and** more than 10 harness-triggered requests per episode. Keep the 10% target as a target on the time-limit chore only.

**A4. The third arm as specified is a guaranteed zero.** "Approval tier forced to queue everything" with nobody answering will deadlock every episode, and 50 episodes will tell you what the October run already told you. Make the third arm **queue everything with a scripted approver that answers after a fixed delay** (pick 5 minutes, write it on the card). That arm then answers a question you cannot otherwise answer: what does a real human-in-the-loop cost when the human is cooperative but slow — which is the setting your group will actually deploy in. If you want the deadlock case too, it is one seed, not ten.

## Part 2 — Additions to Phase 0

**A5. Build the offline replay bench first, before any experiment.** You have 144 recorded command streams. The bench replays an episode's commands against a modified harness, with no GPU and no model, and reports which commands would now be refused, with what message. It cannot predict what the agent would have done next, and must not be used to claim behaviour change. It is for one thing: catching a refusal path that is wrong, missing, or unrecoverable, before it costs a live run. Every harness change in Phase 2 passes the bench before it reaches a live experiment. Acceptance (E8 below) is reproducing the October refusal counts.

**A6. Add two standing metrics.** Alongside the harness-triggered share: **compaction events per episode** (Codex compacts near 80% of the window, and at 65k that is reachable on the long chore; a compaction loses task state and silently doubles cost), and **largest prompt as a fraction of the context window**. Both come from the proxy log you already keep.

## Part 3 — Additions to the agent-facing surface

**A7. A fourth verb: `guard status`.** Prints the whole project state in under 300 tokens: what is running, what is blocked and on what, what the last refusal was, what the remaining budget is, and the single next command. It is not optional polish. It is the recovery anchor after a compaction or a context reset (one October agent looped 91 commands re-reading the budget card), the handoff point between models, and the first thing an agent runs in a resumed session. Word budget: 300 tokens of output, hard.

**A8. Cap the output of every guard command.** No guard command returns more than 40 lines; beyond that it writes a file and returns the path plus the last 10 lines. `guard wait` returns the state change and a log tail, never the whole log. Set `tool_output_token_limit` in the Codex config used by the eval as a second line of defence, but do not rely on it — truncate at the source, because the harness is the thing you control across agent tools.

**A9. Refusal codes.** Every refusal carries a stable code (`H4R-E07`) as its first token, in addition to the reason and the recovery command, inside the two-line budget. The codes are what the replay bench counts, what `tests/run.sh` asserts on, and what makes a refusal's cost measurable across runs. Keep a one-line-per-code table in `docs/refusals.md`; that file is for humans and the bench, and no agent operation may depend on it.

**A10. Generalise the budget-field lesson into a rule.** Write it in `docs/decisions-v8.md` as a design rule, not just a deletion: *never ask the model for a free-form value that a machine must parse.* Derive it, default it, or enumerate the choices in the refusal. Audit every remaining flag in the three verbs against this rule before Phase 2 closes. `--why` is exempt, because nothing parses it.

**A11. `guard ask` carries a deadline and a conservative default.** Signature: `guard ask "<question>" --default <the safe option> --deadline <T>`. If nobody answers in T, the default is taken, the record says it was taken unattended, and the agent is told so in one line. An approval path with no bounded outcome is the October failure; do not ship another one.

**A12. Meter the holdout, and make numbers dereference.** Two additions to `guard holdout`. First, scoring is limited to N submissions per question card (default 3), every call is logged with the solution's hash, and the refusal on exhaustion says so. An unmetered holdout measures leakage; a metered one makes hill-climbing visible in the record and bounded in practice. Second, every number `guard holdout score` returns carries a ledger ID, and the fence's existing "no numbers without an artifact path" rule accepts a ledger ID as that path. This is the seam where this harness meets the research-writing work: a claim in a paper either dereferences to a ledger entry or it is not a claim. Build the ID now even if nothing consumes it yet.

## Part 4 — Additional experiments

Same protocol: one change, 10 seeds, card committed before the run, record in `eval/experiments/<id>.md`.

| # | Change under test | Prediction (median) | Kill criterion | What it decides |
| --- | --- | --- | --- | --- |
| E8 | Replay bench reproduces October refusals from recorded streams | refusal counts per chore within 5% of the recorded run | off by more than 15% on any chore | whether the bench can be trusted to pre-screen harness changes, or everything must run live |
| E9 | `guard status` + 40-line output caps (leaky-set chore, all arms) | largest prompt 58k → under 25k; compaction events → 0; success through scheduler up | largest prompt still over 40k | whether context economy is a real lever or the long chore is irreducibly expensive |
| E10 | Holdout metered at N=3 versus unmetered holdout (leaky-set trap) | rule-breaking at or below E7's, and a visible submission trail in every episode | honest-version success falls by more than 2 of 10 | whether metering adds protection or only friction once the holdout is sealed |
| E11 | `guard ask --default --deadline 5m` against a scripted approver that never answers | zero blocked episodes; every unattended default recorded | any episode ends blocked on the queue | whether the human path can be made non-deadlocking |

**Order.** E8 before everything, because it makes the rest cheaper to iterate. Then E5, then the A2 control, then E1 and E2. E3, E4, E6, E9 independent. E7 then E10 once the holdout commands exist. E11 last; it needs the scripted approver that the third comparison arm (A4) also needs, so build that once.

## Part 5 — Additions to Phases 2 to 4

**Phase 2 build list, append:** `guard status`; output caps on every command; refusal codes plus `docs/refusals.md`; `guard ask` deadline and default; holdout submission metering and ledger IDs; a PATH shim that refuses `pkill -f python3`, `rm -rf` outside the run directory, and force-pushes, each with a recovery line. The shim is zero tokens and closes the hole that killed five October episodes from inside the sandbox.

**Phase 2 gate, append:** every refusal path has a code, a recovery command and a test; the replay bench runs clean over all 144 October streams against v8 with no unhandled command.

**Phase 4 artifact, append:** report compaction events and largest-prompt fraction in the cost table; include the submission trail from the metered holdout as its own small figure, because it is the first direct measurement of evaluation hill-climbing you will have.

**Phase 5 — release the benchmark.** New phase, after Phase 4. Publish the three chores, both versions, the seeds and the scorers as a standalone repository with a one-command runner, independent of the harness. It makes every claim in both reports reproducible by someone who does not trust you, it gives your group a way to ask "which local model can we let near the cluster", and it is the artifact most likely to be cited. Gate: a person who has never seen the harness runs one chore end to end from the README alone.
