# How the rules are enforced

Rules that an agent can read are suggestions. This project puts each rule at a point that every agent passes through, whichever tool runs it. There are four strengths of protection, and each covers the gap in the one below it.

| Strength | Mechanism | What it stops | What gets past it |
|---|---|---|---|
| Note | `AGENTS.md`, the skill | honest mistakes by an agent that reads it | an agent that skips or misreads it |
| Speed bump | `guard/run preflight`, `guard/run ripples`, `guard/run manifest` | direct submits, edited limits, frozen-card edits, silent warning signs | an agent that calls `sbatch` directly with your credentials, or runs its own copy of the scripts (see below) |
| Speed bump (launch host) | `guard/run launch` and its supervisor | over-cap jobs, busy GPUs, jobs past their walltime or memory, silent orphans, a restart after a resource stop that nobody recorded | an agent that runs `nohup` directly, or deletes the state dir; no memory wall exists without an administrator's `MemoryMax` on the user slice |
| Quality check | `guard review`, `guard merge` | changes that miss the request, facts without evidence, incidents without a cause, merges while checks fail | an agent that appends to `.git/guard/reviews.tsv`, a diff that steers the reviewer, `gh pr merge` with a write token |
| Locked door | the `guard-fence` check plus a protected default branch | merging changes to `guard/`, workflows, watched paths, question cards, or reports whose evidence rows cite no committed file | anyone who can bypass branch protection |
| Bank limit | a capped cluster sub-account set by the admins | spending past the cap, by anyone | nothing; the scheduler refuses |

## Who stops a job

On a launch host only two things ever signal a job: the supervisor that launch started for it, and `guard/run launch --stop`. Ripples reports; it never stops anything. An agent never finds or stops a job through a command-line pattern (`pgrep -f`, `pkill -f`); the record written at launch holds the session, and `--list` and `--stop` read it.

## Why the scripts run from the protected branch

`guard/run preflight` does not run `guard/bin/preflight.sh` from your working tree. It runs the copy on the default branch, read with `git show`. An edit to the script, the budget, or the watch list on a branch has no effect by itself, and the next preflight or ripples call reports the edit.

This is a speed bump, not a wall. The agent controls its own clone and environment, so it can run any copy it likes:

- `HPC_GUARD_LOCAL=1` runs the working-tree copy. It exists for the first test before the guard merges (`templates/guard/run`).
- `HPC_GUARD_REF=HEAD` makes the agent's own commit the protected ref for every script.
- `git update-ref refs/remotes/origin/main <commit>` moves the local `origin/main` to any commit, with no environment variable to notice.
- `guard/run` itself is read from the working tree, so an edited `guard/run` runs whatever it chooses.

None of these reaches the CI fence or the bank limit. The fence uses `pull_request_target`, so GitHub runs the base branch's workflow and fence script from GitHub's copy of the branch, and it fetches the pull request only as data. A capped sub-account refuses jobs whichever script submitted them.

## The reviewer reads untrusted text

`guard review` pastes the pull request's diff into the reviewer's prompt verbatim. It runs the reviewer in a checkout of the pull request's head, with Bash allowed, and reads the verdict from the last line of the reply (`lib/review.sh`). The author of the pull request, often another agent, controls the diff and the checkout. Text in the diff can tell the reviewer to approve. A script in the checkout runs if the reviewer runs it. The default Claude Code reviewer also loads the checkout's own project settings and `CLAUDE.md` (`--setting-sources project` in `lib/config.sh`).

What limits the damage (`run_reviewer` in `lib/pr.sh`):

- The reviewer runs without `GH_TOKEN`, `GITHUB_TOKEN` and `SSH_AUTH_SOCK`, and with an empty `GH_CONFIG_DIR`. Without the empty config, `gh` and git's `gh` credential helper fall back to the login stored on the machine, which is often the repository owner's.
- Pushes to `origin` and to GitHub URLs are rewritten to an address that fails.
- `guard merge` still requires the checks, and the ruleset still requires the fence. The fence fails any change to `guard/` or the workflows.
- `guard ship` sends neither a new question card nor a change to `guard/` to a model; it queues them for you (`pr_tier` in `lib/pr.sh`). `guard review <pr>` has no such gate, so on that path a new question card reaches the reviewer and, once approved, `guard merge`.

What it does not limit: the reviewer runs as you, so it can read anything you can read, such as SSH key files, cluster credentials, and tokens stored in files. An approve from a steered reviewer is still an approve. Read an approve as "a second model saw no problem", never as a security check. Do not run `guard review` on pull requests from people or agents you do not trust unless the reviewer runs in a container or as a separate OS user without your credentials.

## The identity problem

GitHub and the cluster see identities, not intentions. If an agent runs with your SSH key, your `gh` login, or your cluster account, every system treats it as you. Anything you can bypass, it can bypass. The locked door and the bank limit are real walls only when the agent holds weaker credentials than you.

Three steps close that gap, in order of value.

1. Cluster sub-account. Ask the admins for a Slurm account with a hard core-hour cap, and put that account in `guard/budget.card`. Preflight forces `--account` to it. Even a job submitted directly is capped. Template: [cluster-subaccount-request.md](cluster-subaccount-request.md).
2. A weaker GitHub token for agents. Create a fine-grained personal access token limited to the project repositories, with Contents and Pull requests set to read and write and no Administration permission. Give agents that token (`GH_TOKEN`) and an HTTPS remote instead of your SSH key. Protect the default branch with a ruleset that requires a pull request and the `guard-fence / fence` status check, with only you on the bypass list. Verify it in the live test: with the agent token, `gh pr merge --admin` on a failing pull request must be refused.
3. Strip your credentials from agent processes. runhub already pushes after the agent exits, so an agent there needs neither `SSH_AUTH_SOCK` nor `GH_TOKEN`. An agent that opens pull requests and runs `guard merge` needs a `GH_TOKEN`, and it must be the agent token from step 2, never yours. `guard merge` refuses to merge with a login that administers the repository. Removing your credentials from the agent's environment is a smaller change than a separate OS user, and it does not touch `node_modules` permissions.

Until those steps are done, the fence catches honest mistakes and makes a deliberate bypass visible. A merged pull request with a failed check stays in the GitHub history. It does not prevent the bypass.

## Changing the guard yourself

You change `guard/` through a pull request like any other change. The fence fails on it by design, and you merge with your bypass. The failed check on that pull request records that a human changed the limits.

## Per-tool permission settings

Claude Code, Cursor and Codex each have their own allow and deny lists. They help as a fourth speed bump, but their formats differ and change between versions, and runhub runs agents with them off. This project does not generate them. If you add them, deny direct `sbatch`, `scancel` and edits under `guard/`.
