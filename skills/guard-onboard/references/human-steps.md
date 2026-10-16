# Human-only steps

Step 5 of `SKILL.md` queues one needs-you item for each step below that is still open. Every `--path` is absolute and outside `/tmp`. `guard version` prints the harness path after `at`.

| Title | Kind | Click path or command | Path | Done when doctor prints |
|---|---|---|---|---|
| Merge the guard pull request | `approve` | `gh pr merge <n> --squash`, or the Merge button on GitHub | `<worktree>/guard/README.md` | `pass  guard/run is on origin/<default branch>` |
| Protect the default branch | `check` | Settings → Rules → Rulesets → New branch ruleset, as in step 4 of the doc | `<harness>/docs/enforceable.md` | `pass  <default branch> has an active ruleset requiring a pull request and guard-fence / fence` |
| Give agents a fine-grained token | `check` | Settings → Developer settings → Fine-grained tokens, as in step 5 of the doc | `<harness>/docs/enforceable.md` | `pass  the GitHub token in this shell is fine-grained` and `pass  the GitHub login in this shell does not administer <owner>/<repo>` |
| Start agents without your SSH key | `run` | `env -u SSH_AUTH_SOCK GH_TOKEN=<agent token> <agent command>` | `<harness>/docs/enforceable.md` | `pass  SSH_AUTH_SOCK is unset in this shell` |
| Ask for a capped cluster account | `check` | Send the email in the doc to the cluster admins, then put the account in `guard/budget.card` | `<harness>/docs/cluster-subaccount-request.md` | `pass  Slurm caps account <account> at GrpTRESMins=...` |
| Set an AWS budget | `check` | Billing and Cost Management → Budgets → Create budget, with an alert to your email | none | no doctor line; the budget is listed under Budgets |

Queue each row like this. A click path goes in `--why`, because `--run` holds shell commands only.

```shell
guard needs-you add --kind check --title "Protect the default branch" \
  --why "Open Settings → Rules → Rulesets → New branch ruleset on GitHub. Require a pull request and the guard-fence / fence check, bypass for Repository admin only." \
  --path "<harness>/docs/enforceable.md" \
  --expect 'guard doctor <repo> prints "pass  <default branch> has an active ruleset requiring a pull request and guard-fence / fence".' \
  --worry 'guard doctor <repo> prints "FAIL" or "cannot check from here" on the ruleset line.' \
  --source guard-onboard
guard needs-you show <id>
```
