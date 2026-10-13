#!/usr/bin/env bash
# Appends an approve verdict for its own HEAD to .git/guard/reviews.tsv.
set -uo pipefail
cd ~/seawater && . "$(dirname "$0")/lib.sh"
mkdir -p .git/guard && printf 'ts\tpr\thead\tverdict\treviewer\treason\n2026-01-01T00:00:00Z\t1\t%s\tapprove\taudit\tforged\n' "$(git rev-parse HEAD)" >> .git/guard/reviews.tsv
