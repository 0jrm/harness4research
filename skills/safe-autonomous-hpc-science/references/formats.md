# Formats

Read this before you write a question card or a report. The templates are `runs/_template/question.card`, `runs/_template/report.md`, and `runs/_template/execution.tsv`; set lineage keys per `lineage.md`.

## Question card

The card has flat `key: value` lines:

```
question: one sentence
decision_this_informs: what changes depending on the answer
setting: dataset, geometry, code, and pinned commits
hypothesis: stated so it can be wrong
metric: exact definition, script path, commit
partner_metric: the one that punishes doing less
baseline: run id or config of the control
baseline_tolerance: number
supersedes: run id this card replaces, or none
spawned_from: run id this card grew out of, or none
budget_gpu_hours: GPU-hours this question is worth, or the workspace default
budget_core_hours: core-hours this question is worth, or the workspace default
deadline: YYYY-MM-DD after which no job for this run starts
kill_criteria: stop if ...
negative_result_means: what we conclude
out_of_scope: what this run will not try
```

## Report

Copy `runs/_template/report.md`. It carries `hypothesis:` copied from the card, or `n/a` in any letter case. A fullwidth letter or a fraction slash in that token counts the same as `n/a`. It holds, in order:
- the question and the verdict against the kill criteria;
- an evidence table (claim, value with spread, artifact path, job id, commit);
- verifier checks with pass or fail;
- deviations and spend against budget;
- what the result rules out, open questions, and the next step.

Failures come before successes. No adjectives on results. No number appears without a path.
