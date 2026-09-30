# Live test on gom-da-workspace

This test exercises everything, including the cluster half. It runs in three sittings.
- Sitting 1 covers the repository reset, about two hours.
- Sitting 2 is a five-minute cluster smoke job.
- Sitting 3 is the first carded run.

The suspects listed below come from conversations in September 2026. They are leads for the poison pass to check, not facts.

## Sitting 1. Reset the repository

### Install and survey

```shell
~/harness4research/install.sh --pstack skip
cd ~/gom-da-workspace && git fetch --prune && git remote set-head origin -a
guard survey ~/gom-da-workspace > /tmp/gom-survey.md
guard archive ~/gom-da-workspace
guard init ~/gom-da-workspace
```

Expected: the survey lists the P3 and P4 branch families and any nested ISAS20 clone under "Duplicate trees and nested repositories". The archive prints tag and delete commands and changes no remote. Init creates `~/gom-da-workspace.guard-init`.

### Configure the guard in the worktree

`guard/watch.list`. List what the implementing agent must not change. Likely candidates, to confirm against the tree:

```text
runs/*/checks/*
prereg/*
config/repos.toml
```

`prereg/` holds your pre-registrations. They are question cards in another format, so they get the same freeze. `config/repos.toml` pins the ISAS20 commit that results depend on.

`guard/budget.card`. Fill every field. Use the capped sub-account if RCC has created it (template: [cluster-subaccount-request.md](../cluster-subaccount-request.md)). Otherwise use your allocation with a conservative `max_core_hours`, and record that the cap is not yet enforced by the scheduler. For `quota_pct_cmd`, use your site's quota command piped to print one percentage.

Commit, push, open the PR, merge it, and add the ruleset as in the runhub test, step 4.

### Poison pass

Run the "Poison pass" prompt from [prompts.md](../prompts.md) in the worktree, with this addition at the end:

```text
Known suspects to check first. Each is a claim from an old conversation; confirm or refute each with evidence:
1. The experiment plan's description of the TSIS observation operator does not match what TSIS executes.
   The E0 null test (PR 25) showed zprofile2lyr maps a zero-innovation profile to a nonzero layer increment.
2. The observation-error file used by the assimilation runs is a smoke-test placeholder that was never replaced.
3. ISAS20 exists in three places (skynet training tree, a laptop directory that is not a git checkout, and a
   nested clone). Which one does config/repos.toml pin, and which do scripts actually import?
4. Scripts or docs still reference the dropped mix-d metric.
5. HANDOFF names more than one canonical job id for the same run.
6. Parked units P5, P6, P7, and P9, and open or conflicting PRs (24, 27): which are live work and which are history?
```

Expected in `guard/RESET.md`:
- a rewrite row for the plan's operator description, citing PR 25
- a row for the obs-error file
- a keep, kill, or archive verdict for each ISAS20 tree
- evidence on every row
- no other file changed

### Reset

Mark the rows you approve with `[x]` and run the "Reset execution" prompt. Expected: one small PR per bin, each passing `guard-fence`. `FACTS.md` gains only lines you approve.

## Sitting 2. Cluster smoke job

On the cluster, in a clone of the repository:

```shell
cd <clone> && git pull && git remote set-head origin -a
mkdir -p runs/explore-hello
cat > runs/explore-hello/job.sh <<'JOB'
#!/bin/bash
#SBATCH --nodes=1
#SBATCH --time=00:05:00
guard/run manifest runs/explore-hello "$0" "$@"
hostname
JOB
guard/run preflight runs/explore-hello runs/explore-hello/job.sh
```

Wait for the job to finish, then run `guard/run ripples runs/explore-hello`.

Expected:
- preflight prints `PREFLIGHT OK` and a job id
- `runs/explore-hello/manifest-<jobid>.txt` exists with the commit and loaded modules
- ripples prints PASS for job states and walltime, the budget line shows a spent figure, and quota is PASS or UNCHECKED

If ripples shows empty job rows, your site's `sacct` fields differ. Record the output of `sacct -X -n -P -o JobID,JobName,State,ElapsedRaw,TimelimitRaw -S <today>` and fix `guard/bin/ripples.sh` in a PR.

Then test one refusal: rerun preflight with `--nodes=2`. Expected: `exceeds max_nodes_per_job=1`.

## Sitting 3. First carded run

Start with a result you already trust. If the clean setup reproduces it, the reset is proven. Use the "First carded run" prompt from [prompts.md](../prompts.md) with:

```text
Question: Does one TSIS cycle with real Argo profiles, run from the current pinned commits, reproduce the
operational thermocline error of about 0.50 °C at 50-200 m?
```

Expected: the agent shows you the card before compute. The report's evidence rows name files, job ids, and commits, and the fence passes on the report PR.

The second card is the E0 null test, which has a known right answer:

```text
Question: Does TSIS return a zero increment when fed profiles equal to the background?
```

Draft of that card, to be completed with your paths and commits:

```text
question: Does TSIS return a zero increment when fed profiles equal to the background?
decision_this_informs: whether any NeSPReSO ingest result is interpretable before the operator is fixed
hypothesis: no; zprofile2lyr produces a nonzero layer increment
metric: max |increment| per variable and layer, <script path> @ <commit>
partner_metric: fraction of observations at the clip bounds
baseline: operational TSIS cycle with real Argo, same date
baseline_tolerance: <number>
kill_criteria: stop if the zero-innovation construction cannot itself be verified as zero
negative_result_means: the operator preserves identity; the January damage lies in observation error or sign
out_of_scope: compiling TSIS
```

## Results

| Step | Expected | Observed | Pass |
|---|---|---|---|
| survey, archive, init | leads listed, tags only, worktree | | |
| poison pass | operator and obs-error rows with evidence | | |
| reset PRs | small, fence green | | |
| cluster smoke | manifest, ripples PASS | | |
| refusal | nodes cap refused | | |
| baseline card | card shown before compute | | |
| baseline report | evidence paths, fence green | | |
