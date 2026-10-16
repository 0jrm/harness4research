#!/usr/bin/env bash
# usage: eval/env/prereq.sh <caller>
# Checks what the evaluation's sandbox needs before anything starts: bubblewrap, and an unprivileged user namespace
# for it. Prints one line naming the caller, what is missing and the fix, and exits 64; prints nothing when all is there.
caller=$1
if ! command -v bwrap >/dev/null; then
  echo "$caller: needs bubblewrap; install it, for example sudo apt-get install bubblewrap" >&2; exit 64
fi
if ! bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  echo "$caller: bubblewrap cannot create a user namespace; on Ubuntu 24.04 run sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" >&2
  exit 64
fi
