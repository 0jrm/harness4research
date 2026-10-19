# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== needs-you"
in_dir() { local d=$1; shift; (cd "$d" && "$@"); }
ny=$tmp/ny; git init -q -b main "$ny"; git -C "$ny" commit -q --allow-empty -m init
expect ny-empty ok '^Nothing needs you\.$' -- in_dir "$ny" "$guard" needs-you
expect ny-remind-empty ok - -- bash -c 'out=$(cd "$1" && "$2" needs-you --remind 2>&1) && [ -z "$out" ]' _ "$ny" "$guard"
expect ny-add ok '^n1$' -- in_dir "$ny" "$guard" needs-you add --kind run --title 'Merge PR #41 (autonomous merge refused)' \
  --why 'the gh login in this shell administers the repository.' --run "cd $ny" --run 'gh pr merge 41 --squash' \
  --expect '"Squashed and merged pull request #41".' --worry 'Pull request is not mergeable.' \
  --undo 'git revert <merge commit> on a new branch.' --path "$here/README.md" --source claude
expect ny-add-next ok '^n2$' -- in_dir "$ny" "$guard" needs-you add --kind check --title 'Read the report' --path "$here/README.md" --path "$here/bin/guard"
expect ny-tsv-header ok '^id	ts	state	kind	title	action	paths	commands	source$' -- head -1 "$ny/.git/guard/needs-you.tsv"
expect ny-show ok - -- bash -c 'diff <(cd "$1" && "$2" needs-you show n1) - <<BLOCK
🩺 n1 · run · Merge PR #41 (autonomous merge refused)

Why: the gh login in this shell administers the repository.

\`\`\`bash
cd $1
gh pr merge 41 --squash
\`\`\`

Expected: "Squashed and merged pull request #41".
Worrisome: Pull request is not mergeable.
Undo: git revert <merge commit> on a new branch.
Files: $3/README.md

Close it once it is done:
\`\`\`bash
cd $1 && guard needs-you done n1
\`\`\`

🩺
BLOCK' _ "$ny" "$guard" "$here"
expect ny-show-omits-empty ok - -- bash -c 'diff <(cd "$1" && "$2" needs-you show n2) - <<BLOCK
🩺 n2 · check · Read the report

Files:
  $3/README.md
  $3/bin/guard

Close it once it is done:
\`\`\`bash
cd $1 && guard needs-you done n2
\`\`\`

🩺
BLOCK' _ "$ny" "$guard" "$here"
expect ny-list ok '^🩺 n1 · run · Merge PR #41 \(autonomous merge refused\) 🩺 n2 · check · Read the report $' -- bash -c '(cd "$1" && "$2" needs-you) | grep "^🩺 n" | tr "\n" " "' _ "$ny" "$guard"
expect ny-show-unknown fail 'no item n9' -- in_dir "$ny" "$guard" needs-you show n9
rows=$(wc -l < "$ny/.git/guard/needs-you.tsv")
expect ny-refuse-relative fail 'README.md is a relative path' -- in_dir "$here" "$guard" needs-you add --kind check --title t --path README.md
expect ny-refuse-missing fail "$here/nope does not exist" -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$here/nope"
mkdir -p "$tmp/ny-files/scratchpad"; touch "$tmp/ny-files/f" "$tmp/ny-files/scratchpad/f"
expect ny-refuse-tmp fail 'which gets cleaned\. Copy the file to a stable place first' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$tmp/ny-files/f"
expect ny-refuse-literal-tmp fail '^guard needs-you: /tmp/\. is under /tmp' -- env TMPDIR= bash -c 'cd "$1" && "$2" needs-you add --kind check --title t --path /tmp/.' _ "$ny" "$guard"
expect ny-refuse-var-tmp fail 'is under /var/tmp' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path /var/tmp
expect ny-refuse-tmpdir fail "is under $here/tests, which gets cleaned" -- env TMPDIR="$here/tests" bash -c 'cd "$1" && "$2" needs-you add --kind check --title t --path "$3/tests/run.sh"' _ "$ny" "$guard" "$here"
expect ny-refuse-scratchpad fail 'is in a scratchpad directory' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$tmp/ny-files/scratchpad/f"
expect ny-refuse-tab fail 'holds a tab or a newline' -- in_dir "$ny" "$guard" needs-you add --kind check --title "$(printf 'a\tb')"
expect ny-refuse-newline fail 'holds a tab or a newline' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --why "$(printf 'a\nb')"
expect ny-refuse-separator fail "holds ';;'" -- in_dir "$ny" "$guard" needs-you add --kind run --title t --run 'case x in x) ;; esac'
expect ny-refuse-run-without-command fail 'needs at least one --run' -- in_dir "$ny" "$guard" needs-you add --kind run --title t
expect ny-refuse-empty-run fail '^guard needs-you: --run is empty$' -- in_dir "$ny" "$guard" needs-you add --kind run --title t --run ''
expect ny-refusals-write-nothing ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$ny/.git/guard/needs-you.tsv"
expect ny-remind-text ok '^🩺 2 items in .* need you:$' -- in_dir "$ny" "$guard" needs-you --remind
expect ny-ack ok '^n1 acked$' -- in_dir "$ny" "$guard" needs-you ack n1 --note seen
expect ny-ack-again ok '^n1 is already acked$' -- in_dir "$ny" "$guard" needs-you ack n1
expect ny-remind-skips-acked ok - -- bash -c 'out=$(cd "$1" && "$2" needs-you --remind); grep -q "n2 · check" <<<"$out" && ! grep -q n1 <<<"$out"' _ "$ny" "$guard"
expect ny-list-keeps-acked ok '^🩺 n1 · run' -- in_dir "$ny" "$guard" needs-you
expect ny-done ok '^n1 done$' -- in_dir "$ny" "$guard" needs-you "done" n1
expect ny-list-drops-done ok - -- bash -c '! (cd "$1" && "$2" needs-you) | grep -q "n1 ·"' _ "$ny" "$guard"
expect ny-ack-after-done fail 'n1 is done, so it cannot become acked' -- in_dir "$ny" "$guard" needs-you ack n1
expect ny-last-row-wins ok '^n1	[^	]*	done	run	Merge PR #41 .*note: seen' -- tail -1 "$ny/.git/guard/needs-you.tsv"
expect ny-hook-json ok '^UserPromptSubmit$' -- bash -c 'cd / && printf "{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"%s\"}" "$1" | "$2" needs-you --remind --format claude-hook | python3 -c "import json, sys
d = json.load(sys.stdin); h = d[\"hookSpecificOutput\"]
assert \"n2 · check · Read the report\" in d[\"systemMessage\"] and \"🩺 n2 · check · Read the report\" in h[\"additionalContext\"]
assert \"🩺 n1\" not in h[\"additionalContext\"]
print(h[\"hookEventName\"])"' _ "$ny" "$guard"
expect ny-hook-session-start ok '"hookEventName": "SessionStart"' -- bash -c 'cd "$1" && echo "{\"hook_event_name\": \"SessionStart\"}" | "$2" needs-you --remind --format claude-hook' _ "$ny" "$guard"
mkdir -p "$tmp/ny-norepo"
expect ny-remind-outside-repo ok - -- bash -c 'export GIT_CEILING_DIRECTORIES=$1; out=$(cd "$1/ny-norepo" && "$2" needs-you --remind 2>&1 && echo "{}" | "$2" needs-you --remind --format claude-hook 2>&1) && [ -z "$out" ]' _ "$tmp" "$guard"
expect ny-remind-closed-stdin ok '^\{"systemMessage": "[^"]*n2 \\u00b7 check' -- bash -c 'cd "$1" && "$2" needs-you --remind --format claude-hook <&-' _ "$ny" "$guard"
expect ny-remind-bad-cwd ok - -- bash -c 'out=$(echo "{\"cwd\": 5, \"hook_event_name\": \"UserPromptSubmit\"}" | "$2" needs-you --remind --format claude-hook 2>&1) && [ -z "$out" ]' _ "$ny" "$guard"
expect ny-remind-ascii-stdout ok '"systemMessage": "\\ud83e\\ude7a ' -- bash -c 'cd "$1" && echo "{\"hook_event_name\": \"SessionStart\"}" | PYTHONIOENCODING=ascii "$2" needs-you --remind --format claude-hook' _ "$ny" "$guard"
expect ny-list-outside-repo fail 'is not a git repository' -- env GIT_CEILING_DIRECTORIES="$tmp" bash -c 'cd "$1" && "$2" needs-you' _ "$tmp/ny-norepo" "$guard"
git -C "$ny" worktree add -q "$tmp/ny-wt" -b other 2>/dev/null
expect ny-worktree-add ok '^n3$' -- in_dir "$tmp/ny-wt" "$guard" needs-you add --kind approve --title 'Approve the question card' --path "$here/README.md"
expect ny-worktree-shared ok '^🩺 n3 · approve · Approve the question card$' -- in_dir "$ny" "$guard" needs-you show n3
expect ny-worktree-sees-main ok '^🩺 n2 · check' -- in_dir "$tmp/ny-wt" "$guard" needs-you
for i in $(seq 8); do (cd "$ny" && "$guard" needs-you add --kind check --title "race $i" > /dev/null) & done; wait
expect ny-concurrent-ids-unique ok '^n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11 $' -- bash -c 'awk -F "\t" "\$3 == \"open\" {print \$1}" "$1" | sort -V | tr "\n" " "' _ "$ny/.git/guard/needs-you.tsv"

rows=$(wc -l < "$ny/.git/guard/needs-you.tsv")
expect ny-add-same-open-item ok '^n2$' -- in_dir "$ny" "$guard" needs-you add --kind check --title 'Read the report' --path "$here/README.md"
expect ny-add-same-writes-nothing ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$ny/.git/guard/needs-you.tsv"
expect ny-add-same-title-other-kind ok '^n12$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title 'Read the report'
expect ny-add-same-as-closed ok '^n13$' -- in_dir "$ny" "$guard" needs-you add --kind run --title 'Merge PR #41 (autonomous merge refused)' --run 'gh pr merge 41 --squash'
expect ny-update-new ok '^n14$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title Digest --why 'one card' --run 'gh pr merge 1 --squash' --update
rows=$(wc -l < "$ny/.git/guard/needs-you.tsv")
expect ny-update-same-content ok '^n14$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title Digest --why 'one card' --run 'gh pr merge 1 --squash' --update
expect ny-update-same-writes-nothing ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$ny/.git/guard/needs-you.tsv"
expect ny-update-refreshes ok '^n14$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title Digest --why 'two cards' --run 'gh pr merge 1 --squash' --run 'gh pr merge 2 --squash' --update
expect ny-update-content ok '^Why: two cards$' -- in_dir "$ny" "$guard" needs-you show n14
expect ny-update-commands ok '^gh pr merge 2 --squash$' -- in_dir "$ny" "$guard" needs-you show n14
expect ny-update-one-open ok '^1$' -- bash -c '(cd "$1" && "$2" needs-you) | grep -c "· Digest$"' _ "$ny" "$guard"
expect ny-without-update-keeps ok '^n14$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title Digest --why 'three cards'
expect ny-without-update-unchanged ok '^Why: two cards$' -- in_dir "$ny" "$guard" needs-you show n14
in_dir "$ny" "$guard" needs-you ack n14 >/dev/null
expect ny-update-acked-same-stays-acked ok '^n14	[^	]*	acked	' -- bash -c 'cd "$1" && "$2" needs-you add --kind approve --title Digest --why "two cards" --run "gh pr merge 1 --squash" --run "gh pr merge 2 --squash" --update >/dev/null && tail -1 .git/guard/needs-you.tsv' _ "$ny" "$guard"
expect ny-update-acked-new-reopens ok '^n14	[^	]*	open	approve	Digest	why: three cards' -- bash -c 'cd "$1" && "$2" needs-you add --kind approve --title Digest --why "three cards" --update >/dev/null && tail -1 .git/guard/needs-you.tsv' _ "$ny" "$guard"
expect ny-find ok '^n14$' -- in_dir "$ny" "$guard" needs-you find --kind approve --title Digest
expect ny-find-other-kind fail '^$' -- in_dir "$ny" "$guard" needs-you find --kind check --title Digest
in_dir "$ny" "$guard" needs-you "done" n14 >/dev/null
expect ny-find-skips-done fail '^$' -- in_dir "$ny" "$guard" needs-you find --kind approve --title Digest
expect ny-update-after-done-new ok '^n15$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title Digest --why 'four cards' --update
