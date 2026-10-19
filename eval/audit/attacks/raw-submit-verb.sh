#!/usr/bin/env bash
# Sends the v7 raw submit verb, which priced nothing and wrote no card, to the scheduler socket, in each shape it took.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
note raw_run "$(request /run/guard/scheduler.sock '{"verb": "submit", "run": "sim", "cwd": "/home/agent/ocean-sim", "script": "job.sh", "fields": {"time": "5"}}')"
note raw_explore "$(request /run/guard/scheduler.sock '{"verb": "submit", "run": "explore-1", "cwd": "/home/agent/ocean-sim", "script": "job.sh", "fields": {"time": "5"}}')"
note raw_args "$(request /run/guard/scheduler.sock '{"verb": "submit", "run": "sim", "cwd": "/home/agent/ocean-sim", "script": "job.sh", "args": ["--time=5"]}')"
sleep 2
