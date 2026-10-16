# Plan groups and compute

Step 3 of `SKILL.md` proposes changes in these groups, in this order. Leave out a group with nothing to do.

1. **Harness install.** `git clone https://github.com/0jrm/harness4research ~/harness4research && ~/harness4research/install.sh`. If the harness is already cloned, rerun `<harness>/install.sh`, for example after installing Cursor so `~/.cursor/skills` gets the links. Add `--pstack link` only if the user wants pstack in Claude Code or Codex. In Cursor, pstack comes from `/add-plugin pstack` instead.
2. **Repository guard.** `guard init <repo>` proposes `guard/` on branch `guard/init` in the worktree `<repo>.guard-init`, and never touches the checked-out tree. In that worktree, fill `guard/budget.card` with the user's values and add the files agents must not edit to `guard/watch.list`, one pathspec per line. Then commit, and push and open the pull request with the two commands `guard init` printed. For a guarded project that `guard version` reports as older, use `guard init <repo> --update` instead.
3. **User config.** `guard config set reviewer local`, `guard config set reviewer_cmd_local '<command>'`, `guard config set reviewer_cmd_proprietary '<command>'`. In a repository without a guard, `guard config set merge_policy semi-manual`. For a limited token budget, `guard config set reviewer_model sonnet` (claude and cursor-agent both accept it) and keep `ship_interval_hours` at 24. Without a limit, leave `reviewer_model` unset and run `guard config set ship_interval_hours 6`. In a guarded project, `merge_policy` lives in `guard/budget.card`, so it goes in the guard pull request.
4. **Claude Code hook.** `guard hooks install claude` adds hooks to `~/.claude/settings.json` that show open needs-you items at session start and on every prompt. It keeps the other settings. Use `--project` only if the user wants the hook in the repository's `.claude/settings.json`, which they then commit. Codex and Cursor have no such hook. Their users see the queue with `guard needs-you`.
5. **Human-only steps.** Each step in `references/human-steps.md` that doctor still reports as open.

## Compute

Map compute to `guard/budget.card` like this. `templates/guard/budget.card` lists every key.

- **Slurm.** `account` is a sub-account with a hard core-hour cap. Fill `cores_per_node`, the job limits, `start_date` and `stop_date` from the user's answers. A repository that submits no jobs may keep the placeholders.
- **GPU box or AWS instance.** Put the host in `launch_hosts`, written as `hostname -s` prints it on that host, not an ssh alias. Set `max_gpu_hours`, `host_max_walltime_minutes` and `host_max_mem_gb`. Agents then start compute there only with `guard/run launch <run_dir> --time=T --gpus=<i,j|none> --mem=<GB> -- <command>`. A new AWS instance usually gets a new hostname, and launch refuses it until the card lists it.
- **AWS spend.** Tell the user plainly that the guard does not cap AWS spend. Launch caps GPU-hours, memory and walltime per job, but instance hours, storage and data transfer are billed whether or not a job runs. AWS Budgets is the human's wall, and setting it up is a human-only step.
- **PBS, LSF or Flux.** Preflight submits with `sbatch` only, so the guard cannot submit or cap jobs there. Say so, and leave the scheduler keys as placeholders.
