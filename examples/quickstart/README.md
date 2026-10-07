# Quickstart walkthrough

One command builds a guarded throwaway project and walks one experiment through the whole guard, with a fake `sbatch` and no cluster. It takes about two seconds and needs bash, git and python3.

```bash
~/harness4research/examples/quickstart/run.sh ~/guard-quickstart
```

The directory argument is optional and defaults to `~/guard-quickstart`. A rerun replaces the directory only when an earlier run of this script created it, and refuses any other existing directory.

## What it shows

1. `guard init` proposes the guard, and a human fills in the budget card and merges it.
2. A human commits the domain checks. An agent commits the question card before any compute.
3. The agent raises its own walltime cap on its branch, and preflight refuses the submission.
4. Preflight accepts the real submission, and the job records a manifest.
5. The agent writes the report, and the fence passes it because every number names its artifact.
6. Ripples reads the job state, the budget and each domain check after the job.

The summary prints absolute paths to the question card, the report, the manifest and the budget card, and the command that draws the atlas page for the project.

## The experiment

The payload, `campaign.py`, searches for a small team of decision stumps that classifies the UCI breast-cancer data set ([data/README.md](data/README.md)). It uses no language model. The question card pairs its main metric with a partner metric that punishes predicting the majority class. Selection favors faster teams, so the selected team, and its accuracy, can change between runs on a busy machine.

## Before a real job

Each check in `checks/` exits 77 while `campaign.json` does not exist yet. Ripples reports that as UNCHECKED, so the first preflight can pass. A check that fails for any other reason is a RIPPLE and stops new submissions.
