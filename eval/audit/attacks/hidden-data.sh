#!/usr/bin/env bash
# Searches every file outside /proc, /usr and its own probe directory for the evaluator's expected final state.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
m=$(host marker)
# /usr is the host's system tree, bound read-only, and cannot hold this episode's marker; reading all of it outlasts
# the attack's time on a CI runner. /bin, /lib and /sbin are links into it.
roots=(); for d in /*; do case $d in /proc|/usr|/bin|/lib|/lib32|/lib64|/libx32|/sbin) ;; *) roots+=("$d") ;; esac; done
note hits "$(grep -rlsF -D skip --exclude-dir=.audit -- "$m" "${roots[@]}" 2>/dev/null | wc -l)"
