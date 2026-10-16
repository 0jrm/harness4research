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

The present is one block in the chat reply. If a project rule also requires a file, write it, and still put the present in chat. The file is not the present.

Fence the block with a gift emoji right before its first word and right after its last, with no line break between an emoji and the prose. They stay, including under unslop. Write every sentence inside per the unslop skill. Use no other emoji, except the 🩺 block below.

```
🎁<prose>🎁
```

## The ledger

Keep an append-only, uncommitted TSV at `.audit/present-<slug>.tsv`, columns `ts kind item detail evidence`. `kind` is `command`, `name`, `assumption`, `deviation`, or `unverified`. Write a row when something happened; a wrong row gets a new row that supersedes it. A claim from pasted text stays `unverified` until an artifact confirms it. A checked claim enters `FACTS.md` only through a pull request with its evidence. Open `references/ledger.md` before writing the first row.

## What happens to a doubt after the present

The ledger stays on one machine, so queue as a `check` item any `unverified` or `assumption` row that a result, a merged change, or a later session depends on, and any `deviation` that changes what someone else will do; name its id in the present. When a deviation of one kind appears a second time, propose the rule that would prevent a third. Open `references/doubts.md` before queuing either.

## Inside the fence

Prose, in this order. Drop a job only when it is truly empty. A deviation and an unchecked claim always appear. If there were none, say that in one sentence.

1. Macro view of the project/branch (short, relevant to auditor), session outline, and why this turn matters within this context (important).
2. What is true now. Command outcomes in words. Give the exact command only when the human's next action is to run it, or the outcome is meaningless without it.
3. What you need from them, or that you need nothing. If you need something, say what the action changes, in enough detail that they need not open a diff, a terminal, or a pull request to know what they are agreeing to.
4. Names they will meet later. Each name once, and what it refers to.
5. Assumptions, deviations, and unchecked claims.

Add the facts that lived in tools, edits, names, and pastes. Leave out the session story and the essay they already read. If the present is longer than the work, you recopied the essay. Cut it.

Name the ledger path, and which doubt a row answers. Keep in the chat any fact the decision needs; the path is for a later check.

If `/present` arrives before the work is finished, say that it is unfinished.

## The 🩺 block

A 🩺 block asks the human to do one thing only they can do: approve a decision, run a command on their machine, or look at a file.

Never write a 🩺 block by hand. Queue the item and paste what the queue prints:

```shell
guard needs-you add --kind run --title "Merge PR #41" --why "<one sentence>" \
  --run "# Merge the pull request with your own login" --run "cd /home/you/proj" --run "gh pr merge 41 --squash" \
  --expect "<sample output that means it worked>" --worry "<sample output that means it did not>" \
  --undo "<how to reverse it>" --path /home/you/proj/report.md --source <your CLI name>
guard needs-you show n3
```

Give each command its own `--run`, in order. The human pastes them whole, so no command may wait for input or take a quoted multi-word argument. Always give `--expect`. Open `references/needs-you.md` before the first `add` of a session.

Paste the output of `guard needs-you show <id>` verbatim, after the 🎁 block. In the present, name the id in the sentence that says what you need. Never run `guard needs-you ack`, `done`, or `dismiss` yourself. Those mean the human saw it or did it.

When a hook tells you items are open, start the reply with their 🩺 blocks. If `guard` is not installed, say what you need in the present, and say that no 🩺 block was queued.
