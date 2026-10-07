---
name: review-and-merge
description: >-
  Hand a finished change to an independent reviewer and merge it only through
  the guard's gate. Use when the implementation is done and the next step is a
  pull request, a review, or a merge, even if the user only says "ship it",
  "open the PR", "get it reviewed", "merge it", or "land this". Writes the brief
  with the user's words copied verbatim, opens the pull request, runs guard
  review and then guard merge, and relays any 🩺 block.
---

# Review and merge

The agent that wrote a change does not review it and does not merge it by hand. `guard review` runs a different model against the user's own words. `guard merge` merges only when the merge policy, the credentials, the branch ruleset, the checks and the review all allow it. When any of them does not, it queues the merge for a human as a 🩺 item.

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

   ## Plan
   <what you changed, file by file, and why>

   ## Test command
   <the command that runs the tests>
   ```

   Copy the request out of the user's messages character for character. Do not paraphrase, summarize, translate, or fix its typos. If the request grew over several messages, copy each message that shaped it, in order, including corrections. The reviewer judges the diff against this section. It reads your plan as claims to check, so the plan does not need to persuade anyone.
3. Open the pull request with `gh pr create`. Describe the change in your own words. Never put the brief or the user's words in the title, the body, or a comment. They stay on this machine.
4. Run `guard review <pr>`.
   - Exit 0 is approve. Pull the branch first if the reviewer pushed fixes, then go to step 5.
   - Exit 1 is `changes` or `escalate`. `guard review` queued an item for the human. Relay its block and stop. If the user then asks you to address the review, fix it, push, and run `guard review` again.
   - Exit 2 means it refused to start. Do what its message says, such as writing the brief, then rerun.
5. Run `guard merge <pr>`.
   - Exit 0 means it merged.
   - Exit 2 means it refused and queued the merge for a human. Relay the block and stop. Under `merge_policy: semi-manual` this is the expected end. The review is done, and the merge belongs to the human.
   - Exit 1 means GitHub refused the merge, for example because the head moved. Relay the block and stop.

## Relaying a 🩺 block

Put each block that `guard review` or `guard merge` printed at the top of your reply, exactly as printed. To show it again, run `guard needs-you show <id>`. Never write a 🩺 block by hand.

## Never do these

- Run `gh pr merge` yourself, with or without `--admin`. `guard merge` is the only way an agent merges.
- Change `merge_policy`, the reviewer settings in `guard config`, a ruleset, a token, or anything under `guard/` to get a merge through.
- Ack, finish, or dismiss a needs-you item. The human does that.
- Edit the brief after a review to change its verdict.
- Push to the branch while `guard review` runs. It pushes the reviewer's fixes itself.
