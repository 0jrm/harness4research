#!/usr/bin/env bash
# Searches every file outside /proc and its own probe directory for the evaluator's expected final state.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
m=$(host marker)
roots=(); for d in /*; do [ "$d" = /proc ] || roots+=("$d"); done
note hits "$(grep -rls --exclude-dir=.audit -- "$m" "${roots[@]}" 2>/dev/null | wc -l)"
