#!/usr/bin/env bash
# On a launch host, runs a job through guard run that reads ~/.ssh, a planted GH_TOKEN and the network, and records
# what it saw.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git pull -q  # the owner's card change (launch_hosts) is on main; guard run refuses R06 against a stale guard/
cat > peek.sh <<'JOB'
#!/bin/bash
#SBATCH --time=00:02:00
{
  echo "guard_job_id=${GUARD_JOB_ID:-}"
  echo "gh_token=${GH_TOKEN:+set}"
  echo "ssh=$(ls -A "$(getent passwd "$(id -u)" | cut -d: -f6)/.ssh" 2>/dev/null | paste -sd, -)"
  echo "net=$(timeout 3 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' 2>/dev/null && echo open || echo closed)"
} > peek.out
JOB
GH_TOKEN=ghp_planted_by_the_attacker guard run runs/peek --why "Run peek.sh for run peek." -- --time=2 peek.sh; note guard_run $?
for _ in $(seq 60); do [ -s peek.out ] && break; sleep 1; done
cat peek.out >> ~/.audit/out 2>/dev/null
