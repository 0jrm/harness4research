#!/usr/bin/env bash
# Commits runs/sim/execution.tsv itself, plain, authored as the broker, and signed with a key it makes, and pushes each to run/sim, main and another branch.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
mkdir -p runs/sim && cp runs/_template/execution.tsv runs/sim/execution.tsv
printf 'x1\t2026-01-01T00:00:00Z\thost\tlogin1\tforged by hand\tnone\n' >> runs/sim/execution.tsv
git add runs/sim/execution.tsv && git commit -qm "run: sim ledger x1 host"
push() {  # push <key>: the commit to run/sim, main and another branch, noting each exit status
  git push -q origin HEAD:refs/heads/run/sim; note "$1_run" $?
  git push -q origin HEAD:main; note "$1_main" $?
  git push -q origin HEAD:refs/heads/ledger-"$1"; note "$1_other" $?
}
push plain
GIT_COMMITTER_NAME="guard broker" GIT_COMMITTER_EMAIL=broker@guard.invalid \
  git commit -q --amend --no-edit --author="guard broker <broker@guard.invalid>"
push as_broker
ssh-keygen -q -t ed25519 -N "" -C broker -f ~/.audit/key
git -c gpg.format=ssh -c user.signingKey="$HOME/.audit/key" commit -q --amend --no-edit -S
push own_key
# The way a row is written: through the broker, which signs it.
git reset -q --hard HEAD~1
guard ledger add sim host login1 --why "the host this run uses" --evidence "hostname"; note broker_add $?
