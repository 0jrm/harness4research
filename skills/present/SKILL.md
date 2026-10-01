---
name: present
description: >-
  Write a chat block a person can judge without opening a file, a diff, or a
  terminal. Use when the user types /present, when declaring work done, or when
  the next step needs a human decision or action such as merge, approve,
  choose, or run something on their machine.
---

# Present

`/present` is this skill. The user types it to get a present before the task ends. Also write one, without being asked, when you say the work is done, or when the next step is a human decision or action. Skip a direct answer that changed nothing and asks nothing.

Human context is the chat text on the screen. It excludes tool output, files, terminals, the IDE, and anything that takes a click. Pasted text, code blocks, and command output sit in the chat and still do not count as understood. Pasted text is often another model's, so restate the part the judgment uses. Write for a reader who has the prompts and your visible replies, and no memory of the project.

## The block

The present is one block in the chat reply. A project rule may also require a file. Obey the rule, and still put the present in chat. The file is not the present.

Fence the block with a gift emoji on its own line at the start and the same emoji on its own line at the end. Those two marks are the only emoji. They stay, including under unslop. Write every sentence inside per the unslop skill.

```
🎁

<prose>

🎁
```

## The ledger

Keep an append-only TSV at `.audit/present-<slug>.tsv`. Leave it uncommitted. Use the run id as the slug when the work has one. A wrong row gets a new row that supersedes it. Do not copy a show-me-your-work decision row into this file. If `decisions.tsv` also exists, name both paths in one sentence of the present.

Columns, one line per cell, no tabs inside a cell:

```
ts	kind	item	detail	evidence
```

`kind` is `command`, `name`, `assumption`, `deviation`, or `unverified`. `evidence` is a path, an exit status, a commit, or `none`. Write a row when something happened. Skip the file only when every kind is empty.

`command` is what you ran and how it ended. `name` is a name the human will meet later, and what it refers to. `assumption` is a guess the result depends on. `deviation` is a place the work left the user's instruction or a project rule, and what you did instead. `unverified` is a claim you did not check against an artifact this session. A claim that arrived in pasted text stays `unverified` until an artifact confirms it.

Leave `FACTS.md` for the human. If a checked claim belongs there, say so in the present as a proposal.

## Inside the fence

Prose, in this order. Drop a job only when it is truly empty. A deviation and an unchecked claim always appear. If there were none, say that in one sentence.

1. What is true now. Command outcomes in words. Give the exact command only when the human's next action is to run it, or the outcome is meaningless without it.
2. What you need from them, or that you need nothing. If you need something, say what the action changes, in enough detail that they need not open a diff, a terminal, or a pull request to know what they are agreeing to.
3. Names they will meet later. Each name once, and what it refers to.
4. Assumptions, deviations, and unchecked claims.

Add the facts that lived in tools, edits, names, and pastes. Leave out the session story and the essay they already read. If the present is longer than the work, you recopied the essay. Cut it.

Name the ledger path, and name which doubt a row answers. Keep in the chat any fact the decision needs. The path is there for a later check.

If `/present` arrives before the work is finished, say that it is unfinished.

## Examples

Write this shape.

```
🎁

The date test passed. `format_date` in `report.py` now writes UTC. You do not need to do anything.

`runs/smoke-3` is this attempt. I assumed the cluster clock is UTC, and I did not check the host. You asked for local time. I used UTC because the question card says timestamps are UTC. The ledger is `.audit/present-smoke-3.tsv`. The unverified row is the clock.

🎁
```

Do not write this. It recaps the session, hides an unchecked number, and has no fence.

```
I explored the date code and improved consistency across the pipeline. The suite looks good and the error rate is effectively zero. Let me know if you want anything else.
```
