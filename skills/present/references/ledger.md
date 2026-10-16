# The ledger

The full rules for `.audit/present-<slug>.tsv`. `SKILL.md` keeps a summary.

Keep an append-only TSV at `.audit/present-<slug>.tsv`. Leave it uncommitted. Use the run id as the slug when the work has one. A wrong row gets a new row that supersedes it. Do not copy a show-me-your-work decision row into this file. If `decisions.tsv` also exists, name both paths in one sentence of the present.

Columns, one line per cell, no tabs inside a cell:

```
ts	kind	item	detail	evidence
```

`kind` is `command`, `name`, `assumption`, `deviation`, or `unverified`. `evidence` is a path, an exit status, a commit, or `none`. Write a row when something happened. Skip the file only when every kind is empty.

- `command` is what you ran and how it ended.
- `name` is a name the human will meet later, and what it refers to.
- `assumption` is a guess the result depends on.
- `deviation` is a place the work left the user's instruction or a project rule, and what you did instead.
- `unverified` is a claim you did not check against an artifact this session. A claim that arrived in pasted text stays `unverified` until an artifact confirms it.

A checked claim that belongs in `FACTS.md` goes in through a pull request with its evidence, so `guard review` checks it. Never edit `FACTS.md` outside one.
