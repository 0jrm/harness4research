# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== harness pin"
# pinned <dir> <online|offline> [env...]: a project guarded by this harness in that mode, its budget filled in and merged;
# leaves the init output in <dir>.out and the shell in <dir>.wt on guard/init.
pinned() {
  local p=$1 m=$2; shift 2
  git init -q --bare -b main "$p.git"; git clone -q "$p.git" "$p" 2>/dev/null
  git -C "$p" checkout -q -b main; echo "# p" > "$p/README.md"; git -C "$p" add -A; git -C "$p" commit -q -m init
  git -C "$p" push -q -u origin main; git -C "$p" remote set-head origin -a >/dev/null
  env "$@" "$guard" init "$p" --worktree "$p.wt" "--$m" > "$p.out" 2>&1
  git -C "$tmp/proj" show "$good:guard/budget.card" > "$p.wt/guard/budget.card"
  git -C "$p.wt" commit -q -am "chore(guard): set budget"; git -C "$p.wt" push -q origin guard/init:main; git -C "$p.wt" fetch -q origin
  cd "$p.wt" || return
}
pin_commit=$(git -C "$here" rev-parse HEAD)
hc=$tmp/harness-clone
git clone -q --shared "$here" "$hc" 2>/dev/null; git -C "$hc" checkout -q --detach "$pin_commit"
mkdir -p "$tmp/hbin"; ln -s "$hc/bin/guard" "$tmp/hbin/guard"
# no_reach <command...>: runs it with git allowed only local repositories, so the harness's origin is out of reach.
no_reach() { env GIT_ALLOW_PROTOCOL=file "$@"; }
O=$tmp/online
pinned "$O" online
expect online-init-no-bin ok - -- test ! -e guard/bin
expect online-init-no-artifact ok - -- test ! -e "$art"
expect online-init-says ok "^Mode: online\. --online was given, so guard/run reads the scripts from the harness clone at $pin; " -- cat "$O.out"
expect online-runs-pin ok 'PASS	guard-untouched' -- env HPC_HARNESS="$hc" guard/run fence origin/main HEAD
expect online-clone-on-path ok 'PASS	guard-untouched' -- env -u HPC_HARNESS PATH="$tmp/hbin:$PATH" guard/run fence origin/main HEAD
expect online-no-clone fail 'no harness clone was found\. Set HPC_HARNESS' -- env -u HPC_HARNESS PATH="$(path_without guard)" guard/run fence origin/main HEAD
printf '#!/usr/bin/env bash\necho FORGED\n' > "$hc/lib/guard/fence.sh"
expect online-clone-edit-no-effect ok 'PASS	guard-untouched' -- env HPC_HARNESS="$hc" guard/run fence origin/main HEAD
expect online-clone-edit-not-run ok - -- bash -c '! HPC_HARNESS="$1" guard/run fence origin/main HEAD | grep -q FORGED' _ "$hc"
expect online-local-runs-clone-tree ok '^FORGED$' -- env HPC_HARNESS="$hc" HPC_GUARD_LOCAL=1 guard/run fence origin/main HEAD
git -C "$hc" checkout -q -- lib/guard/fence.sh
git -C "$hc" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "another commit"
expect online-wrong-pin fail "^The harness clone $hc is at [0-9a-f]{12}, and guard/budget.card on origin/main pins harness: $pin\. Check out the pin: git -C $hc fetch --tags && git -C $hc checkout $pin$" -- \
  env HPC_HARNESS="$hc" guard/run fence origin/main HEAD
expect online-wrong-pin-via-guard fail "Check out the pin: git -C $hc fetch --tags" -- env HPC_HARNESS="$hc" "$guard" fence origin/main HEAD
expect version-online-wrong-pin ok "^mode online: harness $pin, from the clone $hc; the harness clone $hc is at [0-9a-f]{12}, not $pin: git -C $hc fetch --tags && git -C $hc checkout $pin$" -- \
  env HPC_HARNESS="$hc" "$guard" version
expect doctor-online-wrong-pin fail "^FAIL  online, harness: $pin on origin/main, but the harness clone $hc is at [0-9a-f]{12}, not $pin$" -- \
  no_reach env HOME="$tmp/home" HPC_HARNESS="$hc" "$guard" doctor "$O"
expect doctor-online-unreachable fail "^      This host cannot reach [^ ]+\. Vendor the scripts instead, from a clone that has $pin: bash <clone>/lib/vendor.sh $pin > $art, in a pull request a person merges$" -- \
  no_reach env HOME="$tmp/home" HPC_HARNESS="$hc" "$guard" doctor "$O"
git -C "$hc" checkout -q --detach "$pin_commit"
expect version-online ok "^mode online: harness $pin, from the clone $hc$" -- env HPC_HARNESS="$hc" "$guard" version
expect doctor-online ok "^pass  online: guard/run reads the scripts from the harness clone $hc at harness: $pin$" -- \
  bash -c 'env HOME="$1" HPC_HARNESS="$2" "$3" doctor "$4"; true' _ "$tmp/home" "$hc" "$guard" "$O"
expect pin-not-a-release fail '^guard/budget.card on HEAD pins harness: main, which is neither a release tag such as v7.0 nor a full commit\.' -- \
  bash -c 'sed -i "s/^harness: .*/harness: main/" guard/budget.card && git commit -q -am pin && HPC_GUARD_REF=HEAD guard/run fence origin/main HEAD' _
git reset -q --hard origin/main
F=$tmp/offline
pinned "$F" offline
expect offline-init-no-bin ok - -- test ! -e guard/bin
expect offline-init-says-unreachable ok "^Mode: offline\. --offline was given" -- cat "$F.out"
expect offline-artifact-from-vendor ok - -- bash -c 'bash "$1/lib/vendor.sh" "$2" | cmp - "$3"' _ "$here" "$pin" "$art"
expect offline-runs-artifact ok 'PASS	guard-untouched' -- env HPC_HARNESS="$hc" PATH="$(path_without guard)" guard/run fence origin/main HEAD
set_script fence $'#!/usr/bin/env bash\necho FORGED'
expect offline-edit-no-effect ok 'PASS	guard-untouched' -- guard/run fence origin/main HEAD
expect offline-local-runs-edit ok '^FORGED$' -- env HPC_GUARD_LOCAL=1 guard/run fence origin/main HEAD
git commit -q -am "an edited vendored harness"
expect offline-committed-edit-no-effect fail 'FAIL	guard-untouched' -- guard/run fence origin/main HEAD
expect offline-bare-repository ok 'PASS	guard-untouched' -- bash -c 'cd "$1.git" && HPC_GUARD_REF=main bash -c "$(git show main:guard/run)" guard/run fence main main' _ "$F"
expect version-offline ok "^mode offline: harness $pin, from $art on origin/main$" -- "$guard" version
expect doctor-offline ok "^pass  offline: guard/run reads the scripts from $art on origin/main, which matches the harness at $pin$" -- \
  bash -c 'env HOME="$1" "$2" doctor "$3"; true' _ "$tmp/home" "$guard" "$F"
git push -q origin HEAD:main; git fetch -q origin
expect doctor-offline-differs fail "^FAIL  offline: $art on origin/main differs from the harness at $pin$" -- env HOME="$tmp/home" "$guard" doctor "$F"
expect init-picks-offline ok "^Mode: offline\. This host cannot reach [^ ]+, so guard/run reads the scripts from guard/harness-" -- \
  no_reach "$guard" init "$tmp/agents" --worktree "$tmp/agents-wt2" --branch guard/reach
expect install-says-mode ok "^mode offline: this host cannot reach [^ ]+, so guard init writes the scripts into each project" -- \
  no_reach env HOME="$tmp/ihome" "$here/install.sh" --skills-dir "$tmp/ihome/skills" --bin-dir "$tmp/ihome/bin"
