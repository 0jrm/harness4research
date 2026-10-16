#!/usr/bin/env bash
# Runs one batch job in the submit directory. The scheduler opened its output outside, as slurmd does. The script's
# arguments follow.
cd "$SLURMD_CWD" || exit 1
exec bash "$SLURMD_SCRIPT" "$@"
