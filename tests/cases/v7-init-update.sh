# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== init --update"
git -C "$tmp/proj" fetch -q origin
expect update-noop ok "^The guard in proj is current at harness: $pin\. Nothing proposed\.$" -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt3"
expect init-refuses-guarded fail 'already guarded' -- "$guard" init "$tmp/proj" --worktree "$tmp/wt6"
expect version-current ok '^current$' -- "$guard" version
expect version-release ok 'guard schema [0-9]+, release [^,]+, installed from ' -- "$guard" version
good=$(git rev-parse origin/main)
set_main() {  # set_main <file> <sed expression>: commit an edited <file> straight to main
  git switch -q --detach origin/main; sed -i "$2" "$1"; git commit -q -am "$1: $2"
  git push -q origin HEAD:main; git -C "$tmp/proj" fetch -q origin
}
reset_main() { git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin; }
zeros=0000000000000000000000000000000000000000
set_main guard/budget.card "s/^harness: .*/harness: $zeros/"
expect version-harness-older ok '^harness older' -- "$guard" version
expect update-refuses-unknown-pin fail "does not contain the release proj pins \(harness: $zeros, schema" -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
expect update-force ok '^  guard/budget.card$' -- "$guard" init "$tmp/proj" --update --force --worktree "$tmp/wt6"
expect update-force-pins ok "^harness: $pin$" -- grep '^harness:' "$tmp/wt6/guard/budget.card"
git -C "$tmp/proj" worktree remove --force "$tmp/wt6"; git -C "$tmp/proj" branch -q -D guard/update
reset_main
set_main guard/VERSION 's/^schema: .*/schema: 99/'
expect update-refuses-newer-schema fail 'schema 99' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
reset_main
set_main guard/VERSION "s/^installer: .*/installer: $zeros/"
expect version-pin-not-installer ok '^current$' -- "$guard" version
reset_main
git init -q "$tmp/plain"
expect path-refuses-unguarded fail 'runs inside a guarded project' -- bash -c 'cd "$1" && "$2" fence' _ "$tmp/plain" "$guard"
git switch -q --detach "$good"
set_script fence $'<<<<<<< ours\nexit 0\n=======\nexit 1\n>>>>>>> theirs'; git commit -q -am "a vendored harness merged with conflicts"
git push -q origin HEAD:refs/heads/conflicted; git fetch -q origin; git switch -q --detach "$good"
expect run-refuses-conflicted fail 'unresolved conflicts or does not parse' -- env HPC_GUARD_REF=origin/conflicted guard/run fence origin/main HEAD
expect run-names-schema fail "guard is schema $(cat "$here/SCHEMA")" -- env HPC_GUARD_REF=origin/conflicted guard/run frobnicate
