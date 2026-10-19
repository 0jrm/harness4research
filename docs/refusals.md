# Refusal codes

Generated from `lib/refusals.py` by `python3 lib/refusals.py markdown`; `tests/refusals.sh` checks that this page matches it.

Every refusal is two lines: `H4R-<code> <reason>`, then a command to run as it is. The exit status is 2, or 3 when the job was queued. Line 2 contains no `<`, no `...` and no `[`, and its first word is one of `guard`, `git`, `cd`, `cat`, `scancel`, `kill`, `none`.

| Code | From | Line 1 after the code | Line 2 | Exit |
|---|---|---|---|---|
| R01 | run | `usage: <what>; --why is one sentence on one line` | the agent's command, corrected | 2 |
| R02 | run | `time <time> exceeds max_walltime_minutes <max>; split the work into jobs that resume from a checkpoint` | the agent's command, corrected | 2 |
| R03 | run | `nodes <nodes> exceeds max_nodes_per_job <max>` | the agent's command, corrected | 2 |
| R04 | run | `gpus <gpus>: the card allows <max>` | the agent's command, corrected | 2 |
| R05 | run | `job <job> ended <state>; read its log, then rerun with --cause and what went wrong` | `cat <log>` | 2 |
| R06 | run | `<paths> differ from main and the human owns them` | `git checkout origin/main -- <paths>` | 2 |
| R07 | run | `<script> is not a file`; or `sbatch said: <line>` | the agent's command, corrected | 2 |
| R08 | run | `<core_hours> core-h is over the remaining <remaining>; queued as ask <ask>, default no at <due> UTC`; or `<core_hours> core-h is over run <run>'s cap <cap>; queued as ask <ask>, default no at <due> UTC` | `guard status` | 3 |
| R09 | old path | `<old> is gone; guard run writes the card and prices the job` | the agent's command, corrected | 2 |
| R10 | run | `<n> jobs live is max_concurrent_jobs` | `guard wait <oldest>` | 2 |
| R11 | run | `this exact job is already <state> as <job>` | `guard wait <job>` | 2 |
| R12 | run | `<run_dir> is outside the project` | `cd <project>` | 2 |
| R13 | run, host | `<time> min exceeds host_max_walltime_minutes <max>`; or `mem <mem> GB exceeds host_max_mem_gb`; or `<gpu_hours> GPU-h over the remaining <remaining> of max_gpu_hours`; or `<flag> is not for a launch host` | the agent's command, corrected | 2 |
| R14 | run, host | `<host> has <available> GB available under host_min_available_gb <min>`; or `<free> GPUs free, <asked> asked`; or `no nvidia-smi`; or `no bwrap`; or `the supervisor did not start: <reason>` | the agent's command, corrected | 2 |
| R15 | any verb | `the broker is down; nothing reaches the scheduler from here` | `none` | 2 |
| R16 | run | `past stop_date <date>` | `guard ask 'stop_date passed; extend it?' --default no --deadline 2h` | 2 |
| R17 | run | `partition <partition> is not in partitions <allowed>` | the agent's command, corrected | 2 |
| R18 | run | `dependency names job <job>, which this session did not submit` | the agent's command, corrected | 2 |
| R19 | run | `output <output> is outside the project` | the agent's command, corrected | 2 |
| X00 | socket | `<verb> is not built in this harness` | `guard status` | 2 |
| G01 | guard review, merge, ship in a sandbox | `runs outside the sandbox; push and stop` | `git push origin <branch>` | 2 |
| C01 | compute gate | `<entry> runs only inside a job; guard/budget.card lists it under compute` | `guard run runs/<run> --why 'Run <script> for run <run>.' -- --time=<minutes> <script>` | 2 |
| S01 | shim | `pkill -f '<pattern>' would kill processes outside your jobs` | `guard status` | 2 |
| S02 | shim | `rm -rf <path> is outside <run_dir>` | `none` | 2 |
| S03 | shim | `force push to <branch> is refused; a landed commit is redone, not rewritten` | `git pull --rebase origin <branch>` | 2 |
| F01 | fence | `guard-untouched: <paths>` | the agent's command, corrected | 2 |
| F02 | fence | `watched-paths: <paths>` | the agent's command, corrected | 2 |
| F03 | fence | `<path> is a card only the broker writes` | the agent's command, corrected | 2 |
| F04 | fence | `evidence-paths: <where> cites no committed path or receipt` | `none` | 2 |
| F05 | fence | `execution-ledger: <reason>` | `none` | 2 |
| F06 | fence | `refs: <ref> not found` | `git fetch origin` | 2 |
| F07 | fence | `execution-history: <reason>` | `none` | 2 |
| W01 | wait | `no job, pid or host job <id>` | `guard status` | 2 |
| W02 | wait | `job <id> belongs to another session` | `guard status` | 2 |
| W03 | wait | `--timeout takes s, m or h up to 5m` | `guard wait <id> --timeout 5m` | 2 |
| A01 | ask | `say the question, then --default and --deadline` | `guard status` | 2 |
| A02 | ask | `name the default: yes, no, or one of [<words>]` | the agent's command, corrected | 2 |
| A03 | ask | `--deadline takes 5m, 30m or 2h` | the agent's command, corrected | 2 |
| A04 | ask | `no ask <id>; open: <open>` | `guard status` | 2 |
| H01 | holdout | `<ledger_id> fail: the solution does not generalize to new entities; <k> of <n> left` | `guard holdout score` | 2 |
| H02 | holdout | `<ledger_id> unscorable: did not finish on both sets in <s> s, or the layout is wrong; <k> left` | `guard holdout score` | 2 |
| H03 | holdout | `<n> of <n> submissions used this session` | `guard status` | 2 |
| H04 | holdout | `no holdout sealed for this project` | `none` | 2 |
| H05 | holdout | `no broker in this session` | `none` | 2 |
