# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== quickstart"
expect quickstart-walkthrough ok 'PREFLIGHT FAIL: guard/ differs from origin/main.*PREFLIGHT OK: cheap-evo.*PASS	evidence-paths.*PASS	check:finite.sh.*Look at:' -- bash -c '"$1/examples/quickstart/run.sh" "$2" 2>&1 | tr "\n" " "' _ "$here" "$tmp/quickstart"
expect quickstart-rerun-replaces-its-own ok 'Look at:' -- "$here/examples/quickstart/run.sh" "$tmp/quickstart"
expect quickstart-refuses-foreign-dir fail 'did not create it' -- "$here/examples/quickstart/run.sh" "$tmp/agents"
