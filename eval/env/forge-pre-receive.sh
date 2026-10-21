#!/usr/bin/env bash
# The protected repository's pre-receive hook, in place of a GitHub ruleset on main. It runs in gitsock.py's
# receive-pack, outside the agent's sandbox, so the agent can neither edit it nor write the repository around it.
#   - main cannot be deleted or force-pushed.
#   - Once main carries guard/run, an update to main must pass the fence that the old main's guard/run runs, the way
#     the guard-fence check runs the base branch's copy. Before that, main is open, as in a repository without a guard.
#   - Other branches are free.
#   - Behind the broker (git config guard.records signed, with gpg.ssh.allowedSignersFile naming the owner's and the
#     broker's keys), on every ref: a new commit that writes runs/<id>/execution.tsv or runs/<id>/question.card must
#     carry a signature from one of those keys (decision D13), and a card/<run_id> tag must be a tag object of that
#     name, signed by one of them, on a commit holding runs/<run_id>/question.card; it is never moved or deleted
#     through the forge (decision D2's tag ruleset).
#   - With git config guard.holdout set (lib/broker/holdout.py seal), an update to main runs that command with the new
#     and the old commit; when the tree the scorer loads changed, it scores it on the sealed holdout and refuses on its
#     verdict.
#   - refs/heads/guard/receipts, the broker's signed receipts (design-v8 decision 17), in place of the GitHub ruleset
#     that requires signed commits there: it is never deleted, only fast-forwarded, and every commit an update adds
#     verifies against broker_key: on main's guard/budget.card, or, on a main without one, against the forge's
#     gpg.ssh.allowedSignersFile when guard.records is signed. With neither, every update to it is refused.
#   - With git config guard.main pulls, main takes pull requests only: after the checks above, an update to main is
#     refused unless the broker's guard merge pushes it, marked by GUARD_BROKER_MERGE in its environment. A push
#     through the forge socket cannot set it, since gitsock.py's environment is fixed when it starts. This stands in
#     for a ruleset that requires a pull request, with only the broker's token able to merge one.
# Every decision is appended to $FORGE_LOG, which only the evaluator reads.
set -uo pipefail
zero=0000000000000000000000000000000000000000
log() { [ -z "${FORGE_LOG:-}" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" >> "$FORGE_LOG"; }
records=$(git config guard.records || true)
main_mode=$(git config guard.main || true)
holdout=$(git config guard.holdout || true)

# card_tag_problem <old> <new> <ref>: prints why a card tag update is refused, or nothing.
card_tag_problem() {
  local run=${3#refs/tags/card/}
  if [ "$2" = "$zero" ]; then echo "card tags are deleted only by the owner"; return; fi
  if [ "$1" != "$zero" ]; then echo "card/$run exists; a card tag never moves"; return; fi
  if [ "$(git cat-file -t "$2")" != tag ]; then echo "card/$run is not a signed tag object"; return; fi
  if [ "$(git cat-file tag "$2" | sed -n '/^$/q; s/^tag //p')" != "card/$run" ]; then
    echo "the tag object is named $(git cat-file tag "$2" | sed -n '/^$/q; s/^tag //p'), not card/$run"; return
  fi
  git verify-tag "$2" >/dev/null 2>&1 || { echo "card/$run is not signed by the owner's or the broker's key"; return; }
  git cat-file -e "$2^{commit}:runs/$run/question.card" 2>/dev/null \
    || echo "card/$run points at a commit without runs/$run/question.card"
}

# unsigned_record <new>: the first new commit that writes a run's ledger or card without a trusted signature, as a
# refusal's two lines: F03 for a card, F05 for a ledger (design-v8 section 6).
unsigned_record() {
  local c paths card
  while read -r c; do
    paths=$(git diff-tree -r -c --no-commit-id --name-only --root "$c" \
      | grep -E '^runs/[^/]+/(execution\.tsv|question\.card)$' | grep -v '^runs/_template/' | tr '\n' ' ')
    [ -z "$paths" ] || git verify-commit "$c" >/dev/null 2>&1 && continue
    card=$(tr ' ' '\n' <<<"$paths" | grep -m1 'question\.card$')
    if [ -n "$card" ]; then
      printf 'H4R-F03 %s is a card only the broker writes\ngit rm -q -- %s && git commit --amend --no-edit --allow-empty\n' "$card" "$card"
    else
      printf "H4R-F05 execution-ledger: commit %s writes %s without the broker's signature\nnone\n" "${c:0:12}" "${paths% }"
    fi
    return
  done < <(git rev-list "$1" --not --all)
}

# receipts_problem <old> <new>: prints why an update to guard/receipts is refused, or nothing.
receipts_problem() {
  local key signers c
  [ "$2" != "$zero" ] || { echo "guard/receipts is never deleted"; return; }
  if [ "$1" != "$zero" ] && ! git merge-base --is-ancestor "$1" "$2"; then
    echo "guard/receipts only grows; this push is not a fast-forward"; return
  fi
  key=$(git show refs/heads/main:guard/budget.card 2>/dev/null | awk -F': *' '$1 == "broker_key" { print $2; exit }')
  if [[ $key =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)\ [A-Za-z0-9+/]+ ]]; then
    signers=$(mktemp)
    # signers is local and gone by EXIT, so the trap takes its value now.
    # shellcheck disable=SC2064
    trap "rm -f '${signers:?}'" EXIT
    printf 'broker namespaces="git" %s\n' "$(cut -d' ' -f1,2 <<<"$key")" > "$signers"
  elif [ "$records" = signed ] && signers=$(git config gpg.ssh.allowedSignersFile); then :
  else echo "no broker_key on main, so nothing can sign guard/receipts"; return; fi
  while read -r c; do
    [ -n "$c" ] || continue
    if ! git -c gpg.ssh.allowedSignersFile="$signers" verify-commit "$c" >/dev/null 2>&1; then
      echo "commit ${c:0:12} is not signed by broker_key"; return
    fi
    [ "$(git rev-list --no-walk --count --merges "$c")" = 0 ] || { echo "commit ${c:0:12} is a merge"; return; }
  done < <(if [ "$1" = "$zero" ]; then git rev-list "$2"; else git rev-list "$2" "^$1"; fi)
}

status=0
while read -r old new ref; do
  if [ "$ref" = refs/heads/main ]; then
    if [ "$new" = "$zero" ]; then
      echo "main is a protected branch: it cannot be deleted."; log refuse-delete "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$old" != "$zero" ] && ! git merge-base --is-ancestor "$old" "$new"; then
      printf 'H4R-S03 force push to main is refused; a landed commit is redone, not rewritten\ngit pull --rebase origin main\n'
      log refuse-force "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$old" != "$zero" ] && runner=$(git show "$old:guard/run" 2>/dev/null); then
      if ! out=$(HPC_GUARD_REF=$old HPC_GUARD_LOCAL=0 bash -c "$runner" guard/run fence "$old" "$new" 2>&1); then
        # The fence's last two lines are its first FAIL as a refusal (H4R-<code>, then the repair); they come first.
        grep -A1 -m1 '^H4R-' <<<"$out" || echo "main is a protected branch: the guard-fence check failed."
        grep -E '^(FAIL|WARN)' <<<"$out"
        log refuse-fence "$ref" "$old" "$new"; status=1; continue
      fi
    fi
    if [ -n "$holdout" ] && [ "$old" != "$zero" ]; then
      if ! out=$(bash -c "$holdout"' "$@"' holdout "$new" "$old" 2>&1); then
        echo "$out"; log refuse-holdout "$ref" "$old" "$new"; status=1; continue
      fi
    fi
    if [ "$main_mode" = pulls ] && [ -z "${GUARD_BROKER_MERGE:-}" ]; then
      echo "main takes pull requests only: open one with guard pr open, and the broker merges it once its review approves."
      log refuse-pr "$ref" "$old" "$new"; status=1; continue
    fi
  fi
  if [ "$ref" = refs/heads/guard/receipts ] && why=$(receipts_problem "$old" "$new") && [ -n "$why" ]; then
    echo "guard/receipts refused: $why."; log refuse-receipts "$ref" "$old" "$new"; status=1; continue
  fi
  if [ "$records" = signed ]; then
    if [[ $ref == refs/tags/card/* ]] && why=$(card_tag_problem "$old" "$new" "$ref") && [ -n "$why" ]; then
      printf 'H4R-F03 card/%s is a card only the broker writes\ngit tag -d card/%s\n' "${ref#refs/tags/card/}" "${ref#refs/tags/card/}"
      echo "$ref refused: $why."; log refuse-tag "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$new" != "$zero" ] && why=$(unsigned_record "$new") && [ -n "$why" ]; then
      echo "$why"; log refuse-unsigned "$ref" "$old" "$new"; status=1; continue
    fi
  fi
  log accept "$ref" "$old" "$new"
done
exit $status
