# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture: the branch-name rule (lib/branch_name.sh) and guard pr open's use of it.
echo "== branch names"
named() { bash -c '. "$1/lib/branch_name.sh"; why=$(branch_name_problem "$2"); echo "${why:-ok}"; [ -z "$why" ]' _ "$here" "$1"; }
for name in feat/cram-transfer feat/energy-cram run/emu-rea-blur-budget-r3 fix/merge-local-cleanup release/v7.2 \
  guard/init guard/update exp/e12-cram-ablation run/2026-10-19-sweep run/r1 feat/descriptive-branch-name-rule \
  feature/cram-cards report/emu-rea-forcing card/emu-rea-blur-budget-r2 eval/inspect-index; do
  expect "branch-name-passes-$name" ok '^ok$' -- named "$name"
done
expect branch-name-claude-app fail 'does not start with a known type' -- named claude/wizardly-yonath-8145fe
expect branch-name-random-suffix fail 'hash or random suffix, 8145fe' -- named feat/wizardly-yonath-8145fe
expect branch-name-runhub fail 'does not start with a known type' -- named runhub/103a71f5-3aa6-403d-b99e-6be6ddc97e3b
expect branch-name-uuid-on-run fail 'hash or random suffix, 103a71f5' -- named run/103a71f5-3aa6-403d-b99e-6be6ddc97e3b
expect branch-name-bare-code fail 'does not say what the branch does' -- named feat/v8-u1b
expect branch-name-feature-one-letter fail 'does not say what the branch does' -- named feature/x
expect branch-name-one-word fail 'does not say what the branch does' -- named fix/cleanup
expect branch-name-experiment-code fail 'not lowercase kebab-case' -- named exp/E10
expect branch-name-record-code fail 'not lowercase kebab-case' -- named rec/E7b
expect branch-name-no-type fail 'does not start with a known type' -- named energy-cram
expect branch-name-hex-word-passes ok '^ok$' -- named feat/decade-defaced

prev=$PWD; bn=$tmp/branch-name
git init -q --bare "$bn/origin.git"; git clone -q "$bn/origin.git" "$bn/repo" 2>/dev/null; cd "$bn/repo" || exit
git commit -q --allow-empty -m init; git push -q origin HEAD:main
git switch -q -c claude/wizardly-yonath-8145fe; git commit -q --allow-empty -m x
echo "Rename the branches" > "$bn/request"; echo "plan" > "$bn/plan"; echo "Renames." > "$bn/body"
open_pr() { MOCK_GH_LOG=$bn/gh.log "$guard" pr open --title t --request "$bn/request" --plan "$bn/plan" --test t --body "$bn/body"; }
expect branch-name-pr-open-refuses fail '^guard pr open: branch claude/wizardly-yonath-8145fe: ' -- open_pr
expect branch-name-pr-open-rename fail '^  git branch -m claude/wizardly-yonath-8145fe feat/WHAT-IT-DOES$' -- open_pr
expect branch-name-pr-open-push-new fail '^  git push -u origin feat/WHAT-IT-DOES$' -- open_pr
expect branch-name-pr-open-delete-old fail '^  git push origin --delete claude/wizardly-yonath-8145fe ' -- open_pr
expect branch-name-pr-open-nothing-pushed fail - -- git -C "$bn/origin.git" rev-parse -q --verify refs/heads/claude/wizardly-yonath-8145fe
expect branch-name-pr-open-no-brief fail - -- test -e "$bn/repo/.git/guard/briefs/claude-wizardly-yonath-8145fe.md"
expect branch-name-pr-open-no-gh fail - -- grep -q 'pr create' "$bn/gh.log"
git switch -q -c fix/v8-u1b
open_existing() { MOCK_GH_PRS='[{"number":9,"url":"https://github.com/lab/pull/9"}]' open_pr; }
expect branch-name-pr-open-keeps-type fail '^  git branch -m fix/v8-u1b fix/WHAT-IT-DOES$' -- open_pr
expect branch-name-pr-open-existing-pr ok '^https://github.com/lab/pull/9$' -- open_existing
git branch -q -m fix/v8-u1b fix/merge-local-cleanup
expect branch-name-pr-open-after-rename ok '^https://github.com/lab/proj/pull/7$' -- open_pr
cd "$prev" || exit
