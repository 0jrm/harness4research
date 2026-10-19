# guard/

This directory holds the limits and checks that AI agents work under. A human changes it. Agents do not.

- `budget.card` sets the computing budget. `guard run` reads it from the protected branch, never the checkout, before it prices and submits each job.
- `watch.list` names the verifier, test and threshold paths that agents must not edit.
- `budget.card`'s `harness:` line pins the harness4research release the scripts come from. `guard/run <command>` reads the pin from the protected branch and runs that release's script: from the harness clone, checked out at the pin, or, on a host that cannot reach the harness, from `harness-<pin>.sh` in this directory. To update, a human changes the pin in a pull request; to roll back, reverts it.
- `broker_key:` in `budget.card` is the broker's public key. The fence trusts a receipt id only when its commit on `guard/receipts` is signed by this key, so only a person changes the line.
- `SURVEY.md` is the read-only inventory that `guard init` wrote. Delete it after the reset.

Agent commands, which `AGENTS.md` names:

    guard run runs/<run_id> --why "<sentence>" -- <sbatch options> <script>   price and submit a job, or refuse
    guard wait <job_id> | -- <command>                                        wait, with the last lines every 5 minutes
    guard ask "<question>" --default <option> --deadline 30m                  a question for a person
    guard status                                                              what runs, what is blocked, what next

Guard scripts, which the human, CI and job scripts run:

    guard/run manifest <run_dir> "$0" "$@"     first line of work in each job script
    guard/run fence [base] [head]              the merge inspector, also run by CI
    guard/run code <repo> <commit>             print the path of a clean worktree at that commit

On a host named in `budget.card`'s `launch_hosts`, by its short hostname as `hostname -s` prints it on that host, not an ssh alias, `guard run` launches the job under the host supervisor instead of Slurm. Its records live in `host_state_dir`; keep the default under `~/.local/state`, never a tmpfs such as `/tmp` on a host where `/tmp` is RAM-backed, or a reboot erases every record and the GPU-hour count. `max_gpu_hours: 0` refuses every GPU job on a launch host until a person raises it.

`VERSION` records the guard schema and the harness commit that installed this directory. To update, a human runs `guard init <repo> --update` from an up-to-date harness4research clone. It proposes the new `harness:` pin on a branch. Revert that pull request to roll back.

Installed by harness4research. See its README for why each piece exists.
