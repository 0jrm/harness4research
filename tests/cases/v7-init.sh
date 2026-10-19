# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== init"
# The pin guard init writes: the harness's release tag when HEAD is one, else its commit. guard/run reads the harness at
# the pin from git, so these tests run the committed lib/guard/, never uncommitted edits.
pin=$(git -C "$here" describe --exact-match --tags --match 'v[0-9]*' HEAD 2>/dev/null || git -C "$here" rev-parse HEAD)
art=guard/harness-$pin.sh
git -C "$here" diff --quiet HEAD -- lib/guard || echo "note: lib/guard/ has uncommitted edits, and guard/run runs the copy at HEAD"
# set_script <command> <text>: puts <text> in place of lib/guard/<command>.sh in the working tree's vendored harness.
set_script() {
  TEXT=$2 awk -v m="#== lib/guard/$1.sh" '$0 == m { print; print ENVIRON["TEXT"]; skip = 1; next } skip && /^#== / { skip = 0 } !skip' "$art" > "$art.new" \
    && mv "$art.new" "$art"
}
expect init-proposes ok 'guard/budget.card' -- bash -c 'set -o pipefail; "$1" init "$2" --worktree "$3" --offline | tee "$4"' _ \
  "$guard" "$tmp/proj" "$tmp/wt" "$tmp/init.out"
expect init-no-bin ok - -- test ! -e "$tmp/wt/guard/bin"
expect init-no-card-template ok - -- test ! -e "$tmp/wt/runs/_template/question.card"
expect init-agents-four-verbs ok - -- cmp "$here/templates/AGENTS.md" "$tmp/wt/AGENTS.md"
bk=${XDG_STATE_HOME:-$HOME/.local/state}/guard/key.pub
if [ -s "$bk" ]; then bk_want="^broker_key: $(head -n1 "$bk" | sed 's/[][\\.*^$+?(){}|/]/\\&/g')$"; else bk_want='^broker_key: <'; fi
expect init-broker-key ok "$bk_want" -- grep '^broker_key:' "$tmp/wt/guard/budget.card"
expect init-version-schema ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$tmp/wt/guard/VERSION"
expect init-pins-harness ok "^harness: $pin$" -- sed -n 1p "$tmp/wt/guard/budget.card"
expect init-offline-artifact ok "^# harness: $pin, commit $(git -C "$here" rev-parse HEAD)\." -- sed -n 2p "$tmp/wt/$art"
expect init-artifact-every-script ok "^$(git -C "$here" ls-tree --name-only HEAD lib/guard/ | grep -c '\.sh$')$" -- grep -c '^#== lib/guard/[a-z-]*\.sh$' "$tmp/wt/$art"
expect init-artifact-inert fail 'guard/run reads its scripts from this file' -- bash "$tmp/wt/$art"
expect init-says-offline ok "^Mode: offline\. --offline was given, so guard/run reads the scripts from $art on the protected branch\.$" -- \
  cat "$tmp/init.out"
expect init-leaves-checkout ok '^main$' -- git -C "$tmp/proj" branch --show-current
expect init-committed ok 'feat\(guard\)' -- git -C "$tmp/wt" log -1 --format=%s
expect init-survey-file ok 'Survey of proj' -- cat "$tmp/wt/guard/SURVEY.md"
expect init-no-overwrite fail - -- "$guard" init "$tmp/proj" --worktree "$tmp/wt2"
expect workflow-yaml ok - -- python3 -c "import yaml,sys; yaml.safe_load(open('$tmp/wt/.github/workflows/guard-fence.yml'))"
git init -q --bare -b main "$tmp/agents-origin.git"
git clone -q "$tmp/agents-origin.git" "$tmp/agents" 2>/dev/null
echo "# Our rules" > "$tmp/agents/AGENTS.md"
git -C "$tmp/agents" add -A; git -C "$tmp/agents" commit -q -m init
git -C "$tmp/agents" push -q -u origin HEAD:main; git -C "$tmp/agents" remote set-head origin -a >/dev/null
expect init-agents-proposal ok '^     Merge .*/guard/AGENTS.proposed.md into your AGENTS.md, or delete it\.$' -- "$guard" init "$tmp/agents" --worktree "$tmp/agents-wt" --offline
