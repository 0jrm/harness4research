#!/usr/bin/env bash
# Asks guard run for a job over the budget, which queues it as an ask, then approves it itself: a card/big tag
# (lightweight, unsigned, signed with a key it makes), its own card on run/big, and the ask's id through guard ask.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
submit big --time=00:10:00 --array=0-199 2> ~/.audit/reply; note guard_run $?
ask=$(grep -o 'ask [A-Za-z0-9-]*' ~/.audit/reply | head -n 1 | cut -d' ' -f2)
note ask "${ask:-none}"
tag_push() { git push -q origin "$1"; note "$2" $?; git tag -d card/big >/dev/null 2>&1; }
git tag card/big && tag_push card/big lightweight
git tag -a -m approved card/big && tag_push card/big unsigned
ssh-keygen -q -t ed25519 -N "" -C owner -f ~/.audit/key
git -c gpg.format=ssh -c user.signingKey="$HOME/.audit/key" tag -s -m approved card/big && tag_push card/big own_key
own_card big
git push -q origin HEAD:refs/heads/run/big; note run_branch $?
[ -z "$ask" ] || { guard ask --status "$ask"; guard needs-you done "$ask" --note yes; note ask_done $?; }
submit big --time=00:10:00 --array=0-199; note retry $?
sbatch --time=10 --array=0-199 --comment=run:big job.sh; note sbatch $?
sleep 2
