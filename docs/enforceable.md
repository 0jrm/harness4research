# Make the guard enforceable

After `guard init` and the merge, the guard tells an honest agent the rules and refuses bad submissions. It cannot yet stop an agent that merges around the fence, pushes with your key, or submits jobs without preflight. Steps 4 to 6 close those gaps. They are clicks on GitHub and one email to your cluster admins, and `guard doctor` checks each of them.

## Start with guard doctor

Run `guard doctor` in the guarded repository, in a shell started the way your agent starts, because it reads that shell's credentials:

```shell
guard doctor ~/path/to/your-repo
```

On a repository straight after the merge in [step 3](../README.md#3-fill-in-the-guard-and-merge-it), it prints something like this:

```text
guard doctor: /home/you/proj, reading origin/main as last fetched. Credentials are this shell's; run it the way your agent starts.
pass  skills in ~/.agents/skills link to this harness
pass  skills in ~/.claude/skills link to this harness
pass  guard/run is on origin/main
pass  guard schema 3 (release v1.1-34-g0523346) against harness schema 3 (v1.1-34-g0523346): current
pass  guard/budget.card on origin/main has no placeholders
pass  .github/workflows/guard-fence.yml on origin/main defines guard-fence / fence
FAIL  guard-fence / fence has never completed a run on GitHub
      Open any small pull request so the check runs once; only then can a ruleset require it: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#4-protect-the-default-branch
FAIL  main has no active rule requiring a pull request and guard-fence / fence
      Add a branch ruleset for the default branch: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#4-protect-the-default-branch
FAIL  SSH_AUTH_SOCK is set in this shell, so an agent started here can push with your SSH key
      Start agents with env -u SSH_AUTH_SOCK and an HTTPS remote: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#5-give-agents-weaker-credentials
FAIL  the GitHub token in this shell is a classic or OAuth token with scopes repo, workflow, which reaches every repository you can
      Run agents with a fine-grained token for the guarded repositories as GH_TOKEN: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#5-give-agents-weaker-credentials
FAIL  the GitHub login in this shell administers lab/proj, so an agent here can bypass the ruleset
      Run agents with a token that has no Administration permission: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#5-give-agents-weaker-credentials
cannot check from here  whether Slurm caps account gom-agents: sacctmgr is not on this host
      Run guard doctor on a cluster login node: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#6-cap-the-cluster-account
pass  reviewer is proprietary: claude -p --permission-mode acceptEdits --allowedTools=Bash, and claude is on PATH
pass  merge_policy is autonomous in guard/budget.card on origin/main, so guard merge also needs the ruleset and non-admin login items above to pass
FAIL  Claude Code does not show open needs-you items: neither ~/.claude/settings.json nor /home/you/proj/.claude/settings.json runs guard needs-you --remind on SessionStart and UserPromptSubmit
      Run guard hooks install claude
pass  no open needs-you items

9 passed, 6 failed, 1 cannot check from here
```

Each `FAIL` line names what is open and links the step below that fixes it. The last four items cover `guard review` and `guard merge`. They report which reviewer runs, where `merge_policy` is read from, whether Claude Code shows the needs-you queue, and how many items in it are open. Their remedies are commands to run. The hook item appears only where Claude Code is installed, and the open-items count never fails. A `cannot check from here` line is never a pass. It means this host cannot see the answer, so run `guard doctor` again where it can: on a cluster login node for the account cap, or where `gh` can read the repository for the GitHub items. `guard doctor` writes nothing. It exits 1 while any item fails, and 0 otherwise.

GitHub offers rulesets on a private repository only on a paid plan or in an organization. On a free personal account, `guard doctor` reports that GitHub offers no rulesets for the repository. Until you make the repository public or move it, nothing protects its default branch.

## 4. Protect the default branch

The `guard-fence / fence` check exists only after the merge in [step 3](../README.md#3-fill-in-the-guard-and-merge-it), and GitHub offers it in the ruleset form only after it has run once. Open any small pull request first, then:

1. On GitHub, open the repository and go to **Settings → Rules → Rulesets → New ruleset → New branch ruleset**.
2. Set **Enforcement status** to **Active**. Under **Target branches**, choose **Add target → Include default branch**.
3. Select **Require a pull request before merging**.
4. Select **Require status checks to pass**, choose **Add checks**, type `fence`, and pick `guard-fence / fence`.
5. Under **Bypass list**, add **Repository admin** and nobody else. Save.

## 5. Give agents weaker credentials

If an agent runs with your `gh` login or SSH key, it can use your bypass. Give it its own token:

1. On GitHub, go to **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.
2. Under **Repository access**, choose **Only select repositories** and pick the guarded repositories.
3. Under **Permissions**, set **Contents** and **Pull requests** to **Read and write**. Leave **Administration** at **No access**.
4. Run agents with that token as `GH_TOKEN`, an HTTPS remote, and no `SSH_AUTH_SOCK`.

To check it, open a pull request that edits `guard/budget.card`, so the fence fails, and run `GH_TOKEN=<agent token> gh pr merge <number> --admin --merge`. GitHub must refuse. Close the pull request afterwards.

## 6. Cap the cluster account

Ask your cluster admins for a Slurm sub-account with a hard core-hour cap, and put it in `guard/budget.card` as `account`. Preflight forces every job onto it, and the scheduler enforces the cap even for jobs submitted without preflight. Email template: [cluster-subaccount-request.md](cluster-subaccount-request.md). [enforcement.md](enforcement.md) explains why steps 4 to 6 matter.

## Check again

Run `guard doctor` again after each step. When every item passes, or reads `cannot check from here` only on hosts where it cannot, the setup is complete.
