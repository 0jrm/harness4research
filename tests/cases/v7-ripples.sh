# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== ripples"
mkdir -p "$R/checks"; printf '#!/bin/bash\necho "nan count 3"; exit 1\n' > "$R/checks/nan.sh"; chmod +x "$R/checks/nan.sh"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|13000|240\n102|2026-09-29-demo|FAILED|10|240\n103|other|FAILED|1|1\n' > "$tmp/rows"
export MOCK_SACCT_ROWS=$tmp/rows
expect ripples-states fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED \(the work needs more than max_walltime_minutes in one job: split it into jobs that each fit and resume from the last checkpoint, or ask a human to raise the limit; then merge runs/2026-09-29-demo/incidents/<n>.md with a job: <id> line and the root cause for each, since ripples reads incidents from origin/main; a resource stop of a launch continues with an execution.tsv restart or resume row instead\)$' -- guard/run ripples "$R"
expect ripples-walltime fail 'RIPPLE.walltime-headroom.100:100% 101:90% \(the work needs more than max_walltime_minutes in one job: split it' -- guard/run ripples "$R"
expect ripples-check fail 'RIPPLE.check:nan.sh.nan count 3' -- guard/run ripples "$R"
printf '#!/bin/bash\necho "no metrics.csv yet"; exit 77\n' > "$R/checks/later.sh"; chmod +x "$R/checks/later.sh"
expect ripples-check-not-yet fail '^UNCHECKED	check:later.sh	no metrics.csv yet; it exits 77 until its input exists$' -- guard/run ripples "$R"
rm "$R/checks/later.sh"
expect ripples-watched fail 'RIPPLE.watched-paths.*a human merges changes to watched paths, so submit nothing until they reach ' -- guard/run ripples "$R"
expect ripples-quota fail 'PASS.quota.42%' -- guard/run ripples "$R"
expect ripples-other-run-ignored fail 'retries.2 not' -- guard/run ripples "$R"
expect ripples-piped-tsv ok - -- bash -c 'out=$(guard/run ripples "$1" | cat); [ -n "$out" ] && ! grep -vE "^(PASS|RIPPLE|HANDLED|UNCHECKED)	[^	]+	[^	]*$" <<<"$out"' _ "$R"
expect ripples-no-user fail 'PASS	budget' -- env -u USER guard/run ripples "$R"
expect ripples-tty-exit ok - -- bash -c "$(declare -f on_tty)"'; on_tty guard/run ripples "$1" >/dev/null; [ $? -eq 1 ]' _ "$R"
expect ripples-tty-opt-out fail '^RIPPLE	job-states	100:TIMEOUT 102:FAILED \(' -- on_tty env HPC_RIPPLES_TSV=1 guard/run ripples "$R"
expect ripples-term-dumb ok - -- bash -c 'out=$1; [ -n "$out" ] && [ -z "$(tr -dc "\033\t" <<<"$out")" ]' _ "$(on_tty env TERM=dumb guard/run ripples "$R")"
tty=$(on_tty guard/run ripples "$R")
expect ripples-tty-ripple ok $'^\e\\[1;31mRIPPLE   \e\\[0m  job-states {17}100:TIMEOUT 102:FAILED \\(the work needs more than max_walltime_minutes' -- echo "$tty"
expect ripples-tty-pass ok $'^\e\\[32mPASS     \e\\[0m  quota {22}42%$' -- echo "$tty"
expect ripples-tty-no-tabs ok - -- test -z "$(tr -dc '\t' <<<"$tty")"
tty=$(on_tty env NO_COLOR=1 guard/run ripples "$R")
expect ripples-no-color ok '^RIPPLE {5}job-states {17}100:TIMEOUT' -- echo "$tty"
expect ripples-no-color-plain ok - -- test -z "$(tr -dc '\033' <<<"$tty")"
expect ripples-tty-aligned ok - -- test -z "$(awk 'substr($0, 10, 2) != "  " || substr($0, 37, 2) != "  "' <<<"$tty")"
printf '101|2026-09-29-demo|COMPLETED|100|240\n' > "$tmp/rows"; rm -rf "$R/checks"
expect ripples-clean ok 'PASS.budget.30 of 10000' -- guard/run ripples "$R"
expect ripples-no-sacct ok 'UNCHECKED.job-states.*UNCHECKED.walltime-headroom.*UNCHECKED.retries.*UNCHECKED.budget.*PASS.quota.42%' -- \
  env PATH="$(path_without sacct)" bash -c 'set -o pipefail; guard/run ripples "$1" 2>&1 | tr "\n" " "' _ "$R"
expect ripples-unchecked-remedy ok '^UNCHECKED	budget	sacct not found on PATH on this host; run ripples on the cluster login node to check$' -- env PATH="$(path_without sacct)" guard/run ripples "$R"
expect ripples-domain-remedy ok '^UNCHECKED	domain-checks	no executable runs/2026-09-29-demo/checks/\*; add scripts there that exit non-zero when a result looks wrong, with the question card or in a pull request that changes only that directory, which a person merges before the first full submission$' -- guard/run ripples "$R"
expect ripples-tty-unchecked ok '^UNCHECKED  budget {21}sacct not found on PATH on this host; run ripples' -- on_tty env NO_COLOR=1 PATH="$(path_without sacct)" guard/run ripples "$R"
# Off the cluster sacct can exist yet list nothing and exit 0, and the quota path can be missing: no verdict, so no PASS.
R4=runs/2026-10-05-no-jobs; mkdir -p "$R4"; cp runs/_template/question.card "$R4/question.card"; git add -A; git commit -q -m "run: a run with no jobs"
nopass='^PASS	(job-states|walltime-headroom|retries|handled-failures|budget|quota)	'
expect ripples-no-jobs-yet ok '^UNCHECKED	job-states	no jobs yet: sacct lists 1 job\(s\) on account gom since 2026-09-01 from this host, none named 2026-10-05-no-jobs, so there is nothing to judge$' -- guard/run ripples "$R4"
expect ripples-no-jobs-yet-no-pass ok - -- bash -c 'out=$(guard/run ripples "$1"); [ "$(grep -cE "^UNCHECKED	(job-states|walltime-headroom|retries|handled-failures)	no jobs yet: " <<<"$out")" = 4 ]' _ "$R4"
expect ripples-no-account-rows ok '^UNCHECKED	job-states	sacct lists no job at all on account gom since 2026-09-01 from this host, so it may not see this cluster; if the run has submitted jobs, run ripples on the cluster login node$' -- \
  env MOCK_SACCT_ROWS=/dev/null guard/run ripples "$R4"
expect ripples-no-account-rows-no-pass ok - -- bash -c 'out=$(MOCK_SACCT_ROWS=/dev/null guard/run ripples "$1"); [ "$(grep -cE "^UNCHECKED	(job-states|walltime-headroom|retries|handled-failures)	sacct lists no job at all" <<<"$out")" = 4 ]' _ "$R4"
expect ripples-no-account-jobs ok '^UNCHECKED	budget	sacct lists no job on account gom since 2026-09-01 from this host, so spend is unknown here; run ripples on the cluster login node to check$' -- env MOCK_SACCT_CPUSECONDS= guard/run ripples "$R4"
expect ripples-sacct-db-down ok 'UNCHECKED	job-states	sacct cannot reach the Slurm accounting database \(sacct: error: Problem talking to the database: Connection refused\); it is down or unreachable for the cluster, not only this host, so run ripples again later .*UNCHECKED	budget	sacct cannot reach the Slurm accounting database' -- \
  env MOCK_SACCT_EXIT=1 bash -c 'guard/run ripples "$1" 2>/dev/null | tr "\n" " "' _ "$R"
expect ripples-sacct-db-down-no-login-advice ok - -- bash -c '! MOCK_SACCT_EXIT=1 guard/run ripples "$1" 2>&1 | grep "cluster login node"' _ "$R"
expect ripples-sacct-fails ok 'UNCHECKED	job-states	sacct failed on this host \(sacct: error: Invalid user id: 1000\); run ripples on the cluster login node to check .*UNCHECKED	budget	sacct failed on this host \(sacct: error: Invalid user id' -- \
  env MOCK_SACCT_EXIT=1 MOCK_SACCT_ERR='sacct: error: Invalid user id: 1000' bash -c 'guard/run ripples "$1" 2>/dev/null | tr "\n" " "' _ "$R"
sed -i "s|^quota_pct_cmd: .*|quota_pct_cmd: df --output=pcent $tmp/no-such-mount \| tail -1 \| tr -dc 0-9|" guard/budget.card; git commit -q -am "quota on a path this host lacks"
expect ripples-quota-path-missing ok "^UNCHECKED	quota	quota_pct_cmd printed no number on this host \(df: .*No such file or directory\); run ripples where its path exists, or a human fixes quota_pct_cmd in guard/budget.card$" -- env HPC_GUARD_REF=HEAD guard/run ripples "$R"
expect ripples-off-cluster-no-pass ok - -- bash -c 'out=$(HPC_GUARD_REF=HEAD MOCK_SACCT_CPUSECONDS= MOCK_SACCT_ROWS=/dev/null guard/run ripples "$1") && ! grep -E "$2" <<<"$out" && [ "$(grep -c ^UNCHECKED <<<"$out")" -ge 6 ]' _ "$R4" "$nopass"
git reset -q --hard HEAD~2
pre=$(git rev-parse HEAD); mkdir -p "$R/incidents"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|100|240\n102|2026-09-29-demo|FAILED|10|240\n' > "$tmp/rows"
printf '# Incident 0\njob: 10\n' > "$R/incidents/0.md"; git add -A; git commit -q -m "run: incident 0"
expect ripples-incident-exact-id fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
printf '# Incident 1\njob: 100\n' > "$R/incidents/1.md"; printf '# Incident 2\njob: 102\n' > "$R/incidents/2.md"
expect ripples-incident-uncommitted fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
git add -A; git commit -q -m "run: incidents 1 and 2"
expect ripples-incident-unmerged fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
expect ripples-handled-states ok 'HANDLED.job-states.100:TIMEOUT->incidents/1.md 102:FAILED->incidents/2.md' -- merged guard/run ripples "$R"
expect ripples-handled-walltime ok 'HANDLED.walltime-headroom.100:100%->incidents/1.md' -- merged guard/run ripples "$R"
expect ripples-handled-retries ok 'PASS.retries.0 not completed' -- merged guard/run ripples "$R"
expect ripples-handled-count ok 'PASS.handled-failures.2 of 2' -- merged guard/run ripples "$R"
echo '103|2026-09-29-demo|FAILED|10|240' >> "$tmp/rows"; printf '# Incident 3\njob: 103\n' > "$R/incidents/3.md"
git add -A; git commit -q -m "run: incident 3"
expect ripples-handled-cap fail 'RIPPLE.handled-failures.3 handled, over max_handled_failures=2' -- merged guard/run ripples "$R"
git reset -q --hard "$pre"
unset MOCK_SACCT_ROWS
git switch -q -c marker; set_script launch "$(printf '#!/usr/bin/env bash\necho ran >> %s' "$tmp/marker")"; git commit -q -am "launch that leaves a marker"
expect ripples-slurm-skips-launch fail - -- bash -c 'env HPC_GUARD_REF=HEAD guard/run ripples "$1" >/dev/null; test -e "$2"' _ "$R" "$tmp/marker"
git switch -q agent/run; git branch -q -D marker
