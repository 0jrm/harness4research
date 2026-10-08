# Live test on runhub

runhub has no cluster jobs, so this test exercises the repository half: survey, archive, init, the fence on GitHub, the poison pass, and the credential check. Plan about an hour.

Record each result in the last section. A test passes when every expected result holds.

## 0. Install

```shell
git clone https://github.com/0jrm/harness4research ~/harness4research
~/harness4research/install.sh                  # add --pstack link for pstack, unless a pstack plugin is already installed
guard version
```

Expected: `guard version` prints this repo's commit, and `pstack not-linked`, or the pinned cursor/plugins commit after `--pstack link`.

## 1. Survey

```shell
cd ~/runhub && git fetch --prune && git remote set-head origin -a
guard survey ~/runhub | less
```

Expected, from a read of the public repo on 2026-09-29:
- 18 branches besides `origin/main`, 13 of them fully merged
- `SANDBOX.md:11` under "Undecided or temporary language", which recommends the dedicated-user design that commit `7c2d95c` reverted
- four commit subjects that are prompt text, including one with a local home path
- `git -C ~/runhub status` unchanged afterwards

## 2. Archive

```shell
guard archive ~/runhub
```

Expected: tags under `archive/<today>/` for every branch, and printed push and delete commands. Nothing is pushed or deleted. Run the printed tag push. Run the delete command only after checking the unmerged list.

## 3. Init

```shell
guard init ~/runhub
```

Expected: a worktree at `~/runhub.guard-init` on branch `guard/init`, one commit, and `~/runhub` still on its own branch with no changes.

In the worktree:
- `guard/watch.list`: replace the default with `test/contract.ts`, the contract test you own. Do not list all of `test/`, or agents cannot add tests.
- `guard/budget.card`: leave the placeholders. runhub submits no jobs, and preflight refuses placeholders.
- Commit, push, and open the PR with the commands init printed. Merge it yourself.

## 4. Protect main and check the fence

On GitHub: Settings, Rules, Rulesets, New branch ruleset for the default branch. Require a pull request, and require the status check `guard-fence / fence`. Put only yourself on the bypass list.

Then open three throwaway PRs from branches off main:
1. Edit `README.md`. Expected: `guard-fence` passes.
2. Append a line to `guard/budget.card`. Expected: `guard-fence` fails with `FAIL guard-untouched`.
3. Append a comment to `.github/workflows/guard-fence.yml`. Expected: it fails, and the run log shows the base branch's workflow ran, not the edited one.

Close all three unmerged.

## 5. Credential check

Create a fine-grained token for agents as described in [enforcement.md](../enforcement.md), step 2. With it:

```shell
GH_TOKEN=<agent token> gh pr merge <number of PR 2> --admin --merge -R 0jrm/runhub
```

Expected: refused. If it merges, the token can bypass the ruleset. Revert the merge and record the result, because the fence is then only a speed bump for agents that use this token.

## 6. Poison pass through runhub itself

Dispatch the "Poison pass" prompt from [prompts.md](../prompts.md) through runhub on the `guard/init` branch. Or paste it into Claude Code, Cursor, or Codex opened in `~/runhub.guard-init`.

Expected in `guard/RESET.md`:
- `SANDBOX.md` binned rewrite, with the corrected statement that option a was reverted in `7c2d95c` and that agents run under your account with the risk accepted
- `audit-enhance.md` binned archive or move, since it is a skill file in the product root
- the merged branches either left to `guard archive` or listed with evidence
- no file other than `guard/RESET.md` changed: `git -C ~/runhub.guard-init status` shows only that file

## 7. Results

| Step | Expected | Observed | Pass |
|---|---|---|---|
| 0 install | versions print | | |
| 1 survey | SANDBOX.md flagged, 13 merged | | |
| 2 archive | tags only | | |
| 3 init | worktree, one commit | | |
| 4 fence | pass, fail, fail | | |
| 5 token | merge refused | | |
| 6 poison pass | SANDBOX.md rewrite row | | |
