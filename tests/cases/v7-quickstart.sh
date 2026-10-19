# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture: the quickstart walkthrough, with guard run in local mode (U2).
echo "== quickstart"
expect quickstart-walkthrough ok 'H4R-R06 guard/budget.card differ from main.*job 1000 submitted for run cheap-evo: 5 min x 1 node\(s\) x 128 cores = 10.67 core-h.*PASS	evidence-paths.*written_by: guard run, local, unsigned.*Look at:' -- bash -c '"$1/examples/quickstart/run.sh" "$2" 2>&1 | tr "\n" " "' _ "$here" "$tmp/quickstart"
expect quickstart-rerun-replaces-its-own ok 'Look at:' -- "$here/examples/quickstart/run.sh" "$tmp/quickstart"
expect quickstart-refuses-foreign-dir fail 'did not create it' -- "$here/examples/quickstart/run.sh" "$tmp/agents"
