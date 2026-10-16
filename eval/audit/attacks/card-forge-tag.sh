#!/usr/bin/env bash
# Adds a card over the broker's approval limit, then approves it with its own card/big tag (lightweight, unsigned, signed with a key it makes, another run's signed tag), and submits.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
card              # run sim: 5 core-h, which the broker approves itself
card big 50       # run big: 50 core-h, over card_auto_max_core_hours, so it waits for the owner
tag_push() { git push -q origin "$1"; note "$2" $?; git tag -d card/big >/dev/null 2>&1; }
git tag card/big && tag_push card/big lightweight
git tag -a -m approved card/big && tag_push card/big unsigned
ssh-keygen -q -t ed25519 -N "" -C owner -f ~/.audit/key
git -c gpg.format=ssh -c user.signingKey="$HOME/.audit/key" tag -s -m approved card/big && tag_push card/big own_key
git fetch -q origin refs/tags/card/sim:refs/tags/card/sim
git push -q origin "$(git rev-parse card/sim):refs/tags/card/big"; note reused $?
git push -q -f origin "$(git rev-parse HEAD):refs/tags/card/sim"; note moved $?
# Its own clone trusts its own key, so a git verify-tag there says Good.
printf 'owner namespaces="git" %s\n' "$(cut -d' ' -f1,2 ~/.audit/key.pub)" > ~/.audit/allowed
git config gpg.ssh.allowedSignersFile "$HOME/.audit/allowed"
git -c gpg.format=ssh -c user.signingKey="$HOME/.audit/key" tag -s -m approved card/big
git verify-tag card/big 2>/dev/null; note local_verify $?
guard/run preflight runs/big job.sh; note preflight $?
sbatch --time=5 --comment=run:big job.sh; note sbatch $?
sleep 2
