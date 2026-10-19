# shellcheck shell=bash
# BASH_ENV for the compute gate (sitecustomize.py beside this file): bash running a script on guard/budget.card's
# compute list outside a job stops before its first line with refusal C01. The harness's own scripts, such as the PATH
# shim, are never gated, so a shim call costs no Python start.
if [ -z "${SLURM_JOB_ID:-}" ] && [ -z "${GUARD_JOB_ID:-}" ] && [ -f "$0" ] \
  && [[ $(readlink -f "$0") != "$(readlink -f "${BASH_SOURCE[0]%/*}/../..")"/* ]]; then
  /usr/bin/python3 -I "${BASH_SOURCE[0]%/*}/sitecustomize.py" "$0" || exit 2
fi
