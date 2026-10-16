#!/usr/bin/env bash
# usage: eval/env/sandbox.sh <episode_dir> [--job] -- <command...>
# Runs a command inside the episode's sandbox through lib/box.sh, the launcher guard enter uses, laid out as an
# episode: this file only says what the episode binds where.
#
# Inside, the agent sees an ordinary login node: HOME=/home/agent (the episode's home/, writable), the system's /usr
# and /etc read-only, sbatch and friends in /opt/site/bin, the scheduler socket (the broker's at
# /run/guard/scheduler.sock, or else the fake Slurm's at /run/slurm/slurmctld.sock) and the git remote socket at
# /run/forge/forge.sock. Nothing else from the host: no host HOME, no host environment, no
# episode state (job ledger, protected repository, hidden evaluator data), and no path that names the evaluation.
# Before the agent's command, lib/box.sh's pre-flight probe checks those walls from inside and starts nothing if one
# fails.
#
# --job is how fakeslurm.py starts a job: the same sandbox, plus the SLURM_* variables, with the job's saved script
# bound read-only at /run/slurm/job.sh, and no probe.
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: sandbox.sh <episode_dir> [--job] -- <command...>" >&2; exit 64; }
ep=$(cd "$1" && pwd); shift
job=0; [ "$1" = --job ] && { job=1; shift; }
[ "$1" = -- ] || { echo "sandbox.sh: expected -- before the command" >&2; exit 64; }
shift
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

box=(
  --no-tty --hostname login1 --user agent
  --ro "$ep/sandbox/etc/passwd" /etc/passwd
  --ro "$ep/sandbox/etc/group" /etc/group
  --ro "$ep/sandbox/tools/bin" /opt/site/bin
  --ro "$ep/sandbox/tools/lib" /opt/site/lib
  --home "$ep/home" /home/agent
  --sock "$ep/state/git/forge.sock" /run/forge/forge.sock
)
# Behind the broker (up.sh --broker) the agent gets the broker's socket directory, so a broker that is down refuses
# instead of keeping the sandbox from starting, and a job gets no scheduler socket at all. Without the broker, both
# get the fake Slurm's socket.
if [ -d "$ep/state/broker" ]; then
  [ $job = 1 ] || box+=(--sock-dir "$ep/state/broker/sock")
else
  box+=(--sock "$ep/state/slurm/slurmctld.sock" /run/slurm/slurmctld.sock)
fi
# No network: the agent's client reaches the model only through the logging proxy's socket.
[ -S "$ep/state/model/proxy.sock" ] && box+=(--sock "$ep/state/model/proxy.sock" /run/model/proxy.sock)
[ -d "$ep/sandbox/harness" ] && box+=(--ro "$ep/sandbox/harness" /opt/harness4research)
# Extra read-only binds, one "<host path> <sandbox path>" per line, such as the agent client's binary, and the
# directories they add to PATH, one per line, first listed first; then the site's scientific Python
# (site-python.sh), as a cluster module would put it, then the site's tools.
if [ -f "$ep/sandbox/binds" ]; then
  while read -r src dst; do [ -n "$src" ] && box+=(--ro "$src" "$dst"); done < "$ep/sandbox/binds"
fi
if [ -f "$ep/sandbox/path" ]; then
  while read -r dir; do [ -n "$dir" ] && box+=(--path "$dir"); done < "$ep/sandbox/path"
fi
site_python=$here/.site-venv
[ -d "$site_python" ] && box+=(--ro "$site_python" /opt/site/python --path /opt/site/python/bin)
box+=(--path /opt/site/bin)
# Extra variables for the agent's own client, such as the model endpoint, listed one NAME=value per line.
if [ -f "$ep/sandbox/env" ]; then
  while IFS= read -r line; do [ -n "${line%%=*}" ] && box+=(--env "$line"); done < "$ep/sandbox/env"
fi

# Resource limits: lib/box.sh's defaults, or a row's own from sandbox/limits ("mem BYTES" or "tasks N" per line); which
# applied, a scope or prlimit, goes to state/limits.jsonl, outside the sandbox.
if [ -f "$ep/sandbox/limits" ]; then
  while read -r key value; do
    case $key in mem|tasks) box+=("--$key" "$value") ;; esac
  done < "$ep/sandbox/limits"
fi
box+=(--record "$ep/state/limits.jsonl")

if [ $job = 1 ]; then
  box+=(--ro "$SLURMD_SCRIPT" /run/slurm/job.sh)
  while IFS='=' read -r name value; do
    case $name in SLURM_*|SLURMD_*) box+=(--env "$name=$value") ;; esac
  done < <(env)
  box+=(--env SLURMD_SCRIPT=/run/slurm/job.sh --chdir "$SLURMD_CWD")
  set -- bash /opt/site/lib/jobwrap.sh "$@"
else
  box+=(--chdir /home/agent --probe --hide "$ep" --hide "$HOME")
fi
exec "$here/../../lib/box.sh" "${box[@]}" -- "$@"
