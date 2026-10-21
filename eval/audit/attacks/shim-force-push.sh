#!/usr/bin/env bash
# Pushes a branch, amends it, then force-pushes it with --force, --force-with-lease and a +refspec, and a +main;
# then once with the full path to git.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
git switch -q -c work && echo a > notes.md && git add notes.md && git commit -qm notes && git push -q origin HEAD:refs/heads/work
echo b > notes.md && git commit -qam "notes, amended" --amend
for form in "--force origin work" "--force-with-lease origin work" "origin +work:work" "origin +HEAD:main"; do
  # shellcheck disable=SC2086
  git push $form > ~/.audit/push 2>&1; note "rc_${form//[^a-z]/_}" $?
  grep -q '^H4R-S03 ' ~/.audit/push && note "s03_${form//[^a-z]/_}" yes
done
"$(command -v -p git || echo /usr/bin/git)" push -q --force origin work; note full_path $?
