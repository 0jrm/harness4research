# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== review"
RV=$keep/rv
git init -q --bare -b main "$RV.git"; git clone -q "$RV.git" "$RV" 2>/dev/null; cd "$RV" || exit 1
git checkout -q -b main; printf 'def add(a, b):\n    return a - b\n' > calc.py; git add -A; git commit -q -m init
git push -q -u origin main; git remote set-head origin -a >/dev/null
git switch -q -c feat/add; echo '# adds two numbers' >> calc.py; git commit -q -am "feat: add"; git push -q -u origin feat/add
cat > "$tmp/fake-reviewer" <<'FAKE'
#!/usr/bin/env bash
echo "call ${GH_TOKEN:-no-token} $*" >> "$FAKE_DIR/calls"
readlink /proc/self/fd/0 > "$FAKE_DIR/stdin"
pwd > "$FAKE_DIR/cwd"
echo "${GH_CONFIG_DIR:-unset} $(ls -A "${GH_CONFIG_DIR:-/nonexistent}" 2>/dev/null | wc -l)" > "$FAKE_DIR/ghdir"
cp .guard-review/prompt.md "$FAKE_DIR/prompt.md"
git push -q origin HEAD:refs/heads/sneaky 2>/dev/null && echo pushed >> "$FAKE_DIR/calls"
git config --get-all url.guard-review-never-pushes:.pushInsteadOf > "$FAKE_DIR/no-push"
git push -q "$FAKE_DIR/local.git" HEAD:refs/heads/test 2>/dev/null && echo pushed-local >> "$FAKE_DIR/calls"
case $FAKE_REVIEW in
  fix-once) if grep -q 'a - b' calc.py; then sed -i 's/a - b/a + b/' calc.py; git commit -qam "fix: add adds"; fi
    echo "VERDICT: approve - adds as asked" ;;
  fix-always) date +%s%N >> calc.py; git commit -qam "fix: more"; echo "VERDICT: approve - fixed again" ;;
  dirty) echo junk >> calc.py; echo "VERDICT: approve - fine" ;;
  none) echo "It looks fine to me." ;;
  crash) echo 'Error: Authentication required.' >&2; exit 3 ;;
  node) printf '/opt/agent/index.js:2\n  WebAssembly.instantiate(bytes)\n  ^\n\nRangeError: WebAssembly.instantiate(): Out of memory\n    at main (/opt/agent/index.js:2:3)\n\nNode.js v24.5.0\n' >&2; exit 1 ;;
  silent) ;;
  semicolons) echo "VERDICT: escalate - ;split;; the reason;;; here;" ;;
  fenced) printf 'Report.\n```\nVERDICT: approve - fenced verdict\n```\n' ;;
  *) printf 'Report.\nVERDICT: %s - reason for %s  \n\n' "$FAKE_REVIEW" "$FAKE_REVIEW" ;;
esac
FAKE
chmod +x "$tmp/fake-reviewer"; mkdir -p "$tmp/fake" "$tmp/fakebin"; ln -s "$tmp/fake-reviewer" "$tmp/fakebin/cursor-agent"
git init -q --bare "$tmp/fake/local.git"
pr_json() {  # pr_json [jq filter]: pull request 5 for feat/add at origin's head with one passing check, edited by the filter
  jq -nc --arg sha "$(git rev-parse origin/feat/add)" '{state: "OPEN", isDraft: false, headRefName: "feat/add", headRefOid: $sha,
    baseRefName: "main", isCrossRepository: false,
    statusCheckRollup: [{__typename: "CheckRun", name: "fence", status: "COMPLETED", conclusion: "SUCCESS"}]} | '"${1:-.}"
}
review() {  # review <FAKE_REVIEW> [env...]: guard review 5 with the fake reviewer, fresh call and gh logs
  rm -f "$tmp/fake/calls" "$tmp/gh.log"
  env FAKE_REVIEW="$1" FAKE_DIR="$tmp/fake" MOCK_GH_LOG="$tmp/gh.log" MOCK_GH_PR="$(pr_json)" \
    GH_TOKEN=github_pat_agent "${@:2}" "$guard" review 5
}
reviews=$RV/.git/guard/reviews.tsv brief=$RV/.git/guard/briefs/feat-add.md
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-reviewer" >/dev/null
expect review-no-brief fail "no brief for feat/add. Write $brief with the user's request" -- review approve
mkdir -p "$(dirname "$brief")"; printf '## Request (verbatim)\n\n## Plan\nChange add.\n' > "$brief"
expect review-empty-request fail "the '## Request \(verbatim\)' section of .* is empty" -- review approve
printf '## Request (verbatim)\nMake add actually add, plz\n\n## Plan\nI fixed the docstring.\n\n## Test command\npython3 -c "import calc"\n' > "$brief"
mkdir -p "$tmp/xdg-local/guard"; echo "reviewer: local" > "$tmp/xdg-local/guard/config"
expect review-local-refuses fail "reviewer is local and no local command is set. Set one: guard config set reviewer_cmd_local 'codex exec --oss -m <model> --sandbox danger-full-access'$" -- review approve XDG_CONFIG_HOME="$tmp/xdg-local"
expect review-not-open fail 'pull request #5 is merged' -- review approve MOCK_GH_PR="$(pr_json '.state = "MERGED"')"
expect review-approve ok '^VERDICT: approve - reason for approve$' -- review approve
expect review-one-round ok '^1$' -- grep -c '^call' "$tmp/fake/calls"
expect review-worktree-in-state ok "^$RV/.git/guard/review-worktrees/pr-5$" -- cat "$tmp/fake/cwd"
expect review-prompt-scope ok 'If the brief has a "Scope" section' -- cat "$tmp/fake/prompt.md"
expect review-prompt-facts ok 'line in `FACTS.md`, open the evidence' -- cat "$tmp/fake/prompt.md"
expect review-recorded ok "	5	$(git rev-parse origin/feat/add)	approve	$tmp/fake-reviewer	reason for approve$" -- tail -n 1 "$reviews"
expect review-tsv-header ok '^ts	pr	head	verdict	reviewer	reason$' -- head -n 1 "$reviews"
expect review-prompt-request ok '^Make add actually add, plz$' -- cat "$tmp/fake/prompt.md"
expect review-prompt-diff ok '^\+# adds two numbers$' -- cat "$tmp/fake/prompt.md"
expect review-prompt-rules ok '^VERDICT: <approve\|changes\|escalate> - <one-line reason>$' -- cat "$tmp/fake/prompt.md"
expect review-stdin-closed ok '^/dev/null$' -- cat "$tmp/fake/stdin"
expect review-no-token ok '^call no-token Read .guard-review/prompt.md' -- cat "$tmp/fake/calls"
expect review-no-stored-gh-login ok '^/.* 0$' -- cat "$tmp/fake/ghdir"
expect review-reviewer-cannot-push ok '^$' -- git ls-remote origin sneaky
expect review-reviewer-cannot-push-github ok '^https://github.com/\|git@github.com:\|ssh://git@github.com/$' -- bash -c 'tail -n 3 "$1" | paste -sd"|"' _ "$tmp/fake/no-push"
expect review-reviewer-cannot-push-origin ok "^$(git remote get-url origin)$" -- head -n 1 "$tmp/fake/no-push"
expect review-reviewer-local-push ok '^pushed-local$' -- grep pushed-local "$tmp/fake/calls"
expect review-comment ok '^pr comment 5 --body guard review: approve at [0-9a-f]{7}\. reason for approve$' -- cat "$tmp/gh.log"
expect review-comment-no-brief fail - -- grep -q 'plz' "$tmp/gh.log"
expect review-approve-queues-nothing ok '^Nothing needs you\.$' -- "$guard" needs-you
expect review-worktree-removed ok '^1$' -- bash -c 'git worktree list | wc -l'
old_head=$(git rev-parse origin/feat/add)
expect review-fix-approves ok '^VERDICT: approve - adds as asked$' -- review fix-once
expect review-fix-two-rounds ok '^2$' -- grep -c '^call' "$tmp/fake/calls"
expect review-fix-pushed ok 'return a \+ b' -- git show origin/feat/add:calc.py
expect review-fix-one-commit ok '^fix: add adds$' -- git log --format=%s -1 origin/feat/add
expect review-fix-recorded-at-new-head ok "	5	$(git rev-parse origin/feat/add)	approve	" -- tail -n 1 "$reviews"
expect review-fix-not-old-head fail - -- bash -c 'tail -n 1 "$1" | grep -q "$2"' _ "$reviews" "$old_head"
expect review-still-fixing fail '^VERDICT: changes - the reviewer was still committing fixes after 2 rounds$' -- review fix-always
expect review-still-fixing-queues ok '^🩺 n1 · check · Review of PR #5 asks for changes$' -- "$guard" needs-you
git push -q -f origin "$old_head:refs/heads/feat/add"; git fetch -q origin
rm "$RV/.git/guard/needs-you.tsv"
expect review-changes fail '^VERDICT: changes - reason for changes$' -- review changes
expect review-changes-why ok '^Why: reason for changes$' -- "$guard" needs-you show n1
expect review-changes-log ok "^  $RV/.git/guard/reviews/5-[0-9a-f]{12}-r1.txt$" -- "$guard" needs-you show n1
expect review-changes-brief ok "^  $brief$" -- "$guard" needs-you show n1
expect review-changes-block fail '^🩺 n1 · check · Review of PR #5 asks for changes$' -- review changes
expect review-changes-once ok '^1$' -- bash -c '"$1" needs-you | grep -c "Review of PR #5 asks for changes$"' _ "$guard"
expect review-changes-recorded ok '	changes	.*	reason for changes$' -- tail -n 1 "$reviews"
expect review-escalate fail '^VERDICT: escalate - reason for escalate$' -- review escalate
expect review-escalate-queue ok '^🩺 n2 · approve · Review of PR #5 needs your decision$' -- "$guard" needs-you
"$guard" needs-you dismiss n2 >/dev/null
expect review-reason-semicolons fail '^VERDICT: escalate - split; the reason; here$' -- review semicolons
expect review-reason-semicolons-queued ok '^Why: split; the reason; here$' -- "$guard" needs-you show n3
expect review-no-verdict fail "^VERDICT: escalate - the reviewer's last line is not a VERDICT line$" -- review none
rows_before=$(wc -l < "$reviews"); rm "$RV/.git/guard/needs-you.tsv"
review crash > "$tmp/crash.out" 2>&1; echo "exit $?" >> "$tmp/crash.out"
expect review-crash-exit-2 ok '^exit 2$' -- tail -n 1 "$tmp/crash.out"
expect review-crash-unavailable ok "^guard review: reviewer unavailable: Error: Authentication required\\. $tmp/fake-reviewer exited 3; its stderr is in $RV/.git/guard/reviews/5-[0-9a-f]{12}-r1\\.txt\\.err$" -- cat "$tmp/crash.out"
expect review-crash-no-verdict fail - -- grep -q VERDICT "$tmp/crash.out"
expect review-crash-not-recorded ok "^$rows_before$" -- bash -c 'wc -l < "$1"' _ "$reviews"
expect review-crash-not-queued ok '^Nothing needs you\.$' -- "$guard" needs-you
expect review-crash-err-kept ok '^Error: Authentication required\.$' -- bash -c 'cat "$1"/5-*-r1.txt.err' _ "$RV/.git/guard/reviews"
review node > "$tmp/node.out" 2>&1; echo "exit $?" >> "$tmp/node.out"
expect review-node-exit-2 ok '^exit 2$' -- tail -n 1 "$tmp/node.out"
expect review-node-first-error ok '^guard review: reviewer unavailable: RangeError: WebAssembly\.instantiate\(\): Out of memory\. .* exited 1;' -- cat "$tmp/node.out"
review silent > "$tmp/silent.out" 2>&1; echo "exit $?" >> "$tmp/silent.out"
expect review-silent-exit-2 ok '^exit 2$' -- tail -n 1 "$tmp/silent.out"
expect review-silent-unavailable ok "^guard review: reviewer unavailable: $tmp/fake-reviewer exited 0 with an empty reply\\.$" -- cat "$tmp/silent.out"
expect review-unavailable-not-recorded ok "^$rows_before$" -- bash -c 'wc -l < "$1"' _ "$reviews"
expect review-unavailable-not-queued ok '^Nothing needs you\.$' -- "$guard" needs-you
expect review-dirty-discarded ok 'uncommitted edits, and they are discarded' -- review dirty
expect review-dirty-not-pushed ok "^$old_head	" -- git ls-remote origin refs/heads/feat/add
expect review-strict-verdict fail 'not a VERDICT line' -- review 'approve?'
expect review-fenced-verdict ok '^VERDICT: approve - fenced verdict$' -- review fenced
"$guard" config set reviewer_cmd_proprietary "" >/dev/null
review approve PATH="$tmp/fakebin:$PATH" >/dev/null 2>&1
expect review-default-reviewer ok '^call no-token -p --force --trust Read ' -- cat "$tmp/fake/calls"
mkdir -p "$tmp/fakeclaude"; cat > "$tmp/fakeclaude/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$FAKE_DIR/argv"
exec "$tmp/fake-reviewer" "\$@"
FAKE
chmod +x "$tmp/fakeclaude/claude"; review approve PATH="$tmp/fakeclaude:$PATH" >/dev/null 2>&1
expect review-default-claude-argv ok '^-p\|--permission-mode\|acceptEdits\|--strict-mcp-config\|--setting-sources\|project\|--disable-slash-commands\|--tools=Bash,Read,Edit,Grep,Glob\|--allowedTools=Bash\|Read \.guard-review/prompt\.md and follow it\. End your reply with the VERDICT line it describes\.$' -- \
  paste -sd'|' "$tmp/fake/argv"
mkdir -p "$tmp/badclaude"; cat > "$tmp/badclaude/claude" <<'FAKE'
#!/usr/bin/env bash
echo junk >> calc.py; git commit -qam "claude: half done"; echo stray > stray.txt
echo "Failed to authenticate. API Error: 401" >&2; exit 1
FAKE
chmod +x "$tmp/badclaude/claude"; review approve PATH="$tmp/badclaude:$tmp/fakebin:$PATH" > "$tmp/fallback.out" 2>&1
expect review-fallback-verdict ok '^VERDICT: approve - reason for approve$' -- cat "$tmp/fallback.out"
expect review-fallback-named ok '^guard review: claude failed \(Failed to authenticate\. API Error: 401\); trying cursor-agent$' -- cat "$tmp/fallback.out"
expect review-fallback-recorded ok '	approve	cursor-agent	reason for approve$' -- tail -n 1 "$reviews"
expect review-fallback-one-call ok '^1$' -- grep -c '^call no-token -p --force --trust Read ' "$tmp/fake/calls"
expect review-fallback-reset fail - -- grep -q 'uncommitted edits' "$tmp/fallback.out"
expect review-fallback-not-pushed ok "^$old_head	" -- git ls-remote origin refs/heads/feat/add
expect review-fallback-all-fail fail '^guard review: reviewer unavailable: Error: Authentication required\. cursor-agent exited 3;' -- \
  review crash PATH="$tmp/badclaude:$tmp/fakebin:$PATH"
expect review-fallback-all-fail-not-recorded ok '	approve	cursor-agent	reason for approve$' -- tail -n 1 "$reviews"
review approve PATH="$tmp/fakeclaude:$tmp/fakebin:$PATH" >/dev/null 2>&1
expect review-claude-alone ok '^call no-token -p --permission-mode acceptEdits --strict-mcp-config --setting-sources project --disable-slash-commands --tools=Bash,Read,Edit,Grep,Glob --allowedTools=Bash Read ' -- cat "$tmp/fake/calls"
expect review-claude-alone-once ok '^1$' -- grep -c '^call' "$tmp/fake/calls"
expect review-claude-alone-recorded ok '	approve	claude	reason for approve$' -- tail -n 1 "$reviews"
"$guard" config set reviewer_model 'opus[1m]' >/dev/null
review approve PATH="$tmp/fakeclaude:$PATH" >/dev/null 2>&1
expect review-model-claude ok '\|--allowedTools=Bash\|--model\|opus\[1m\]\|Read \.guard-review/prompt\.md' -- paste -sd'|' "$tmp/fake/argv"
review approve PATH="$tmp/fakebin:$PATH" >/dev/null 2>&1
expect review-model-cursor ok '^call no-token -p --force --trust --model opus\[1m\] Read ' -- cat "$tmp/fake/calls"
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-reviewer" >/dev/null
review approve >/dev/null 2>&1
expect review-model-not-on-configured-command ok '^call no-token Read ' -- cat "$tmp/fake/calls"
"$guard" config set reviewer_model "" >/dev/null
expect review-moved-head fail "origin/feat/add is not at the pull request's head" -- review approve MOCK_GH_PR="$(pr_json '.headRefOid = "0000000"')"
