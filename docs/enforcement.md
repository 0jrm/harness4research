# How the rules are enforced

Rules that an agent can read are suggestions. This project puts each rule at a point that every agent passes through, whichever tool runs it. There are four strengths of protection, and each covers the gap in the one below it.

| Strength | Mechanism | What it stops | What gets past it |
|---|---|---|---|
| Note | `AGENTS.md`, the skill | honest mistakes by an agent that reads it | an agent that skips or misreads it |
| Speed bump | `guard/run preflight`, `guard/run ripples`, `guard/run manifest` | direct submits, edited limits, frozen-card edits, silent warning signs | an agent that calls `sbatch` directly with your credentials |
| Speed bump (launch host) | `guard/run launch` and its supervisor | over-cap jobs, busy GPUs, jobs past their walltime or memory, silent orphans, a restart after a resource stop that nobody recorded | an agent that runs `nohup` directly, or deletes the state dir; no memory wall exists without an administrator's `MemoryMax` on the user slice |
| Locked door | the `guard-fence` check plus a protected default branch | merging changes to `guard/`, workflows, watched paths, question cards, or reports whose evidence rows cite no committed file | anyone who can bypass branch protection |
| Bank limit | a capped cluster sub-account set by the admins | spending past the cap, by anyone | nothing; the scheduler refuses |

## Who stops a job

On a launch host only two things ever signal a job: the supervisor that launch started for it, and `guard/run launch --stop`. Ripples reports; it never stops anything. An agent never finds or stops a job through a command-line pattern (`pgrep -f`, `pkill -f`); the record written at launch holds the session, and `--list` and `--stop` read it.

## Why the scripts run from the protected branch

`guard/run preflight` does not run `guard/bin/preflight.sh` from your working tree. It runs the copy on the default branch, read with `git show`. An agent that edits the script, the budget, or the watch list on its own branch changes nothing, and the next preflight or ripples call reports the edit. The CI fence works the same way. It uses `pull_request_target`, so GitHub runs the base branch's workflow and fence script, and it fetches the pull request only as data.

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
