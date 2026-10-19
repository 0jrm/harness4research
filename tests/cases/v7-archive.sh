# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== archive"
expect archive-tags ok 'Tagged 1 merged' -- "$guard" archive "$tmp/proj"
expect archive-tag-exists ok 'archive/' -- git -C "$tmp/proj" tag -l 'archive/*/stale'
expect archive-no-push ok '^$' -- git ls-remote --tags "$tmp/origin.git"
