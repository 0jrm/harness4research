# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== batch"
BT=$keep/bt
git init -q --bare -b main "$BT.git"; git clone -q "$BT.git" "$BT" 2>/dev/null; cd "$BT" || exit 1
git config url."$BT.git".insteadOf https://github.com/lab/batch.git; git remote set-url origin https://github.com/lab/batch.git
git checkout -q -b main; mkdir -p guard runs/r9; echo cap > guard/budget.card; echo q > runs/r9/question.card
printf 'def add(a, b):\n    return a + b\n' > calc.py; echo '# Batch' > README.md
git add -A; git commit -q -m init; git push -q -u origin main; git remote set-head origin -a >/dev/null
branch() {  # branch <name> <shell command>: a branch from main that makes the command's changes, pushed
  git switch -q -c "$1" main; eval "$2"; git add -A; git commit -q -m "$1"; git push -q -u origin "$1"; git switch -q main
}
branch rec 'mkdir -p runs/r1; echo 1 > runs/r1/out.csv'
branch card 'mkdir -p runs/r2; echo "hypothesis: h" > runs/r2/question.card'
branch guardpr 'echo more >> guard/budget.card'
branch s1 'echo "# adds" >> calc.py'
branch s2 'echo "More." >> README.md'
branch s3 'echo "# nobrief" >> calc.py'
branch big 'seq 30 > numbers.txt'
for b in s1 s2 big; do mkdir -p .git/guard/briefs; printf '## Request (verbatim)\nPlease do %s\n\n## Plan\nDid it.\n' "$b" > ".git/guard/briefs/$b.md"; done
prs_json() {  # prs_json <createdAt> <number:branch>...: MOCK_GH_PRS for those branches at origin's heads, each with one passing check
  local created=$1 x; shift
  for x in "$@"; do
    jq -nc --argjson n "${x%%:*}" --arg b "${x#*:}" --arg sha "$(git rev-parse "origin/${x#*:}")" --arg c "$created" \
      '{number: $n, title: "Change \($b)", headRefName: $b, headRefOid: $sha, baseRefName: "main", isCrossRepository: false,
        isDraft: false, createdAt: $c, state: "OPEN", mergeCommit: {oid: "abc\($n)def0"},
        statusCheckRollup: [{__typename: "CheckRun", name: "fence", status: "COMPLETED", conclusion: "SUCCESS"}]}'
  done | jq -sc .
}
all=(11:rec 12:card 13:guardpr 14:s1 15:s2 16:s3 17:big)
old=2020-01-01T00:00:00Z
PRS=$(prs_json "$old" "${all[@]}")
cat > "$tmp/fake-batch" <<'FAKE'
#!/usr/bin/env bash
prs=$(sed -n 's/^# Pull request #\([0-9]*\)$/\1/p' .guard-review/prompt.md)
ulimit -Sv > "$FAKE_DIR/vmem"
[ -n "$prs" ] || [ "${FAKE_SINGLE:-}" != crash ] || { echo "Error: offline" >&2; exit 3; }
[ -n "$prs" ] || { printf 'Single.\nVERDICT: approve - single review\n'; exit; }
git rev-parse HEAD > "$FAKE_DIR/head"
echo $prs >> "$FAKE_DIR/sessions"; cp .guard-review/prompt.md "$FAKE_DIR/prompt.md"
case ${FAKE_BATCH:-} in
  crash) echo "Error: rate limited" >&2; exit 3 ;;
  commit) echo junk >> calc.py; git commit -qam "reviewer commit" ;;
esac
echo "Findings for each."
for n in $prs; do
  case " ${FAKE_MISS:-} " in *" $n "*) continue ;; esac
  case " ${FAKE_TWICE:-} " in *" $n "*) echo "VERDICT #$n: approve - once" ;; esac
  echo "VERDICT #$n: approve - fine $n"
done
[ "${FAKE_BATCH:-}" != trailer ] || echo "Thanks for reading."
FAKE
chmod +x "$tmp/fake-batch"; mkdir -p "$tmp/fakeb"
batch() {  # batch <command...>: runs it with the batch reviewer, every merge gate open and MOCK_GH_PRS=$PRS, unless an assignment changes one
  rm -f "$tmp/gh.log" "$tmp/fakeb/sessions" "$tmp/fakeb/prompt.md"
  env -u GH_TOKEN -u GITHUB_TOKEN FAKE_DIR="$tmp/fakeb" MOCK_GH_LOG="$tmp/gh.log" MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false \
    MOCK_GH_RULES=pull_request MOCK_GH_PRS="$PRS" "$@"
}
fresh() { rm -f .git/guard/reviews.tsv .git/guard/needs-you.tsv; }
bt_reviews=$BT/.git/guard/reviews.tsv
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-batch" >/dev/null; "$guard" config set review_small_lines 20 >/dev/null
batch env FAKE_MISS=15 "$guard" review --batch > "$tmp/batch.out" 2>&1
expect batch-records-approve ok "	11	$(git rev-parse origin/rec)	approve	records-tier	records only; the fence and CI check them$" -- cat "$bt_reviews"
expect batch-one-session ok '^14 15$' -- cat "$tmp/fakeb/sessions"
expect batch-session-on-base ok "^$(git rev-parse origin/main)$" -- cat "$tmp/fakeb/head"
expect batch-prompt-rules ok '^VERDICT #<n>: <approve\|changes\|escalate> - <one-line reason>$' -- cat "$tmp/fakeb/prompt.md"
expect batch-prompt-briefs ok '^Please do s1 Please do s2 $' -- bash -c 'grep "^Please do" "$1" | tr "\n" " "' _ "$tmp/fakeb/prompt.md"
expect batch-prompt-diffs ok '^\+More\.$' -- cat "$tmp/fakeb/prompt.md"
expect batch-small-approve ok "	14	$(git rev-parse origin/s1)	approve	$tmp/fake-batch	fine 14$" -- cat "$bt_reviews"
expect batch-missing-line-escalates ok "	15	$(git rev-parse origin/s2)	escalate	$tmp/fake-batch	the reviewer's reply does not end with one VERDICT line for #15$" -- cat "$bt_reviews"
expect batch-escalate-queued ok '· approve · Review of PR #15 needs your decision$' -- "$guard" needs-you
expect batch-no-brief-skipped ok '^note: #16 is small and waits for its brief, which carries the user.s words: no brief for s3\.' -- cat "$tmp/batch.out"
expect batch-no-brief-not-reviewed fail - -- grep -q '	16	' "$bt_reviews"
expect batch-large-single ok "	17	$(git rev-parse origin/big)	approve	$tmp/fake-batch	single review$" -- cat "$bt_reviews"
expect batch-human-no-review fail - -- grep -qE '	1[23]	' "$bt_reviews"
expect batch-guard-merge-item ok '· approve · Merge PR #13$' -- "$guard" needs-you
expect batch-card-digest ok '^Why: Only you approve a question card\. .*: #12 Change card \(runs/r2/question\.card\)$' -- \
  bash -c 'id=$("$1" needs-you find --kind approve --title "Approve question cards") && "$1" needs-you show "$id"' _ "$guard"
expect batch-card-digest-run ok '^gh pr merge 12 --squash$' -- bash -c '"$1" needs-you | sed -n "/Approve question cards/,/^🩺$/p"' _ "$guard"
expect batch-summary-tiers ok '^tiers: records 1, small 3, large 1, human 2$' -- cat "$tmp/batch.out"
expect batch-summary-verdict ok '^  #15 small: escalate - the reviewer.s reply does not end' -- cat "$tmp/batch.out"
expect batch-comments ok '^pr comment 14 --body guard review: approve at [0-9a-f]{7}\. fine 14$' -- cat "$tmp/gh.log"
expect batch-worktree-removed ok '^1$' -- bash -c 'git worktree list | wc -l'
rows=$(wc -l < "$bt_reviews"); items=$(wc -l < .git/guard/needs-you.tsv)
batch "$guard" review --batch > "$tmp/batch.out" 2>&1
expect batch-rerun-no-session fail - -- test -e "$tmp/fakeb/sessions"
expect batch-rerun-no-rows ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$bt_reviews"
expect batch-rerun-same-items ok "^$items\$" -- bash -c 'wc -l < "$1"' _ .git/guard/needs-you.tsv
expect batch-rerun-says-reviewed ok '^note: #14 already has the verdict approve at [0-9a-f]{7}\.$' -- cat "$tmp/batch.out"
fresh; "$guard" config set review_batch_max 1 >/dev/null
batch "$guard" review --batch >/dev/null 2>&1
expect batch-max-per-session ok '^14 15 $' -- bash -c 'tr "\n" " " < "$1"' _ "$tmp/fakeb/sessions"
"$guard" config set review_batch_max "" >/dev/null
fresh; batch env FAKE_TWICE=14 "$guard" review --batch >/dev/null 2>&1
expect batch-two-lines-escalate ok "	14	[0-9a-f]*	escalate	.*one VERDICT line for #14$" -- cat "$bt_reviews"
expect batch-two-lines-other-fine ok "	15	[0-9a-f]*	approve	.*fine 15$" -- cat "$bt_reviews"
fresh; batch env FAKE_BATCH=crash "$guard" review --batch > "$tmp/batch.out" 2>&1; echo "exit $?" >> "$tmp/batch.out"
expect batch-crash-exit-2 ok '^exit 2$' -- tail -n 1 "$tmp/batch.out"
expect batch-crash-not-recorded ok '^0$' -- bash -c 'grep -c "	1[45]	" "$1" || true' _ "$bt_reviews"
expect batch-crash-not-queued fail - -- bash -c '"$1" needs-you | grep -q "Review of PR #1[45]"' _ "$guard"
expect batch-crash-summary ok '^  #14 small: not reviewed; reviewer unavailable: Error: rate limited\. .*fake-batch exited 3;' -- cat "$tmp/batch.out"
fresh; batch env FAKE_SINGLE=crash "$guard" review --batch > "$tmp/batch.out" 2>&1; echo "exit $?" >> "$tmp/batch.out"
expect batch-large-crash-exit-2 ok '^exit 2$' -- tail -n 1 "$tmp/batch.out"
expect batch-large-crash-summary ok '^  #17 large: not reviewed; reviewer unavailable: Error: offline\. .*fake-batch exited 3;' -- cat "$tmp/batch.out"
expect batch-large-crash-not-recorded ok '^0$' -- bash -c 'grep -c "	17	" "$1" || true' _ "$bt_reviews"
expect batch-large-crash-small-reviewed ok "	14	[0-9a-f]*	approve	.*fine 14$" -- cat "$bt_reviews"
fresh; batch env FAKE_BATCH=trailer "$guard" review --batch >/dev/null 2>&1
expect batch-verdicts-must-end-reply ok '^2$' -- grep -c '	escalate	.*one VERDICT line for #1[45]$' "$bt_reviews"
fresh; batch env FAKE_BATCH=commit "$guard" review --batch > "$tmp/batch.out" 2>&1
expect batch-commit-discarded ok '^note: the reviewer changed the checkout of main, and the change is discarded\.$' -- cat "$tmp/batch.out"
expect batch-commit-not-pushed ok "^$(git rev-parse main)	" -- git ls-remote origin refs/heads/main
expect batch-review-gh-fails fail '^guard review --batch: gh cannot list the open pull requests' -- batch env PATH="$(path_without gh)" "$guard" review --batch

fresh; batch "$guard" review --batch >/dev/null 2>&1
batch "$guard" merge --batch > "$tmp/batch.out" 2>&1
expect batch-merge-order ok '^11 14 15 17 $' -- bash -c 'sed -n "s/^pr merge \([0-9]*\) --squash --match-head-commit .*/\1/p" "$1" | tr "\n" " "' _ "$tmp/gh.log"
expect batch-merge-summary ok '^merged #11 as abc11de$' -- cat "$tmp/batch.out"
expect batch-merge-skips-human fail - -- grep -qE '^pr merge 1[236]' "$tmp/gh.log"
PRS=$(jq -c 'map(if .number == 14 then .statusCheckRollup += [{name: "tests", status: "COMPLETED", conclusion: "FAILURE"}]
  elif .number == 17 then .statusCheckRollup = [] else . end)' <<<"$PRS")
batch "$guard" merge --batch > "$tmp/batch.out" 2>&1
expect batch-merge-passing-still-merge ok '^11 15 $' -- bash -c 'sed -n "s/^pr merge \([0-9]*\) --squash --match-head-commit .*/\1/p" "$1" | tr "\n" " "' _ "$tmp/gh.log"
expect batch-refused-one-item ok '^1$' -- bash -c '"$1" needs-you | grep -c "· Merge approved pull requests$"' _ "$guard"
expect batch-refused-no-per-pr fail - -- bash -c '"$1" needs-you | grep -qE "· Merge PR #1[47]$"' _ "$guard"
expect batch-refused-why ok '^Why: guard merge refused these approved pull requests, .*: #14 not every check passed: tests \(failure\); #17 no checks ran on pull request #17, so nothing tested it$' -- \
  bash -c '"$1" needs-you show "$("$1" needs-you find --kind approve --title "Merge approved pull requests")"' _ "$guard"
expect batch-refused-commands ok '^cd .*/bt\|gh pr merge 14 --squash\|gh pr merge 17 --squash$' -- \
  bash -c '"$1" needs-you show "$("$1" needs-you find --kind approve --title "Merge approved pull requests")" | awk "/^\`\`\`bash\$/ {f=1; next} /^\`\`\`\$/ {exit} f" | paste -sd"|"' _ "$guard"
expect batch-refused-summary ok '^refused #17: no checks ran on pull request #17, so nothing tested it$' -- cat "$tmp/batch.out"
PRS=$(prs_json "$old" "${all[@]}")
batch "$guard" merge --batch >/dev/null 2>&1
expect batch-refused-done ok - -- bash -c '! "$1" needs-you find --kind approve --title "Merge approved pull requests"' _ "$guard"
expect merge-single-unchanged fail '^FAIL  guard review has no verdict for pull request #16$' -- batch env "$guard" merge 16

fresh; now=$(date -u +%FT%TZ)
pending11='map(if .number == 11 then .statusCheckRollup[0] += {status: "IN_PROGRESS", conclusion: null} else . end)'
PRS=$(prs_json "$now" "${all[@]}" | jq -c "$pending11")
batch "$guard" ship > "$tmp/batch.out" 2>&1
expect ship-not-due ok '^guard ship: 5 pull request\(s\) wait \(#11 #14 #15 #16 #17\)\. The batch is due in about 24 hour\(s\), when the oldest is 24 hours old, or once 8 wait\. guard ship --now runs it now\.$' -- cat "$tmp/batch.out"
expect ship-not-due-no-review fail - -- test -e "$bt_reviews"
expect ship-not-due-no-merge fail - -- grep -q '^pr merge' "$tmp/gh.log"
expect ship-not-due-digest ok '· approve · Approve question cards$' -- "$guard" needs-you
PRS=$(prs_json "$now" 11:rec 13:guardpr 14:s1 | jq -c "$pending11")
batch "$guard" ship >/dev/null 2>&1
expect ship-digest-done-without-cards fail - -- bash -c '"$1" needs-you find --kind approve --title "Approve question cards"' _ "$guard"
"$guard" config set review_batch_max 2 >/dev/null
expect ship-due-by-count ok '^== guard ship: 3 open pull request\(s\)$' -- batch "$guard" ship
"$guard" config set review_batch_max "" >/dev/null
fresh; PRS=$(prs_json "$old" 11:rec 14:s1 | jq -c "$pending11")
expect ship-due-by-age-pending ok '^== guard ship: 2 open pull request\(s\)$' -- batch "$guard" ship
fresh; PRS=$(prs_json "$old" 11:rec 14:s1)
batch "$guard" ship > "$tmp/batch.out" 2>&1
expect ship-due-by-age ok '^merged #11 as abc11de$' -- cat "$tmp/batch.out"
expect ship-due-summary ok '^tiers: records 1, small 1, large 0, human 0$' -- cat "$tmp/batch.out"
expect ship-due-merged-small ok '^merged #14 as abc14de$' -- cat "$tmp/batch.out"
fresh; PRS=$(prs_json "$now" 11:rec 14:s1)
batch "$guard" ship > "$tmp/batch.out" 2>&1
expect ship-due-by-green-records ok '^guard ship: due now: green records pull request\(s\) #11 need no model\.$' -- cat "$tmp/batch.out"
expect ship-green-records-merged ok '^merged #11 as abc11de$' -- cat "$tmp/batch.out"
fresh; PRS=$(prs_json "$now" 11:rec 14:s1)
expect ship-now ok '^merged #14 as abc14de$' -- batch "$guard" ship --now
fresh; PRS=$(prs_json "$now" 14:s1); rm -f "$tmp/fakeb/vmem"
( ulimit -Sv 6000000 2>/dev/null; batch "$guard" ship --now ) >/dev/null 2>&1
expect ship-raises-vmem-soft-limit ok "^$(ulimit -Hv)$" -- cat "$tmp/fakeb/vmem"
expect ship-nothing ok '^guard ship: nothing waits for review or merge\.$' -- batch env MOCK_GH_PRS='[]' "$guard" ship
expect ship-usage fail '^usage: guard review --batch \| guard merge --batch \| guard ship \[--now\]$' -- "$guard" ship --later
expect review-batch-usage fail '^usage: guard review <pr number> \| guard review --batch$' -- "$guard" review --batch 5
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-reviewer" >/dev/null; "$guard" config set review_small_lines "" >/dev/null
cd "$tmp/wt" || exit 1
