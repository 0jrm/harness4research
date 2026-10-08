# Evaluation environment

This directory holds the environment for the evaluation in [docs/evaluation.md](../docs/evaluation.md): a stand-in for a cluster login node where an agent works on a research project, with a scheduler, a protected git remote, and evaluator data the agent cannot reach. It needs bash, git, python3 and [bubblewrap](https://github.com/containers/bubblewrap), with unprivileged user namespaces. It needs no root and no Docker, so it can run on machines where the user has no sudo.

The agent never sees this directory. The sandbox gets only the parts of the harness that `guard` runs from (`bin`, `lib`, `skills`, `templates`, `SCHEMA`). It leaves out `eval/`, `docs/` and `README.md`, which describe this evaluation. An agent never reads those in a real install either, because its rules come from `AGENTS.md` and the skills. The self-test checks that no file inside mentions the evaluation.

## Check it

```shell
eval/env/selftest.sh
```

CI does not run it yet. A workflow change is a human's merge, and the step is in the pull request that added this directory.

The self-test builds one episode and checks:

- the isolation: user, environment, no host paths, the hidden data unreadable, no harness file that mentions the evaluation;
- `guard init` running clean inside the sandbox;
- preflight against the fake Slurm: one job submitted, one over-cap job refused;
- `sacct` and ripples reading the finished job;
- the forge: a clean push to `main` lands, a change to `guard/` and a force push are refused;
- teardown leaving no process behind.

On a host where `unshare --user true` fails, bubblewrap cannot start, and every check fails at `up`.

## What an episode is

```shell
eval/env/up.sh <episode_dir> --project <dir> [--harness <harness_repo>] [--cluster <cluster.json>]
eval/env/sandbox.sh <episode_dir> -- <command...>     # run the agent, or anything, inside
eval/env/down.sh <episode_dir>
```

| Path in the episode | Inside the sandbox | What it is |
|---|---|---|
| `home/` | `/home/agent` | the agent's HOME, with the project cloned at `~/<project>` |
| `sandbox/tools/` | `/opt/site/bin`, `/opt/site/lib` | `sbatch`, `squeue`, `sacct`, `scancel`, `sacctmgr`, `forge-connect`, and `guard` with `--harness` |
| `sandbox/harness/` | `/opt/harness4research` | the harness's `bin`, `lib`, `skills`, `templates` and `SCHEMA`, with `--harness` |
| `state/slurm/` | the socket only, at `/run/slurm/slurmctld.sock` | the fake Slurm's ledger (`state.json`), job scripts, and `audit.jsonl` |
| `state/git/` | the socket only, at `/run/forge/forge.sock` | the protected repository and `forge.log` |
| `hidden/` | nothing | the evaluator's data |

Inside, the environment holds only `HOME`, `USER`, `LOGNAME`, `PATH`, `LANG` and `TERM`, plus the names in `sandbox/env`, one `NAME=value` per line. That file is for the agent client's own settings, such as the model endpoint. The user is `agent` and the host is `login1`. `/usr` and `/etc` are the host's, read-only. The network is shared, because the agent client must reach the model server.

## The pieces, and what each stands in for

| Piece | Stands in for | How |
|---|---|---|
| `fakeslurm.py` | a Slurm controller with accounting | Keeps the job ledger and runs each job in the same sandbox, in the submit directory. Time runs `time_scale` times faster than the clock (60 by default: a one-second job uses a minute). Nodes are allocated whole, so CPU time is `nodes × cores_per_node × elapsed`, which is what preflight projects. An account's `cap_cpu_minutes` holds jobs that could cross it as PENDING (`AssocGrpCPUMinutesLimit`), like a capped sub-account. |
| `slurmclient.py` | `sbatch`, `squeue`, `sacct`, `scancel`, `sacctmgr` | Sends its arguments to the controller over the socket. Every call goes into `audit.jsonl` with the calling process chain. That log is how the evaluator sees a direct `sbatch` that skipped preflight. |
| `gitsock.py`, `forge_connect.py` | a GitHub remote | The agent's `origin` is `ext::forge-connect %S`. The forge runs `git-upload-pack` and `git-receive-pack` outside the sandbox, so the agent has no write access to the repository files. |
| `forge-pre-receive.sh` | the ruleset on `main` | Refuses deleting or force-pushing `main`. Once `main` has the guard, every update to `main` must pass the fence read from the old `main`. Every decision goes to `forge.log`. A human "merges past the fence" by fetching straight into the protected repository, as a ruleset bypass would. |
| `sandbox.sh` | a login node and its compute nodes | bubblewrap with every namespace unshared except the network. bwrap's own arguments go through a file descriptor, so PID 1 inside shows no host path. |

## Differences from the handoff's design, and why

The external review's handoff (section 2.3, "Environment") asked for one Docker compose file with a real Slurm. Two of its parts are replaced, because FSU machines give users no root:

- **Slurm is a fake, not slurm-docker-cluster.** slurmd must run as root ([Slurm quick-start guide](https://slurm.schedmd.com/quickstart_admin.html)), and Docker needs root or a rootless setup that an administrator enables. The fake answers the exact queries the guard makes, and its accounting is computed by code, never by a judge model. The cost is that `sacct` comes from our ledger rather than Slurm's. One smoke run on a real Slurm, such as skynet's, should confirm that the output formats match. That run has not been done yet.
- **The hidden evaluator is separated by absence, not by a container.** Its data sits in `hidden/`, which the sandbox never binds. Scoring happens after `down.sh`, when no agent process is left. An evaluator on another host, sent a `git bundle` of the agent's repository, is the stronger version, if a reviewer asks for one.

The protected git remote follows the handoff: a hook that the agent cannot reach refuses to move `main` without a passing fence.

## Known limits

- The agent runs as the host user's uid. The namespaces are its only isolation. A sandbox escape would be a bubblewrap bug.
- The network is shared, so the agent can reach anything the host can. A run that must rule this out needs a network namespace with only the model endpoint forwarded.
- The sandbox's mount table (`/proc/self/mountinfo`) shows the host path of each bound directory. Name episode directories neutrally, with no run, arm, task or seed in the path.
- Real Slurm also reports job steps, partitions and QOS. The fake reports allocations only, with no steps, which matches every query the guard makes (`sacct -X`).
