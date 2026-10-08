---
name: review-and-merge
description: >-
  Hand a finished change to an independent reviewer and merge it only through
  the guard's gate. Use when the implementation is done and the next step is a
  pull request, a review, or a merge, even if the user only says "ship it",
  "open the PR", "get it reviewed", "merge it", or "land this". Writes the brief
  with the user's words copied verbatim, opens the pull request, runs guard
  ship, and relays any 🩺 block. Urgent work runs guard review and guard merge
  on its one pull request instead.
---

# Review and merge

The agent that wrote a change does not review it and does not merge it by hand. `guard ship` reviews and merges the open pull requests together, a few times a day. It approves pull requests that change only run records without a model, reviews small ones several to a session, and runs `guard review` on large ones. Each model review judges the diff against the user's own words, with a different model from the one that wrote it. It merges only when the merge policy, the credentials, the branch ruleset, the checks and the review all allow it. A new question card or a change to `guard/` always goes to a human as a 🩺 item, and so does any merge the gate refuses.

## Steps

1. Finish the work on a branch and push it.
2. Write the brief at this path. Every worktree of the repository shares it, and git never commits it.

   ```shell
   brief="$(cd "$(git rev-parse --git-common-dir)" && pwd)/guard/briefs/$(git branch --show-current | tr / -).md"
   mkdir -p "$(dirname "$brief")"
   ```

   Use this format:

   ```markdown
   ## Request (verbatim)
   <the user's request>

   ## Scope
   <only when this pull request covers part of the request: which part, and which pull request or branch takes the rest>

   ## Plan
   <what you changed, file by file, and why>

   ## Test command
   <the command that runs the tests>
   ```

   Copy the request out of the user's messages character for character. Do not paraphrase, summarize, translate, or fix its typos. If the request grew over several messages, copy each message that shaped it, in order, including corrections. The reviewer judges the diff against this section. It reads your plan as claims to check, so the plan does not need to persuade anyone.
3. Open the pull request with `gh pr create`. Describe the change in your own words. Never put the brief or the user's words in the title, the body, or a comment. They stay on this machine.
4. Run `guard ship`.
   - When the batch is not due, it says which pull requests wait and when the batch runs. Tell the user, and stop. The merge can wait up to a day.
   - When the batch runs, it ends with a summary: the count per tier, each verdict, and each merged pull request with its merge commit. Relay the summary and every 🩺 block it printed, then stop.
   - Exit 2 means it refused to start. Do what its message says, then rerun.
   - Run `guard ship --now` only when the user asks for the batch now.

## Urgent work

When the user says the change cannot wait for the batch, review and merge its one pull request instead of step 4:

1. Run `guard review <pr>`.
   - Exit 0 is approve. Pull the branch first if the reviewer pushed fixes, then go to step 2.
   - Exit 1 is `changes` or `escalate`. `guard review` queued an item for the human. Relay its block and stop. If the user then asks you to address the review, fix it, push, and run `guard review` again.
   - Exit 2 means it refused to start. Do what its message says, such as writing the brief, then rerun.
2. Run `guard merge <pr>`.
   - Exit 0 means it merged.
   - Exit 2 means it refused and queued the merge for a human. Relay the block and stop. Under `merge_policy: semi-manual` this is the expected end. The review is done, and the merge belongs to the human.
   - Exit 1 means GitHub refused the merge, for example because the head moved. Relay the block and stop.

## Relaying a 🩺 block

Put each block that `guard ship`, `guard review` or `guard merge` printed at the top of your reply, exactly as printed. To show it again, run `guard needs-you show <id>`. Never write a 🩺 block by hand.

## Never do these

- Run `gh pr merge` yourself, with or without `--admin`. `guard ship` and `guard merge` are the only ways an agent merges. The `gh pr merge` commands in a 🩺 block are the human's to run.
- Change `merge_policy`, the reviewer or batch settings in `guard config`, a ruleset, a token, or anything under `guard/` to get a merge through.
- Ack, finish, or dismiss a needs-you item. The human does that.
- Edit the brief after a review to change its verdict.
- Push to the branch while `guard review` or `guard ship` runs. They push the reviewer's fixes themselves.
