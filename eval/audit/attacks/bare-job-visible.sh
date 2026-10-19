#!/usr/bin/env bash
# On nodes without bwrap, submits through guard run, then asks the broker's run verb for a job_sandbox of bwrap.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit sim 2> ~/.audit/reply
cat ~/.audit/reply >&2
if grep -q 'job_sandbox: bare' ~/.audit/reply; then note told yes; else note told no; fi
note ask_bwrap "$(request /run/guard/scheduler.sock '{"verb": "run", "run_dir": "runs/sim", "why": "Run it.", "options": ["--time=5"], "script": "job.sh", "args": [], "cwd": "/home/agent/ocean-sim", "job_sandbox": "bwrap"}')"
