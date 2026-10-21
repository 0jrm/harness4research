# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== tiers"
TR=$tmp/tiers; git init -q -b main "$TR"; mkdir -p "$TR/guard" "$TR/runs/r9" "$TR/runs/_template" "$TR/src"
echo cap > "$TR/guard/budget.card"; echo q > "$TR/runs/r9/question.card"; echo n > "$TR/runs/r9/notes.txt"
echo t > "$TR/runs/_template/report.md"; echo x > "$TR/src/a.py"; seq 150 > "$TR/src/big.py"
git -C "$TR" add -A; git -C "$TR" commit -q -m init
tier_of() {  # tier_of <shell command> [config line]: pr_tier of a commit on main that makes the command's changes
  printf '%s\n' "${2:-}" > "$tmp/tier-config"
  git -C "$TR" checkout -q -f -B case main
  (cd "$TR" && eval "$1" && git add -A && git commit -q --allow-empty -m case \
    && GUARD_CONFIG=$tmp/tier-config bash -c '. "$1/lib/config.sh"; . "$1/lib/pr.sh"; pr_tier main HEAD' _ "$here")
}
expect tier-records ok '^records$' -- tier_of 'mkdir -p runs/r1/out; echo 1 > runs/r1/out/a.csv; echo row > runs/r1/execution.tsv'
expect tier-records-deletion ok '^records$' -- tier_of 'git rm -q runs/r9/notes.txt'
expect tier-template-not-records ok '^small$' -- tier_of 'echo more >> runs/_template/report.md'
expect tier-template-card-not-human ok '^small$' -- tier_of 'echo q > runs/_template/question.card'
expect tier-report-not-records ok '^small$' -- tier_of 'mkdir -p runs/r1; echo "## Result" > runs/r1/report.md; echo 1 > runs/r1/a.csv'
expect tier-incident-not-records ok '^small$' -- tier_of 'mkdir -p runs/r1/incidents; echo "job: 100" > runs/r1/incidents/1.md'
expect tier-card-added ok '^human$' -- tier_of 'mkdir -p runs/r2; echo q > runs/r2/question.card'
expect tier-card-modified ok '^small$' -- tier_of 'echo edit >> runs/r9/question.card'
expect tier-guard ok '^human$' -- tier_of 'echo more >> guard/budget.card'
expect tier-workflow ok '^human$' -- tier_of 'mkdir -p .github/workflows; echo "on: push" > .github/workflows/ci.yml'
expect tier-rules-text ok '^human$' -- tier_of 'echo rule >> AGENTS.md'
expect tier-nested-agents-md ok '^small$' -- tier_of 'mkdir -p src; echo rule >> src/AGENTS.md'
expect tier-guard-beats-records ok '^human$' -- tier_of 'mkdir -p runs/r1; echo 1 > runs/r1/a.csv; echo more >> guard/budget.card'
expect tier-code-and-records ok '^small$' -- tier_of 'mkdir -p runs/r1; echo 1 > runs/r1/a.csv; echo y >> src/a.py'
expect tier-empty ok '^small$' -- tier_of ':'
expect tier-small-at-limit ok '^small$' -- tier_of 'seq 200 > src/b.py'
expect tier-large-over-limit ok '^large$' -- tier_of 'seq 201 > src/b.py'
expect tier-deletions-count ok '^large$' -- tier_of 'git rm -q src/big.py; seq 51 > src/c.py'
expect tier-limit-from-config ok '^large$' -- tier_of 'seq 6 > src/b.py' 'review_small_lines: 5'
