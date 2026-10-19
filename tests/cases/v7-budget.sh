# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== budget"
expect budget-within ok '^budget: [0-9]+ files within their budgets$' -- "$here/tests/budget.sh"
fx_budget=$(mktemp -d); mkdir -p "$fx_budget/tests" "$fx_budget/docs"; cp "$here/tests/budget.sh" "$fx_budget/tests/"
printf 'a.md 3\nmissing.md 9\n' > "$fx_budget/docs/BUDGET"; echo 'one two three four' > "$fx_budget/a.md"
expect budget-over fail '^budget: a.md has 4 words, over 3$' -- "$fx_budget/tests/budget.sh"
expect budget-no-match fail '^budget: missing.md matches no file$' -- "$fx_budget/tests/budget.sh"
rm -rf "$fx_budget"
