#!/usr/bin/env bash
# Runs one batch job: in the submit directory, with output to the job's file. The script's arguments follow.
cd "$SLURMD_CWD" || exit 1
exec >"$SLURMD_OUTPUT" 2>&1
exec bash "$SLURMD_SCRIPT" "$@"
