---
name: guard-onboard
description: >-
  Set up harness4research for a person and a repository, or recheck a setup
  that already exists. Use when the user says "set up harness4research",
  "onboard me", "check my setup", "re-board", "is my guard set up right", or
  asks how to start using guard with their agents and compute. Reads guard
  version, guard doctor and guard survey, asks only what those cannot show,
  proposes numbered changes with exact commands, applies each one after the
  user confirms it, and queues every human-only step as a 🩺 item.
---

# Guard onboard

You walk one person through setting up the harness for one repository. You change only what the user confirms in this conversation. The commands report the current state, so read their output instead of guessing.

## 1. Read the current state

Run these in the repository and read their output. `guard doctor` reads the credentials of the shell it runs in, so run it in the shell your agent sessions start from. Each doctor run is saved in a folder that every worktree of the repository shares and git never commits, so a later run can compare against it.

```shell
cd <repo>
guard version
guard config list
state="$(cd "$(git rev-parse --git-common-dir)" && pwd)/guard/onboard"; mkdir -p "$state"
ls -t "$state"/doctor-*.txt 2>/dev/null | head -n 1
guard doctor . | tee "$state/doctor-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

The `ls` line prints the previous run's file, or nothing on a first setup. If `guard` is not found, the harness is not installed, and the plan starts with the install. If doctor prints `FAIL  guard/run is not on origin/<default branch>`, also run `guard survey .`.

## 2. Ask what the commands cannot show

Ask once, in a single message, with options and a recommended answer for each. Skip any question that the output already answers. Do not ask about anything doctor reports.

```text
1. Which agents do you run? Claude Code, Codex, Cursor, a local model (through which front-end and model: Codex with --oss on Ollama or LM Studio, or another CLI). Recommended: the one you are using now.
2. Where does compute run? A Slurm cluster (its name, and the account agents should charge, if you have one), a GPU box without a scheduler, AWS instances, another HPC scheduler (PBS, LSF, Flux), or nowhere yet. Recommended: nowhere yet, if you are unsure.
3. Merge policy. autonomous: guard merge merges once the reviewer approves and every check passes, and refuses while the gh login can administer the repository or no ruleset requires a pull request. semi-manual: the review still runs, and you click every merge. Recommended: autonomous.
4. Reviewer. proprietary: claude, falling back to cursor-agent when claude is missing or fails, or a command you name. local: a command you name that runs a local model. Recommended: proprietary.
5. Token budget. Are you limited on tokens or usage, by an API budget or a subscription's limits? A model review costs about 300,000 to 400,000 input tokens, run records cost none, and up to 8 small pull requests share one review session. limited: reviews use a smaller model, and guard ship runs once a day. not limited: the default model, and guard ship every few hours so merges and the question card digest arrive sooner. Recommended: limited, if you are unsure.
```

A local reviewer command must run without a prompt from a person, take the prompt as its last argument, work in the current directory, and print its reply on stdout. `codex exec --oss -m <model> --sandbox danger-full-access` fits.

## 3. Propose a numbered plan

List each change with its exact command and one sentence on what it changes. Group the changes in this order, and leave out a group with nothing to do.

1. **Harness install.** `git clone https://github.com/0jrm/harness4research ~/harness4research && ~/harness4research/install.sh`. If the harness is already cloned, rerun `<harness>/install.sh`, for example after installing Cursor so `~/.cursor/skills` gets the links. Add `--pstack link` only if the user wants pstack in Claude Code or Codex. In Cursor, pstack comes from `/add-plugin pstack` instead.
2. **Repository guard.** `guard init <repo>` proposes `guard/` on branch `guard/init` in the worktree `<repo>.guard-init`, and never touches the checked-out tree. In that worktree, fill `guard/budget.card` with the user's values and add the files agents must not edit to `guard/watch.list`, one pathspec per line. Then commit, and push and open the pull request with the two commands `guard init` printed. For a guarded project that `guard version` reports as older, use `guard init <repo> --update` instead.
3. **User config.** `guard config set reviewer local`, `guard config set reviewer_cmd_local '<command>'`, `guard config set reviewer_cmd_proprietary '<command>'`. In a repository without a guard, `guard config set merge_policy semi-manual`. For a limited token budget, `guard config set reviewer_model sonnet` (claude and cursor-agent both accept it) and keep `ship_interval_hours` at 24. Without a limit, leave `reviewer_model` unset and run `guard config set ship_interval_hours 6`. In a guarded project, `merge_policy` lives in `guard/budget.card`, so it goes in the guard pull request.
4. **Claude Code hook.** `guard hooks install claude` adds hooks to `~/.claude/settings.json` that show open needs-you items at session start and on every prompt. It keeps the other settings. Use `--project` only if the user wants the hook in the repository's `.claude/settings.json`, which they then commit. Codex and Cursor have no such hook. Their users see the queue with `guard needs-you`.
5. **Human-only steps.** Each step in the table below that doctor still reports as open.

Map compute to the card like this.

- **Slurm.** `account` is a sub-account with a hard core-hour cap. Fill `cores_per_node`, the job limits, `start_date` and `stop_date` from the user's answers. A repository that submits no jobs may keep the placeholders.
- **GPU box or AWS instance.** Put the host in `launch_hosts`, written as `hostname -s` prints it on that host, not an ssh alias. Set `max_gpu_hours`, `host_max_walltime_minutes` and `host_max_mem_gb`. Agents then start compute there only with `guard/run launch <run_dir> --time=T --gpus=<i,j|none> --mem=<GB> -- <command>`. A new AWS instance usually gets a new hostname, and launch refuses it until the card lists it.
- **AWS spend.** Tell the user plainly that the guard does not cap AWS spend. Launch caps GPU-hours, memory and walltime per job, but instance hours, storage and data transfer are billed whether or not a job runs. AWS Budgets is the human's wall, and setting it up is a human-only step.
- **PBS, LSF or Flux.** Preflight submits with `sbatch` only, so the guard cannot submit or cap jobs there. Say so, and leave the scheduler keys as placeholders.

## 4. Apply what the user confirms

Run a change only after the user confirms its number. They may confirm several numbers at once. Run one command at a time, and stop at the first error to show it. After the last change, rerun and save doctor, then compare it with the run from step 1, leaving out the indented remedy lines:

```shell
guard doctor . > "$state/doctor-$(date -u +%Y%m%dT%H%M%SZ).txt"
diff <(grep -v '^      ' "<step 1 file>") <(grep -v '^      ' "<new file>")
```

Show the diff lines in the reply, and say in a sentence which items changed from FAIL to pass and which are still open.

## 5. Queue what only the human can do

Never create, read, or change tokens, SSH keys, branch rulesets, cluster accounts, or AWS budgets, and never merge a change to `guard/`, which includes the guard pull request. For each of these that is still open, queue one needs-you item and paste the block it prints. Every `--path` is absolute and outside `/tmp`. `guard version` prints the harness path after `at`.

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
  --source guard-onboard
guard needs-you show <id>
```

Paste the printed blocks after your reply, as the present skill says. Never write a 🩺 block by hand, and never ack, finish, or dismiss an item.

## Re-boarding

"Check my setup" runs the same steps against the existing setup. Diff step 1's doctor output against the previous run's file that `ls` printed, the same way as in step 4, and show what changed since then. Ask only the questions whose answers may have changed, and show the current answers from `guard config list` and `git show origin/HEAD:guard/budget.card`. Propose only the deltas: new FAIL lines, a `guard version` that reports either side older, and changes the user asks for. Queue a human-only step only if `guard needs-you` does not already list it.
