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
    guard/run code <repo> <commit>                           print the path of a clean worktree at that commit
    guard/run launch <run_dir> --time=T --gpus=I,J|none --mem=GB -- <cmd>   run a job on a launch host, or refuse
    guard/run launch --stop <job_id> [--reason=<text>]        stop a launched job gently; --list [run_dir] shows them

Launch runs only on a host named in `budget.card`'s `launch_hosts`, by its short hostname as `hostname -s` prints it on that host, not an ssh alias. Its records live in `host_state_dir`; keep the default under `~/.local/state`, never a tmpfs such as `/tmp` on a host where `/tmp` is RAM-backed, or a reboot erases every record and the GPU-hour count.

`VERSION` records the guard schema and the harness commit that installed this directory. To update, a human runs `guard init <repo> --update` from an up-to-date harness4research clone. It merges your edits with the new scripts and proposes the result on a branch. Revert that pull request to roll back.

Installed by harness4research. See its README for why each piece exists.
