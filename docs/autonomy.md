# How agents review and merge their own work

An agent in a guarded repository can take a change from a finished branch to a merged pull request without a person in the loop. Three commands do the work: `guard review` gets a second model to judge the change, `guard merge` merges only when every condition holds, and `guard needs-you` queues whatever is left for a person. Whether this lowers rule violations or keeps agent success is unmeasured; [evaluation.md](evaluation.md) describes how it will be measured. The review is a quality tool, not an enforcement point: the walls are the checks and the ruleset, as the last section says. `guard ship` runs the first two over every open pull request at once, a few times a day. This page explains what each one checks, how `guard ship` sorts pull requests into tiers, what agents never do, and where the protection stops.

## Two merge modes

`merge_policy` picks the mode.

- `autonomous` is the default. `guard merge` merges the pull request once every check below passes.
- `semi-manual` runs the same review, and then `guard merge` always refuses and queues the merge for you. You click every merge.

In a guarded repository, `guard merge` reads `merge_policy` from `guard/budget.card` on the pull request's base branch, so an agent cannot change it on its own branch. To switch to `semi-manual`, change that line through a pull request you merge. In a repository without a guard, `guard merge` reads your user config instead:

```shell
guard config set merge_policy semi-manual
```

## What the agent does

The [review-and-merge skill](../skills/review-and-merge/SKILL.md) tells the agent these steps:

1. Push the branch.
2. Write a brief at `.git/guard/briefs/<branch>.md`, with `/` in the branch name replaced by `-`.
3. Open the pull request with `gh pr create`, described in its own words.
4. Run `guard ship`. It reviews and merges the open pull requests once the batch is due, and otherwise says when it is due.

For urgent work, the agent runs `guard review <pr>` and, on approve, `guard merge <pr>` instead. The agent never runs `gh pr merge` itself.

### The brief

The brief has up to four sections:

```markdown
## Request (verbatim)
<the user's request, copied character for character>

## Scope
<optional: which part of the request this pull request covers, and where the rest goes>

## Plan
<what changed, file by file, and why>

## Test command
<the command that runs the tests>
```

`guard review` refuses to start when the brief is missing or its `## Request (verbatim)` section is empty. The reviewer judges the diff against the request, and reads the plan as claims to check.

The brief stays on your machine. It lives in the repository's git directory, which every worktree shares and git never commits. The skill forbids putting it, or your words, in the pull request title, body, or comments, and `guard review` posts only the verdict and a one-line reason.

## What `guard review` checks

`guard review <pr>` checks out the pull request's head in a fresh worktree under `.git/guard/review-worktrees/`. It runs the reviewer with [lib/review-prompt.md](../lib/review-prompt.md), the brief, and the diff. The reviewer leaves the full test suite to CI, which `guard merge` requires to pass. It runs one targeted test only when the diff raises a doubt that the test settles, and it may commit small fixes such as a typo or a missing import. The default Claude reviewer starts without MCP servers, plugins, hooks, or the skills list, so each of its turns carries a few thousand tokens of setup instead of tens of thousands. It cannot push: `guard review` starts it without `GH_TOKEN`, `GITHUB_TOKEN`, or `SSH_AUTH_SOCK`, and with a push URL that fails. `guard review` pushes the reviewer's commits itself.

A round that adds commits is followed by another round, up to `review_rounds` (default 2). The verdict is approve only for a round that added no commits. The reviewer ends with one of three verdicts:

- `approve`: the diff does what the request asks, and any test the reviewer ran passed. Exit 0.
- `changes`: part of the request is missing, or a defect is too large to fix in review. Exit 1, and a `check` item joins the queue.
- `escalate`: a person must decide, for example because the request is ambiguous or the change touches a guard file, a frozen question card, a credential, or a limit. Exit 1, and an `approve` item joins the queue.

`guard review` appends each verdict to `.git/guard/reviews.tsv` and comments it on the pull request.

## What `guard merge` checks

`guard merge <pr>` prints one `pass` or `FAIL` line per item, in the style of `guard doctor`. It merges only when every item passes:

1. `merge_policy` is `autonomous`.
2. The gh login in this shell does not administer the repository.
3. The base branch has an active ruleset that requires a pull request. In a guarded repository, the ruleset also requires `guard-fence / fence`.
4. The pull request is open and not a draft.
5. At least one check ran, and every check passed.
6. `reviews.tsv` records approve at the pull request's current head.

Then it runs `gh pr merge <pr> --squash --match-head-commit <sha>`, so a push after the checks stops the merge. It never passes `--admin`. On any `FAIL`, it exits 2, queues an `approve` item titled `Merge PR #<pr>` with the command you run, and prints that item.

Items 2 and 3 are why autonomous merge needs [the enforceable setup](enforceable.md). An agent that holds your admin login could bypass the ruleset, so `guard merge` refuses to merge with it.

## Tiers and batches

A model review cost 1.5 to 3.5 million input tokens before the reviewer was trimmed, and costs about 300,000 to 400,000 now. In one project, 79 pull requests merged in a week, and 31 of them only added run records. `guard ship` spends a model review only where one helps. It sorts each open pull request into a tier by the paths it changes and its size, then reviews and merges them together, a few times a day.

`pr_tier` in [lib/pr.sh](../lib/pr.sh) gives the tier from the diff between the base branch and the pull request's head. The first row that matches wins.

| Tier | The pull request | What `guard review --batch` does |
|---|---|---|
| human | changes a path under `guard/` or `.github/workflows/`, or adds a `runs/<id>/question.card` | No review. A new question card joins one 🩺 item, `Approve question cards`, with a `gh pr merge` command for each card pull request. Any other change gets its own `Merge PR #<n>` item. |
| records | changes only paths under `runs/<id>/`, and none of them is a `question.card`, a `report.md`, or an incident note under `incidents/` | Approve without a model, recorded with reviewer `records-tier`. The fence and CI check the records. |
| small | changes at most `review_small_lines` lines, added and deleted (default 200) | One reviewer session judges up to `review_batch_max` pull requests (default 8). |
| large | anything else | `guard review <pr>`, with its rounds and fixes. |

`runs/_template/` is a template, not a run, so its files count as ordinary code. A report carries science claims, so a pull request that changes a `report.md` gets a model review. A question card that already exists is frozen, and the fence fails a pull request that edits it.

The small-tier session reads each pull request's brief and diff from one prompt, [lib/review-batch-prompt.md](../lib/review-batch-prompt.md). It runs in a checkout of the base branch, which it uses only to read code around a change. It runs no tests, commits nothing, and fixes nothing. It ends with one line per pull request:

```text
VERDICT #12: approve - adds the missing unit to the plot label as asked
VERDICT #15: changes - renames the flag but leaves the old name in the README
```

A pull request without exactly one valid line gets `escalate`. Each verdict goes to `reviews.tsv` at that pull request's head, and `changes` and `escalate` queue an item as `guard review <pr>` does. A small pull request without a brief waits, because the brief carries your words.

`guard review --batch` skips a pull request whose last verdict in `reviews.tsv` is at its current head, and it leaves out drafts and pull requests from forks. `guard merge --batch` runs the gate of `guard merge` on every pull request approved at its head, lowest number first. When the gate refuses some of them, one item, `Merge approved pull requests`, lists each with its first failing reason and its `gh pr merge` command.

### When `guard ship` runs the batch

A pull request waits for the batch when it is not in the human tier and has no verdict at its head, or has approve there and is not merged yet. `guard ship` runs `guard review --batch` and then `guard merge --batch` when either of these holds:

- `review_batch_max` pull requests wait.
- The oldest waiting pull request is `ship_interval_hours` old (default 24).

Otherwise it refreshes the question card digest, which needs no model, and prints which pull requests wait and when the batch is due. `guard ship --now` runs the batch at once. After a batch, it prints the count per tier, each verdict, and each merged pull request with its merge commit.

Run `guard ship` every few hours, by hand or from a scheduler, so the card digest stays current. A merge can wait up to `ship_interval_hours`. For a change that cannot wait, run `guard review <pr>` and `guard merge <pr>`.

The digests update in place. `guard needs-you add --update` gives an open or acked item the new content under the same id and opens it again. When the content is the same, the item does not change. When no card pull request is open, `guard ship` marks the card digest done. When the gate refuses no approved pull request, `guard merge --batch` marks the merge digest done.

## Choose the reviewer

`reviewer` in your user config picks the model that reviews.

- `proprietary` is the default. `guard review` runs `reviewer_cmd_proprietary` if you set it. Otherwise it runs `claude`. When `claude` is not on your PATH or exits with an error, such as when it is not signed in, it runs `cursor-agent`.
- `local` runs `reviewer_cmd_local`, a command you name that runs a local model. `guard review` refuses until you set it.

`reviewer_model` names the model for the default `claude` and `cursor-agent` commands, which then get `--model <reviewer_model>`. A command you set in `reviewer_cmd_proprietary` or `reviewer_cmd_local` runs as written.

For example, to review with a local model through Codex and Ollama:

```shell
guard config set reviewer local
guard config set reviewer_cmd_local 'codex exec --oss --local-provider ollama -m <model> --sandbox danger-full-access'
guard config list
```

The config lives in `~/.config/guard/config`, or `$XDG_CONFIG_HOME/guard/config`. The guard-onboard skill asks which reviewer you want and sets it, and `guard doctor` reports the reviewer and whether its command is on your PATH. Pick a reviewer from a different model family than the agent that writes the code where you can. A model shares blind spots with itself.

## The needs-you queue

`guard needs-you` is the list of what only you can do, check, or approve. Each item has a kind:

- `approve`: a decision only you make, such as a merge.
- `run`: a command only you can run, such as a step that needs your credentials.
- `check`: something to look at, such as a reviewer's report.

The queue is one file, `.git/guard/needs-you.tsv`, shared by every worktree of the repository and never committed. `guard review` and `guard merge` add items, and so can an agent:

```shell
guard needs-you add --kind run --title "Ask the cluster admins for a capped account" \
  --why "preflight caps the budget card, and only the scheduler caps a direct sbatch" \
  --run "open docs/cluster-subaccount-request.md" --expect "a reply naming the new account" \
  --worry "a reply saying the account cannot be capped" --source codex
```

`add` refuses a relative path, a missing path, or a path under `/tmp`, `/var/tmp`, `$TMPDIR`, or a directory named `scratchpad`, because those disappear when a session ends. `guard needs-you` prints each open item as a 🩺 block:

````text
🩺 n1 · run · Ask the cluster admins for a capped account

Why: preflight caps the budget card, and only the scheduler caps a direct sbatch

```bash
open docs/cluster-subaccount-request.md
```

Expected: a reply naming the new account
Worrisome: a reply saying the account cannot be capped

Close it once it is done:
```bash
cd /home/you/proj && guard needs-you done n1
```

🩺
````

Agents paste blocks from `guard needs-you show <id>` and never write one by hand. You close an item with `guard needs-you ack <id>`, `done <id>`, or `dismiss <id>`. `ack` keeps the item in the list and stops its reminder.

`guard needs-you --remind` prints a one-line summary per open item and nothing when the queue is empty. Two things run it:

- Claude Code, after `guard hooks install claude`, at session start and on every prompt.
- Every other agent, at session start, because of a line in `AGENTS.md`.

`guard atlas` shows the same queue under Needs you: open items first, with their commands to copy and their files, then acked items. [atlas.md](atlas.md) says how to serve the page.

## What agents never do

Some of these are walls that hold even against an agent that ignores its instructions. The rest are rules that an honest agent follows and a reviewer checks.

| Agents never | What stops it |
|---|---|
| change anything under `guard/` | the fence check, the ruleset, and `guard/run`, which runs the protected branch's copy |
| touch a ruleset or credentials | a token with no Administration permission for the ruleset. Credentials are a rule in the skill. |
| approve a question card | a rule. The fence blocks edits to a card after its first commit, not the merge of a new card. |
| decide to continue past a science stop (FAILED or TIMEOUT) | a rule. The agent writes the incident note, and the next call is yours. An `execution.tsv` restart row does not handle a science stop. |
| ack, finish, or dismiss a needs-you item | a rule in the skill |
| merge with `gh pr merge` | a line in `AGENTS.md` and the skill. A non-admin token can still run `gh pr merge` once the required checks pass. |

What agents may do is queue any of these for you with `guard needs-you add`, with the exact command and the files to look at.

Agents may merge lines into `FACTS.md` through `guard review` and `guard merge`. The reviewer opens the evidence each new or changed line cites and asks for changes when it cannot confirm it. To keep `FACTS.md` for humans only, add it to `guard/watch.list`, and the fence then fails any pull request that changes it.

## Where the protection stops

- Review records are local and forgeable. `reviews.tsv` is a plain file in `.git/guard/`, and an agent with shell access can append an approve row. `guard merge` trusts it.
- The real walls are outside the agent's reach: CI checks that must pass, the fence, a ruleset with only you on the bypass list, and an agent token with no admin rights. Without them, `guard merge` is a checklist an honest agent follows, not a lock.
- A non-admin token with write access can run `gh pr merge` once the required checks pass, without `guard review`. Only the skill stops that. A required GitHub review would stop it, and needs a second account.
- The reviewer reads the user's request but not your intent. A request that was wrong passes review.
- The pull request's author controls text the reviewer reads and code it may run, so a diff can steer the verdict. [enforcement.md](enforcement.md#the-reviewer-reads-untrusted-text) lists what limits that and what does not.

[enforcement.md](enforcement.md) explains the credential gap in full, and [enforceable.md](enforceable.md) gives the steps that close it.
