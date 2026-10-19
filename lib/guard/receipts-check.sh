#!/usr/bin/env bash
# usage: receipts-check.sh <base> <id>...
# Exits 0 when every id is a receipt the broker signed: a row of receipts.jsonl on guard/receipts, whose head commit
# and whose row's own commit both verify against broker_key: on <base>'s guard/budget.card (design-v8 section 6,
# decision 17). Otherwise prints the first failure as the two lines of F04 and exits 2. The fence's F04 calls it; with
# no ids it checks the ref alone.
# The ref is GUARD_RECEIPTS_REF, else refs/remotes/origin/guard/receipts (CI: the workflow fetches it), else
# refs/heads/guard/receipts (the forge's bare repository); when neither exists it fetches origin's once.
# GUARD_RECEIPTS_SIGNERS names an allowed-signers file in place of the card's broker_key: (the broker's own check).
# Receipts are one row per commit on a linear history, so row n of the head's file was added by the n-th commit.
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: receipts-check.sh <base> <id>..." >&2; exit 64; }
base=$1; shift
first=${1:-guard/receipts}
refuse() {  # refuse <what> <why>
  printf 'H4R-F04 evidence-paths: %s (%s) cites no committed path or receipt\nnone\n' "$1" "$2"
  exit 2
}

for id in "$@"; do
  [[ $id =~ ^l[0-9a-f]{10}$ ]] && refuse "$id" "a local unsigned receipt, never published"
  [[ $id =~ ^L[0-9a-f]{10}$ ]] || refuse "$id" "not a receipt id"
done

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "${GUARD_RECEIPTS_SIGNERS:-}" ]; then
  signers=$GUARD_RECEIPTS_SIGNERS
else
  key=$(git show "$base:guard/budget.card" 2>/dev/null | awk -F': *' '$1 == "broker_key" { print $2; exit }')
  [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] \
    || refuse "$first" "no broker_key on ${base#origin/}"
  signers=$tmp/allowed_signers
  printf 'broker namespaces="git" %s\n' "$(cut -d' ' -f1,2 <<<"$key")" > "$signers"
fi
signed() { git -c gpg.ssh.allowedSignersFile="$signers" verify-commit "$1" >/dev/null 2>&1; }

find_ref() {
  local r
  for r in ${GUARD_RECEIPTS_REF:-refs/remotes/origin/guard/receipts refs/heads/guard/receipts}; do
    git rev-parse -q --verify "$r^{commit}" && return
  done
  return 1
}
head=$(find_ref) || { git fetch -q origin +refs/heads/guard/receipts:refs/remotes/origin/guard/receipts 2>/dev/null \
  && head=$(find_ref); } || refuse "$first" "no guard/receipts ref"
signed "$head" || refuse "$first" "guard/receipts head ${head:0:12} is not signed by broker_key"
[ -z "$(git rev-list --merges -n 1 "$head")" ] || refuse "$first" "guard/receipts has a merge; it only appends"
git show "$head:receipts.jsonl" > "$tmp/rows" 2>/dev/null || refuse "$first" "guard/receipts holds no receipts.jsonl"
mapfile -t commits < <(git rev-list --reverse "$head")
[ "${#commits[@]}" = "$(wc -l < "$tmp/rows")" ] || refuse "$first" "guard/receipts is not one row per commit"

for id in "$@"; do
  n=$(grep -n -m 1 -F "{\"id\": \"$id\", " "$tmp/rows" | cut -d: -f1)
  [ -n "$n" ] || refuse "$id" "no row on guard/receipts"
  c=${commits[n-1]}
  signed "$c" || refuse "$id" "its commit ${c:0:12} is not signed by broker_key"
  [ "$(git show "$c:receipts.jsonl" | wc -l)" = "$n" ] && [ "$(git show "$c:receipts.jsonl" | tail -n 1)" = "$(sed -n "${n}p" "$tmp/rows")" ] \
    || refuse "$id" "its commit ${c:0:12} did not add it"
done
exit 0
