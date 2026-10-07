#!/usr/bin/env bash
# usage: tests/run.sh
# End-to-end checks against throwaway git repos and a fake Slurm. Exit 1 on the first unexpected result.
set -uo pipefail
# Launch finds a job's processes host-wide by HPC_JOB_ID, and these tests reuse fixed job ids, so two suites on one
# host would measure and kill each other's jobs. Where the host allows it, the suite runs as PID 1 of a private PID
# namespace, and every process it leaves dies with it. unshare ignores INT and TERM, so this outer copy forwards them.
ns=(unshare --user --map-current-user --pid --fork --mount-proc)
if [ -z "${HPC_TESTS_IN_NS:-}" ] && "${ns[@]}" true 2>/dev/null; then
  set -m; HPC_TESTS_IN_NS=1 "${ns[@]}" "$0" "$@" & u=$!; set +m
  for sig in INT TERM HUP; do trap 'kill -'$sig' $(pgrep -P '$u') 2>/dev/null' $sig; done
  while :; do wait $u; rc=$?; kill -0 $u 2>/dev/null || exit $rc; done
fi
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard=$here/bin/guard
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export PATH="$here/tests/mock-bin:$PATH" XDG_CONFIG_HOME=$tmp/xdg USER=tester GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0
expect() {  # expect <name> <want: ok|fail> <grep pattern or -> -- command...
  local name=$1 want=$2 pat=$3; shift 4
  local out rc; out=$("$@" 2>&1); rc=$?
  local got=ok; [ $rc -ne 0 ] && got=fail
  if [ "$got" = "$want" ] && { [ "$pat" = - ] || grep -q -E -- "$pat" <<<"$out"; }; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (exit $rc, wanted $want, pattern '$pat')"; sed 's/^/     /' <<<"$out" | tail -8; fi
}
path_without() {  # path_without <cmd>: prints a PATH like this one on which <cmd> is not found
  local cmd=$1 shadow=$tmp/no-$1 out="" d f IFS=:
  mkdir -p "$shadow"
  for d in $PATH; do
    if [ -e "$d/$cmd" ]; then
      for f in "$d"/*; do [ "${f##*/}" = "$cmd" ] || [ -e "$shadow/${f##*/}" ] || ln -s "$f" "$shadow/"; done
      d=$shadow
    fi
    [[ :$out: == *":$d:"* ]] || out=${out:+$out:}$d
  done
  echo "$out"
}
on_tty() {  # on_tty <command...>: runs it with stdout on a pseudo-terminal, TERM=xterm and no NO_COLOR; prints its output, keeps its exit code
  python3 -c '
import os, signal, subprocess, sys
signal.alarm(120)
m, s = os.openpty()
p = subprocess.Popen(["env", "-u", "NO_COLOR", "TERM=xterm"] + sys.argv[1:], stdout=s)
os.close(s)
out = b""
while True:
    try: b = os.read(m, 65536)
    except OSError: break
    if not b: break
    out += b
sys.stdout.buffer.write(out.replace(b"\r\n", b"\n"))
sys.exit(p.wait())' "$@"
}

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/proj" 2>/dev/null
cd "$tmp/proj" || exit 1
git checkout -q -b main
printf '# Proj\nSee `src/old.py` for the scorer.\nNone of the three options below is implemented. Pick one.\n' > README.md
mkdir -p src; echo 'x = 1  # HACK until the real error file exists' > src/new.py
git add -A; git commit -q -m init; git push -q -u origin main; git remote set-head origin -a >/dev/null
git switch -q -c stale; git push -q -u origin stale; git switch -q main
git commit -q --allow-empty -m "runhub: You are working on proj at /home/someone/proj, please fix things"; git push -q
git clone -q "$tmp/origin.git" "$tmp/proj/nested-copy" 2>/dev/null

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

echo "== archive"
expect archive-tags ok 'Tagged 1 merged' -- "$guard" archive "$tmp/proj"
expect archive-tag-exists ok 'archive/' -- git -C "$tmp/proj" tag -l 'archive/*/stale'
expect archive-no-push ok '^$' -- git ls-remote --tags "$tmp/origin.git"

echo "== init"
expect init-proposes ok 'guard/budget.card' -- "$guard" init "$tmp/proj" --worktree "$tmp/wt"
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
expect init-agents-proposal ok '^     Merge .*/guard/AGENTS.proposed.md into your AGENTS.md, or delete it\.$' -- "$guard" init "$tmp/agents" --worktree "$tmp/agents-wt"

echo "== merge the guard, as the human would"
cd "$tmp/wt" || exit 1
cat > guard/budget.card <<CARD
account: gom
start_date: 2026-09-01
stop_date: 2099-01-01
max_core_hours: 10000
verification_reserve_core_hours: 1500
cores_per_node: 128
max_nodes_per_job: 4
max_walltime_minutes: 720
max_concurrent_jobs: 10
quota_pct_cmd: echo 42%
CARD
printf 'runs/*/checks/*\ntests\n' > guard/watch.list
git commit -q -am "chore(guard): set budget"; git push -q origin guard/init:main; git fetch -q origin
git switch -q -c agent/run origin/main
R=runs/2026-09-29-demo; mkdir -p "$R"
printf '#!/bin/bash\n#SBATCH --time=04:00:00\n#SBATCH --nodes=2\nguard/run manifest "$1" "$0"\n' > job.sh

echo "== preflight"
expect preflight-no-card fail 'not committed' -- guard/run preflight "$R" job.sh
cp runs/_template/question.card "$R/question.card"; git add -A; git commit -q -m "run: question card"
expect preflight-ok ok 'SBATCH .*--account=gom --job-name=2026-09-29-demo' -- guard/run preflight "$R" job.sh --array=0-3
expect preflight-no-scheduler fail '^preflight: no scheduler on this host; guard/run manifest is the only allowed step here$' -- \
  env PATH="$(path_without sbatch)" guard/run preflight "$R" job.sh
expect preflight-account-wins ok 'SBATCH --account=other .*--account=gom' -- guard/run preflight "$R" job.sh --account=other
expect preflight-walltime fail 'exceeds max_walltime' -- guard/run preflight "$R" job.sh --time=1-00:00:00
expect preflight-budget fail 'exceeds 8500 available' -- guard/run preflight "$R" job.sh --nodes=4 --time=12:00:00 --array=0-9%2
expect preflight-reserve-open ok 'available=10000' -- env HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: <core-hours held back for baselines and verifier jobs>/' guard/budget.card
git commit -q -am "placeholder reserve"
expect preflight-reserve-placeholder fail "^PREFLIGHT FAIL: budget card 'verification_reserve_core_hours' is still a placeholder" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
sed -i 's/^verification_reserve_core_hours: .*/verification_reserve_core_hours: 1500/; s/^cores_per_node: .*/cores_per_node: 128 cores/' guard/budget.card
git commit -q -am "unit in cores_per_node"
expect preflight-budget-not-integer fail "^PREFLIGHT FAIL: budget card 'cores_per_node' must be a whole number: 128 cores; a human fixes it in guard/budget.card on the protected branch$" -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~2
sed -i 's/^stop_date: .*/stop_date: 2000-01-01/' guard/budget.card; git commit -q -am "past stop date"
expect preflight-past-stop fail '^PREFLIGHT FAIL: past stop_date 2000-01-01; a human extends stop_date in guard/budget.card on the protected branch$' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
sed -i 's/max_core_hours: 10000/max_core_hours: 99999/' guard/budget.card; git commit -q -am "raise budget"
expect preflight-card-edit fail 'guard/ differs' -- guard/run preflight "$R" job.sh
printf '#!/usr/bin/env bash\necho SBATCH bypassed\n' > guard/bin/preflight.sh; git commit -q -am "neuter preflight"
expect run-uses-protected-copy fail 'guard/ differs' -- guard/run preflight "$R" job.sh
echo stray > guard/untracked
expect preflight-guard-remedy fail '^PREFLIGHT FAIL: guard/ differs from origin/main: [^;]*guard/untracked[^;]*; restore it with git restore --source=origin/main --staged --worktree -- guard, commit, and remove any untracked file under guard/$' -- guard/run preflight "$R" job.sh
git restore --source=origin/main --staged --worktree -- guard; git commit -q -m "restore guard"; rm guard/untracked
expect preflight-guard-remedy-works ok 'SBATCH ' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~3
echo "metric: changed" >> "$R/question.card"; git commit -q -am "edit card"
expect preflight-card-frozen fail 'edited after its first commit' -- guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
expect explore-no-card ok 'SBATCH .*--job-name=explore-sketch' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
expect explore-capped fail 'exceeds max_nodes_per_job=1' -- guard/run preflight runs/explore-sketch job.sh
expect explore-one-task fail 'one task at a time' -- guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00 --array=0-3
R3=runs/2026-09-29-budget; mkdir -p "$R3"; sed 's/^budget_core_hours: .*/budget_core_hours: 1100/' runs/_template/question.card > "$R3/question.card"
R4=runs/2026-09-29-late; mkdir -p "$R4"; sed 's/^deadline: .*/deadline: 2000-01-01/' runs/_template/question.card > "$R4/question.card"
git add -A; git commit -q -m "run: budget and deadline cards"
expect preflight-run-budget-fits ok 'SBATCH .*--job-name=2026-09-29-budget' -- guard/run preflight "$R3" job.sh
printf '2026-09-29-budget|360000\nother|999999\n' > "$tmp/runrows"
expect preflight-run-budget fail 'this run spent 100 \+ this job 1024 core-h exceeds budget_core_hours=1100' -- env MOCK_SACCT_RUNROWS=$tmp/runrows guard/run preflight "$R3" job.sh
expect preflight-deadline fail 'past deadline 2000-01-01 in runs/2026-09-29-late/question.card' -- guard/run preflight "$R4" job.sh
echo "default_run_core_hours: 10" >> guard/budget.card; git commit -q -am "default run budget"
expect preflight-default-run-budget fail 'this job 64 core-h exceeds budget_core_hours=10' -- env HPC_GUARD_REF=HEAD guard/run preflight runs/explore-sketch job.sh --nodes=1 --time=00:30:00
git reset -q --hard HEAD~1
printf '100|2026-09-29-demo|FAILED|10|240\n' > "$tmp/rows"
expect preflight-refuses-on-ripple fail '^PREFLIGHT FAIL: ripples reports job-states 100:FAILED \(diagnose, then commit runs/2026-09-29-demo/incidents/<n>.md with a job: <id> line for each; a resource stop of a launch continues with an execution.tsv restart or resume row instead\); fix the cause' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run preflight "$R" job.sh
expect ripples-single-entry fail '^RIPPLE	job-states	100:FAILED \(diagnose' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run ripples "$R"
expect preflight-reserve-skips-ripples ok 'SBATCH .*--job-name=2026-09-29-demo' -- env MOCK_SACCT_ROWS="$tmp/rows" HPC_SPEND_RESERVE=1 guard/run preflight "$R" job.sh
mkdir -p "$R/incidents"; printf '# Incident 0\njob: 100\n' > "$R/incidents/0.md"; git add -A; git commit -q -m "run: incident 0"
expect preflight-handled-ripple-passes ok 'SBATCH .*--job-name=2026-09-29-demo' -- env MOCK_SACCT_ROWS="$tmp/rows" guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1
printf '#!/usr/bin/env bash\nexit 3\n' > guard/bin/ripples.sh; git commit -q -am "ripples errors"
expect preflight-ripples-error-fails-closed fail '^PREFLIGHT FAIL: ripples could not run \(exit 3\); run guard/run ripples runs/2026-09-29-demo to see why$' -- env HPC_GUARD_REF=HEAD guard/run preflight "$R" job.sh
git reset -q --hard HEAD~1

echo "== ripples"
mkdir -p "$R/checks"; printf '#!/bin/bash\necho "nan count 3"; exit 1\n' > "$R/checks/nan.sh"; chmod +x "$R/checks/nan.sh"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|13000|240\n102|2026-09-29-demo|FAILED|10|240\n103|other|FAILED|1|1\n' > "$tmp/rows"
export MOCK_SACCT_ROWS=$tmp/rows
expect ripples-states fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED \(diagnose, then commit runs/2026-09-29-demo/incidents/<n>.md with a job: <id> line for each; a resource stop of a launch continues with an execution.tsv restart or resume row instead\)$' -- guard/run ripples "$R"
expect ripples-walltime fail 'RIPPLE.walltime-headroom.100:100% 101:90%' -- guard/run ripples "$R"
expect ripples-check fail 'RIPPLE.check:nan.sh.nan count 3' -- guard/run ripples "$R"
printf '#!/bin/bash\necho "no metrics.csv yet"; exit 77\n' > "$R/checks/later.sh"; chmod +x "$R/checks/later.sh"
expect ripples-check-not-yet fail '^UNCHECKED	check:later.sh	no metrics.csv yet; it exits 77 until its input exists$' -- guard/run ripples "$R"
rm "$R/checks/later.sh"
expect ripples-watched fail 'RIPPLE.watched-paths' -- guard/run ripples "$R"
expect ripples-quota fail 'PASS.quota.42%' -- guard/run ripples "$R"
expect ripples-other-run-ignored fail 'retries.2 not' -- guard/run ripples "$R"
expect ripples-piped-tsv ok - -- bash -c 'out=$(guard/run ripples "$1" | cat); [ -n "$out" ] && ! grep -vE "^(PASS|RIPPLE|HANDLED|UNCHECKED)	[^	]+	[^	]*$" <<<"$out"' _ "$R"
expect ripples-tty-exit ok - -- bash -c "$(declare -f on_tty)"'; on_tty guard/run ripples "$1" >/dev/null; [ $? -eq 1 ]' _ "$R"
expect ripples-tty-opt-out fail '^RIPPLE	job-states	100:TIMEOUT 102:FAILED \(' -- on_tty env HPC_RIPPLES_TSV=1 guard/run ripples "$R"
expect ripples-term-dumb ok - -- bash -c 'out=$1; [ -n "$out" ] && [ -z "$(tr -dc "\033\t" <<<"$out")" ]' _ "$(on_tty env TERM=dumb guard/run ripples "$R")"
tty=$(on_tty guard/run ripples "$R")
expect ripples-tty-ripple ok $'^\e\\[1;31mRIPPLE   \e\\[0m  job-states {17}100:TIMEOUT 102:FAILED \\(diagnose' -- echo "$tty"
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
expect ripples-domain-remedy ok '^UNCHECKED	domain-checks	no executable runs/2026-09-29-demo/checks/\*; add a script there that exits non-zero when a result looks wrong$' -- guard/run ripples "$R"
expect ripples-tty-unchecked ok '^UNCHECKED  budget {21}sacct not found on PATH on this host; run ripples' -- on_tty env NO_COLOR=1 PATH="$(path_without sacct)" guard/run ripples "$R"
# Off the cluster sacct can exist yet list nothing and exit 0, and the quota path can be missing: no verdict, so no PASS.
R4=runs/2026-10-05-no-jobs; mkdir -p "$R4"; cp runs/_template/question.card "$R4/question.card"; git add -A; git commit -q -m "run: a run with no jobs"
nopass='^PASS	(job-states|walltime-headroom|retries|handled-failures|budget|quota)	'
expect ripples-no-jobs ok '^UNCHECKED	job-states	sacct lists no job named 2026-10-05-no-jobs on account gom since 2026-09-01 from this host, so there is nothing to judge; if the run has submitted jobs, run ripples on the cluster login node$' -- guard/run ripples "$R4"
expect ripples-no-jobs-no-pass ok - -- bash -c 'out=$(guard/run ripples "$1"); [ "$(grep -cE "^UNCHECKED	(job-states|walltime-headroom|retries|handled-failures)	sacct lists no job named" <<<"$out")" = 4 ]' _ "$R4"
expect ripples-no-account-jobs ok '^UNCHECKED	budget	sacct lists no job on account gom since 2026-09-01 from this host, so spend is unknown here; run ripples on the cluster login node to check$' -- env MOCK_SACCT_CPUSECONDS= guard/run ripples "$R4"
expect ripples-sacct-fails ok 'UNCHECKED	job-states	sacct failed on this host; run ripples on the cluster login node to check .*UNCHECKED	budget	sacct failed on this host' -- \
  env MOCK_SACCT_EXIT=1 bash -c 'guard/run ripples "$1" 2>/dev/null | tr "\n" " "' _ "$R"
sed -i "s|^quota_pct_cmd: .*|quota_pct_cmd: df --output=pcent $tmp/no-such-mount \| tail -1 \| tr -dc 0-9|" guard/budget.card; git commit -q -am "quota on a path this host lacks"
expect ripples-quota-path-missing ok "^UNCHECKED	quota	quota_pct_cmd printed no number on this host \(df: .*No such file or directory\); run ripples where its path exists, or a human fixes quota_pct_cmd in guard/budget.card$" -- env HPC_GUARD_REF=HEAD guard/run ripples "$R"
expect ripples-off-cluster-no-pass ok - -- bash -c 'out=$(HPC_GUARD_REF=HEAD MOCK_SACCT_CPUSECONDS= guard/run ripples "$1") && ! grep -E "$2" <<<"$out" && [ "$(grep -c ^UNCHECKED <<<"$out")" -ge 6 ]' _ "$R4" "$nopass"
git reset -q --hard HEAD~2
pre=$(git rev-parse HEAD); mkdir -p "$R/incidents"
printf '100|2026-09-29-demo|TIMEOUT|14400|240\n101|2026-09-29-demo|COMPLETED|100|240\n102|2026-09-29-demo|FAILED|10|240\n' > "$tmp/rows"
printf '# Incident 0\njob: 10\n' > "$R/incidents/0.md"; git add -A; git commit -q -m "run: incident 0"
expect ripples-incident-exact-id fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
printf '# Incident 1\njob: 100\n' > "$R/incidents/1.md"; printf '# Incident 2\njob: 102\n' > "$R/incidents/2.md"
expect ripples-incident-uncommitted fail 'RIPPLE.job-states.100:TIMEOUT 102:FAILED' -- guard/run ripples "$R"
git add -A; git commit -q -m "run: incidents 1 and 2"
expect ripples-handled-states ok 'HANDLED.job-states.100:TIMEOUT->incidents/1.md 102:FAILED->incidents/2.md' -- guard/run ripples "$R"
expect ripples-handled-walltime ok 'HANDLED.walltime-headroom.100:100%->incidents/1.md' -- guard/run ripples "$R"
expect ripples-handled-retries ok 'PASS.retries.0 not completed' -- guard/run ripples "$R"
expect ripples-handled-count ok 'PASS.handled-failures.2 of 2' -- guard/run ripples "$R"
echo '103|2026-09-29-demo|FAILED|10|240' >> "$tmp/rows"; printf '# Incident 3\njob: 103\n' > "$R/incidents/3.md"
git add -A; git commit -q -m "run: incident 3"
expect ripples-handled-cap fail 'RIPPLE.handled-failures.3 handled, over max_handled_failures=2' -- guard/run ripples "$R"
git reset -q --hard "$pre"
unset MOCK_SACCT_ROWS
git switch -q -c marker; printf '#!/usr/bin/env bash\necho ran >> %s\n' "$tmp/marker" > guard/bin/launch.sh; git commit -q -am "launch that leaves a marker"
expect ripples-slurm-skips-launch fail - -- bash -c 'env HPC_GUARD_REF=HEAD guard/run ripples "$1" >/dev/null; test -e "$2"' _ "$R" "$tmp/marker"
git switch -q agent/run; git branch -q -D marker

echo "== manifest"
echo "$tmp/rows" > "$R/inputs.list"
expect manifest-writes ok - -- env SLURM_JOB_ID=555 LOADEDMODULES=hycom/2.3 bash job.sh "$R"
expect manifest-content ok 'modules: hycom/2.3' -- cat "$R/manifest-555.txt"
expect manifest-idempotent ok 'manifest exists' -- env SLURM_JOB_ID=555 bash job.sh "$R"
rm -f "$R"/manifest-* "$R/inputs.list"

echo "== code"
git init -q "$tmp/model"; echo 'print(1)' > "$tmp/model/model.py"
git -C "$tmp/model" add -A; git -C "$tmp/model" commit -q -m init
code_sha=$(git -C "$tmp/model" rev-parse HEAD)
export HPC_CODE_ROOT=$tmp/code-root
code_path=$(realpath -m "$HPC_CODE_ROOT")/model-${code_sha:0:12}
# code_from_runs <commit>: guard/run code from the project's runs/ with a relative repo, which resolves only from there.
code_from_runs() { local out; out=$(cd runs && ../guard/run code ../../model "$1") || return; echo "$out"; [ "$out" = "$code_path" ]; }
expect code-absolute-path ok '^/' -- code_from_runs "$code_sha"
expect code-idempotent ok '^/' -- code_from_runs "${code_sha:0:7}"
expect code-at-commit ok "^$code_sha$" -- git -C "$code_path" rev-parse HEAD
expect code-unknown-commit fail 'not a commit' -- guard/run code "$tmp/model" deadbeef
touch "$code_path/scratch.txt"
expect code-refuses-dirty ok 'uncommitted' -- bash -c '! guard/run code "$1" "$2" && test -e "$3/scratch.txt"' _ "$tmp/model" "$code_sha" "$code_path"
expect code-refuses-relative-root fail 'not absolute' -- env HPC_CODE_ROOT=rel/dir guard/run code "$tmp/model" "$code_sha"
expect code-not-inside-repo fail 'is inside' -- env HPC_CODE_ROOT="$tmp/model/frozen" guard/run code "$tmp/model" "$code_sha"
unset HPC_CODE_ROOT

echo "== launch"
expect ripples-not-opted-in fail - -- bash -c 'guard/run ripples "$1" | grep -q "gpu-hours"' _ "$R"
git switch -q -c launch-base origin/main
cat >> guard/budget.card <<CARD
launch_hosts: skynet
max_gpu_hours: 10
host_max_walltime_minutes: 720
host_max_mem_gb: 1000
host_min_available_gb: 0
host_stop_grace_seconds: 1
host_state_dir: $tmp/state
explore_max_gpus: 1
CARD
git commit -q -am "chore(guard): opt skynet in"; git push -q origin launch-base; git fetch -q origin
git switch -q -c launch/agent origin/launch-base
export HPC_GUARD_REF=origin/launch-base
proj_id=$(git rev-list --max-parents=0 origin/main | tail -n1)
boot=$(cat /proc/sys/kernel/random/boot_id)
ago() { date -u -d "-$1" +%FT%TZ; }
rec() {  # rec <id> <file>: write one record file by hand from stdin, in the documented format
  mkdir -p "$tmp/state/$1"; cat > "$tmp/state/$1/$2"
}
req() {  # req <id> <run_id> <gpus> <time_limit_seconds> <requested> [host] [mem_gb] [shm]: a request record for this project
  rec "$1" request <<REQ
job_id: $1
run_id: $2
run_dir: $PWD/runs/$2
project: $proj_id
origin: $tmp/origin.git
host: ${6:-skynet}
guard_commit: $(git rev-parse origin/launch-base)
card: none
cwd: $tmp/scratch
cwd_commit: none
cwd_dirty: none
log: $tmp/scratch/launch-$1.log
gpus: $3
time_limit_seconds: $4
mem_limit_gb: ${7:-1}
shm: ${8:-}
stop_grace_seconds: 1
host_min_available_gb: 0
command: sleep 30
requested: $5
REQ
}
start_rec() {  # start_rec <id> <boot_id> <supervisor_pid> <supervisor_start> <job_pid> <job_start> [started]
  rec "$1" start <<START
started: ${7:-$(ago '1 hour')}
boot_id: $2
supervisor_pid: $3
supervisor_start: $4
job_pid: $5
job_start: $6
sid: $5
log_fd: ok
START
}
end_rec() {  # end_rec <id> <elapsed> <exit> <stop>
  rec "$1" end <<END
ended: $(ago '1 min')
elapsed_seconds: $2
exit: $3
stop: $4
peak_mem_gb: 0.5
leftover_killed: 0
writer: supervisor
END
}
beat_rec() {  # beat_rec <id> <elapsed> <mem_gb> [time] [extra line]
  rec "$1" beat <<BEAT
time: ${4:-$(ago '1 min')}
elapsed_seconds: $2
mem_gb: $3
peak_mem_gb: $3
host_available_gb: 100.0
low_polls: 0${5:+
$5}
BEAT
}
mkdir -p "$tmp/scratch"
F=runs/2026-10-02-fixtures; mkdir -p "$F"
expect launch-usage fail 'usage: guard/run launch' -- guard/run launch
req skynet-20260901T000000Z 2026-10-02-fixtures 0,1 36000 "$(ago '10 hours')"; end_rec skynet-20260901T000000Z 33966 0 none
req skynet-20260901T010000Z 2026-10-02-fixtures 2 21600 "$(ago '9 hours')"; end_rec skynet-20260901T010000Z 1276 130 mem
req skynet-20260901T020000Z 2026-10-02-fixtures 0,1 36000 "$(ago '8 hours')"
start_rec skynet-20260901T020000Z 00000000-0000-0000-0000-000000000000 1 1 1 1; beat_rec skynet-20260901T020000Z 3600 10.0
req skynet-20260901T030000Z 2026-10-02-fixtures none 60 "$(ago '10 min')"
req skynet-20260901T040000Z 2026-10-02-fixtures none 60 "$(date -u +%FT%TZ)"
req skynet-20260901T050000Z 2026-10-02-fixtures none 60 "$(ago '5 min')"
touch "$tmp/scratch/launch-skynet-20260901T050000Z.log"; env HPC_JOB_ID=skynet-20260901T050000Z sleep 30 & alive_pid=$!
req skynet-20260901T060000Z 2026-10-02-fixtures none 3600 "$(ago '2 hours')"
start_rec skynet-20260901T060000Z "$boot" 2 999999999 3 999999999; printf 'ended: half' > "$tmp/state/skynet-20260901T060000Z/end.tmp.123"
req skynet-20260901T070000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')"; end_rec skynet-20260901T070000Z 3300 0 none
mkdir -p "$tmp/state/skynet-20260901T080000Z"
req gpu2-20260901T000000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')" gpu2
req gpu2-20260901T010000Z 2026-10-02-fixtures 1 3600 "$(ago '1 hour')" gpu2; end_rec gpu2-20260901T010000Z 10 1 none
req skynet-20260801T000000Z 2026-10-02-fixtures 3 36000 "2026-08-01T00:00:00Z"; end_rec skynet-20260801T000000Z 36000 0 none
sacct_rows=$(guard/run launch --sacct)
expect sacct-completed ok '^skynet-20260901T000000Z\|2026-10-02-fixtures\|COMPLETED\|33966\|600$' -- echo "$sacct_rows"
expect sacct-oom ok '^skynet-20260901T010000Z\|2026-10-02-fixtures\|OUT_OF_MEMORY\|1276\|360$' -- echo "$sacct_rows"
expect crash-reboot ok '^skynet-20260901T020000Z\|2026-10-02-fixtures\|NODE_FAIL\|3600\|600$' -- echo "$sacct_rows"
expect crash-no-start-stale ok '^skynet-20260901T030000Z\|2026-10-02-fixtures\|LAUNCH_FAILED\|0\|1$' -- echo "$sacct_rows"
expect crash-no-start-fresh ok '^skynet-20260901T040000Z\|2026-10-02-fixtures\|PENDING\|0\|1$' -- echo "$sacct_rows"
expect crash-no-start-alive ok '^skynet-20260901T050000Z\|2026-10-02-fixtures\|RUNNING\|[0-9]+\|1$' -- echo "$sacct_rows"
expect crash-half-written ok '^skynet-20260901T060000Z\|2026-10-02-fixtures\|SUPERVISOR_FAILED\|0\|60$' -- echo "$sacct_rows"
expect crash-empty-dir fail - -- grep skynet-20260901T080000Z <<<"$sacct_rows"
expect crash-remote-unended fail - -- grep gpu2-20260901T000000Z <<<"$sacct_rows"
expect crash-remote-ended ok '^gpu2-20260901T010000Z\|2026-10-02-fixtures\|FAILED\|10\|60$' -- echo "$sacct_rows"
expect sacct-before-start-date fail - -- grep skynet-20260801 <<<"$sacct_rows"
expect list-header ok '^job	state	elapsed	limit	mem_gb	mem_limit_gb	gpus	log$' -- guard/run launch --list
expect list-incomplete ok '^skynet-20260901T080000Z	incomplete$' -- guard/run launch --list
expect list-remote ok '^gpu2-20260901T000000Z	REMOTE	0	3600	-	1	1	' -- guard/run launch --list "$F"
expect list-running ok '^skynet-20260901T050000Z	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- guard/run launch --list "$F"
rip=$(env PATH="$(path_without sacct)" guard/run ripples "$F")
expect ripples-launch-states ok 'RIPPLE	job-states	skynet-20260901T060000Z:SUPERVISOR_FAILED skynet-20260901T030000Z:LAUNCH_FAILED skynet-20260901T020000Z:NODE_FAIL skynet-20260901T010000Z:OUT_OF_MEMORY gpu2-20260901T010000Z:FAILED' -- echo "$rip"
expect ripples-launch-walltime ok 'RIPPLE	walltime-headroom	skynet-20260901T070000Z:91%' -- echo "$rip"
expect ripples-launch-retries ok 'RIPPLE	retries	5 not completed' -- echo "$rip"
expect ripples-launch-budget-unchanged ok '^UNCHECKED	budget	sacct not found on PATH on this host; run ripples on the cluster login node to check$' -- echo "$rip"
expect ripples-gpu-hours ok 'RIPPLE	gpu-hours	22\.1 of 10 GPU-h \(0\.0 in 1 running\)' -- echo "$rip"
expect ripples-supervision-alive ok '^RIPPLE	host-supervision	skynet-20260901T050000Z:no-supervisor-started-it \(stop each with guard/run launch --stop <id> --reason=<why>, or tell the human\)$' -- echo "$rip"
expect ripples-host-memory-pass ok 'PASS	host-memory	[0-9.]+G available; 1 live, at most 80% of --mem' -- echo "$rip"
expect ripples-strays-pass ok 'PASS	host-strays	$' -- echo "$rip"
expect ripples-log-errors-pass ok 'PASS	host-log-errors	1 running log\(s\) scanned' -- echo "$rip"
printf '100|2026-10-02-fixtures|TIMEOUT|14400|240\n' > "$tmp/rows"
expect ripples-launch-plus-sacct fail 'RIPPLE	job-states	100:TIMEOUT skynet-20260901T060000Z:SUPERVISOR_FAILED' -- env MOCK_SACCT_ROWS=$tmp/rows guard/run ripples "$F"
expect ripples-launch-plus-budget fail 'PASS	budget	30 of 10000 core-h' -- env MOCK_SACCT_ROWS=$tmp/rows guard/run ripples "$F"
expect ripples-other-host fail 'UNCHECKED	host-strays	login1 is not in launch_hosts \(skynet\); run ripples on a launch host to check$' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
expect ripples-other-host-gpu-hours fail 'RIPPLE	gpu-hours	22\.1 of 10' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
expect ripples-other-host-no-rows fail 'UNCHECKED	job-states	sacct not found' -- env MOCK_HOSTNAME=login1 PATH="$(path_without sacct)" guard/run ripples "$F"
kill "$alive_pid" 2>/dev/null; wait "$alive_pid" 2>/dev/null
rip=$(env PATH="$(path_without sacct)" guard/run ripples "$F")
expect ripples-alive-gone ok 'skynet-20260901T050000Z:LAUNCH_FAILED' -- echo "$rip"
expect ripples-remote-unended ok 'UNCHECKED	host-supervision	1 launch\(es\) unended on gpu2; run ripples there' -- echo "$rip"
mkdir -p "$F/incidents"; printf '# Incident 1\njob: skynet-20260901T010000Z\n' > "$F/incidents/1.md"; printf '# Incident 2\njob: ../x\n' > "$F/incidents/2.md"
git add -A; git commit -q -m "run: incidents"
expect ripples-incident-alnum fail 'HANDLED	job-states	skynet-20260901T010000Z:OUT_OF_MEMORY->incidents/1.md' -- env PATH="$(path_without sacct)" guard/run ripples "$F"
git reset -q --hard HEAD~1
sleep 60 & stray_pid=$!
printf 'GPU-aaaa, %s\n' "$stray_pid" > "$tmp/apps"
expect ripples-strays-gpu fail "RIPPLE	host-strays	pid$stray_pid:0\.[0-9]+G:gpu:sleep_60" -- env MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
expect ripples-strays-no-nvsmi fail 'UNCHECKED	host-strays	no memory strays; GPU strays unchecked, nvidia-smi not found or timed out; put nvidia-smi on PATH and rerun$' -- env PATH="$(path_without nvidia-smi)" guard/run ripples "$F"
git switch -q -c launch-ignore origin/launch-base; echo 'stray_ignore: ^sleep 60$' >> guard/budget.card; git commit -q -am "ignore"
expect ripples-strays-ignore fail 'PASS	host-strays	$' -- env HPC_GUARD_REF=HEAD MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
git switch -q launch/agent
req skynet-20260901T090000Z 2026-10-02-fixtures none 60 "$(ago '5 min')"
touch "$tmp/scratch/launch-skynet-20260901T090000Z.log"; env HPC_JOB_ID=skynet-20260901T090000Z sleep 60 & launch_pid=$!
printf 'GPU-aaaa, %s\n' "$launch_pid" > "$tmp/apps"
expect ripples-strays-live-launch fail 'PASS	host-strays	$' -- env MOCK_NVSMI_APPS=$tmp/apps guard/run ripples "$F"
kill "$stray_pid" "$launch_pid" 2>/dev/null; wait "$stray_pid" "$launch_pid" 2>/dev/null

sup() {  # sup <id> <time_limit_seconds> <mem_gb> <shm> <gpus> -- <command...>: a request plus a detached supervisor, as launch starts it
  local id=$1; req "$1" 2026-10-02-sup "$5" "$2" "$(date -u +%FT%TZ)" skynet "$3" "$4"; shift 6
  setsid -f guard/run launch --supervise "$tmp/state/$id" -- "$@"
}
wait_end() {  # wait_end <id>...: wait up to 10 s for each end record
  local id i; for id in "$@"; do for ((i = 0; i < 100; i++)); do [ -f "$tmp/state/$id/end" ] && break; sleep 0.1; done; done
}
E=runs/2026-10-02-sup; mkdir -p "$E" "$tmp/shm-m"
sup s-completed 60 1 "" none -- true
sup s-failed 60 1 "" none -- false
sup s-walltime 2 1 "" none -- sleep 30
sup s-mem 60 0.01 "$tmp/shm-m" none -- bash -c 'head -c 20000000 /dev/zero > "$1/blob"; sleep 30' _ "$tmp/shm-m"
sup s-mem-pss 60 0.01 "" none -- bash -c 'x=$(head -c 20000000 /dev/zero | tr "\0" a); sleep 30; echo "${#x}"'
sup s-gentle 1 1 "" none -- bash -c 'trap "echo checkpointed; exit 0" INT; sleep 30 & wait'
sup s-escalates 1 1 "" none -- bash -c 'trap "" INT TERM; sleep 30'
sup s-leftovers 60 1 "" none -- bash -c 'sleep 300 & exit 0'
sup s-escape 60 1 "" none -- bash -c 'setsid sleep 300 & sleep 0.2; exit 0'
sup s-env 60 1 "" 1 -- env
sup s-usr1 60 1 "" none -- sleep 30
sup s-term 60 1 "" none -- bash -c 'trap "echo trapped; exit 0" INT; sleep 30 & wait'
sup s-caller 60 1 "" none -- bash -c 'sleep 2; echo alive'
sleep 1
expect sup-start-written ok '^log_fd: ok$' -- cat "$tmp/state/s-usr1/start"
expect sup-start-sid ok - -- bash -c '[ "$(grep ^job_pid: "$1" | cut -d" " -f2)" = "$(grep ^sid: "$1" | cut -d" " -f2)" ]' _ "$tmp/state/s-usr1/start"
expect sup-list-running ok '^s-usr1	RUNNING	[0-9]+	60	0\.[0-9]+	1	none	' -- guard/run launch --list "$E"
expect sup-supervision-pass ok 'PASS	host-supervision	[0-9]+ live, supervised' -- bash -c 'guard/run ripples "$1" | grep host-supervision' _ "$E"
kill -USR1 "$(grep ^supervisor_pid: "$tmp/state/s-usr1/start" | cut -d' ' -f2)"
kill -TERM "$(grep ^supervisor_pid: "$tmp/state/s-term/start" | cut -d' ' -f2)"
wait_end s-completed s-failed s-walltime s-mem s-mem-pss s-gentle s-escalates s-leftovers s-escape s-env s-usr1 s-term s-caller
expect sup-completed ok '^stop: none$' -- cat "$tmp/state/s-completed/end"
expect sup-completed-exit ok '^exit: 0$' -- cat "$tmp/state/s-completed/end"
expect sup-failed ok '^exit: 1$' -- cat "$tmp/state/s-failed/end"
expect sup-walltime ok '^stop: walltime$' -- cat "$tmp/state/s-walltime/end"
expect sup-mem ok '^stop: mem$' -- cat "$tmp/state/s-mem/end"
expect sup-mem-pss ok '^stop: mem$' -- cat "$tmp/state/s-mem-pss/end"
expect sup-gentle-log ok '^checkpointed$' -- cat "$tmp/scratch/launch-s-gentle.log"
expect sup-gentle-end ok '^exit: 0$' -- cat "$tmp/state/s-gentle/end"
expect sup-escalates ok '^exit: 137$' -- cat "$tmp/state/s-escalates/end"
expect sup-escalates-log ok ' KILL$' -- cat "$tmp/state/s-escalates/supervisor.log"
expect sup-leftovers ok '^leftover_killed: 1$' -- cat "$tmp/state/s-leftovers/end"
expect sup-leftovers-gone fail - -- grep -lzx HPC_JOB_ID=s-leftovers /proc/[0-9]*/environ
expect sup-escape ok '^leftover_killed: 1$' -- cat "$tmp/state/s-escape/end"
expect sup-env ok '^HPC_JOB_ID=s-env$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-env-cuda ok '^CUDA_VISIBLE_DEVICES=1$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-env-order ok '^CUDA_DEVICE_ORDER=PCI_BUS_ID$' -- cat "$tmp/scratch/launch-s-env.log"
expect sup-usr1 ok '^stop: requested$' -- cat "$tmp/state/s-usr1/end"
expect sup-term ok '^stop: signal$' -- cat "$tmp/state/s-term/end"
expect sup-term-trapped ok '^trapped$' -- cat "$tmp/scratch/launch-s-term.log"
expect sup-caller ok '^alive$' -- cat "$tmp/scratch/launch-s-caller.log"
states=$(guard/run launch --sacct)
expect sup-states-completed ok '^s-completed\|2026-10-02-sup\|COMPLETED\|' -- echo "$states"
expect sup-states-failed ok '^s-failed\|2026-10-02-sup\|FAILED\|' -- echo "$states"
expect sup-states-timeout ok '^s-walltime\|2026-10-02-sup\|TIMEOUT\|[2-9]\|1$' -- echo "$states"
expect sup-states-oom ok '^s-mem\|2026-10-02-sup\|OUT_OF_MEMORY\|' -- echo "$states"
expect sup-states-cancelled ok '^s-usr1\|2026-10-02-sup\|CANCELLED\|' -- echo "$states"
expect sup-states-preempted ok '^s-term\|2026-10-02-sup\|PREEMPTED\|' -- echo "$states"
expect sup-no-leftover-processes fail - -- grep -lzE '^HPC_JOB_ID=s-' /proc/[0-9]*/environ
tick_job() {  # tick_job <id> <mem_gb> <started> <time_limit_seconds> [mem_limit_gb]: a running job with a start record and a beat, polled by --tick
  req "$1" 2026-10-02-tick none "$4" "$(ago '1 hour')" skynet "${5:-1000}"
  local pid; pid=$( env HPC_JOB_ID="$1" setsid sleep 30 >/dev/null 2>&1 & echo $! ); sleep 0.1
  start_rec "$1" "$boot" $$ "$(sed 's/^.*) //' /proc/$$/stat | awk '{print $20}')" "$pid" "$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')" "$3"
  beat_rec "$1" 10 "$2" "$(date -u +%FT%TZ)"
}
tick_job t-big 400.0 "$(ago '1 hour')" 36000; tick_job t-small 200.0 "$(ago '30 min')" 36000
expect tick-no-pressure ok 'reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=104857600 guard/run launch --tick "$tmp/state/t-big"
sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-big/request" "$tmp/state/t-small/request"
expect tick-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-big"
expect tick-small-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-small"
expect tick-small-not-elected ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-small"
expect tick-big-elected ok 'low=2 reason=host-mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=419430400 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-big"
expect tick-big-end ok '^stop: host-mem$' -- cat "$tmp/state/t-big/end"
expect tick-big-elected-detail ok '^elected: largest of 2 live, 400.0 GB$' -- cat "$tmp/state/t-big/end"
expect tick-big-writer ok '^writer: tick$' -- cat "$tmp/state/t-big/end"
expect tick-small-alive fail - -- test -f "$tmp/state/t-small/end"
expect tick-small-state ok '^t-small\|2026-10-02-tick\|RUNNING\|' -- guard/run launch --sacct
expect tick-big-state ok '^t-big\|2026-10-02-tick\|HOST_OUT_OF_MEMORY\|' -- guard/run launch --sacct
tick_job t-stopping 400.0 "$(ago '1 hour')" 36000; tick_job t-other 200.0 "$(ago '30 min')" 36000
beat_rec t-stopping 10 400.0 "$(date -u +%FT%TZ)" "stopping: host-mem"; sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 32/' "$tmp/state/t-other/request"
expect tick-other-first-low ok 'low=1 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-other"
expect tick-yields-to-stopping ok 'low=2 reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=209715200 HPC_LAUNCH_TEST_AVAILABLE_KB=10485760 guard/run launch --tick "$tmp/state/t-other"
expect tick-stopping-not-elected fail - -- bash -c 'test -e "$1/t-other/end" || test -e "$1/t-stopping/end"' _ "$tmp/state"
expect tick-big-beat-stopping ok '^stopping: host-mem$' -- cat "$tmp/state/t-big/beat"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-stopping/start" | cut -d' ' -f2)" "$(grep ^job_pid: "$tmp/state/t-other/start" | cut -d' ' -f2)" 2>/dev/null
tick_job t-wall 1.0 "$(ago '2 hours')" 3600
expect tick-walltime ok 'reason=walltime$' -- guard/run launch --tick "$tmp/state/t-wall"
expect tick-walltime-end ok '^exit: unknown$' -- cat "$tmp/state/t-wall/end"
expect tick-walltime-measure ok '^charge_measure: rss_anon$' -- cat "$tmp/state/t-wall/end"
tick_job t-pss 0.5 "$(ago '1 hour')" 36000 1
expect tick-mem-not-confirmed ok 'charge=2.0G .*reason=none$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=524288 guard/run launch --tick "$tmp/state/t-pss"
expect tick-mem-confirmed ok 'charge=1.5G .*reason=mem$' -- env HPC_LAUNCH_TEST_CHARGE_KB=2097152 HPC_LAUNCH_TEST_PSS_KB=1572864 guard/run launch --tick "$tmp/state/t-pss"
expect tick-mem-confirmed-measure ok '^charge_measure: pss$' -- cat "$tmp/state/t-pss/end"
expect tick-mem-confirmed-peak ok '^peak_mem_gb: 2.0$' -- cat "$tmp/state/t-pss/end"
kill -KILL "$(grep ^job_pid: "$tmp/state/t-small/start" | cut -d' ' -f2)" 2>/dev/null

rm -rf "$tmp/state"
R2=runs/2026-10-02-launch; mkdir -p "$R2"; cp runs/_template/question.card "$R2/"; git add -A; git commit -q -m "run: launch card"
L() { env HPC_SPEND_RESERVE=1 guard/run launch "$@"; }
expect launch-off-by-default fail '^LAUNCH FAIL: skynet is not in launch_hosts \(none\)' -- env HPC_GUARD_REF=origin/main HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=none --mem=0.01 -- true
expect launch-other-host fail 'login1 is not in launch_hosts' -- env MOCK_HOSTNAME=login1 HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=none --mem=0.01 -- true
expect launch-usage-no-command fail 'usage: guard/run launch' -- L "$R2" --time=1 --gpus=none --mem=0.01
expect launch-needs-time fail 'state --time' -- L "$R2" --gpus=none --mem=0.01 -- true
expect launch-needs-gpus fail 'state --gpus' -- L "$R2" --time=1 --mem=0.01 -- true
expect launch-needs-mem fail 'state --mem' -- L "$R2" --time=1 --gpus=none -- true
expect launch-bad-time fail 'is not a Slurm time' -- L "$R2" --time=abc --gpus=none --mem=0.01 -- true
expect launch-shm-relative fail 'absolute' -- L "$R2" --time=1 --gpus=none --mem=0.01 --shm=shm -- true
expect launch-cwd-missing fail 'not a writable directory' -- L "$R2" --time=1 --gpus=none --mem=0.01 --cwd="$tmp/nope" -- true
expect launch-no-card fail 'runs/2026-10-02-nocard/question.card is not committed' -- L runs/2026-10-02-nocard --time=1 --gpus=none --mem=0.01 -- true
echo "metric: changed" >> "$R2/question.card"; git commit -q -am "edit card"
expect launch-card-frozen fail 'edited after its first commit' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
sed -i 's/^max_gpu_hours: .*/max_gpu_hours: 999/' guard/budget.card; git commit -q -am "raise"
expect launch-guard-touched fail 'guard/ differs' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
same_refusal() {  # same_refusal <name> <preflight args...> -- <launch args...>: the text after the two prefixes is identical
  local name=$1 p l; shift; local pre=(); while [ "$1" != -- ]; do pre+=("$1"); shift; done; shift
  p=$(guard/run preflight "${pre[@]}" 2>&1); l=$(L "$@" 2>&1)
  expect "$name" ok - -- test "${p#PREFLIGHT FAIL: }" = "${l#LAUNCH FAIL: }"
}
same_refusal launch-gates-match-guard "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
same_refusal launch-gates-match-no-card runs/2026-10-02-nocard job.sh -- runs/2026-10-02-nocard --time=1 --gpus=none --mem=0.01 -- true
echo "metric: changed" >> "$R2/question.card"; git commit -q -am "edit card"
same_refusal launch-gates-match-frozen "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git reset -q --hard HEAD~1
git switch -q -c launch-past; sed -i 's/^stop_date: .*/stop_date: 2000-01-01/' guard/budget.card; git commit -q -am "past"
export HPC_GUARD_REF=HEAD
expect launch-past-stop fail '^LAUNCH FAIL: past stop_date 2000-01-01; a human extends stop_date in guard/budget.card on the protected branch$' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
same_refusal launch-gates-match-stop-date "$R2" job.sh -- "$R2" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -c launch-floor launch/agent; sed -i 's/^host_min_available_gb: .*/host_min_available_gb: 999999/' guard/budget.card; git commit -q -am "floor"
expect launch-host-memory fail 'MemAvailable .* leaves less than --mem=0.01G plus host_min_available_gb=999999' -- L "$R2" --time=1 --gpus=none --mem=0.01 -- true
export HPC_GUARD_REF=origin/launch-base; git switch -q launch/agent
expect launch-walltime-cap fail 'exceeds host_max_walltime_minutes=720' -- L "$R2" --time=13:00:00 --gpus=none --mem=0.01 -- true
expect launch-explore-gpus fail 'exceeds explore_max_gpus=1' -- L runs/explore-l --time=1 --gpus=0,1 --mem=0.01 -- true
expect launch-explore-time fail 'exceeds explore_max_walltime_minutes=60' -- L runs/explore-l --time=02:00:00 --gpus=none --mem=0.01 -- true
expect launch-mem-cap fail 'exceeds host_max_mem_gb=1000' -- L "$R2" --time=1 --gpus=none --mem=1001 -- true
expect launch-gpu-unknown fail 'no GPU 7 on skynet' -- L "$R2" --time=1 --gpus=7 --mem=0.01 -- true
printf 'GPU-aaaa, 999\n' > "$tmp/apps"
expect launch-gpu-busy fail 'GPU 0 is busy \(pid 999\)' -- env MOCK_NVSMI_APPS=$tmp/apps HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=0 --mem=0.01 -- true
expect launch-gpu-budget fail 'this job 12.0 GPU-h exceeds 10 GPU-h' -- L "$R2" --time=06:00:00 --gpus=0,1 --mem=0.01 -- true
expect launch-no-nvidia-smi fail 'nvidia-smi not found' -- env PATH="$(path_without nvidia-smi)" HPC_SPEND_RESERVE=1 guard/run launch "$R2" --time=1 --gpus=0 --mem=0.01 -- true
expect launch-cpu-without-nvidia-smi ok '^skynet-' -- env PATH="$(path_without nvidia-smi)" HPC_SPEND_RESERVE=1 guard/run launch runs/explore-cpu --time=1 --gpus=none --mem=0.01 -- true
held=$(L runs/explore-held --time=1 --gpus=1 --mem=0.01 -- sleep 30 2>/dev/null)
expect launch-gpu-held fail "GPU 1 is held by $held" -- L "$R2" --time=1 --gpus=1 --mem=0.01 -- true
L runs/explore-race --time=1 --gpus=3 --mem=0.01 -- sleep 1 >"$tmp/race1" 2>&1 &
L runs/explore-race --time=1 --gpus=3 --mem=0.01 -- sleep 1 >"$tmp/race2" 2>&1 &
wait
expect launch-gpu-race ok '^1$' -- bash -c 'grep -c "^LAUNCH OK" "$1" "$2" | awk -F: "{s+=\$2} END{print s}"' _ "$tmp/race1" "$tmp/race2"
expect launch-gpu-race-loser ok 'GPU 3 is held by skynet-' -- cat "$tmp/race1" "$tmp/race2"
id=$(L "$R2" --time=1 --gpus=2 --mem=0.01 -- env 2>"$tmp/launch.err")
expect launch-prints-id ok '^skynet-[0-9]{8}T[0-9]{6}Z$' -- echo "$id"
expect launch-ok-line ok '^LAUNCH OK: 2026-10-02-launch job=skynet-.* gpus=2 time=1m mem=0.01G gpu_h_spent=0.0 available=[0-9.]+ log=' -- cat "$tmp/launch.err"
expect launch-manifest ok "^job_id: $id$" -- cat "$R2/manifest-$id.txt"
expect launch-manifest-cuda ok '^cuda_visible_devices: unset$' -- cat "$R2/manifest-$id.txt"
expect launch-request-cwd-commit ok "^cwd_commit: $(git rev-parse HEAD)$" -- cat "$tmp/state/$id/request"
expect launch-request-card ok "^card: $(git rev-parse "HEAD:$R2/question.card")$" -- cat "$tmp/state/$id/request"
expect launch-request-run-dir ok "^run_dir: $PWD/$R2$" -- cat "$tmp/state/$id/request"
absid=$(L "$PWD/runs/explore-abs" --time=1 --gpus=none --mem=0.01 -- true 2>/dev/null)
expect launch-request-run-dir-absolute ok "^run_dir: $PWD/runs/explore-abs$" -- cat "$tmp/state/$absid/request"
idem=$(L runs/explore-idem --time=1 --gpus=none --mem=0.01 -- bash -c 'guard/run manifest "$HPC_RUN_DIR" x' 2>/dev/null)
cwdid=$(L runs/explore-cwd --time=1 --gpus=none --mem=0.01 --cwd="$tmp/scratch" -- pwd 2>/dev/null)
caller=$(setsid bash -c 'env HPC_SPEND_RESERVE=1 guard/run launch runs/explore-caller --time=1 --gpus=none --mem=0.01 -- bash -c "sleep 1; echo alive" 2>/dev/null; kill -HUP 0')
local=$(env HPC_GUARD_LOCAL=1 HPC_SPEND_RESERVE=1 guard/run launch runs/explore-local --time=1 --gpus=none --mem=0.01 -- true 2>/dev/null)
expect launch-local-copy ok '^skynet-' -- echo "$local"
secs=$(L runs/explore-secs --time=0:15 --gpus=none --mem=0.01 -- true 2>"$tmp/secs.err")
expect launch-ok-seconds ok ' time=15s ' -- cat "$tmp/secs.err"
failed=$(L runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- false 2>/dev/null)
wait_end "$id" "$idem" "$cwdid" "$caller" "$local" "$failed" "$absid" "$secs"
expect launch-env ok "^HPC_JOB_ID=$id$" -- cat "launch-$id.log"
expect launch-env-cuda ok '^CUDA_VISIBLE_DEVICES=2$' -- cat "launch-$id.log"
expect launch-env-run-dir ok "^HPC_RUN_DIR=$PWD/$R2$" -- cat "launch-$id.log"
expect launch-manifest-idempotent ok 'manifest exists' -- cat "launch-$idem.log"
expect launch-cwd-log ok "^$tmp/scratch$" -- cat "$tmp/scratch/launch-$cwdid.log"
expect launch-survives-caller ok '^alive$' -- cat "launch-$caller.log"
expect launch-completed ok "^$local	COMPLETED	" -- guard/run launch --list runs/explore-local
expect launch-ripples-gate fail "ripples reports job-states: $failed:FAILED" -- guard/run launch runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- true
expect launch-ripples-reserve ok '^skynet-' -- L runs/explore-ripple --time=1 --gpus=none --mem=0.01 -- true
expect launch-stop ok '^CANCELLED$' -- guard/run launch --stop "$held" --reason=done
expect launch-stop-end ok '^stop: requested$' -- cat "$tmp/state/$held/end"
expect launch-stop-reason ok '^reason: done$' -- cat "$tmp/state/$held/end"
expect launch-stop-writer ok '^writer: supervisor$' -- cat "$tmp/state/$held/end"
expect launch-stop-again ok '^already ended: CANCELLED$' -- guard/run launch --stop "$held"
req foreign-1 other none 60 "$(date -u +%FT%TZ)"; sed -i 's/^project: .*/project: 0000000000000000000000000000000000000000/' "$tmp/state/foreign-1/request"
expect launch-stop-foreign fail 'belongs to another project' -- guard/run launch --stop foreign-1
expect launch-stop-unknown fail 'no launch nope-1' -- guard/run launch --stop nope-1
crash=$(L runs/explore-crash --time=1 --gpus=none --mem=0.01 -- sleep 30 2>/dev/null)
kill -9 "$(grep ^supervisor_pid: "$tmp/state/$crash/start" | cut -d' ' -f2)"
expect crash-supervisor-killed fail "RIPPLE	host-supervision	$crash:pid[0-9]+-has-no-supervisor" -- guard/run ripples runs/explore-crash
expect crash-supervisor-killed-list ok "^$crash	RUNNING	" -- guard/run launch --list runs/explore-crash
expect crash-stop-unsupervised ok '^CANCELLED$' -- guard/run launch --stop "$crash"
expect crash-stop-unsupervised-end ok '^exit: unknown$' -- cat "$tmp/state/$crash/end"
expect crash-stop-unsupervised-writer ok '^writer: stop$' -- cat "$tmp/state/$crash/end"
expect crash-stop-supervision-pass ok 'PASS	host-supervision	0 live, supervised' -- bash -c 'guard/run ripples runs/explore-crash | grep host-supervision'
wait_end "$(cat "$tmp/race1" "$tmp/race2" | grep -o 'job=skynet-[0-9TZ]*' | cut -d= -f2)"
expect launch-no-job-left fail - -- grep -lzE '^HPC_JOB_ID=skynet-' /proc/[0-9]*/environ
X=runs/2026-10-02-ledger; mkdir -p "$X"; cp runs/_template/question.card "$X/"
req x-1-done 2026-10-02-ledger 1 3600 "$(ago '2 hours')" skynet 100; end_rec x-1-done 1800 0 none
req x-2-oom 2026-10-02-ledger 1 3600 "$(ago '1 hour')" skynet 100; end_rec x-2-oom 1200 130 mem
git add -A; git commit -q -m "run: ledger card"
expect ripples-no-ledger-no-line fail - -- bash -c 'guard/run ripples "$1" | grep -q execution-within-envelope' _ "$X"
expect launch-after-resource-stop fail 'x-2-oom ended OUT_OF_MEMORY; commit an execution.tsv row \(restart or resume\) citing it, then launch again' -- L "$X" --time=1 --gpus=none --mem=0.01 -- true
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\t2026-10-02T12:00:00Z\thost\tskynet\tthe A100 box\tnone\nx2\t2026-10-02T12:01:00Z\tmem_stop_gb\t300\tshm staging\tnone\nx3\t2026-10-02T12:02:00Z\trestart\tx-2-oom\tOOM at epoch 3\tlaunch-x-2-oom.log\nx4\t2026-10-02T12:03:00Z\tresume\t%s/scratch/ckpt/epoch3.pt\tcheckpoint\tnone\n' "$tmp" > "$X/execution.tsv"
expect ripples-ledger-uncommitted fail - -- bash -c 'guard/run ripples "$1" | grep -q execution-within-envelope' _ "$X"
git add -A; git commit -q -m "run: ledger"
rip=$(guard/run ripples "$X")
expect ripples-envelope-pass ok 'PASS	execution-within-envelope	4 rows: host x1, mem_stop_gb x2, restart x3, resume x4' -- echo "$rip"
expect ripples-restart-handles ok 'HANDLED	job-states	x-2-oom:OUT_OF_MEMORY->execution.tsv:x3' -- echo "$rip"
expect ripples-restart-counts ok 'PASS	handled-failures	1 of 2' -- echo "$rip"
expect ripples-envelope-without-launch fail 'RIPPLE	execution-within-envelope	x1: host skynet is not in launch_hosts \(none\)' -- env HPC_GUARD_REF=origin/main guard/run ripples "$X"
expect launch-after-restart-row ok '^skynet-' -- guard/run launch "$X" --time=1 --gpus=none --mem=0.01 -- true
X2=runs/2026-10-02-badledger; mkdir -p "$X2"; cp runs/_template/question.card "$X2/"
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\tsetting\tfloat32\tw\te\nx3\tt\thost\tlogin1\tw\te\nx3\tt\tmem_stop_gb\t2000\tw\te\nx4\tt\trestart\tx-1-done\tw\te\nx5\tt\tresume\t/nowhere/ckpt\tw\te\n' > "$X2/execution.tsv"
git add -A; git commit -q -m "run: bad ledger"
rip=$(guard/run ripples "$X2")
expect ripples-envelope-design fail 'RIPPLE	execution-within-envelope	x1: setting is design; a change to it needs a new card' -- guard/run ripples "$X2"
expect ripples-envelope-order ok 'x3: ids run x1, x2, \.\.\. in order; this is row 2' -- echo "$rip"
expect ripples-envelope-host ok 'x3: host login1 is not in launch_hosts \(skynet\)' -- echo "$rip"
expect ripples-envelope-mem ok 'x3: mem_stop_gb 2000 is over host_max_mem_gb=1000' -- echo "$rip"
expect ripples-envelope-restart ok 'x4: restart x-1-done is not a resource stop of this run' -- echo "$rip"
expect ripples-envelope-resume ok 'x5: resume /nowhere/ckpt is under no launch cwd of this run' -- echo "$rip"
X3=runs/2026-10-02-science; mkdir -p "$X3"; cp runs/_template/question.card "$X3/"
X4=runs/2026-10-02-capped; mkdir -p "$X4"; sed 's/^budget_gpu_hours: .*/budget_gpu_hours: 1/' runs/_template/question.card > "$X4/question.card"
X5=runs/2026-10-02-late; mkdir -p "$X5"; sed 's/^deadline: .*/deadline: 2000-01-01/' runs/_template/question.card > "$X5/question.card"
git add -A; git commit -q -m "run: science, capped and late cards"
req x-3-fail 2026-10-02-science none 60 "$(ago '1 hour')"; end_rec x-3-fail 10 1 none
expect launch-after-science-stop fail 'x-3-fail ended FAILED, a science stop; the human decides whether this run continues' -- L "$X3" --time=1 --gpus=none --mem=0.01 -- true
req x-3-stopped 2026-10-02-science none 60 "$(ago '30 min')"; end_rec x-3-stopped 10 unknown requested
expect launch-after-cancelled-is-resource fail 'x-3-stopped ended CANCELLED; commit an execution.tsv row \(restart or resume\) citing it' -- L "$X3" --time=1 --gpus=none --mem=0.01 -- true
printf '2026-10-02-science|CANCELLED by 1000\n' > "$tmp/staterow"
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\trestart\tx-3-stopped\tw\te\nx2\tt\trestart\t12345\tw\te\n' > "$X3/execution.tsv"; git add -A; git commit -q -m "run: science ledger"
expect ripples-restart-cancelled-rows fail 'PASS	execution-within-envelope	2 rows: restart x1, restart x2' -- env MOCK_SACCT_STATE=$tmp/staterow guard/run ripples "$X3"
req x-4-spent 2026-10-02-capped 1 3600 "$(ago '2 hours')" skynet 100; end_rec x-4-spent 1800 0 none
expect launch-run-gpu-budget fail 'this run spent 0.5 \+ running 0.0 \+ this job 1.0 GPU-h exceeds budget_gpu_hours=1' -- L "$X4" --time=1:00:00 --gpus=0 --mem=0.01 -- true
capped=$(L "$X4" --time=0:30:00 --gpus=0 --mem=0.01 -- true 2>/dev/null)
expect launch-run-gpu-budget-fits ok '^skynet-' -- echo "$capped"
req x-5-more 2026-10-02-capped 1 3600 "$(ago '1 hour')" skynet 100; end_rec x-5-more 1900 0 none
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\tgpus\t0\tw\te\n' > "$X4/execution.tsv"; git add -A; git commit -q -m "run: capped ledger"
expect ripples-envelope-spend fail 'execution-within-envelope	.*spent 1.0 GPU-h over budget_gpu_hours=1' -- guard/run ripples "$X4"
expect launch-deadline fail 'past deadline 2000-01-01 in runs/2026-10-02-late/question.card' -- L "$X5" --time=1 --gpus=none --mem=0.01 -- true
git switch -q -c launch-default; echo "default_run_gpu_hours: 1" >> guard/budget.card; git commit -q -am "default run budget"
expect launch-default-run-budget fail 'this job 2.0 GPU-h exceeds budget_gpu_hours=1' -- env HPC_GUARD_REF=HEAD HPC_SPEND_RESERVE=1 guard/run launch "$X" --time=2:00:00 --gpus=0 --mem=0.01 -- true
git switch -q launch/agent
wait_end "$capped"
rm -f launch-*.log; rm -rf runs/explore-*; git checkout -q -- .
rm -rf "$tmp/state"; unset HPC_GUARD_REF

echo "== fence"
git switch -q -c pr/clean origin/main; mkdir -p runs/r1; cp runs/_template/question.card runs/r1/; git add -A; git commit -q -m "run: r1"
expect fence-clean ok 'PASS.guard-untouched' -- guard/run fence origin/main HEAD
expect fence-clean-setting ok 'PASS.setting-key' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/r1/report.md
printf '| Claim | Value | Artifact | Job | Commit |\n' > /dev/null
sed -i '/^|---|---|---|---|---|$/a | RMSE 50-200 m | 0.81 (0.06) | `runs/r1/metrics.csv` | 812400 | a1b2c3d |\n| looks great | 23% | none | - | - |' runs/r1/report.md
git add -A; git commit -q -m "report"
expect fence-unproven fail 'FAIL.evidence-paths.*runs/r1/report.md:' -- guard/run fence origin/main HEAD
git switch -q -c pr/explore origin/main; mkdir -p runs/explore-a; cp runs/_template/report.md runs/explore-a/; git add -A; git commit -q -m x
expect fence-explore-report fail 'FAIL.no-exploration-reports' -- guard/run fence origin/main HEAD
git switch -q -c pr/guard origin/main; echo "max_nodes_per_job: 64" >> guard/budget.card; git commit -q -am x
expect fence-guard fail 'FAIL.guard-untouched' -- guard/run fence origin/main HEAD
git switch -q -c pr/workflow origin/main; echo "# off" >> .github/workflows/guard-fence.yml; git commit -q -am x
expect fence-workflow fail 'FAIL.guard-untouched.*guard-fence.yml' -- guard/run fence origin/main HEAD
git switch -q -c pr/tests origin/main; mkdir -p tests; echo x > tests/t; git add -A; git commit -q -m x
expect fence-watched fail 'FAIL.watched-paths.*tests/t' -- guard/run fence origin/main HEAD
git push -q origin pr/clean:refs/heads/pr-clean; git switch -q -c pr/card origin/pr-clean
echo "metric: moved" >> runs/r1/question.card; git commit -q -am x
expect fence-card fail 'FAIL.question-cards-frozen.*runs/r1/question.card' -- guard/run fence origin/pr-clean HEAD

git switch -q -c pr/no-setting origin/main; mkdir -p runs/ns; cp runs/_template/question.card runs/ns/
sed -i '/^setting:/d' runs/ns/question.card
git add -A; git commit -q -m x
expect fence-card-no-setting fail 'FAIL.setting-key' -- guard/run fence origin/main HEAD

lineage() { guard/run fence origin/main HEAD | grep card-lineage; }
no_lineage() { ! lineage | grep -qE "$1"; }
expect template-lineage-keys ok - -- bash -c 'grep -q "^supersedes: <" "$1" && grep -q "^spawned_from: <" "$1"' _ "$here/templates/runs/_template/question.card"
git switch -q -c pr/lineage origin/main
for r in lin-053 lin-054 lin-054b lin-053-phys2 explore-lin explore-lin-2; do mkdir -p runs/$r; cp runs/_template/question.card runs/$r/; done
git add -A; git commit -q -m x
expect fence-lineage-warns ok 'WARN.card-lineage.*lin-054 extends lin-053' -- guard/run fence origin/main HEAD
expect fence-lineage-says-amend ok 'WARN.card-lineage.*amending the commit that added the card' -- guard/run fence origin/main HEAD
expect fence-lineage-letter ok 'lin-054b extends lin-054(;|$)' -- lineage
expect fence-lineage-suffix ok 'lin-053-phys2 extends lin-053(;|$)' -- lineage
expect fence-lineage-root ok - -- no_lineage ' lin-053 extends|explore-'
expect fence-lineage-passes ok - -- bash -c 'out=$(guard/run fence origin/main HEAD) && ! grep -q "^FAIL" <<<"$out"'
git push -q origin pr/lineage:refs/heads/pr-lineage
sed -i 's/^supersedes: .*/supersedes: none/' runs/lin-054/question.card
sed -i 's/^spawned_from: .*/spawned_from: lin-054/' runs/lin-054b/question.card
sed -i '/^supersedes:/d; /^spawned_from:/d' runs/lin-053-phys2/question.card
git commit -q -am x
expect fence-lineage-none ok - -- no_lineage 'lin-054 extends'
expect fence-lineage-set ok - -- no_lineage 'lin-054b extends'
expect fence-lineage-missing-keys ok 'lin-053-phys2 extends lin-053$' -- lineage
git switch -q -c pr/after-lineage origin/pr-lineage; cp runs/_template/report.md runs/lin-054/; git add -A; git commit -q -m x
expect fence-lineage-added-only ok - -- bash -c 'out=$(guard/run fence origin/pr-lineage HEAD) && grep -q "^PASS.setting-key" <<<"$out" && ! grep -q card-lineage <<<"$out"'

git switch -q -c pr/hyp-na origin/main; mkdir -p runs/hn
cp runs/_template/question.card runs/hn/; cp runs/_template/report.md runs/hn/
git add -A; git commit -q -m x
expect fence-hypothesis-na ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-case origin/main; mkdir -p runs/hc
cp runs/_template/question.card runs/hc/; cp runs/_template/report.md runs/hc/
sed -i 's/^hypothesis: .*/hypothesis: N\/A/' runs/hc/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-case ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-wide origin/main; mkdir -p runs/hw
cp runs/_template/question.card runs/hw/; cp runs/_template/report.md runs/hw/
awk 'BEGIN{line="hypothesis: \357\274\256\357\274\217\357\274\241"} /^hypothesis: /{print line; next} {print}' runs/hw/report.md > runs/hw/report.md.new
mv runs/hw/report.md.new runs/hw/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-wide ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-na-dot origin/main; mkdir -p runs/hd
cp runs/_template/question.card runs/hd/; cp runs/_template/report.md runs/hd/
sed -i 's/^hypothesis: .*/hypothesis: N.A./' runs/hd/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-na-dot fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-match origin/main; mkdir -p runs/hm
cp runs/_template/question.card runs/hm/; cp runs/_template/report.md runs/hm/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hm/question.card runs/hm/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-match ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-lt origin/main; mkdir -p runs/hl
cp runs/_template/question.card runs/hl/; cp runs/_template/report.md runs/hl/
sed -i 's/^hypothesis: .*/hypothesis: layer increment < 1e-6/' runs/hl/question.card runs/hl/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-lessthan ok 'PASS.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-mismatch origin/main; mkdir -p runs/hx
cp runs/_template/question.card runs/hx/; cp runs/_template/report.md runs/hx/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hx/question.card
sed -i 's/^hypothesis: .*/hypothesis: increment grows with depth/' runs/hx/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-mismatch fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-ph origin/main; mkdir -p runs/hp
cp runs/_template/question.card runs/hp/; cp runs/_template/report.md runs/hp/
sed -i 's/^hypothesis: .*/hypothesis: increment is zero at every layer/' runs/hp/question.card
sed -i 's/^hypothesis: .*/hypothesis: <placeholder>/' runs/hp/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-placeholder fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/hyp-head origin/main; mkdir -p runs/hh
cp runs/_template/question.card runs/hh/; cp runs/_template/report.md runs/hh/
sed -i '/^hypothesis:/d' runs/hh/report.md
sed -i '/^## Open questions$/a hypothesis: n/a' runs/hh/report.md
git add -A; git commit -q -m x
expect fence-hypothesis-heading fail 'FAIL.hypothesis-line' -- guard/run fence origin/main HEAD

git switch -q -c pr/legacy-card origin/main; mkdir -p runs/legacy
cp runs/_template/question.card runs/legacy/
sed -i '/^setting:/d' runs/legacy/question.card
git add -A; git commit -q -m x
git push -q origin pr/legacy-card:refs/heads/pr-legacy-card
git switch -q -c pr/legacy-report origin/pr-legacy-card
cp runs/_template/report.md runs/legacy/
git add -A; git commit -q -m x
expect fence-legacy-setting ok 'PASS.setting-key' -- guard/run fence origin/pr-legacy-card HEAD
expect fence-legacy-hypothesis ok 'PASS.hypothesis-line' -- guard/run fence origin/pr-legacy-card HEAD

git switch -q -c pr/ledger origin/main; mkdir -p runs/lg; cp runs/_template/question.card runs/lg/
printf 'id\tts\tfield\tvalue\twhy\tevidence\nx1\tt\thost\tskynet\tw\te\n' > runs/lg/execution.tsv; git add -A; git commit -q -m x
expect fence-ledger-added ok 'PASS.execution-ledger' -- guard/run fence origin/main HEAD
expect fence-history-no-report ok 'PASS.execution-history' -- guard/run fence origin/main HEAD
cp runs/_template/report.md runs/lg/report.md; git add -A; git commit -q -m x
expect fence-history-placeholder fail 'FAIL.execution-history.*runs/lg/report.md' -- guard/run fence origin/main HEAD
sed -i 's/^<one line per execution.tsv row.*/`x1` ran on skynet/' runs/lg/report.md; git commit -q -am x
expect fence-history-cited ok 'PASS.execution-history' -- guard/run fence origin/main HEAD
git push -q origin pr/ledger:refs/heads/pr-ledger
git switch -q -c pr/ledger-append origin/pr-ledger; printf 'x2\tt\tgpus\t0,1\tw\te\n' >> runs/lg/execution.tsv; echo "A note." >> runs/lg/report.md; git commit -q -am x
expect fence-ledger-appended fail 'PASS.execution-ledger' -- guard/run fence origin/pr-ledger HEAD
expect fence-history-uncited fail 'FAIL.execution-history.*runs/lg/report.md' -- guard/run fence origin/pr-ledger HEAD
sed -i '/^`x1` ran on skynet$/a `x2` took GPUs 0,1' runs/lg/report.md; git commit -q -am x
expect fence-history-appended ok 'PASS.execution-history' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-rewrite origin/pr-ledger; sed -i 's/skynet/login1/' runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-rewritten fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(rows changed or removed\)' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-delete origin/pr-ledger; git rm -q runs/lg/execution.tsv; git commit -q -m x
expect fence-ledger-deleted fail 'FAIL.execution-ledger.*runs/lg/execution.tsv \(deleted\)' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/ledger-design origin/pr-ledger; printf 'x2\tt\tsetting\tfloat64\tw\te\n' >> runs/lg/execution.tsv; git commit -q -am x
expect fence-ledger-design fail 'FAIL.execution-ledger.*runs/lg/execution.tsv$' -- guard/run fence origin/pr-ledger HEAD
git switch -q -c pr/legacy-ledger origin/main; mkdir -p runs/ll; printf 'bad header\nx1\tt\tsetting\tx\tw\te\n' > runs/ll/execution.tsv; git add -A; git commit -q -m x
expect fence-ledger-bad-header fail 'FAIL.execution-ledger.*runs/ll/execution.tsv$' -- guard/run fence origin/main HEAD
git push -q origin pr/legacy-ledger:refs/heads/pr-legacy-ledger
git switch -q -c pr/legacy-ledger-edit origin/pr-legacy-ledger; printf 'x2\tt\tgpus\t0\tw\te\n' >> runs/ll/execution.tsv; git commit -q -am x
expect fence-legacy-ledger ok 'PASS.execution-ledger' -- guard/run fence origin/pr-legacy-ledger HEAD

git switch -q -c pr/old-report origin/main; mkdir -p runs/old
cp runs/_template/question.card runs/_template/report.md runs/old/
sed -i '/^hypothesis:/d' runs/old/report.md
git add -A; git commit -q -m x
git push -q origin pr/old-report:refs/heads/pr-old-report
git switch -q -c pr/old-report-edit origin/pr-old-report
echo "A later note." >> runs/old/report.md; git commit -q -am x
expect fence-legacy-report-modified ok 'PASS.hypothesis-line' -- guard/run fence origin/pr-old-report HEAD

echo "== init --update"
git -C "$tmp/proj" fetch -q origin
expect update-noop ok 'already current' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt3"
expect init-refuses-guarded fail 'already guarded' -- "$guard" init "$tmp/proj" --worktree "$tmp/wt6"
expect version-current ok '^current$' -- "$guard" version
expect version-release ok 'guard schema [0-9]+, release [^,]+, installed from ' -- "$guard" version
good=$(git rev-parse origin/main)
set_version() {  # set_version <sed expression>: commit an edited guard/VERSION straight to main
  git switch -q --detach origin/main; sed -i "$1" guard/VERSION; git commit -q -am "version: $1"
  git push -q origin HEAD:main; git -C "$tmp/proj" fetch -q origin
}
set_version 's/^installer: .*/installer: 0000000000000000000000000000000000000000/'
expect version-harness-older ok '^harness older' -- "$guard" version
expect update-refuses-unknown-installer fail 'does not contain the one that installed' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
expect update-force ok 'guard/VERSION' -- "$guard" init "$tmp/proj" --update --force --worktree "$tmp/wt6"
expect update-force-records ok "^installer: $(git -C "$here" rev-parse HEAD)$" -- grep '^installer:' "$tmp/wt6/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt6"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
set_version 's/^schema: .*/schema: 99/'
expect update-refuses-newer-schema fail 'schema 99' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
set_version '/^schema:/d'
expect version-project-older ok '^project older' -- "$guard" version
expect update-schema-1 ok 'guard/VERSION' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt6"
expect update-writes-schema ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$tmp/wt6/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt6"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
set_version '/^schema:/d; /^release:/d'
expect version-no-release-stamp ok "^project older, installed before release stamps; run guard init $tmp/[^ ]+ --update$" -- "$guard" version
expect version-no-release-header ok 'guard schema 1, installed from ' -- "$guard" version
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin
old_rev=$(git -C "$here" rev-parse "$(git -C "$here" log -1 --format=%H -S'hypothesis: n/a' -- templates/runs/_template/report.md)^")
old_install() {  # old_install: commit to main the guard files as the harness at $old_rev installed them
  git switch -q --detach "$good"
  for f in guard/bin/preflight.sh guard/bin/ripples.sh guard/bin/manifest.sh guard/bin/fence.sh guard/run guard/README.md \
    runs/_template/question.card runs/_template/report.md; do git -C "$here" show "$old_rev:templates/$f" > "$f"; done
  git -C "$here" show "$old_rev:templates/github/workflows/guard-fence.yml" > .github/workflows/guard-fence.yml
  sed -i "s/^installer: .*/installer: $old_rev/; /^schema:/d" guard/VERSION
}
old_install
sed -i 's/-le 150 \]/-le 200 ]/' guard/bin/fence.sh
sed -i 's/^Question: .*/Question: our wording/' runs/_template/report.md
echo "custom_note: leave this" >> runs/_template/question.card
git commit -q -am "an older install with site edits"; git push -q -f origin HEAD:main; git -C "$tmp/proj" fetch -q origin
expect version-old-install ok '^project older' -- "$guard" version
expect path-runs-project-copy ok 'PASS.guard-untouched' -- "$guard" fence origin/main HEAD
expect path-not-harness-copy fail - -- bash -c '"$1" fence origin/main HEAD | grep -q hypothesis-line' _ "$guard"
git init -q "$tmp/plain"
expect path-refuses-unguarded fail 'runs inside a guarded project' -- bash -c 'cd "$1" && "$2" ripples runs/x' _ "$tmp/plain" "$guard"
expect update-from-old ok 'guard/bin/fence.sh' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt7"
expect update-reports-edit ok '^  guard/bin/fence.sh$' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt8" --branch guard/again
expect update-merged-new-rule ok 'hypothesis-line' -- cat "$tmp/wt7/guard/bin/fence.sh"
expect update-kept-site-edit ok '-le 200 \]' -- cat "$tmp/wt7/guard/bin/fence.sh"
expect update-scripts-current ok '^$' -- git -C "$tmp/wt7" diff --no-index --stat "$here/templates/guard/bin/preflight.sh" guard/bin/preflight.sh
expect update-run-executable ok - -- test -x "$tmp/wt7/guard/run"
expect update-workflow-fixed ok 'x-access-token' -- cat "$tmp/wt7/.github/workflows/guard-fence.yml"
expect update-keeps-card ok '^account: gom$' -- cat "$tmp/wt7/guard/budget.card"
expect update-adds-key ok '^max_handled_failures: 2$' -- cat "$tmp/wt7/guard/budget.card"
expect update-skips-removed-key fail - -- grep '^explore_max_nodes' "$tmp/wt7/guard/budget.card"
expect update-filled-setting ok '^setting: <dataset, geometry, code, and pinned commits; hosts, GPUs and memory limits go in execution.tsv>$' -- grep '^setting:' "$tmp/wt7/runs/_template/question.card"
expect update-adds-envelope-keys ok '^deadline: <' -- grep '^deadline:' "$tmp/wt7/runs/_template/question.card"
expect update-adds-run-defaults ok '^default_run_gpu_hours: 0$' -- grep '^default_run_gpu_hours:' "$tmp/wt7/guard/budget.card"
expect update-adds-launch ok '^launch_hosts: none$' -- grep '^launch_hosts:' "$tmp/wt7/guard/budget.card"
expect update-adds-merge-policy ok '^merge_policy: autonomous$' -- grep '^merge_policy:' "$tmp/wt7/guard/budget.card"
expect update-adds-launch-script ok 'cmd_supervise' -- cat "$tmp/wt7/guard/bin/launch.sh"
expect update-filled-note ok '^custom_note: leave this$' -- grep '^custom_note:' "$tmp/wt7/runs/_template/question.card"
expect update-filled-hypothesis ok '^hypothesis: n/a$' -- sed -n 4p "$tmp/wt7/runs/_template/report.md"
expect update-kept-question ok '^Question: our wording$' -- grep '^Question:' "$tmp/wt7/runs/_template/report.md"
expect update-writes-version ok "^schema: $(cat "$here/SCHEMA")$" -- grep '^schema:' "$tmp/wt7/guard/VERSION"
git -C "$tmp/proj" worktree remove --force "$tmp/wt7"; git -C "$tmp/proj" branch -q -D guard/update
git -C "$tmp/proj" worktree remove --force "$tmp/wt8"; git -C "$tmp/proj" branch -q -D guard/again

old_install
sed -i 's/max_ch=$(need max_core_hours)/max_ch=$(need max_core_hours)  # site/' guard/bin/preflight.sh
git commit -q -am "an older install with an overlapping edit"; git push -q -f origin HEAD:main; git -C "$tmp/proj" fetch -q origin
expect update-conflicts fail '^CONFLICTS' -- "$guard" init "$tmp/proj" --update --worktree "$tmp/wt7"
expect update-conflict-named ok '^<<<<<<< guard/bin/preflight.sh \(yours\)$' -- grep '^<<<<<<<' "$tmp/wt7/guard/bin/preflight.sh"
expect update-conflict-others-clean ok 'hypothesis-line' -- cat "$tmp/wt7/guard/bin/fence.sh"
git -C "$tmp/wt7" push -q origin guard/update:refs/heads/conflicted
git fetch -q origin; git switch -q --detach "$good"
expect run-refuses-conflicted fail 'unresolved conflicts or does not parse' -- env HPC_GUARD_REF=origin/conflicted guard/run preflight "$R" job.sh
expect run-names-schema fail "guard is schema $(cat "$here/SCHEMA")" -- env HPC_GUARD_REF=origin/conflicted guard/run frobnicate
git -C "$tmp/proj" worktree remove --force "$tmp/wt7"; git -C "$tmp/proj" branch -q -D guard/update
git push -q -f origin "$good":main; git -C "$tmp/proj" fetch -q origin

expect skill-states-schema ok - -- grep -q "describes guard schema $(cat "$here/SCHEMA")\." "$here/skills/safe-autonomous-hpc-science/SKILL.md"
expect contract-names-required ok - -- bash -c 'for k in $(grep "<" "$1/templates/guard/budget.card" | cut -d: -f1); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect contract-names-every-key ok - -- bash -c 'for k in $(cut -d: -f1 "$1/templates/guard/budget.card"); do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"
expect envelope-vocabulary-pinned ok - -- bash -c 'a=$(sed -n "s/^readonly ENVELOPE_FIELDS=//p" "$1/templates/guard/bin/launch.sh"); b=$(sed -n "s/^fields=//p" "$1/templates/guard/bin/fence.sh"); [ -n "$a" ] && [ "$a" = "$b" ]' _ "$here"
expect contract-names-check-names ok - -- bash -c 'for k in gpu-hours host-supervision host-memory host-strays host-log-errors execution-within-envelope execution-ledger execution-history card-lineage; do grep -q "\`$k\`" "$1/docs/compatibility.md" || { echo "$k"; exit 1; }; done' _ "$here"

echo "== doctor"
D=$tmp/doc
git init -q --bare -b main "$D.git"; git clone -q "$D.git" "$D" 2>/dev/null
git -C "$D" checkout -q -b main; echo "# d" > "$D/README.md"; git -C "$D" add -A; git -C "$D" commit -q -m init
git -C "$D" push -q -u origin main; git -C "$D" remote set-head origin -a >/dev/null
"$guard" init "$D" --worktree "$D.wt" >/dev/null 2>&1
git -C "$D" update-ref refs/remotes/origin/main guard/init
git -C "$D" remote set-url origin https://github.com/lab/proj.git
mkdir -p "$tmp/home/.agents/skills" "$tmp/home-bare"
for s in "$here"/skills/*/; do ln -s "${s%/}" "$tmp/home/.agents/skills/"; done
setup=(MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false MOCK_GH_RULES=$'pull_request\ncheck fence'
  "MOCK_GH_RUNS=success 2026-10-01T12:00:00Z https://github.com/lab/proj/actions/runs/1" MOCK_SACCTMGR_ASSOC='|cpu=600000')
doctor() { env -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK HOME="$tmp/home" "${setup[@]}" "$@" "$guard" doctor "$D"; }
expect doctor-placeholders fail '^FAIL  guard/budget.card on origin/main still has placeholders: account start_date stop_date' -- doctor
expect doctor-placeholder-account fail '^FAIL  guard/budget.card on origin/main sets no account$' -- doctor
expect doctor-remedy-links-readme fail '^      Replace each <placeholder> .*: https://github.com/0jrm/harness4research#3-fill-in-the-guard-and-merge-it$' -- doctor
git -C "$tmp/proj" show "$good:guard/budget.card" > "$D.wt/guard/budget.card"
git -C "$D.wt" commit -q -am "chore(guard): set budget"; git -C "$D" update-ref refs/remotes/origin/main guard/init
expect doctor-clean-card ok '^pass  guard/budget.card on origin/main has no placeholders$' -- doctor
expect doctor-all-pass ok '^11 passed, 0 failed, 0 cannot check from here$' -- doctor
expect doctor-version ok '^pass  guard schema [0-9]+ \(release .*\) against harness schema [0-9]+ .*: current$' -- doctor
expect doctor-version-once ok - -- bash -c '! grep -E "\(release ([^ )]+)\1\)" <<<"$1"' _ "$(doctor)"
expect doctor-workflow ok '^pass  .github/workflows/guard-fence.yml on origin/main defines guard-fence / fence$' -- doctor
doctor > "$tmp/doctor-out"
expect doctor-no-colour-in-pipe fail - -- grep -q $'\e' "$tmp/doctor-out"
expect doctor-no-gh ok '^cannot check from here  whether guard-fence / fence has run on GitHub: gh is not on PATH$' -- doctor PATH="$(path_without gh)"
expect doctor-cannot-is-not-pass ok '^9 passed, 0 failed, 2 cannot check from here$' -- doctor PATH="$(path_without gh)"
expect doctor-gh-logged-out ok '^cannot check from here  whether main has an active ruleset requiring guard-fence / fence: gh is not logged in$' -- doctor MOCK_GH_TOKEN=
expect doctor-not-github ok '^cannot check from here  .*: origin is not a github.com remote$' -- \
  doctor GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="$D.git"
expect doctor-ruleset ok '^pass  main has an active ruleset requiring a pull request and guard-fence / fence$' -- doctor
expect doctor-ruleset-full-name ok '^pass  main has an active ruleset' -- doctor MOCK_GH_RULES=$'pull_request\ncheck guard-fence / fence'
expect doctor-ruleset-no-check fail '^FAIL  main has no active rule requiring guard-fence / fence$' -- doctor MOCK_GH_RULES=$'pull_request\ncheck lint'
expect doctor-ruleset-none fail '^FAIL  main has no active rule requiring a pull request and guard-fence / fence$' -- doctor MOCK_GH_RULES=
expect doctor-ruleset-free-plan fail '^FAIL  GitHub offers no rulesets on lab/proj: Upgrade to GitHub Pro' -- \
  doctor MOCK_GH_RULES='!Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
expect doctor-fence-never-ran fail '^FAIL  guard-fence / fence has never completed a run on GitHub$' -- doctor MOCK_GH_RUNS=
expect doctor-fence-failure-ran ok '^pass  guard-fence / fence has run on GitHub \(last completed run: failure, ' -- doctor "MOCK_GH_RUNS=failure 2026-10-01T12:00:00Z https://x/1"
expect doctor-fence-broken fail '^FAIL  guard-fence / fence last completed run ended startup_failure' -- doctor "MOCK_GH_RUNS=startup_failure 2026-10-01T12:00:00Z https://x/1"
expect doctor-ssh fail '^FAIL  SSH_AUTH_SOCK is set in this shell' -- doctor SSH_AUTH_SOCK=/tmp/agent.sock
expect doctor-classic-token fail '^FAIL  the GitHub token in this shell is a classic or OAuth token with scopes repo, workflow,' -- \
  doctor MOCK_GH_TOKEN=gho_x MOCK_GH_SCOPES='repo, workflow'
expect doctor-admin fail '^FAIL  the GitHub login in this shell administers lab/proj' -- doctor MOCK_GH_ADMIN=true
expect doctor-no-token ok '^pass  no GitHub token in this shell' -- doctor MOCK_GH_TOKEN=
expect doctor-cap ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- doctor
expect doctor-user-cap ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\ntester|cpu=600000'
expect doctor-no-cap fail '^FAIL  Slurm sets no GrpTRESMins cap on account gom$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\ntester|'
expect doctor-other-user-cap fail '^FAIL  Slurm sets no GrpTRESMins cap on account gom$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\nalice|cpu=100\ntester|'
expect doctor-no-user-var ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- env -u USER -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK HOME="$tmp/home" "${setup[@]}" "$guard" doctor "$D"
expect doctor-no-account fail '^FAIL  Slurm has no account gom$' -- doctor MOCK_SACCTMGR_ASSOC=
expect doctor-no-sacctmgr ok '^cannot check from here  whether Slurm caps account gom: sacctmgr is not on this host$' -- doctor PATH="$(path_without sacctmgr)"
expect doctor-skills-missing fail '^FAIL  skills in ~/.agents/skills do not link to this harness: present \(missing\)' -- doctor HOME="$tmp/home-bare"
mkdir -p "$tmp/home/.claude"
expect doctor-skills-claude fail '^FAIL  skills in ~/.claude/skills do not link to this harness' -- doctor
rmdir "$tmp/home/.claude"
expect doctor-unguarded fail '^FAIL  guard/run is not on origin/main$' -- env HOME="$tmp/home" "$guard" doctor "$tmp/agents"
expect doctor-not-a-repo fail 'is not a git repository' -- "$guard" doctor "$tmp/home"
git -C "$D" status --porcelain > "$tmp/doctor-status"; touch "$tmp/doctor-before"
doctor >/dev/null; doctor MOCK_GH_TOKEN= SSH_AUTH_SOCK=/x >/dev/null; doctor PATH="$(path_without gh)" >/dev/null
expect doctor-writes-nothing ok '^$' -- find "$D" "$D.wt" "$tmp/home" -newer "$tmp/doctor-before"
expect doctor-status-unchanged ok '^$' -- bash -c 'git -C "$1" status --porcelain | diff - "$2"' _ "$D" "$tmp/doctor-status"
cd "$tmp/wt" || exit 1

echo "== config"
expect config-defaults ok '^reviewer: proprietary$' -- "$guard" config
expect config-default-rounds ok '^2$' -- "$guard" config get review_rounds
expect config-unset ok '^reviewer_cmd_local: <unset>$' -- "$guard" config list
expect config-set ok '^reviewer: local$' -- "$guard" config set reviewer local
expect config-get ok '^local$' -- "$guard" config get reviewer
expect config-set-command ok '^reviewer_cmd_local: codex exec --oss -m "qwen3: 32b"$' -- "$guard" config set reviewer_cmd_local 'codex exec --oss -m "qwen3: 32b"'
expect config-set-replaces ok '^reviewer: proprietary$' -- "$guard" config set reviewer proprietary
expect config-one-line-per-key ok '^1$' -- grep -c '^reviewer:' "$XDG_CONFIG_HOME/guard/config"
expect config-clear ok '^$' -- bash -c '"$1" config set reviewer_cmd_local "" >/dev/null && "$1" config get reviewer_cmd_local' _ "$guard"
expect config-bad-value fail "^guard config: reviewer is proprietary or local, not 'cloud'$" -- "$guard" config set reviewer cloud
expect config-bad-rounds fail 'review_rounds is a whole number' -- "$guard" config set review_rounds 0
expect config-bad-policy fail 'merge_policy is autonomous or semi-manual' -- "$guard" config set merge_policy yolo
expect config-unknown-key fail "unknown key 'colour'" -- "$guard" config get colour
expect config-private ok '^600$' -- stat -c %a "$XDG_CONFIG_HOME/guard/config"

echo "== review"
RV=$tmp/rv
git init -q --bare -b main "$RV.git"; git clone -q "$RV.git" "$RV" 2>/dev/null; cd "$RV" || exit 1
git checkout -q -b main; printf 'def add(a, b):\n    return a - b\n' > calc.py; git add -A; git commit -q -m init
git push -q -u origin main; git remote set-head origin -a >/dev/null
git switch -q -c feat/add; echo '# adds two numbers' >> calc.py; git commit -q -am "feat: add"; git push -q -u origin feat/add
cat > "$tmp/fake-reviewer" <<'FAKE'
#!/usr/bin/env bash
echo "call ${GH_TOKEN:-no-token} $*" >> "$FAKE_DIR/calls"
cp .guard-review/prompt.md "$FAKE_DIR/prompt.md"
git push -q origin HEAD:refs/heads/sneaky 2>/dev/null && echo pushed >> "$FAKE_DIR/calls"
case $FAKE_REVIEW in
  fix-once) if grep -q 'a - b' calc.py; then sed -i 's/a - b/a + b/' calc.py; git commit -qam "fix: add adds"; fi
    echo "VERDICT: approve - adds as asked" ;;
  fix-always) date +%s%N >> calc.py; git commit -qam "fix: more"; echo "VERDICT: approve - fixed again" ;;
  dirty) echo junk >> calc.py; echo "VERDICT: approve - fine" ;;
  none) echo "It looks fine to me." ;;
  crash) exit 3 ;;
  *) printf 'Report.\nVERDICT: %s - reason for %s  \n\n' "$FAKE_REVIEW" "$FAKE_REVIEW" ;;
esac
FAKE
chmod +x "$tmp/fake-reviewer"; mkdir -p "$tmp/fake" "$tmp/fakebin"; ln -s "$tmp/fake-reviewer" "$tmp/fakebin/codex"
pr_json() {  # pr_json [jq filter]: pull request 5 for feat/add at origin's head with one passing check, edited by the filter
  jq -nc --arg sha "$(git rev-parse origin/feat/add)" '{state: "OPEN", isDraft: false, headRefName: "feat/add", headRefOid: $sha,
    baseRefName: "main", isCrossRepository: false,
    statusCheckRollup: [{__typename: "CheckRun", name: "fence", status: "COMPLETED", conclusion: "SUCCESS"}]} | '"${1:-.}"
}
review() {  # review <FAKE_REVIEW> [env...]: guard review 5 with the fake reviewer, fresh call and gh logs
  rm -f "$tmp/fake/calls" "$tmp/gh.log" "$tmp/guard.log"
  env FAKE_REVIEW="$1" FAKE_DIR="$tmp/fake" MOCK_GH_LOG="$tmp/gh.log" MOCK_GUARD_LOG="$tmp/guard.log" MOCK_GH_PR="$(pr_json)" \
    GH_TOKEN=github_pat_agent "${@:2}" "$guard" review 5
}
reviews=$RV/.git/guard/reviews.tsv brief=$RV/.git/guard/briefs/feat-add.md
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-reviewer" >/dev/null
expect review-no-brief fail "no brief for feat/add. Write $brief with the user's request" -- review approve
mkdir -p "$(dirname "$brief")"; printf '## Request (verbatim)\n\n## Plan\nChange add.\n' > "$brief"
expect review-empty-request fail "the '## Request \(verbatim\)' section of .* is empty" -- review approve
printf '## Request (verbatim)\nMake add actually add, plz\n\n## Plan\nI fixed the docstring.\n\n## Test command\npython3 -c "import calc"\n' > "$brief"
mkdir -p "$tmp/xdg-local/guard"; echo "reviewer: local" > "$tmp/xdg-local/guard/config"
expect review-local-refuses fail "reviewer is local and no local command is set. Set one: guard config set reviewer_cmd_local 'codex exec --oss -m <model>'$" -- review approve XDG_CONFIG_HOME="$tmp/xdg-local"
expect review-not-open fail 'pull request #5 is merged' -- review approve MOCK_GH_PR="$(pr_json '.state = "MERGED"')"
expect review-approve ok '^VERDICT: approve - reason for approve$' -- review approve
expect review-one-round ok '^1$' -- grep -c '^call' "$tmp/fake/calls"
expect review-recorded ok "	5	$(git rev-parse origin/feat/add)	approve	$tmp/fake-reviewer	reason for approve$" -- tail -n 1 "$reviews"
expect review-tsv-header ok '^ts	pr	head	verdict	reviewer	reason$' -- head -n 1 "$reviews"
expect review-prompt-request ok '^Make add actually add, plz$' -- cat "$tmp/fake/prompt.md"
expect review-prompt-diff ok '^\+# adds two numbers$' -- cat "$tmp/fake/prompt.md"
expect review-prompt-rules ok '^VERDICT: <approve\|changes\|escalate> - <one-line reason>$' -- cat "$tmp/fake/prompt.md"
expect review-no-token ok '^call no-token Read .guard-review/prompt.md' -- cat "$tmp/fake/calls"
expect review-reviewer-cannot-push ok '^$' -- git ls-remote origin sneaky
expect review-comment ok '^pr comment 5 --body guard review: approve at [0-9a-f]{7}\. reason for approve$' -- cat "$tmp/gh.log"
expect review-comment-no-brief fail - -- grep -q 'plz' "$tmp/gh.log"
expect review-approve-queues-nothing fail - -- test -e "$tmp/guard.log"
expect review-worktree-removed ok '^1$' -- bash -c 'git worktree list | wc -l'
old_head=$(git rev-parse origin/feat/add)
expect review-fix-approves ok '^VERDICT: approve - adds as asked$' -- review fix-once
expect review-fix-two-rounds ok '^2$' -- grep -c '^call' "$tmp/fake/calls"
expect review-fix-pushed ok 'return a \+ b' -- git show origin/feat/add:calc.py
expect review-fix-one-commit ok '^fix: add adds$' -- git log --format=%s -1 origin/feat/add
expect review-fix-recorded-at-new-head ok "	5	$(git rev-parse origin/feat/add)	approve	" -- tail -n 1 "$reviews"
expect review-fix-not-old-head fail - -- bash -c 'tail -n 1 "$1" | grep -q "$2"' _ "$reviews" "$old_head"
expect review-still-fixing fail '^VERDICT: changes - the reviewer was still committing fixes after 2 rounds$' -- review fix-always
expect review-still-fixing-queues ok '^check$' -- sed -n 4p "$tmp/guard.log"
git push -q -f origin "$old_head:refs/heads/feat/add"; git fetch -q origin
expect review-changes fail '^VERDICT: changes - reason for changes$' -- review changes
expect review-changes-queue ok "^needs-you add --kind check --title Review of PR #5 asks for changes --why reason for changes --path $RV/.git/guard/reviews/5-[0-9a-f]{12}-r1.txt --path $brief --source guard review  needs-you show n1  $" -- \
  bash -c 'tr "\n" " " < "$1"' _ "$tmp/guard.log"
expect review-changes-block fail '^🩺 n1 · stub$' -- review changes
expect review-changes-recorded ok '	changes	.*	reason for changes$' -- tail -n 1 "$reviews"
expect review-escalate fail '^VERDICT: escalate - reason for escalate$' -- review escalate
expect review-escalate-queue ok '^approve$' -- sed -n 4p "$tmp/guard.log"
expect review-no-verdict fail "^VERDICT: escalate - the reviewer's last line is not a VERDICT line$" -- review none
expect review-crash fail '^VERDICT: escalate - the reviewer command exited 3$' -- review crash
expect review-dirty-discarded ok 'uncommitted edits, and they are discarded' -- review dirty
expect review-dirty-not-pushed ok "^$old_head	" -- git ls-remote origin refs/heads/feat/add
expect review-strict-verdict fail 'not a VERDICT line' -- review 'approve?'
"$guard" config set reviewer_cmd_proprietary "" >/dev/null
review approve PATH="$tmp/fakebin:$(path_without claude)" >/dev/null 2>&1
expect review-default-reviewer ok '^call no-token exec --sandbox danger-full-access Read ' -- cat "$tmp/fake/calls"
mkdir -p "$tmp/fakeclaude"; cat > "$tmp/fakeclaude/claude" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" > "\$FAKE_DIR/argv"
exec "$tmp/fake-reviewer" "\$@"
FAKE
chmod +x "$tmp/fakeclaude/claude"; review approve PATH="$tmp/fakeclaude:$PATH" >/dev/null 2>&1
expect review-default-claude-argv ok '^-p\|--permission-mode\|acceptEdits\|--allowedTools=Bash\|Read \.guard-review/prompt\.md and follow it\. End your reply with the VERDICT line it describes\.$' -- \
  paste -sd'|' "$tmp/fake/argv"
expect review-moved-head fail "origin/feat/add is not at the pull request's head" -- review approve MOCK_GH_PR="$(pr_json '.headRefOid = "0000000"')"
"$guard" config set reviewer_cmd_proprietary "$tmp/fake-reviewer" >/dev/null

echo "== merge"
gate=(MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false "MOCK_GH_RULES=pull_request
check guard-fence / fence" MOCK_GH_LOG="$tmp/gh.log" MOCK_GUARD_LOG="$tmp/guard.log")
merge() {  # merge [env...]: guard merge 5 here with every gate open, unless an assignment changes one
  rm -f "$tmp/gh.log" "$tmp/guard.log"
  env -u GH_TOKEN -u GITHUB_TOKEN "${gate[@]}" MOCK_GH_PR="$(pr_json)" "$@" "$guard" merge 5
}
on_github=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0=https://github.com/lab/proj.git)
review approve >/dev/null 2>&1
expect merge-unguarded ok '^✓ Squashed and merged pull request lab/proj#5$' -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-unguarded-policy ok "^pass  merge_policy is autonomous in $tmp/xdg/guard/config$" -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-squash-pinned ok "^pr merge 5 --squash --match-head-commit $(git rev-parse origin/feat/add)$" -- grep '^pr merge' "$tmp/gh.log"
expect merge-never-admin fail - -- grep -q -- --admin "$tmp/gh.log"
expect merge-not-github fail '^FAIL  cannot tell whether the gh login administers the repository: origin is not a github.com remote$' -- merge
"$guard" config set merge_policy semi-manual >/dev/null
expect merge-config-semi-manual fail "^FAIL  merge_policy is semi-manual in $tmp/xdg/guard/config, so a human merges$" -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
expect merge-config-remedy fail '^      A human merges it, or runs guard config set merge_policy autonomous\.$' -- merge "${on_github[@]}" MOCK_GH_RULES=pull_request
"$guard" config set merge_policy autonomous >/dev/null

cd "$D" || exit 1
git update-ref refs/remotes/origin/feat/add "$(git rev-parse guard/init)"; head5=$(git rev-parse origin/feat/add)
approve_at() { mkdir -p .git/guard; printf 'ts\tpr\thead\tverdict\treviewer\treason\n2026-10-07T00:00:00Z\t5\t%s\t%s\tclaude\tok\n' "$1" "${2:-approve}" > .git/guard/reviews.tsv; }
approve_at "$head5"
expect merge-ok ok '^✓ Squashed and merged pull request lab/proj#5$' -- merge
expect merge-ok-call ok "^pr merge 5 --squash --match-head-commit $head5$" -- grep '^pr merge' "$tmp/gh.log"
expect merge-ok-queues-nothing fail - -- test -e "$tmp/guard.log"
expect merge-card-default ok '^pass  merge_policy is autonomous in guard/budget.card on origin/main$' -- merge
expect merge-fence-required ok '^pass  main has an active ruleset requiring a pull request and guard-fence / fence$' -- merge
expect merge-already-merged ok '^Pull request #5 is already merged\.$' -- merge MOCK_GH_PR="$(pr_json '.state = "MERGED"')"
expect merge-admin fail '^FAIL  the gh login in this shell administers lab/proj, so a merge here could bypass the ruleset$' -- merge MOCK_GH_ADMIN=true
expect merge-admin-no-call fail - -- grep -q '^pr merge' "$tmp/gh.log"
expect merge-admin-remedy fail '^      Run agents with a token that has no Administration permission: https://github.com/0jrm/harness4research/blob/main/docs/enforceable.md#5-give-agents-weaker-credentials$' -- merge MOCK_GH_ADMIN=true
expect merge-admin-kind ok '^run$' -- sed -n 4p "$tmp/guard.log"
expect merge-admin-command ok '^gh pr merge 5 --squash$' -- cat "$tmp/guard.log"
expect merge-admin-cd ok "^cd $D$" -- cat "$tmp/guard.log"
expect merge-admin-block fail '^🩺 n1 · stub$' -- merge MOCK_GH_ADMIN=true
expect merge-logged-out fail '^FAIL  cannot tell whether the gh login in this shell administers lab/proj: To get started with GitHub CLI' -- merge MOCK_GH_TOKEN=
expect merge-no-ruleset fail '^FAIL  main has no active rule requiring a pull request and guard-fence / fence$' -- merge MOCK_GH_RULES=
expect merge-no-fence-rule fail '^FAIL  main has no active rule requiring guard-fence / fence$' -- merge MOCK_GH_RULES=pull_request
expect merge-ruleset-unreadable fail '^FAIL  cannot tell whether main has an active ruleset requiring a pull request and guard-fence / fence: Upgrade to GitHub Pro' -- \
  merge MOCK_GH_RULES='!Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
expect merge-draft fail '^FAIL  pull request #5 is a draft$' -- merge MOCK_GH_PR="$(pr_json '.isDraft = true')"
expect merge-draft-kind ok '^approve$' -- sed -n 4p "$tmp/guard.log"
expect merge-closed fail '^FAIL  pull request #5 is closed$' -- merge MOCK_GH_PR="$(pr_json '.state = "CLOSED"')"
expect merge-failed-check fail '^FAIL  not every check passed: tests \(failure\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "tests", status: "COMPLETED", conclusion: "FAILURE"}]')"
expect merge-pending-check fail '^FAIL  not every check passed: tests \(in_progress\), ci/legacy \(pending\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "tests", status: "IN_PROGRESS", conclusion: ""}, {__typename: "StatusContext", context: "ci/legacy", state: "PENDING"}]')"
expect merge-skipped-check ok '^pass  every check passed \(3\)$' -- \
  merge MOCK_GH_PR="$(pr_json '.statusCheckRollup += [{__typename: "CheckRun", name: "docs", status: "COMPLETED", conclusion: "SKIPPED"}, {__typename: "StatusContext", context: "ci/legacy", state: "SUCCESS"}]')"
expect merge-no-checks fail '^FAIL  no checks ran on pull request #5, so nothing tested it$' -- merge MOCK_GH_PR="$(pr_json '.statusCheckRollup = []')"
approve_at "$(git rev-parse origin/main~1)"
expect merge-old-head fail "^FAIL  guard review approved $(git rev-parse --short=7 origin/main~1), and the head is now ${head5:0:7}$" -- merge
approve_at "$head5" changes
expect merge-review-changes fail "^FAIL  the last guard review of pull request #5 says changes at ${head5:0:7}$" -- merge
rm .git/guard/reviews.tsv
expect merge-no-review fail '^FAIL  guard review has no verdict for pull request #5$' -- merge
approve_at "$head5"
merge MOCK_GH_ADMIN=true MOCK_GH_PR="$(pr_json '.isDraft = true')" >/dev/null
expect merge-one-item ok '^1$' -- grep -cx add "$tmp/guard.log"
expect merge-why-lists-all ok '^autonomous merge refused: the gh login in this shell administers lab/proj, .*; pull request #5 is a draft\.$' -- cat "$tmp/guard.log"
expect merge-gh-refuses fail '^gh refused the merge: GraphQL: Head branch was modified' -- merge MOCK_GH_MERGE='GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)'
expect merge-gh-refuses-queued ok '^gh pr merge refused: GraphQL: Head branch was modified' -- cat "$tmp/guard.log"
git -C "$D.wt" switch -q -c semi guard/init; echo "merge_policy: semi-manual" >> "$D.wt/guard/budget.card"
git -C "$D.wt" commit -q -am "semi-manual"; git update-ref refs/remotes/origin/main semi
expect merge-semi-manual fail '^FAIL  merge_policy is semi-manual in guard/budget.card on origin/main, so a human merges$' -- merge
expect merge-semi-manual-queued ok '^Merge PR #5 \(autonomous merge refused\)$' -- cat "$tmp/guard.log"
git update-ref refs/remotes/origin/main guard/init
cd "$tmp/wt" || exit 1

echo "== upgrade from each supported release"
# old_project <tag> <dir>: a project guarded by the harness at <tag>, with the budget filled in and merged to main.
old_project() {
  local tag=$1 p=$2 h=$tmp/h-$1
  [ -d "$h" ] || { git clone -q --shared --no-checkout "$here" "$h"; git -C "$h" checkout -q --detach "$tag"; }
  git init -q --bare -b main "$p.git"; git clone -q "$p.git" "$p" 2>/dev/null
  git -C "$p" checkout -q -b main; echo "# p" > "$p/README.md"; git -C "$p" add -A; git -C "$p" commit -q -m init
  git -C "$p" push -q -u origin main; git -C "$p" remote set-head origin -a >/dev/null
  "$h/bin/guard" init "$p" --worktree "$p.wt" >/dev/null 2>&1
  git -C "$tmp/proj" show "$good:guard/budget.card" > "$p.wt/guard/budget.card"
  printf 'runs/*/checks/*\n' > "$p.wt/guard/watch.list"
}
names() { { guard/run ripples "$1"; guard/run fence origin/main HEAD; } 2>/dev/null | cut -f2 | sort -u; }
placeholders() { grep '<' "$1" | cut -d: -f1 | sort; }
upgrade_from() {
  local tag=$1 p=$tmp/p-$1 c=compat-$1 old_names
  old_project "$tag" "$p"; cd "$p.wt" || return
  sed -i 's/^exec sbatch "\$@"/exec sbatch --qos=normal "$@"/' guard/bin/preflight.sh
  sed -i 's/runs-on: ubuntu-latest/runs-on: self-hosted/' .github/workflows/guard-fence.yml
  mkdir -p runs/legacy; cp runs/_template/question.card runs/_template/report.md runs/legacy/
  git add -A; git commit -q -m "budget, site edits, and a legacy run"; git push -q origin HEAD:main; git fetch -q origin
  old_names=$(names runs/legacy)
  expect "$c-update" ok 'Changed:' -- "$guard" init "$p" --update --worktree "$p.up"
  expect "$c-card-kept" ok '^account: gom$' -- cat "$p.up/guard/budget.card"
  if git -C "$here" show "$tag:templates/guard/budget.card" | grep -q '^max_handled_failures:'; then
    expect "$c-no-readded-key" fail - -- grep '^max_handled_failures:' "$p.up/guard/budget.card"
  else expect "$c-key-added" ok '^max_handled_failures: 2$' -- cat "$p.up/guard/budget.card"; fi
  expect "$c-port-kept" ok 'exec sbatch --qos=normal' -- cat "$p.up/guard/bin/preflight.sh"
  expect "$c-workflow-fixed" ok 'x-access-token' -- cat "$p.up/.github/workflows/guard-fence.yml"
  expect "$c-workflow-edit-kept" ok 'runs-on: self-hosted' -- cat "$p.up/.github/workflows/guard-fence.yml"
  expect "$c-no-conflicts" fail - -- grep -rlE '^(<{7}|>{7}) ' "$p.up/guard" "$p.up/.github"
  expect "$c-schema" ok "^schema: $(cat "$here/SCHEMA")$" -- cat "$p.up/guard/VERSION"
  expect "$c-merge-policy" ok '^merge_policy: autonomous$' -- cat "$p.up/guard/budget.card"
  expect "$c-lineage-keys" ok '^spawned_from: <' -- grep -A1 '^supersedes: <' "$p.up/runs/_template/question.card"
  git -C "$p.up" push -q origin guard/update:main; git fetch -q origin; git switch -q -c agent origin/main
  mkdir -p runs/r; cp runs/_template/question.card runs/r/
  printf '#!/bin/bash\n#SBATCH --time=01:00:00\n#SBATCH --nodes=1\n' > job.sh; git add -A; git commit -q -m "run: r"
  expect "$c-preflight-ok" ok 'SBATCH --qos=normal .*--account=gom' -- guard/run preflight runs/r job.sh
  expect "$c-ripples-clean" ok - -- bash -c 'out=$(guard/run ripples runs/r) && ! grep -vE "^(PASS|UNCHECKED)	" <<<"$out"'
  sed -i '/^|---|---|---|---|---|$/a | rows | 3 | `runs/legacy/rows.csv` | 1 | abc1234 |' runs/legacy/report.md
  git commit -q -am "edit the legacy report"
  expect "$c-fence-legacy" ok - -- bash -c 'out=$(guard/run fence origin/main HEAD) && ! grep -q "^FAIL" <<<"$out"'
  expect "$c-check-names-kept" ok '^$' -- comm -23 <(echo "$old_names") <(names runs/legacy)
  expect "$c-no-new-required" ok '^$' -- comm -23 <(placeholders "$here/templates/guard/budget.card") \
    <(git -C "$here" show "$tag:templates/guard/budget.card" | placeholders /dev/stdin)
  git switch -q --detach origin/main; git revert --no-edit HEAD >/dev/null; git push -q origin HEAD:main; git fetch -q origin
  expect "$c-rollback" ok '^$' -- diff <(echo "$old_names") <(names runs/legacy)
  if git -C "$here" show "$tag:templates/guard/bin/ripples.sh" | grep -qE '^rows=\$\(sacct'; then
    old_project "$tag" "$p-sacct"; cd "$p-sacct.wt" || return
    sed -i 's/^rows=$(sacct \(.*\)JobID,JobName,State/rows=$(sacct \1JobID,JobName%60,State/' guard/bin/ripples.sh
    git add -A; git commit -q -m "site: longer job names"; git push -q origin HEAD:main
    expect "$c-sacct-port-conflicts" fail '^CONFLICTS' -- "$guard" init "$p-sacct" --update --worktree "$p-sacct.up"
  fi
  cd "$tmp/wt" || return
}
oldest=$(cat "$here/tests/oldest-supported")
releases=$(git -C "$here" tag -l 'v*' --contains "$oldest" --merged HEAD 2>/dev/null)
if [ -z "$releases" ]; then fail=$((fail+1)); echo "FAIL compat-releases (no tags from $oldest; fetch them with git fetch --tags)"; fi
for tag in $releases; do upgrade_from "$tag"; done
echo "== atlas"
mkdir -p "$tmp/atlas"; bash "$here/tests/atlas-fixture.sh" "$tmp/atlas" > "$tmp/atlas/env.sh"
atlas_before=$(git -C "$tmp/atlas/casts-v4-training" status --porcelain)
expect atlas-renders ok '14 runs, 2 branches' -- bash -c '. "$1"; "$2" atlas --out "$3/atlas.html" --json "$3/atlas.json"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-catches-early-compute ok 'started before the card was committed' -- cat "$tmp/atlas/atlas.html"
expect atlas-broken-receipt ok '<li class="rc-broken"><span class="b b-broken">.*</span><span class="rc-kind">commit</span> <code>deadbee</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-drawer-key-diff ok 'max_walltime_minutes 240 to 600' -- cat "$tmp/atlas/atlas.html"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in ("atlas_schema", "behind_base", "generated_at"): print(" ~ ".join(["S", k, str(d[k])]))
for k, v in sorted(d["summary"].items()): print(" ~ ".join(["S", "summary." + k, str(v)]))
for e in d["lineage"]: print(" ~ ".join(["E", e["from"], e["to"], e["kind"], str(e["lineage_inferred"])]))
for w in d["waters"]: print(" ~ ".join(["W", w["name"], w["fence"], ",".join(w["hand"])]))
for r in d["runs"]:
    print(" ~ ".join(["O", r["id"], r["outcome"], r["outcome_detail"], r["severity"]]))
    for x in r["needs_you"]: print(" ~ ".join(["N", r["id"], x]))
    for v in r["violations"]: print(" ~ ".join(["V", r["id"], v]))
    for m in r["manifests"]: print(" ~ ".join(["M", r["id"], m["path"], str(m["committed"])]))
    for e in (r["report"] or {}).get("evidence", []):
        for l in e["links"]: print(" ~ ".join(["L", r["id"], e["claim"], l["kind"], l["value"], l["state"], l["note"]]))' "$tmp/atlas/atlas.json" > "$tmp/atlas/atlas.tsv"
expect atlas-escaped-pipe ok '^L ~ cosine-v2 ~ Max \|dT\| at the casts ~ commit ~ [0-9a-f]{7} ~ ok' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-note ok '^L ~ cosine-v2 ~ Max .* ~ artifact ~ runs/cosine-v2/manifest-4830.txt ~ ok ~ committed at HEAD$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-absent-host ok 'artifact ~ /unity/g9/nobody/casts-v4/pred.nc ~ unknown ~ absolute path not on this host$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-on-disk ok 'artifact ~ runs/cosine-v2/scores.csv ~ local ~ on disk here, not committed$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-job-not-slurm ok 'job ~ skynet interactive, GPU 2 ~ unknown ~ no scheduler job id' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-commit-in-code-repo ok 'commit ~ casts-loader [0-9a-f]{7} ~ ok ~ resolves in casts-loader$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-code-row ok '<dt>Code repositories</dt><dd><code>casts-loader</code> at <code>/' -- cat "$tmp/atlas/atlas.html"
expect atlas-cause-bullet ok '<code>rescore.md</code>: the scorer read the wrong month of casts. Fix: pinned the month' -- cat "$tmp/atlas/atlas.html"
expect atlas-cause-bullet-not-flagged ok - -- bash -c '! grep -q "rescore.md names no root cause" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-verdict-prose ok '^O ~ lr-sweep ~ supported ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-explore-outcome ok '<span class="id">explore-07</span><span class="o o-explore">explore</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-explore-no-card-violations ok - -- bash -c '! grep -Eq "^V ~ explore-07 ~ (question card|job .* started|card edited|no partner)" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-run ok '^V ~ q-batch ~ question card is not committed, so nothing froze it$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-manifest ok '^M ~ q-batch ~ runs/q-batch/manifest-4860.txt ~ False$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-note ok '<span class="id">q-batch</span>.*<span class="f">2 uncommitted</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-uncommitted-cartouche ok 'plus the working tree \(4 uncommitted files\)' -- cat "$tmp/atlas/atlas.html"
expect atlas-schema ok '^S ~ atlas_schema ~ 1$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-generated-at ok '^S ~ generated_at ~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-summary ok '^S ~ summary.needs_you ~ [1-9]' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-severity ok '^O ~ explore-07 ~ explore ~ .* ~ ripple$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-last-event ok '"last_event": \{' -- cat "$tmp/atlas/atlas.json"
expect atlas-frozen-no-record ok '^O ~ skynet-train ~ no scheduler record ~ card frozen, but no manifest' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-not-run-is-rare ok - -- bash -c '! grep -q "^O ~ [^~]* ~ not run ~" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-ledger-by-hand ok '^O ~ hand-run ~ recorded by hand ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-incident-by-hand ok '^O ~ incident-only ~ recorded by hand ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-host ok '^W ~ skynet ~ none ~ hand-run$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-host-card ok 'hand-run is placed here only by execution.tsv rows: recorded by hand, not by a scheduler, and not counted in the budget' -- cat "$tmp/atlas/atlas.html"
expect atlas-report-unmerged ok '^O ~ report-branch ~ report unmerged ~ report on origin/docs/report-branch-report, unmerged ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-report-unmerged-needs-you ok '^N ~ report-branch ~ report waits for review on origin/docs/report-branch-report$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-behind-base ok '^S ~ behind_base ~ 1$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-behind-header ok '<p class="snap-behind">.* This checkout is 1 commit behind <code>origin/main</code>.*<code class="cmd">git pull</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-card-on-base ok '^V ~ behind-card ~ card exists on origin/main; this checkout is 1 commit behind, run git pull$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-card-on-base-not-uncommitted ok - -- bash -c '! grep -q "^V ~ behind-card ~ question card is not committed" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-report-not-pulled ok '^O ~ behind-card ~ report not pulled ~ report on origin/main;' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-bad-header ok '^V ~ behind-card ~ execution.tsv header is not id ts field value why evidence' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-other-column ok '<td class="c c-ripple"><svg class="i" role="img" aria-label="other: execution-within-envelope">.*<span class="detail">execution-within-envelope: x1: host skynet is not in launch_hosts' -- cat "$tmp/atlas/atlas.html"
expect atlas-lineage-inferred ok '^E ~ lr-sweep ~ lr-sweep-fine ~ inferred ~ True$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-lineage-declared ok '^E ~ q-warmup-v2 ~ cosine-v2 ~ supersedes ~ False$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-lineage-declared-not-inferred ok - -- bash -c '! grep -q "^E ~ q-warmup ~ q-warmup-v2 ~ inferred" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-lineage-dotted ok '<ol class="lineage lineage-inferred"><li><div class="q"><span class="q-date">' -- cat "$tmp/atlas/atlas.html"
expect atlas-lineage-none-not-inferred ok - -- bash -c '! grep -q "^E ~ [^~]* ~ lr-sweep-2 ~" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-lineage-none-no-link ok - -- bash -c '! grep -q "href=\"#run-none\"" "$1"' _ "$tmp/atlas/atlas.html"
expect atlas-lineage-run-note ok '<span class="rel rel-inferred">follows <a class="id" href="#run-lr-sweep">lr-sweep</a>, inferred from name</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-lineage-names ok '^emu-b00-053-phys2<emu-b00-053 emu-b00-054<emu-b00-053 emu-b00-054b<emu-b00-054 emu-b00-e2b<emu-b00-e2 emu-b00-e2c<emu-b00-e2b $' -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import atlas
ids = {"emu-b00-053", "emu-b00-053-phys2", "emu-b00-054", "emu-b00-054b", "emu-b00-e2", "emu-b00-e2b", "emu-b00-e2c", "emu-store-054", "f2-train-deploy-shift", "f2b-past-only-inputs", "p1-lookahead"}
print("".join(f"{i}<{p} " for i in sorted(ids) for p in [atlas.name_parent(i, ids - {i})] if p))' "$here/lib"
expect atlas-stray-incident ok '^V ~ explore-07 ~ incident.md is a write-up not where the guard looks; move it to incidents/' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-stray-incident-keeps-ripple ok '^N ~ explore-07 ~ ripple on job-states, so stop spending$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-release-stamp ok '<dt>Guard version</dt><dd>schema [0-9]+, release ' -- cat "$tmp/atlas/atlas.html"
expect atlas-no-release-stamp ok "<dt>Guard version</dt><dd>schema 1, installed before release stamps; run <code>guard init $tmp/atlas/casts-v4-training --update</code></dd>" -- python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import atlas
d = json.load(open(sys.argv[2])); d["version"] = {"installer": "b017edd"}; print(atlas.render(d))' "$here/lib" "$tmp/atlas/atlas.json"
expect atlas-verdict-stop ok '<p class="verdict-line">Stop spending on 4 runs: each has a ripple.</p>' -- cat "$tmp/atlas/atlas.html"
expect atlas-no-jobs-unchecked ok '^UNCHECKED$' -- python3 -c 'import json, sys
r = next(r for r in json.load(open(sys.argv[1]))["runs"] if r["id"] == "hand-run")
print(*{l["status"] for l in r["ripples"] if l["check"] in ("job-states", "walltime-headroom", "retries", "handled-failures")})' "$tmp/atlas/atlas.json"
expect atlas-no-jobs-prose ok '</svg>jobs: unchecked</span> <span class="detail">sacct lists no job named hand-run on account gom since 2026-09-01' -- cat "$tmp/atlas/atlas.html"
# The skynet reproduction: sacct on PATH that lists nothing. No run may show a job or budget pass.
expect atlas-off-cluster ok 'Spend source</dt><dd>none: the budget ripple could not read sacct on this host</dd>' -- bash -c '. "$1"; MOCK_SACCT_ROWS=/dev/null MOCK_SACCT_CPUSECONDS= "$2" atlas --out "$3/off.html" >/dev/null && cat "$3/off.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-off-cluster-no-pass ok - -- bash -c '! grep -oE "aria-label=\"(job-states|walltime-headroom|retries|handled-failures|budget): pass\"" "$1"' _ "$tmp/atlas/off.html"
expect atlas-needs-you-incident ok 'Write up job 4840 at <code class="cmd">runs/explore-07/incidents/YYYY-MM-DD-4840.md</code>, the only place the guard counts incidents' -- python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import atlas
d = json.load(open(sys.argv[2]))
for r in d["runs"]: r["stray_incidents"] = []
print(atlas.render(d))' "$here/lib" "$tmp/atlas/atlas.json"
expect atlas-needs-you-branch ok 'review it as a pull request: <code class="cmd">git diff --stat origin/main...origin/agent/fp32-check</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-needs-you-await ok '<li class="todo-await">.*href="#run-skynet-train"' -- cat "$tmp/atlas/atlas.html"
atlas_group() {  # atlas_group <html> <group> <run id>: succeeds when the run sits in that run group
  python3 -c 'import re, sys
page, group, rid = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
m = re.search(r"<section class=\"rgroup\" id=\"runs-" + group + r"\".*?</section>", page, re.S)
sys.exit(0 if m and f"id=\"run-{rid}\"" in m.group(0) else 1)' "$@"
}
expect atlas-group-stop ok - -- atlas_group "$tmp/atlas/atlas.html" stop explore-07
expect atlas-group-stop-open ok '<details class="run" id="run-explore-07" open>' -- cat "$tmp/atlas/atlas.html"
expect atlas-group-rule ok - -- atlas_group "$tmp/atlas/atlas.html" rule q-batch
expect atlas-group-await ok - -- atlas_group "$tmp/atlas/atlas.html" await skynet-train
expect atlas-group-not-quiet ok - -- bash -c '! atlas_group "$1" quiet skynet-train' _ "$tmp/atlas/atlas.html"
expect atlas-no-tooltips ok '^abbr$' -- python3 -c 'import re, sys; print(" ".join(sorted(set(re.findall(r"<(\w+)[^>]* title=", open(sys.argv[1]).read())))))' "$tmp/atlas/atlas.html"
expect atlas-every-run-opens ok '^14$' -- grep -c '<details class="run" id="run-' <(sed 's/<details class="run"/\n&/g' "$tmp/atlas/atlas.html")
expect atlas-needs-you-stray ok 'A write-up exists at <code>runs/explore-07/incident.md</code>, but the guard does not count it there. Move it: <code class="cmd">git mv runs/explore-07/incident.md runs/explore-07/incidents/YYYY-MM-DD-4840.md</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-needs-you-unmerged ok 'href="#run-report-branch">report-branch</a> <span class="b b-handled">.*report unmerged</span><p>Its report is only on <code>origin/docs/report-branch-report</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-timeline-ledger ok '<span>execution.tsv x1: host skynet, recorded by hand</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-golden ok - -- bash -c 'diff <("$1/tests/atlas-golden.sh" "$2") "$1/tests/golden/atlas-fixture.html"' _ "$here" "$tmp/golden"
expect atlas-no-network ok - -- bash -c '! grep -Eiq "<link[^>]*https?://|src=\"?https?://" "$1"' _ "$tmp/atlas/atlas.html"
expect atlas-head-only ok '\(12 runs,' -- bash -c '. "$1"; "$2" atlas --no-ripples --head-only --out "$3/head.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-no-ripples-says-so ok 'Safety checks were not run for this render, so this page cannot say whether anything is wrong.' -- cat "$tmp/atlas/head.html"
expect atlas-verdict-unknown ok 'class="verdict verdict-unknown" role="status"' -- cat "$tmp/atlas/head.html"
expect atlas-head-only-hides-disk-run ok - -- bash -c '! grep -q "run-q-batch" "$1"' _ "$tmp/atlas/head.html"
expect atlas-read-only ok '^same$' -- bash -c '[ "$(git -C "$1" status --porcelain)" = "$2" ] && echo same' _ "$tmp/atlas/casts-v4-training" "$atlas_before"
cp "$tmp/atlas/casts-v4-training/guard/run" "$tmp/atlas/guard-run.kept"
printf '#!/bin/bash\ntouch "$HOME/forged"; printf "PASS\\tguard-untouched\\tforged\\n"\n' > "$tmp/atlas/casts-v4-training/guard/run"
expect atlas-runs-protected-guard ok '^RIPPLE$' -- bash -c '. "$1"; HPC_GUARD_LOCAL=1 HOME="$2" "$3" atlas --runs lr-sweep --out "$2/forged.html" --json "$2/forged.json" > /dev/null
  python3 -c "import json, sys; print(*{l[\"status\"] for r in json.load(open(sys.argv[1]))[\"runs\"] for l in r[\"ripples\"] if l[\"check\"] == \"guard-untouched\"})" "$2/forged.json"' _ "$tmp/atlas/env.sh" "$tmp/atlas" "$guard"
expect atlas-forged-runner-not-run ok - -- test ! -e "$tmp/atlas/forged"
cp "$tmp/atlas/guard-run.kept" "$tmp/atlas/casts-v4-training/guard/run"
expect atlas-default-out ok "atlas: $tmp/atlas/tmpdir/atlas-casts-v4-training-$(id -u).html" -- bash -c '. "$1"; mkdir -p "$2/tmpdir"; TMPDIR="$2/tmpdir" "$3" atlas --no-ripples' _ "$tmp/atlas/env.sh" "$tmp/atlas" "$guard"
expect atlas-default-out-private ok '^600$' -- stat -c %a "$tmp/atlas/tmpdir/atlas-casts-v4-training-$(id -u).html"
expect atlas-default-out-read-only ok '^same$' -- bash -c '[ "$(git -C "$1" status --porcelain)" = "$2" ] && echo same' _ "$tmp/atlas/casts-v4-training" "$atlas_before"
expect atlas-runs-filter ok '\(2 runs,' -- bash -c '. "$1"; "$2" atlas --no-ripples --runs "cosine-*" --runs "explore-*" --title casts --out "$3/filtered.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-runs-title ok '<p class="eyebrow">Guard atlas · project <code>casts-v4-training</code> · runs <code>cosine-\*</code>, <code>explore-\*</code></p>' -- cat "$tmp/atlas/filtered.html"
expect atlas-runs-title-h1 ok '<h1>casts</h1>' -- cat "$tmp/atlas/filtered.html"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
( . "$tmp/atlas/env.sh"; exec "$guard" atlas --serve "$port" --every 60 --no-ripples ) > "$tmp/atlas/serve.log" 2>&1 &
serve_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/atlas.json" && break; sleep 0.2; done
expect atlas-serve-line ok "^atlas: serving http://127.0.0.1:$port/ from " -- cat "$tmp/atlas/serve.log"
expect atlas-serve-page ok '<meta http-equiv="refresh" content="60">' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-run ok 'id="run-cosine-v2"' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-footer ok 'Served live from .*; re-surveyed at most every 1 min on reload' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-json ok '"id": "q-batch"' -- curl -s "http://127.0.0.1:$port/atlas.json"
kill "$serve_pid" 2>/dev/null; wait "$serve_pid" 2>/dev/null
sock="$tmp/atlas/atlas.sock"
( . "$tmp/atlas/env.sh"; exec "$guard" atlas --serve "$sock" --every 60 --no-ripples ) > "$tmp/atlas/sock.log" 2>&1 &
sock_pid=$!
for _ in $(seq 50); do [ -S "$sock" ] && curl -s -o /dev/null --unix-socket "$sock" http://atlas/atlas.json && break; sleep 0.2; done
expect atlas-sock-line ok "^atlas: serving unix:$sock from " -- cat "$tmp/atlas/sock.log"
expect atlas-sock-page ok 'id="run-cosine-v2"' -- curl -s --unix-socket "$sock" http://atlas/
expect atlas-sock-mode ok '^600$' -- stat -c %a "$sock"
kill -TERM "$sock_pid" 2>/dev/null; wait "$sock_pid" 2>/dev/null
expect atlas-sock-removed ok '^gone$' -- bash -c '[ ! -e "$1" ] && echo gone' _ "$sock"
echo plain > "$tmp/atlas/not-a-socket"
expect atlas-sock-refuses-file fail 'not a socket' -- bash -c '. "$1"; "$2" atlas --serve "$3" --no-ripples' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas/not-a-socket"
expect atlas-serve-bad-value fail "port number or a socket path" -- "$guard" atlas --serve nope
expect atlas-refuses-unguarded fail 'no guard/run' -- "$guard" atlas "$tmp/agents"

echo "== quickstart"
expect quickstart-walkthrough ok 'PREFLIGHT FAIL: guard/ differs from origin/main.*PREFLIGHT OK: cheap-evo.*PASS	evidence-paths.*PASS	check:finite.sh.*Look at:' -- bash -c '"$1/examples/quickstart/run.sh" "$2" 2>&1 | tr "\n" " "' _ "$here" "$tmp/quickstart"
expect quickstart-rerun-replaces-its-own ok 'Look at:' -- "$here/examples/quickstart/run.sh" "$tmp/quickstart"
expect quickstart-refuses-foreign-dir fail 'did not create it' -- "$here/examples/quickstart/run.sh" "$tmp/agents"
echo "== needs-you"
in_dir() { local d=$1; shift; (cd "$d" && "$@"); }
ny=$tmp/ny; git init -q -b main "$ny"; git -C "$ny" commit -q --allow-empty -m init
expect ny-empty ok '^Nothing needs you\.$' -- in_dir "$ny" "$guard" needs-you
expect ny-remind-empty ok - -- bash -c 'out=$(cd "$1" && "$2" needs-you --remind 2>&1) && [ -z "$out" ]' _ "$ny" "$guard"
expect ny-add ok '^n1$' -- in_dir "$ny" "$guard" needs-you add --kind run --title 'Merge PR #41 (autonomous merge refused)' \
  --why 'the gh login in this shell administers the repository.' --run "cd $ny" --run 'gh pr merge 41 --squash' \
  --expect '"Squashed and merged pull request #41".' --undo 'git revert <merge commit> on a new branch.' --path "$here/README.md" --source claude
expect ny-add-next ok '^n2$' -- in_dir "$ny" "$guard" needs-you add --kind check --title 'Read the report' --path "$here/README.md" --path "$here/bin/guard"
expect ny-tsv-header ok '^id	ts	state	kind	title	action	paths	commands	source$' -- head -1 "$ny/.git/guard/needs-you.tsv"
expect ny-show ok - -- bash -c 'diff <(cd "$1" && "$2" needs-you show n1) - <<BLOCK
🩺 n1 · run · Merge PR #41 (autonomous merge refused)

Why: the gh login in this shell administers the repository.

Run, in order:
  cd $1
  gh pr merge 41 --squash

Expect: "Squashed and merged pull request #41".
Undo: git revert <merge commit> on a new branch.
Files: $3/README.md
Done: guard needs-you done n1

🩺
BLOCK' _ "$ny" "$guard" "$here"
expect ny-show-omits-empty ok - -- bash -c 'diff <(cd "$1" && "$2" needs-you show n2) - <<BLOCK
🩺 n2 · check · Read the report

Files:
  $3/README.md
  $3/bin/guard
Done: guard needs-you done n2

🩺
BLOCK' _ "$ny" "$guard" "$here"
expect ny-list ok '^🩺 n1 · run · Merge PR #41 \(autonomous merge refused\) 🩺 n2 · check · Read the report $' -- bash -c '(cd "$1" && "$2" needs-you) | grep "^🩺 n" | tr "\n" " "' _ "$ny" "$guard"
expect ny-show-unknown fail 'no item n9' -- in_dir "$ny" "$guard" needs-you show n9
rows=$(wc -l < "$ny/.git/guard/needs-you.tsv")
expect ny-refuse-relative fail 'README.md is a relative path' -- in_dir "$here" "$guard" needs-you add --kind check --title t --path README.md
expect ny-refuse-missing fail "$here/nope does not exist" -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$here/nope"
mkdir -p "$tmp/ny-files/scratchpad"; touch "$tmp/ny-files/f" "$tmp/ny-files/scratchpad/f"
expect ny-refuse-tmp fail 'which gets cleaned\. Copy the file to a stable place first' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$tmp/ny-files/f"
expect ny-refuse-literal-tmp fail '^guard needs-you: /tmp/\. is under /tmp' -- env TMPDIR= bash -c 'cd "$1" && "$2" needs-you add --kind check --title t --path /tmp/.' _ "$ny" "$guard"
expect ny-refuse-var-tmp fail 'is under /var/tmp' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path /var/tmp
expect ny-refuse-tmpdir fail "is under $here/tests, which gets cleaned" -- env TMPDIR="$here/tests" bash -c 'cd "$1" && "$2" needs-you add --kind check --title t --path "$3/tests/run.sh"' _ "$ny" "$guard" "$here"
expect ny-refuse-scratchpad fail 'is in a scratchpad directory' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --path "$tmp/ny-files/scratchpad/f"
expect ny-refuse-tab fail 'holds a tab or a newline' -- in_dir "$ny" "$guard" needs-you add --kind check --title "$(printf 'a\tb')"
expect ny-refuse-newline fail 'holds a tab or a newline' -- in_dir "$ny" "$guard" needs-you add --kind check --title t --why "$(printf 'a\nb')"
expect ny-refuse-separator fail "holds ';;'" -- in_dir "$ny" "$guard" needs-you add --kind run --title t --run 'case x in x) ;; esac'
expect ny-refuse-run-without-command fail 'needs at least one --run' -- in_dir "$ny" "$guard" needs-you add --kind run --title t
expect ny-refuse-empty-run fail '^guard needs-you: --run is empty$' -- in_dir "$ny" "$guard" needs-you add --kind run --title t --run ''
expect ny-refusals-write-nothing ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$ny/.git/guard/needs-you.tsv"
expect ny-remind-text ok '^🩺 2 items in .* need you:$' -- in_dir "$ny" "$guard" needs-you --remind
expect ny-ack ok '^n1 acked$' -- in_dir "$ny" "$guard" needs-you ack n1 --note seen
expect ny-ack-again ok '^n1 is already acked$' -- in_dir "$ny" "$guard" needs-you ack n1
expect ny-remind-skips-acked ok - -- bash -c 'out=$(cd "$1" && "$2" needs-you --remind); grep -q "n2 · check" <<<"$out" && ! grep -q n1 <<<"$out"' _ "$ny" "$guard"
expect ny-list-keeps-acked ok '^🩺 n1 · run' -- in_dir "$ny" "$guard" needs-you
expect ny-done ok '^n1 done$' -- in_dir "$ny" "$guard" needs-you "done" n1
expect ny-list-drops-done ok - -- bash -c '! (cd "$1" && "$2" needs-you) | grep -q "n1 ·"' _ "$ny" "$guard"
expect ny-ack-after-done fail 'n1 is done, so it cannot become acked' -- in_dir "$ny" "$guard" needs-you ack n1
expect ny-last-row-wins ok '^n1	[^	]*	done	run	Merge PR #41 .*note: seen' -- tail -1 "$ny/.git/guard/needs-you.tsv"
expect ny-hook-json ok '^UserPromptSubmit$' -- bash -c 'cd / && printf "{\"hook_event_name\": \"UserPromptSubmit\", \"cwd\": \"%s\"}" "$1" | "$2" needs-you --remind --format claude-hook | python3 -c "import json, sys
d = json.load(sys.stdin); h = d[\"hookSpecificOutput\"]
assert \"n2 · check · Read the report\" in d[\"systemMessage\"] and \"🩺 n2 · check · Read the report\" in h[\"additionalContext\"]
assert \"🩺 n1\" not in h[\"additionalContext\"]
print(h[\"hookEventName\"])"' _ "$ny" "$guard"
expect ny-hook-session-start ok '"hookEventName": "SessionStart"' -- bash -c 'cd "$1" && echo "{\"hook_event_name\": \"SessionStart\"}" | "$2" needs-you --remind --format claude-hook' _ "$ny" "$guard"
mkdir -p "$tmp/ny-norepo"
expect ny-remind-outside-repo ok - -- bash -c 'export GIT_CEILING_DIRECTORIES=$1; out=$(cd "$1/ny-norepo" && "$2" needs-you --remind 2>&1 && echo "{}" | "$2" needs-you --remind --format claude-hook 2>&1) && [ -z "$out" ]' _ "$tmp" "$guard"
expect ny-remind-closed-stdin ok '^\{"systemMessage": "[^"]*n2 \\u00b7 check' -- bash -c 'cd "$1" && "$2" needs-you --remind --format claude-hook <&-' _ "$ny" "$guard"
expect ny-remind-bad-cwd ok - -- bash -c 'out=$(echo "{\"cwd\": 5, \"hook_event_name\": \"UserPromptSubmit\"}" | "$2" needs-you --remind --format claude-hook 2>&1) && [ -z "$out" ]' _ "$ny" "$guard"
expect ny-remind-ascii-stdout ok '"systemMessage": "\\ud83e\\ude7a ' -- bash -c 'cd "$1" && echo "{\"hook_event_name\": \"SessionStart\"}" | PYTHONIOENCODING=ascii "$2" needs-you --remind --format claude-hook' _ "$ny" "$guard"
expect ny-list-outside-repo fail 'is not a git repository' -- env GIT_CEILING_DIRECTORIES="$tmp" bash -c 'cd "$1" && "$2" needs-you' _ "$tmp/ny-norepo" "$guard"
git -C "$ny" worktree add -q "$tmp/ny-wt" -b other 2>/dev/null
expect ny-worktree-add ok '^n3$' -- in_dir "$tmp/ny-wt" "$guard" needs-you add --kind approve --title 'Approve the question card' --path "$here/README.md"
expect ny-worktree-shared ok '^🩺 n3 · approve · Approve the question card$' -- in_dir "$ny" "$guard" needs-you show n3
expect ny-worktree-sees-main ok '^🩺 n2 · check' -- in_dir "$tmp/ny-wt" "$guard" needs-you
for i in $(seq 8); do (cd "$ny" && "$guard" needs-you add --kind check --title "race $i" > /dev/null) & done; wait
expect ny-concurrent-ids-unique ok '^n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11 $' -- bash -c 'awk -F "\t" "\$3 == \"open\" {print \$1}" "$1" | sort -V | tr "\n" " "' _ "$ny/.git/guard/needs-you.tsv"

rows=$(wc -l < "$ny/.git/guard/needs-you.tsv")
expect ny-add-same-open-item ok '^n2$' -- in_dir "$ny" "$guard" needs-you add --kind check --title 'Read the report' --path "$here/README.md"
expect ny-add-same-writes-nothing ok "^$rows\$" -- bash -c 'wc -l < "$1"' _ "$ny/.git/guard/needs-you.tsv"
expect ny-add-same-title-other-kind ok '^n12$' -- in_dir "$ny" "$guard" needs-you add --kind approve --title 'Read the report'
expect ny-add-same-as-closed ok '^n13$' -- in_dir "$ny" "$guard" needs-you add --kind run --title 'Merge PR #41 (autonomous merge refused)' --run 'gh pr merge 41 --squash'

echo "== hooks install"
home=$tmp/hooks-home; mkdir -p "$home/.claude" "$home/dotfiles"
cat > "$home/dotfiles/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "check-bash"}]}]
  }
}
JSON
ln -s "$home/dotfiles/settings.json" "$home/.claude/settings.json"
reminder_counts_and_kept_settings() {
  python3 -c 'import json, sys
s = json.load(open(sys.argv[1])); h = s["hooks"]
n = lambda e: sum("needs-you --remind --format claude-hook" in x["command"] for g in h.get(e, []) for x in g["hooks"])
print(n("SessionStart"), n("UserPromptSubmit"), s.get("model"), s.get("permissions"), [x["command"] for g in h.get("UserPromptSubmit", []) for x in g["hooks"]][0], h.get("PreToolUse"))' "$1"
}
expect hooks-dry-run ok '"command": "guard needs-you --remind --format claude-hook"' -- env HOME="$home" "$guard" hooks install claude --dry-run
expect hooks-dry-run-writes-nothing ok - -- bash -c '! grep -q needs-you "$1"' _ "$home/dotfiles/settings.json"
expect hooks-install-user ok 'added SessionStart and UserPromptSubmit hooks' -- env HOME="$home" "$guard" hooks install claude --user
expect hooks-install-keeps-settings ok "^1 1 opus \{'allow': \['Bash\(ls:\*\)'\]\} echo mine \[\{'matcher': 'Bash', 'hooks': \[\{'type': 'command', 'command': 'check-bash'\}\]\}\]$" -- reminder_counts_and_kept_settings "$home/.claude/settings.json"
expect hooks-install-keeps-symlink ok - -- test -L "$home/.claude/settings.json"
sum=$(sha256sum < "$home/dotfiles/settings.json")
expect hooks-install-idempotent ok 'nothing changed' -- env HOME="$home" "$guard" hooks install claude
expect hooks-install-unchanged ok - -- test "$sum" = "$(sha256sum < "$home/dotfiles/settings.json")"
expect hooks-install-project ok "^$ny/.claude/settings.json: added SessionStart and UserPromptSubmit" -- in_dir "$ny" env HOME="$home" "$guard" hooks install claude --project
expect hooks-install-project-shape ok '^1 1 None None ' -- reminder_counts_and_kept_settings "$ny/.claude/settings.json"
mkdir -p "$tmp/bad-home/.claude"; echo '{"hooks": ' > "$tmp/bad-home/.claude/settings.json"
expect hooks-refuse-bad-json fail 'is not valid JSON' -- env HOME="$tmp/bad-home" "$guard" hooks install claude
expect hooks-bad-json-untouched ok '^\{"hooks": $' -- cat "$tmp/bad-home/.claude/settings.json"
echo '{"hooks": {"SessionStart": [{"hooks": null}]}}' > "$tmp/bad-home/.claude/settings.json"
expect hooks-refuse-bad-shape fail 'does not have the shape Claude Code reads for hooks' -- env HOME="$tmp/bad-home" "$guard" hooks install claude
mkdir -p "$tmp/locked-home/.claude"; chmod 555 "$tmp/locked-home/.claude"
expect hooks-unwritable fail "^guard hooks: cannot write $tmp/locked-home/.claude/settings.json: Permission denied$" -- env HOME="$tmp/locked-home" "$guard" hooks install claude
chmod 755 "$tmp/locked-home/.claude"
expect hooks-unknown-agent fail 'invalid choice' -- "$guard" hooks install codex

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
