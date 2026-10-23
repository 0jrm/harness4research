---
name: review-and-merge
description: >-
  Hand a finished change to an independent reviewer and merge it only through
  the guard's gate. Use when the implementation is done and the next step is a
  pull request, a review, or a merge, even if the user only says "ship it",
  "open the PR", "get it reviewed", "merge it", or "land this". Writes the brief
  with the user's words copied verbatim, opens the pull request with guard pr
  open, runs guard ship, and relays any 🩺 block. Urgent work runs guard review
  and guard merge on its one pull request instead.
---

# Review and merge

The agent that wrote a change neither reviews nor merges it by hand. `guard ship` reviews and merges the open pull requests together, at once for a green record-only one, else within `ship_interval_hours`: it approves record-only ones without a model, reviews small ones several to a session, and large ones alone. Each model review judges the diff against the user's words in a fresh session that never saw the implementer's reasoning; a merge needs the merge policy, credentials, ruleset, checks and review to allow it. A new question card, a change to `guard/`, and any merge the gate refuses go to a human as 🩺 items. A run's records ride one pull request from its `run/<run_id>` branch; never open one for a single record. Independent changes may run in parallel worktrees, one pull request each, never stacked.

## Steps

1. Commit the work on a branch.
2. Write four files outside the repository:
   - the request, copied from the user's messages character for character: no paraphrase, summary, translation, or typo fixes. If it grew over several messages, copy each that shaped it, in order. The reviewer judges the diff against it.
   - the plan: what you changed, file by file, and why; the reviewer checks it as claims.
   - the scope, only for part of the request: which part, and which pull request takes the rest.
   - the body: the change in your own words.
3. Open the pull request:

   ```shell
   guard pr open --title <title> --request <file> --plan <file> --test <command> --body <file> [--scope <file>] [--item <plan item id>]
   ```

   It writes the brief where `guard review` reads it (shared by every worktree, never committed), pushes, opens the pull request, prints its URL; `--item W1.2` titles it `[W1.2] <title>`. The user's words stay on this machine: it refuses a body or scope that repeats a line of the request, and they never go in a comment. A rerun prints the URL; before review, a rerun's `--scope <file>` sets the scope.
4. Run `guard ship`.
   - When the batch is not due, it says which pull requests wait and when it runs. Tell the user and stop.
   - When it runs, it ends with a summary: the count per tier, each verdict, each merge commit. Relay the summary and every 🩺 block it printed, then stop.
   - Exit 2 means it refused to start, or no reviewer could run (`reviewer unavailable:`, this host's problem, which `guard doctor` names; tell the user). Do what its message says, then rerun.
   - Run `guard ship --now` only when the user asks for the batch now.

## Urgent work

When the user says the change cannot wait for the batch, review and merge its one pull request instead of step 4:

1. Run `guard review <pr>`.
   - Exit 0 is approve. Pull the branch first if the reviewer pushed fixes, then go to step 2.
   - Exit 1 is `changes` or `escalate`. `guard review` queued an item for the human. Relay its block and stop. If the user then asks you to address the review, fix it, push, and run `guard review` again.
   - Exit 2 means it refused to start, or no reviewer could run. Do what its message says, such as writing the brief, then rerun. `reviewer unavailable:` is this host's problem (no network, no login, too little memory), which `guard doctor` names. Tell the user; it is not a verdict.
2. Once `gh pr checks <pr>` shows every check finished, run `guard merge <pr>`. Run while a check is pending, it refuses and queues the merge for the human.
   - Exit 0 means it merged.
   - Exit 2 means it refused and queued the merge for a human. Relay the block and stop. Under `merge_policy: semi-manual` this is the expected end: the merge belongs to the human.
   - Exit 1 means GitHub refused the merge, for example because the head moved. Relay the block and stop.

## Relaying a 🩺 block

Put each block that `guard ship`, `guard review` or `guard merge` printed at the top of your reply, exactly as printed. To show it again, run `guard needs-you show <id>`. Never write a 🩺 block by hand.

## Never do these

- Run `gh pr merge` yourself, with or without `--admin`. An agent merges only through `guard ship` and `guard merge`; the `gh pr merge` commands in a 🩺 block are the human's.
- Change `merge_policy`, the reviewer or batch settings in `guard config`, a ruleset, a token, or anything under `guard/` to get a merge through.
- Ack, finish, or dismiss a needs-you item. The human does that.
- Edit the brief after a review to change its verdict.
- Push to the branch while `guard review` or `guard ship` runs. They push the reviewer's fixes.
