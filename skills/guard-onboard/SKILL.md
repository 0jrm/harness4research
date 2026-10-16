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

Run these in the repository. `guard doctor` reads the credentials of the shell it runs in, so run it in the shell your agent sessions start from. Each doctor run is saved in a folder that all worktrees share and git never commits, so a later run can compare against it.

```shell
cd <repo>
guard version
guard config list
state="$(cd "$(git rev-parse --git-common-dir)" && pwd)/guard/onboard"; mkdir -p "$state"
ls -t "$state"/doctor-*.txt 2>/dev/null | head -n 1
guard doctor . | tee "$state/doctor-$(date -u +%Y%m%dT%H%M%SZ).txt"
```

The `ls` line prints the previous run's file, or nothing on a first setup. If `guard` is not found, the plan starts with the install. If doctor prints `FAIL  guard/run is not on origin/<default branch>`, also run `guard survey .`.

## 2. Ask what the commands cannot show

Ask the five questions in `references/questions.md` (agents, compute, merge policy, reviewer, token budget) once, in a single message, with options and a recommended answer for each. Skip any question the output already answers, and never ask about what doctor reports. The file also says what a local reviewer command must do.

## 3. Propose a numbered plan

List each change with its exact command and one sentence on what it changes. Group them in this order, leaving out empty groups. Open `references/plan-groups.md` while writing it: it has each group's full commands and conditions, and how each kind of compute maps to `guard/budget.card`.

1. **Harness install.** `git clone https://github.com/0jrm/harness4research ~/harness4research && ~/harness4research/install.sh`; if already cloned, rerun `<harness>/install.sh`.
2. **Repository guard.** `guard init <repo>` proposes `guard/` in the worktree `<repo>.guard-init`. Fill `guard/budget.card` and `guard/watch.list` there, commit, and push and open the pull request with the two commands it printed. For a guarded project that `guard version` reports as older, use `guard init <repo> --update`.
3. **User config.** `guard config set` for the reviewer, for `merge_policy` in a repository without a guard, and for `reviewer_model` and `ship_interval_hours` from the token budget.
4. **Claude Code hook.** `guard hooks install claude`. Codex and Cursor users, who have no such hook, see the queue with `guard needs-you`.
5. **Human-only steps.** Each step in `references/human-steps.md` that doctor still reports as open.

If compute runs on AWS, tell the user plainly that the guard does not cap AWS spend; AWS Budgets is the human's wall. On PBS, LSF or Flux, say the guard cannot submit or cap jobs there.

## 4. Apply what the user confirms

Run a change only after the user confirms its number; they may confirm several at once. Run one command at a time, and stop at the first error to show it. After the last change, rerun and save doctor, then compare it with the run from step 1, leaving out the indented remedy lines:

```shell
guard doctor . > "$state/doctor-$(date -u +%Y%m%dT%H%M%SZ).txt"
diff <(grep -v '^      ' "<step 1 file>") <(grep -v '^      ' "<new file>")
```

Show the diff lines, and say in a sentence which items went from FAIL to pass and which are still open.

## 5. Queue what only the human can do

Never create, read, or change tokens, SSH keys, branch rulesets, cluster accounts, or AWS budgets, and never merge a change to `guard/`, which includes the guard pull request. Queue one needs-you item for each that is still open. Every `--path` is absolute and outside `/tmp`. A click path goes in `--why`, because `--run` holds shell commands only.

Open `references/human-steps.md` before queueing: it lists the six steps, each with its kind, path and the doctor line that marks it done, and a full `guard needs-you add ... --source guard-onboard` then `guard needs-you show <id>` example. The guard pull request is done when doctor prints `pass  guard/run is on origin/<default branch>`.

Paste the printed blocks after your reply, as the present skill says. Never write a 🩺 block by hand, and never ack, finish, or dismiss an item.

## Re-boarding

"Check my setup" reruns these steps on the existing setup. Diff step 1's doctor output against the previous run's file that `ls` printed, as in step 4, and show what changed. Ask only the questions whose answers may have changed, showing the current answers from `guard config list` and `git show origin/HEAD:guard/budget.card`. Propose only the deltas: new FAIL lines, a `guard version` that reports either side older, and changes the user asks for. Queue a human-only step only if `guard needs-you` does not already list it.
