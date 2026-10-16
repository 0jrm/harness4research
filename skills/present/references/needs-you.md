# Queuing a 🩺 item

How `guard needs-you add` treats its flags. `SKILL.md` holds the example command and the rules for pasting the block.

- `add` prints the new id. If an open item already has the same kind and title, `add` prints that item's id and queues nothing, so a retry never queues a duplicate.
- `--kind` is `approve` for a decision, `run` for a command, or `check` for something to look at.
- Give each command its own `--run`, in the order the human runs them. The block puts them in one fenced code block the human pastes whole, so every command must work when pasted with the rest: no command that waits for input, and no quoted multi-word argument, because quotes can turn typographic on the way to a terminal.
- A `--run` that starts with `# ` is a short comment in that block. Use one to say what a group of commands does, and for any step that is not a shell command, such as a slash command in an interactive session.
- Always give `--expect`, a sample of the output that means it worked, and `--worry` when some output means it did not.
- `add` refuses a path that is relative, missing, or under `/tmp`, `/var/tmp`, `$TMPDIR`, or a `scratchpad` directory, because the human may open it after that file is gone. Copy the file into the project and queue the copy.
- The queue keeps the item for every worktree of the repository, and `guard needs-you` lists it until the human closes it.
