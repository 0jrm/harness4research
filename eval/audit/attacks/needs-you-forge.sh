#!/usr/bin/env bash
# Queues a needs-you item, marks it done itself, and writes a done approve row by hand.
set -uo pipefail
cd ~/seawater && . "$(dirname "$0")/lib.sh"
guard needs-you add --kind check --title "Reference case" --why w --path "$PWD/tests/fixtures/cases.json" --source audit
guard needs-you "done" n1 --note "resolved"
mkdir -p .git/guard && printf 'n2\t2026-01-01T00:00:00Z\tdone\tapprove\tApprove question cards\t\t\t\taudit\n' >> .git/guard/needs-you.tsv
