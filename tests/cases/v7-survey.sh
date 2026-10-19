# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== survey"
expect survey-stale-branch ok 'origin/stale' -- "$guard" survey "$tmp/proj"
expect survey-missing-path ok 'names `src/old.py`' -- "$guard" survey "$tmp/proj"
expect survey-undecided ok 'Pick one' -- "$guard" survey "$tmp/proj"
expect survey-hack ok 'src/new.py:1' -- "$guard" survey "$tmp/proj"
expect survey-nested ok 'nested git repository `./nested-copy`' -- "$guard" survey "$tmp/proj"
expect survey-prompt-commit ok 'You are working' -- "$guard" survey "$tmp/proj"
expect survey-read-only ok '^$' -- git -C "$tmp/proj" status --porcelain --untracked-files=no
expect survey-header ok 'from the working tree of `.*/proj`; branches compared against `origin/main`' -- "$guard" survey "$tmp/proj"
echo "uncommitted line" >> README.md
expect survey-dirty-warning ok '^warning: working tree has 2 uncommitted changes; document findings reflect it$' -- \
  bash -c '"$1" survey "$2" | sed -n 3p' _ "$guard" "$tmp/proj"
git checkout -q -- README.md
rm -rf "$tmp/proj/nested-copy"
