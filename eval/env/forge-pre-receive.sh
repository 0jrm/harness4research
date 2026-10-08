#!/usr/bin/env bash
# The protected repository's pre-receive hook, in place of a GitHub ruleset on main. It runs in gitsock.py's
# receive-pack, outside the agent's sandbox, so the agent can neither edit it nor write the repository around it.
#   - main cannot be deleted or force-pushed.
#   - Once main carries guard/bin/fence.sh, an update to main must pass that fence, read from the old main, the way
#     the guard-fence check runs the base branch's copy. Before that, main is open, as in a repository without a guard.
#   - Other branches are free.
# Every decision is appended to $FORGE_LOG, which only the evaluator reads.
set -uo pipefail
zero=0000000000000000000000000000000000000000
log() { [ -z "${FORGE_LOG:-}" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" >> "$FORGE_LOG"; }
status=0
while read -r old new ref; do
  [ "$ref" = refs/heads/main ] || { log accept "$ref" "$old" "$new"; continue; }
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
  log accept "$ref" "$old" "$new"
done
exit $status
