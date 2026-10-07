# How agents review and merge their own work

An agent in a guarded repository can take a change from a finished branch to a merged pull request without a person in the loop. Three commands make that safe enough to allow: `guard review` gets a second model to judge the change, `guard merge` merges only when every condition holds, and `guard needs-you` queues whatever is left for a person. This page explains what each one checks, what agents never do, and where the protection stops.

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
4. Run `guard review <pr>`.
5. On approve, run `guard merge <pr>`.

The agent never runs `gh pr merge` itself.

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

`guard review <pr>` checks out the pull request's head in a fresh worktree under `.git/guard/review-worktrees/`. It runs the reviewer with [lib/review-prompt.md](../lib/review-prompt.md), the brief, and the diff. The reviewer runs the test command, and may commit small fixes such as a typo or a missing import. It cannot push: `guard review` starts it without `GH_TOKEN`, `GITHUB_TOKEN`, or `SSH_AUTH_SOCK`, and with a push URL that fails. `guard review` pushes the reviewer's commits itself.

A round that adds commits is followed by another round, up to `review_rounds` (default 2). The verdict is approve only for a round that added no commits. The reviewer ends with one of three verdicts:

- `approve`: the diff does what the request asks and the tests pass. Exit 0.
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

## Choose the reviewer

`reviewer` in your user config picks the model that reviews.

- `proprietary` is the default. `guard review` runs `reviewer_cmd_proprietary` if you set it. Otherwise it runs the first of `claude`, `codex`, and `cursor-agent` on your PATH.
- `local` runs `reviewer_cmd_local`, a command you name that runs a local model. `guard review` refuses until you set it.

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
  --run "open docs/cluster-subaccount-request.md" --expect "a reply naming the new account" --source codex
```

`add` refuses a relative path, a missing path, or a path under `/tmp`, `/var/tmp`, `$TMPDIR`, or a directory named `scratchpad`, because those disappear when a session ends. `guard needs-you` prints each open item as a 🩺 block:

```text
🩺 n1 · run · Ask the cluster admins for a capped account

Why: preflight caps the budget card, and only the scheduler caps a direct sbatch

Run, in order:
  open docs/cluster-subaccount-request.md

Expect: a reply naming the new account
Done: guard needs-you done n1

🩺
```

Agents paste blocks from `guard needs-you show <id>` and never write one by hand. You close an item with `guard needs-you ack <id>`, `done <id>`, or `dismiss <id>`. `ack` keeps the item in the list and stops its reminder.

`guard needs-you --remind` prints a one-line summary per open item and nothing when the queue is empty. Two things run it:

- Claude Code, after `guard hooks install claude`, at session start and on every prompt.
- Every other agent, at session start, because of a line in `AGENTS.md`.

## What agents never do

Some of these are walls that hold even against an agent that ignores its instructions. The rest are rules that an honest agent follows and a reviewer checks.

| Agents never | What stops it |
|---|---|
| change anything under `guard/` | the fence check, the ruleset, and `guard/run`, which runs the protected branch's copy |
| touch a ruleset or credentials | a token with no Administration permission for the ruleset. Credentials are a rule in the skill. |
| merge a change to `FACTS.md` | a rule in `AGENTS.md` and the skills. It is a wall only if you add `FACTS.md` to `guard/watch.list`, so the fence fails on it. |
| approve a question card | a rule. The fence blocks edits to a card after its first commit, not the merge of a new card. |
| decide to continue past a science stop (FAILED or TIMEOUT) | a rule. The agent writes the incident note, and the next call is yours. An `execution.tsv` restart row does not handle a science stop. |
| ack, finish, or dismiss a needs-you item | a rule in the skill |
| merge with `gh pr merge` | a line in `AGENTS.md` and the skill. A non-admin token can still run `gh pr merge` once the required checks pass. |

What agents may do is queue any of these for you with `guard needs-you add`, with the exact command and the files to look at.

## Where the protection stops

- Review records are local and forgeable. `reviews.tsv` is a plain file in `.git/guard/`, and an agent with shell access can append an approve row. `guard merge` trusts it.
- The real walls are outside the agent's reach: CI checks that must pass, the fence, a ruleset with only you on the bypass list, and an agent token with no admin rights. Without them, `guard merge` is a checklist an honest agent follows, not a lock.
- A non-admin token with write access can run `gh pr merge` once the required checks pass, without `guard review`. Only the skill stops that. A required GitHub review would stop it, and needs a second account.
- The reviewer reads the user's request but not your intent. A request that was wrong passes review.

[enforcement.md](enforcement.md) explains the credential gap in full, and [enforceable.md](enforceable.md) gives the steps that close it.
