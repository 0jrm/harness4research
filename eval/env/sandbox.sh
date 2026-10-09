#!/usr/bin/env bash
# usage: eval/env/sandbox.sh <episode_dir> [--job] -- <command...>
# Runs a command inside the episode's sandbox, without root, through bubblewrap.
#
# Inside, the agent sees an ordinary login node: HOME=/home/agent (the episode's home/, writable), the system's /usr
# and /etc read-only, sbatch and friends in /opt/site/bin, the scheduler socket at /run/slurm/slurmctld.sock and the
# git remote socket at /run/forge/forge.sock. Nothing else from the host: no host HOME, no host environment, no
# episode state (job ledger, protected repository, hidden evaluator data), and no path that names the evaluation.
#
# --job is how fakeslurm.py starts a job: the same sandbox, plus the SLURM_* variables, with the job's saved script
# bound read-only at /run/slurm/job.sh.
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: sandbox.sh <episode_dir> [--job] -- <command...>" >&2; exit 64; }
ep=$(cd "$1" && pwd); shift
job=0; [ "$1" = --job ] && { job=1; shift; }
[ "$1" = -- ] || { echo "sandbox.sh: expected -- before the command" >&2; exit 64; }
shift

args=(
  --unshare-all --share-net --die-with-parent --new-session
  --hostname login1
  --ro-bind /usr /usr
  --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib
  --ro-bind /etc /etc
  --ro-bind "$ep/sandbox/etc/passwd" /etc/passwd
  --ro-bind "$ep/sandbox/etc/group" /etc/group
  --ro-bind "$ep/sandbox/tools/bin" /opt/site/bin
  --ro-bind "$ep/sandbox/tools/lib" /opt/site/lib
  --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run
  --bind "$ep/home" /home/agent
  --bind "$ep/state/slurm/slurmctld.sock" /run/slurm/slurmctld.sock
  --bind "$ep/state/git/forge.sock" /run/forge/forge.sock
  --clearenv
  --setenv HOME /home/agent --setenv USER agent --setenv LOGNAME agent
  --setenv LANG C.UTF-8 --setenv TERM "${TERM:-xterm}"
)
path=/opt/site/bin:/usr/local/bin:/usr/bin:/bin
[ -e /lib64 ] && args+=(--symlink usr/lib64 /lib64)
[ -d "$ep/sandbox/harness" ] && args+=(--ro-bind "$ep/sandbox/harness" /opt/harness4research)
# The site's scientific Python (site-python.sh), first on PATH, as a cluster module would put it.
site_python=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.site-venv
[ -d "$site_python" ] && { args+=(--ro-bind "$site_python" /opt/site/python); path=/opt/site/python/bin:$path; }
# Extra read-only binds, one "<host path> <sandbox path>" per line, such as the agent client's binary, and the
# directories they add to PATH, one per line, first listed first.
if [ -f "$ep/sandbox/binds" ]; then
  while read -r src dst; do [ -n "$src" ] && args+=(--ro-bind "$src" "$dst"); done < "$ep/sandbox/binds"
fi
if [ -f "$ep/sandbox/path" ]; then
  extra=$(paste -sd: "$ep/sandbox/path")
  [ -z "$extra" ] || path=$extra:$path
fi
args+=(--setenv PATH "$path")
# Extra variables for the agent's own client, such as the model endpoint, listed one NAME=value per line.
if [ -f "$ep/sandbox/env" ]; then
  while IFS='=' read -r name value; do
    [ -n "$name" ] && args+=(--setenv "$name" "$value")
  done < "$ep/sandbox/env"
fi

if [ $job = 1 ]; then
  args+=(--ro-bind "$SLURMD_SCRIPT" /run/slurm/job.sh)
  while IFS='=' read -r name value; do
    case $name in SLURM_*|SLURMD_*) args+=(--setenv "$name" "$value") ;; esac
  done < <(env)
  args+=(--setenv SLURMD_SCRIPT /run/slurm/job.sh --chdir "$SLURMD_CWD")
  set -- bash /opt/site/lib/jobwrap.sh "$@"
else
  args+=(--chdir /home/agent)
fi
# bwrap stays in the sandbox as PID 1, so its arguments, which name host paths, go through a file descriptor
# instead of its command line.
exec bwrap --args 3 -- "$@" 3< <(printf '%s\0' "${args[@]}")
