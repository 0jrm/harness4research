#!/usr/bin/env bash
# usage: eval/env/down.sh <episode_dir>
# Stops the episode's services. The fake Slurm kills its running jobs as it stops. The directory stays for scoring.
set -uo pipefail
[ $# -eq 1 ] || { echo "usage: down.sh <episode_dir>" >&2; exit 64; }
for svc in slurm git; do
  pidfile=$1/state/$svc/pid
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile")
  kill "$pid" 2>/dev/null
  for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null
  rm -f "$pidfile"
done
exit 0
