# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== update moves the pin"
# old_pin: the commit before lib/guard/ last changed, so this harness's scripts differ from the ones it pins.
old_pin=$(git -C "$here" rev-parse "$(git -C "$here" log -1 --format=%H -- lib/guard)^")
pin_at() {  # pin_at <project> <pin>: commits to its main a card that pins <pin>, and offline, the vendored file renamed to match
  local p=$1 old; cd "$p.wt" || return; git fetch -q origin; git switch -q --detach origin/main
  old=$(sed -n 's/^harness: //p' guard/budget.card)
  sed -i "s/^harness: .*/harness: $2/" guard/budget.card
  [ ! -e "guard/harness-$old.sh" ] || git mv "guard/harness-$old.sh" "guard/harness-$2.sh"
  git commit -q -am "pin $2"; git push -q origin HEAD:main; git fetch -q origin
}
changes() { git -C "$1" diff --name-status --no-renames origin/main HEAD | sort; }  # changes <worktree>: its proposal's files
card_lines() { git -C "$1" diff -U0 origin/main HEAD -- guard/budget.card | grep '^[-+][^-+]' | tr '\n' ' '; }
pin_at "$O" "$old_pin"
expect version-pin-older ok '^project older: guard init ' -- "$guard" version
expect update-pin-online ok '^  guard/budget.card$' -- bash -c 'set -o pipefail; "$1" init "$2" --update --worktree "$2.up" | tee "$2.up.out"' _ "$guard" "$O"
expect update-pin-online-files ok '^M	guard/budget.card$' -- changes "$O.up"
expect update-pin-online-one-line ok "^-harness: $old_pin \+harness: $pin $" -- card_lines "$O.up"
expect update-pin-keeps-mode ok '^Mode: online\. The project is online, ' -- cat "$O.up.out"
git -C "$O.up" push -q origin guard/update:main; git fetch -q origin
expect update-pin-then-current ok 'Nothing proposed\.$' -- "$guard" init "$O" --update --worktree "$O.up2" --branch guard/again
pin_at "$F" "$old_pin"
expect update-pin-offline ok "^  $art$" -- "$guard" init "$F" --update --worktree "$F.up"
expect update-pin-offline-files ok '^$' -- diff <(printf 'A\t%s\nD\t%s\nM\tguard/budget.card\n' "$art" "guard/harness-$old_pin.sh" | sort) <(changes "$F.up")
expect update-pin-offline-one-line ok "^-harness: $old_pin \+harness: $pin $" -- card_lines "$F.up"
expect update-pin-offline-artifact ok - -- bash -c 'bash "$1/lib/vendor.sh" "$2" | cmp - "$3"' _ "$here" "$pin" "$F.up/$art"
