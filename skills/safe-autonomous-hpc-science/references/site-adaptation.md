# Site adaptation

Read this before the first submission at a new site, or when the scheduler is not Slurm.

The scripts target Slurm. PBS maps to `qsub`, `qstat`, `-W depend=`, and Flux to `flux batch`, `flux jobs`. Port preflight's three scheduler calls and ripples' one `sacct` call in `guard/bin/`, in a pull request the human merges. `guard init --update` merges the port with later releases and shows overlapping lines as conflicts for the human. When the difference is a value rather than code, ask the human for a budget-card key instead, as `quota_pct_cmd` is. Check the site docs for flag names, the scratch purge policy, and login-node rules before the first submission, and log the source.
