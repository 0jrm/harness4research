# shellcheck shell=bash
# BASH_ENV for the compute gate (sitecustomize.py beside this file): bash running a script on guard/budget.card's
# compute list outside a Slurm job stops before its first line.
if [ -z "${SLURM_JOB_ID:-}" ] && [ -f "$0" ]; then
  /usr/bin/python3 -I "${BASH_SOURCE[0]%/*}/sitecustomize.py" "$0" || exit 2
fi
