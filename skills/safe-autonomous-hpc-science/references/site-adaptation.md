# Site adaptation

Read this before the first submission at a new site, or when the scheduler is not Slurm.

The scripts target Slurm. PBS maps to `qsub`, `qstat`, `-W depend=`, and Flux to `flux batch`, `flux jobs`. The broker makes every scheduler call (`sbatch`, `squeue`, `sacct`, `scancel`); a port is a harness change, in a pull request to harness4research the human merges. When the difference is a value rather than code, ask the human for a budget-card key instead, as `quota_pct_cmd` is. Check the site docs for flag names, the scratch purge policy, and login-node rules before the first submission, and log the source.
