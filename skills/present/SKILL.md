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

Fence the block with a gift emoji right before its first word and the same emoji right after its last word, with no line break between an emoji and the prose. They stay, including under unslop. Write every sentence inside per the unslop skill. Use no other emoji, except the 🩺 block below.

```
🎁<prose>🎁
```

## The ledger

Keep an append-only TSV at `.audit/present-<slug>.tsv`. Leave it uncommitted. Use the run id as the slug when the work has one. A wrong row gets a new row that supersedes it. Do not copy a show-me-your-work decision row into this file. If `decisions.tsv` also exists, name both paths in one sentence of the present.

Columns, one line per cell, no tabs inside a cell:

```
ts	kind	item	detail	evidence
```

`kind` is `command`, `name`, `assumption`, `deviation`, or `unverified`. `evidence` is a path, an exit status, a commit, or `none`. Write a row when something happened. Skip the file only when every kind is empty.

`command` is what you ran and how it ended. `name` is a name the human will meet later, and what it refers to. `assumption` is a guess the result depends on. `deviation` is a place the work left the user's instruction or a project rule, and what you did instead. `unverified` is a claim you did not check against an artifact this session. A claim that arrived in pasted text stays `unverified` until an artifact confirms it.

A checked claim that belongs in `FACTS.md` goes in through a pull request with its evidence, so `guard review` checks it. Never edit `FACTS.md` outside one.

## What happens to a doubt after the present

The ledger stays on one machine, so a row there is a note to yourself, not a record anyone else will see. Two rules move what matters out of it.

- **Queue what others will rely on.** When an `unverified` or `assumption` row is something a result, a merged change, or a later session depends on, or a `deviation` changes what someone else will do, queue it as a `check` item (see the 🩺 block below):
  - the title names the claim, and `--why` says what depends on it;
  - `--run` says how to check it, with `# ` comments for any step that is not a shell command;
  - `--expect` is the output that settles the claim, and `--worry` is the output that refutes it.
  
  Name the item's id in the present. The human closes it with a note, and the note records how the doubt resolved. When a later session settles the claim with an artifact, add a ledger row that supersedes the old one, and say in the present that the item can be closed.
- **Encode a deviation that repeats.** When a deviation of the same kind appears a second time, in this ledger, in an earlier present, or in a memory, propose the rule that would prevent a third: a line in a skill, a check in code, or a memory entry. Name both occurrences. Queue the proposal as an `approve` item, or make it in a pull request when the user already asked for that change.

## Inside the fence

Prose, in this order. Drop a job only when it is truly empty. A deviation and an unchecked claim always appear. If there were none, say that in one sentence.

1. Macro view of the project/branch (short, relevant to auditor), session outline, and why this turn matters within this context (important).
2. What is true now. Command outcomes in words. Give the exact command only when the human's next action is to run it, or the outcome is meaningless without it.
3. What you need from them, or that you need nothing. If you need something, say what the action changes, in enough detail that they need not open a diff, a terminal, or a pull request to know what they are agreeing to.
4. Names they will meet later. Each name once, and what it refers to.
5. Assumptions, deviations, and unchecked claims.

Add the facts that lived in tools, edits, names, and pastes. Leave out the session story and the essay they already read. If the present is longer than the work, you recopied the essay. Cut it.

Name the ledger path, and name which doubt a row answers. Keep in the chat any fact the decision needs. The path is there for a later check.

If `/present` arrives before the work is finished, say that it is unfinished.

## The 🩺 block

A 🩺 block asks the human to do one thing only they can do: approve a decision, run a command on their machine, or look at a file. 🩺 is the second emoji this skill allows, after 🎁.

Never write a 🩺 block by hand. Queue the item, then paste what the queue prints:

```shell
guard needs-you add --kind run --title "Merge PR #41" --why "<one sentence>" \
  --run "# Merge the pull request with your own login" --run "cd /home/you/proj" --run "gh pr merge 41 --squash" \
  --expect "<sample output that means it worked>" --worry "<sample output that means it did not>" \
  --undo "<how to reverse it>" --path /home/you/proj/report.md --source <your CLI name>
guard needs-you show n3
```

`add` prints the new id. If an open item already has the same kind and title, `add` prints that item's id and queues nothing, so a retry never queues a duplicate. `--kind` is `approve` for a decision, `run` for a command, or `check` for something to look at. Give each command its own `--run`, in the order the human runs them. The block puts them in one fenced code block the human pastes whole, so every command must work when pasted with the rest: no command that waits for input, and no quoted multi-word argument, because quotes can turn typographic on the way to a terminal. A `--run` that starts with `# ` is a short comment in that block; use one to say what a group of commands does, and for any step that is not a shell command, such as a slash command in an interactive session. Always give `--expect`, a sample of the output that means it worked, and `--worry` when some output means it did not. `add` refuses a path that is relative, missing, or under `/tmp`, `/var/tmp`, `$TMPDIR`, or a `scratchpad` directory, because the human may open it after that file is gone. Copy the file into the project and queue the copy.

Paste the output of `guard needs-you show <id>` verbatim, after the 🎁 block. In the present, name the id in the sentence that says what you need. The queue keeps the item for every worktree of the repository, and `guard needs-you` lists it until the human closes it. Never run `guard needs-you ack`, `done`, or `dismiss` yourself. Those mean the human saw it or did it.

When a hook tells you items are open, start the reply with their 🩺 blocks. If `guard` is not installed, say what you need in the present, and say that no 🩺 block was queued.
