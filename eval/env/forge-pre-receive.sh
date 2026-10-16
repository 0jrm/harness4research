#!/usr/bin/env bash
# The protected repository's pre-receive hook, in place of a GitHub ruleset on main. It runs in gitsock.py's
# receive-pack, outside the agent's sandbox, so the agent can neither edit it nor write the repository around it.
#   - main cannot be deleted or force-pushed.
#   - Once main carries guard/bin/fence.sh, an update to main must pass that fence, read from the old main, the way
#     the guard-fence check runs the base branch's copy. Before that, main is open, as in a repository without a guard.
#   - Other branches are free.
#   - Behind the broker (git config guard.records signed, with gpg.ssh.allowedSignersFile naming the owner's and the
#     broker's keys), on every ref: a new commit that writes runs/<id>/execution.tsv or runs/<id>/question.card must
#     carry a signature from one of those keys (decision D13), and a card/<run_id> tag must be a tag object of that
#     name, signed by one of them, on a commit holding runs/<run_id>/question.card; it is never moved or deleted
#     through the forge (decision D2's tag ruleset).
# Every decision is appended to $FORGE_LOG, which only the evaluator reads.
set -uo pipefail
zero=0000000000000000000000000000000000000000
log() { [ -z "${FORGE_LOG:-}" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" >> "$FORGE_LOG"; }
records=$(git config guard.records || true)

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

# unsigned_record <new>: prints the first new commit that writes a run's ledger or card without a trusted signature.
unsigned_record() {
  local c paths
  while read -r c; do
    paths=$(git diff-tree -r -c --no-commit-id --name-only --root "$c" \
      | grep -E '^runs/[^/]+/(execution\.tsv|question\.card)$' | grep -v '^runs/_template/' | tr '\n' ' ')
    [ -z "$paths" ] || git verify-commit "$c" >/dev/null 2>&1 \
      || { echo "commit ${c:0:12} writes ${paths% } without the broker's signature; use guard ledger add or guard card add"; return; }
  done < <(git rev-list "$1" --not --all)
}

status=0
while read -r old new ref; do
  if [ "$ref" = refs/heads/main ]; then
    if [ "$new" = "$zero" ]; then
      echo "main is a protected branch: it cannot be deleted."; log refuse-delete "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$old" != "$zero" ] && ! git merge-base --is-ancestor "$old" "$new"; then
      echo "main is a protected branch: force pushes are refused."; log refuse-force "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$old" != "$zero" ] && fence=$(git show "$old:guard/bin/fence.sh" 2>/dev/null); then
      if ! out=$(bash -c "$fence" guard/bin/fence.sh "$old" "$new" 2>&1); then
        echo "main is a protected branch: the guard-fence check failed."
        grep -E '^(FAIL|WARN)' <<<"$out"
        log refuse-fence "$ref" "$old" "$new"; status=1; continue
      fi
    fi
  fi
  if [ "$records" = signed ]; then
    if [[ $ref == refs/tags/card/* ]] && why=$(card_tag_problem "$old" "$new" "$ref") && [ -n "$why" ]; then
      echo "$ref refused: $why."; log refuse-tag "$ref" "$old" "$new"; status=1; continue
    fi
    if [ "$new" != "$zero" ] && why=$(unsigned_record "$new") && [ -n "$why" ]; then
      echo "$ref refused: $why."; log refuse-unsigned "$ref" "$old" "$new"; status=1; continue
    fi
  fi
  log accept "$ref" "$old" "$new"
done
exit $status
