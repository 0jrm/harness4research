#!/usr/bin/env bash
# usage: lib/vendor.sh <pin>    prints guard/harness-<pin>.sh, built from this clone's object store at the pin
# Sourced by bin/guard, install.sh and lib/init.sh, lib/doctor.sh, after they set $here to the harness root. A project
# pins the harness with the harness: line of guard/budget.card, and guard/run reads its scripts from one of two places:
#   online:  the harness clone, checked out at the pin, reading each script from its object store;
#   offline: guard/harness-<pin>.sh on the project's protected branch, written by harness_artifact below, for a host
#            that cannot reach the harness's origin.

# harness_pin: the pin for this clone's HEAD, its release tag when HEAD is exactly one, else its full commit.
harness_pin() {
  git -C "$here" describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || git -C "$here" rev-parse -q --verify HEAD
}

# harness_online: whether this host reaches the harness's origin within 10 seconds, without a password prompt.
harness_online() {
  local ssh
  git -C "$here" remote get-url origin >/dev/null 2>&1 || return 1
  ssh=${GIT_SSH_COMMAND:-$(git -C "$here" config core.sshCommand || echo ssh)}
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh -o BatchMode=yes" \
    timeout 10 git -C "$here" ls-remote -q origin HEAD </dev/null >/dev/null 2>&1
}
harness_origin() { git -C "$here" remote get-url origin 2>/dev/null || echo "no origin remote"; }

# harness_artifact <pin>: prints the vendored file: every lib/guard script at the pin's commit, each after a marker
# line `#== lib/guard/<name>.sh`, then `#== end`. Fails when the clone lacks the pin, or a script has a marker line.
harness_artifact() {
  local pin=$1 commit f text
  commit=$(git -C "$here" rev-parse -q --verify "$pin^{commit}") || { echo "this harness clone has no $pin" >&2; return 1; }
  printf '#!/usr/bin/env bash\n'
  printf '# harness: %s, commit %s. The guard scripts of harness4research, vendored for a host that cannot reach\n' "$pin" "$commit"
  printf '# its origin. guard/run reads one script from this file on the protected branch; never edit it. A new pin\n'
  printf '# brings a new file, written by the harness: bash <harness>/lib/vendor.sh <pin>.\n'
  printf 'echo "guard/run reads its scripts from this file; run guard/run <command> instead" >&2; exit 64\n'
  while IFS= read -r f; do
    text=$(git -C "$here" show "$commit:$f")
    if grep -q '^#== ' <<<"$text"; then echo "$f at $pin has a line starting with #== , which this file uses as a marker" >&2; return 1; fi
    printf '#== %s\n%s\n' "$f" "$text"
  done < <(git -C "$here" ls-tree --name-only "$commit" lib/guard/ | grep '\.sh$')
  printf '#== end\n'
}

# pin_problem <clone> <pin>: prints why guard/run cannot read the pin from that clone, or nothing. pin_fix names the fix.
pin_problem() {
  local clone=$1 pin=$2 at want
  at=$(git -C "$clone" rev-parse -q --verify HEAD 2>/dev/null) || { echo "$clone is not a harness4research clone"; return; }
  want=$(git -C "$clone" rev-parse -q --verify "$pin^{commit}" 2>/dev/null || true)
  [ -n "$want" ] && [ "$at" = "$want" ] && return
  echo "the harness clone $clone is at ${at:0:12}, not $pin"
}
pin_fix() { echo "git -C $1 fetch --tags && git -C $1 checkout $2"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ $# -eq 1 ] || { echo "usage: lib/vendor.sh <pin>" >&2; exit 64; }
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  harness_artifact "$1"
fi
