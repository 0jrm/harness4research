# Draft: sandboxed agents, with a broker for every way out

Merged from two independent designs written from the same brief on 2026-10-13. The originals stay on the owner's laptop in `.audit/launcher/`. Waiting on the owner's decisions, listed at the end.

## The idea

An agent session runs inside the same rootless bubblewrap sandbox the evaluation uses: no network, no credentials, no scheduler access of its own, and nothing writable but the project and an agent home. Every way out is a unix socket served by one process outside, `guard broker`. The broker holds the Slurm access, the agent's GitHub token, the model key and the records, and it checks each request against state the agent cannot write. A sandbox that should not do something, such as the reviewer's sandbox submitting jobs, simply lacks that socket.

The audit's expectation: 20 of the 21 bypassed rows flip to held. Special-casing a test input stays bypassed, because only detection catches it.

## Commands

```shell
guard broker setup                      # once per host: agent token, model keys, allowlist, self-test
guard enter ~/proj -- claude            # every session; any agent, any argv
guard enter ~/proj --no-tty -- codex exec "..."   # what runhub calls
guard broker status                     # sessions, live jobs, recent refusals
```

`guard enter` follows Fable's design, because it takes any argument list and so works with agents that aren't ours. Per-agent profiles under `~/.config/guard/agents/` follow Opus's design: they list each agent's binaries and the config files to copy into its home, never credential files.

## The sandbox

It is built by `lib/box.sh`, from `eval/env/sandbox.sh`.

- **Bound at their real paths:** the project, and a per-agent home seeded from the profile, sitting where `$HOME` would be. Paths agree inside and out, and the rest of `$HOME` doesn't exist: `~/.ssh`, `~/.config/gh` and `~/.config/guard` are all absent.
- **Read-only:** `/usr`, `/etc`, `/opt`, the harness, the agent's own binaries, and the stand-in commands first on `PATH`: `sbatch`, `squeue`, `sacct`, `scancel`, `gh`, `guard`.
- **Invisible:** `/run/munge` (without it, a real `sbatch` can't authenticate), `/run/user/$UID` (the ssh-agent and dbus), the host's network and processes, GPUs, and all of the broker's state.
- **Sockets:** under `/tmp/guard-$UID/s-<session>/`, mode 0700. Socket files fail on NFS homes, and skynet has no `XDG_RUNTIME_DIR` in non-interactive sessions.
- **The pre-flight probe:** before starting the agent, the launcher runs the audit's sandbox checks inside the new sandbox, and starts nothing if any fails.

## The broker

It is one standard-library Python process per user per host, built from `fakeslurm.py`'s server, `gitsock.py` and `proxy.py`. It starts with the first session and outlives it, as Opus proposes, because jobs outlive sessions. Its state, under `~/.local/state/guard/`, is the job ledger, a mirror of `origin`, a worktree of the protected `main`, the records and the gateway logs. It fails closed: when the broker is down, the sockets refuse, and the agent has no binary, credential or route to fall back on.

**Who is calling.** The socket's directory names the session. `SO_PEERCRED` must show the user's uid, and the caller's process namespace must match the one recorded for that sandbox. Nothing the caller reports about itself is trusted, which also closes the `forged-chain` row.

**The scheduler, in four steps:**
1. **Normalise.** One parser reads every option form, on the command line and in `#SBATCH` lines, short and long, with `=` or a space. It accepts an allowlist only: `time nodes ntasks cpus-per-task mem array gres gpus partition dependency output error chdir parsable`. Anything else is refused, including `--export`, `--wrap` and `--get-user-env`. The agent's environment never crosses the socket.
2. **Apply the policy, from the mirror's `main` only.** The budget card and the protected `preflight.sh` come from the mirror, never from the agent's clone or environment. Explore runs get the smaller of the explore and project caps. Live jobs and spend are counted with `squeue` and `sacct` called by absolute path, plus the broker's own pending submissions. The reserve becomes a verb a person approves outside the sandbox: `guard approve reserve <run>`.
3. **Rewrite the submission.** The broker runs the real `sbatch --export=NONE` with its own `--account`, `--time`, `--nodes`, `--comment=guard:<session>:<seq>` and `--output` placed last, so whatever the script says, the scheduler sees the broker's values.
4. **Ledger first.** The broker records its intent before submitting, and reconciles by the comment tag after a crash. `squeue`, `sacct` and `scancel` see only the project's own ledger jobs.

**Jobs.** The broker submits a wrapper that runs the agent's script inside a job sandbox on the compute node, with no munge (so a job can't submit jobs), no home, no network, the allotted GPUs and the project at its real path. Slurm's output goes to a spool the agent can't write, so a planted symlink can't aim it at `~/.bashrc`, and the job sandbox copies it to the requested path. A probe job at setup checks that the compute nodes have bwrap.

**The model and the network.** A relay inside the sandbox turns `127.0.0.1` ports into sockets.
- **Model requests** go through `proxy.py`, generalised. The broker adds the API key from outside and logs every request, so the agent never holds a key. A local vLLM is simply an upstream with no key.
- **Package indexes** go through a CONNECT proxy that allows only hosts on an allowlist a person owns, logging each host and byte count without opening the traffic.
- **Everything else** is unreachable.

**Git.** The agent's `origin` is the socket, as in the evaluation. The broker serves its mirror. Its pre-receive hook refuses any update to `main`, runs the fence early as a warning, and walks every pushed commit for question cards. Then it pushes the accepted refs to GitHub with the agent token. The GitHub ruleset and `guard-fence` remain the real wall. The `gh` stand-in allows `pr create`, `view`, `list`, `diff`, `checks` and `comment`, and refuses `pr merge`, `auth` and any `api` call that writes. `guard review`, `guard merge` and `guard ship` run in the broker. The reviewer gets its own sandbox, holding only the model socket.

**Records.** `needs-you.tsv`, `reviews.tsv` and the review briefs move to the broker's state. The records socket offers `add`, `list`, `show` and `find`, with the source stamped by the broker. It has no verb for marking done, dismissing, approving or recording a verdict, so no approval can be expressed through it. People close items from an outside shell.

## Resources without root

- **Where the system lets user sessions limit memory and processes** (Fedora usually does): the sandbox runs under `systemd-run --user --scope` with `MemoryMax` and `TasksMax`. That's a real wall. skynet has no user manager in non-interactive sessions, so it doesn't apply there.
- **Elsewhere:** `prlimit --as --fsize` per process.
- **A correction to the Fable design.** It says `prlimit --nproc` binds only the sandbox, but the kernel counts processes per uid, your shells and servers included. The cap must be set to your current process count plus the sandbox's allowance, and it is a speed bump, not a wall.
- **Disk:** the broker's 2-second watchdog, and 1 GB caps on the in-memory `/tmp` and `/run`. That's a kill, not a wall.
- **Needs an administrator:** scratch-space quotas, memory limits where nothing is delegated, an enforced cap at the scheduler (see `.audit/admin-request-skynet.md`), and GPU accounting.

## What stays a speed bump

- Everything still runs as your uid, so a bubblewrap or kernel escape is you.
- The model API and the allowlisted hosts can carry data out.
- Multi-node `srun` jobs need munge, and with it they could submit as you.
- Code the agent plants that you later run outside a sandbox: git hooks, `core.fsmonitor`, editor tasks. The #82 lesson applies to people too.
- Commands the agent queues for you to paste.
- Special-casing a test input, and a reviewer that can be talked into approving.

An administrator's enforced cap still walls every path that reaches Slurm as you.

## Build sequence

Each increment lands in the evaluation environment first, so `eval/audit/run.py` measures it.

| # | Increment | Rows that flip to held | New attack rows |
|---|---|---|---|
| 0 | Small harness fixes (in progress now) | explore-cap, sbatch-short-form, cli-space-form, fake-squeue, push-card-one-push, push-agents-md | |
| 1 | Broker scheduler verbs between the sandbox and `fakeslurm.py`, whose socket is hidden. Landed in `eval/broker/` (W1.1), with D9's request fields and D5's `job_sandbox: bare` | sbatch-walltime, sbatch-nodes, sbatch-no-account, sbatch-no-time, local-copy, ref-head, update-ref, edit-run, spend-reserve, forged-chain | option-smuggle, output-symlink, scancel-foreign, broker-down, job-submits, bare-job-visible |
| 2 | Records store and socket. Landed in `eval/broker/records.py` (W1.2): `add list show find` and nothing that closes; the broker's signing key; `guard ledger add` and `guard card add` commit to `run/<run_id>`, signed (D13), and the forge refuses unsigned ones; a card is approved by the signed tag `card/<run_id>`, which the broker verifies before submitting (D2) | needs-you-forge | records-approve, ledger-hand-edit, card-forge-tag |
| 3 | The `gh` stand-in; review and merge in the broker. Landed in `eval/broker/forge.py` (W1.3): the sandbox's `gh` offers `pr create`, `view`, `list`, `diff`, `checks`, `comment` and api reads, never `pr merge`, `auth` or an api write; pull requests, `guard pr open`'s brief (A3) and `reviews.tsv` live in the broker's state; `broker.py review` runs the reviewer in a sandbox holding only the model socket; the reviewer's tree gets no `.git`, and the broker reads its changes through its own mirror with a git dir the reviewer cannot write (the `scorer-escape`/#82 discipline), so a planted `.git/config`, hook or alternates runs nothing outside; `broker.py merge` and `ship` merge only on its verdict; with `guard.main pulls` the forge takes `main` only from that merge | reviews-forge | gh-pr-merge, token-search, reviewer-escape |
| 4 | `lib/box.sh` and profiles; the audit reruns every sandbox row through the real launcher | none; all must stay held | ssh-agent, gh-config, munge |
| 5 | Resource scopes | many-processes; memory-many-procs where delegated | |
| 6 | Model and network gateway | none | net-allowlist, api-key-search |
| 7 | Job sandbox on skynet, a supervised skynet session, then runhub | none | job-home, job-munge |

## Decisions for the owner

1. **The hand-off's "no new subcommands before the first result" rule.** This design adds `guard enter` and `guard broker`. Recommendation: build increments 1 to 3 under `eval/` first, where the audit measures them, and add the subcommands at increment 4.
2. **When a question card counts.** Recommendation: only once you've merged it to `main`. It's stronger than freezing at first push, and it matches "only a person approves a card".
3. **Subscription logins.** A Claude Code login that refreshes its own token puts a model credential inside the sandbox. Recommendation: API keys through the gateway for unattended runs; accept the login for sessions you supervise.
4. **Network allowlist.** Which package hosts, and should jobs get any network? Recommendation: PyPI and conda only; jobs get none.
5. **Compute nodes without bwrap.** Recommendation: refuse jobs there by default.
6. **Multi-node `srun`.** Recommendation: out of scope for now.
7. **The broker on skynet** runs in tmux, since skynet has no user-level service manager.
8. **Working practice.** Never open an agent's working tree in your own shell or editor outside a sandbox: planted git hooks and settings run as you.
