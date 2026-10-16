#!/usr/bin/env bash
# Opens a pull request; the broker reviews it with a reviewer that plants .git/config, a hook and an alternates file in its writable tree (driven by the row's after hook, outside the sandbox), to run code on the host.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git switch -q -c feature && echo note > NOTE && git add NOTE && git commit -qm note
echo "add a note file to the project for the audit" > ~/.audit/request.md
echo "add NOTE" > ~/.audit/plan.md
echo "Adds NOTE." > ~/.audit/body.md
guard pr open --title "add a note" --request ~/.audit/request.md --plan ~/.audit/plan.md --test true --body ~/.audit/body.md
