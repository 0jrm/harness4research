# guard/

This directory holds the limits and checks that AI agents work under. A human changes it. Agents do not.

- `budget.card` sets the computing budget. `guard/run preflight` reads it from the protected branch before each job.
- `watch.list` names the verifier, test and threshold paths that agents must not edit.
- `bin/` holds the scripts. `guard/run <command>` always runs the protected branch's copy.
- `SURVEY.md` is the read-only inventory that `guard init` wrote. Delete it after the reset.

Commands:

    guard/run preflight <run_dir> <job.sh> [sbatch options]   submit a job, or refuse
    guard/run ripples <run_dir>                              check warning signs, exit 1 on any
    guard/run manifest <run_dir> "$0" "$@"                   first line of work in each job script
    guard/run fence [base] [head]                            the merge inspector, also run by CI

Installed by harness4research. See its README for why each piece exists.
