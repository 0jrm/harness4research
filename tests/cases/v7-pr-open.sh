# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== pr open"
prev=$PWD; po=$tmp/pr-open
git init -q --bare "$po/origin.git"; git clone -q "$po/origin.git" "$po/repo" 2>/dev/null; cd "$po/repo" || exit
git commit -q --allow-empty -m init; git push -q origin HEAD:main; git switch -q -c feat/x; git commit -q --allow-empty -m x
printf 'Make add actually add, plz\nand keep the old name working\n' > "$po/request"; echo "calc.py: + not -" > "$po/plan"
echo "Fixes add." > "$po/body"; echo "Says: Make add actually add, plz" > "$po/leaky"; : > "$po/empty"
pr_open() { MOCK_GH_LOG=$po/gh.log "$guard" pr open --item W0.5 --title "add adds" --request "$po/request" --plan "$po/plan" --test "tests/run.sh" "$@"; }
expect pr-open-usage fail 'usage: guard pr open' -- "$guard" pr open --item W0.5
expect pr-open-no-item ok '^https://github.com/lab/proj/pull/7$' -- env MOCK_GH_LOG="$po/gh-noitem.log" bash -c 'git switch -q -c feat/y && "$1" pr open --title plain --request "$2/request" --plan "$2/plan" --test t --body "$2/body"; rc=$?; git switch -q feat/x; exit $rc' _ "$guard" "$po"
expect pr-open-no-item-title ok '--title plain --body-file' -- grep 'pr create' "$po/gh-noitem.log"
expect pr-open-bad-item fail 'not a plan item id' -- pr_open --body "$po/body" --item 'W 1'
expect pr-open-empty-request fail 'is empty' -- pr_open --body "$po/body" --request "$po/empty"
expect pr-open-leaky-body fail 'repeats a line of the request' -- pr_open --body "$po/leaky"
expect pr-open-no-brief-on-refusal fail - -- test -e "$(git rev-parse --git-common-dir)/guard/briefs/feat-x.md"
expect pr-open-opens ok '^https://github.com/lab/proj/pull/7$' -- pr_open --body "$po/body"
expect pr-open-title ok '^pr create --base main --head feat/x --title \[W0\.5\] add adds --body-file ' -- grep 'pr create' "$po/gh.log"
expect pr-open-pushed ok - -- git -C "$po/origin.git" rev-parse -q --verify refs/heads/feat/x
expect pr-open-brief ok '^Make add actually add, plz$' -- cat "$(git rev-parse --git-common-dir)/guard/briefs/feat-x.md"
expect pr-open-brief-plan ok '^## Plan$' -- cat "$(git rev-parse --git-common-dir)/guard/briefs/feat-x.md"
expect pr-open-brief-test ok '^tests/run.sh$' -- cat "$(git rev-parse --git-common-dir)/guard/briefs/feat-x.md"
expect pr-open-brief-reviewable ok - -- bash -c '. "$1/lib/pr.sh"; [ -z "$(brief_problem feat/x)" ]' _ "$here"
expect pr-open-rerun ok '^https://github.com/lab/pull/9$' -- env MOCK_GH_PRS='[{"number":9,"url":"https://github.com/lab/pull/9"}]' bash -c 'pr_open() { "$1" pr open --item W0.5 --title t --request "$2/request" --plan "$2/plan" --test t --body "$2/body"; }; pr_open "$@"' _ "$guard" "$po"
expect pr-open-on-base fail 'is main itself' -- bash -c 'git switch -q main && "$1" pr open --item W0.5 --title t --request "$2/request" --plan "$2/plan" --test t --body "$2/body"; rc=$?; git switch -q feat/x; exit $rc' _ "$guard" "$po"
expect pr-open-gh-fails fail 'gh cannot open the pull request: no permission' -- env MOCK_GH_CREATE='no permission' bash -c '"$1" pr open --item W0.5 --title t --request "$2/request" --plan "$2/plan" --test t --body "$2/body"' _ "$guard" "$po"
cd "$prev" || exit
