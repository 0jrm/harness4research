#!/usr/bin/env bash
# usage: tests/run.sh
# Runs tests/cases/*.sh in the fixture below.
# End-to-end checks against throwaway git repos and a fake Slurm. Exit 1 on the first unexpected result.
set -uo pipefail
# git rebase --exec and git hooks export GIT_DIR, which would turn every throwaway repo below into the caller's own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
# What the suite needs, checked before anything runs: one line with the fix, exit 64.
prereq() { echo "tests/run.sh: $1" >&2; exit 64; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq >/dev/null || prereq "needs jq; install it, for example sudo apt-get install jq"
python3 -c 'import yaml' 2>/dev/null || prereq "needs PyYAML; install it, for example sudo apt-get install python3-yaml"
[ "$(git -C "$here" rev-parse --is-shallow-repository)" = false ] ||
  prereq "needs the full history; run git -C $here fetch --unshallow"
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
# The fence prints its CI repair under GITHUB_ACTIONS=true; the cases that want it set it themselves.
unset GITHUB_ACTIONS
# The sourced cases read guard.
# shellcheck disable=SC2034
guard=$here/bin/guard
tmp=$(mktemp -d); cache=${XDG_CACHE_HOME:-$HOME/.cache}; mkdir -p "$cache"
keep=$(mktemp -d "$cache/guard-tests.XXXXXX"); trap 'rm -rf "$tmp" "$keep"' EXIT
export PATH="$here/tests/mock-bin:$PATH" XDG_CONFIG_HOME=$tmp/xdg USER=tester GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0; skipped=0
expect() {  # expect <name> <want: ok|fail> <grep pattern or -> -- command...
  local name=$1 want=$2 pat=$3; shift 4
  local out rc; out=$("$@" 2>&1); rc=$?
  local got=ok; [ $rc -ne 0 ] && got=fail
  if [ "$got" = "$want" ] && { [ "$pat" = - ] || grep -q -E -- "$pat" <<<"$out"; }; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (exit $rc, wanted $want, pattern '$pat')"; sed 's/^/     /' <<<"$out" | tail -8; fi
}
expect_refusal() {  # expect_refusal <name> <code> -- command...: it prints exactly refusal <code>'s two lines and exits
  local name=$1 code=$2; shift 3   # with its status, and line 2 obeys the line 2 rule (lib/refusals.py check)
  local out rc why; out=$("$@" 2>&1); rc=$?
  if why=$(python3 "$here/lib/refusals.py" check "$code" "$rc" <<<"$out" 2>&1); then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name ($why)"; sed 's/^/     /' <<<"$out" | tail -8; fi
}
skip() { skipped=$((skipped+1)); echo "skip $1 ($2)"; }  # skip <name> <reason>: a case this host cannot run
merged() {  # merged <command...>: runs it with the protected branch at HEAD, as if HEAD's pull request had merged
  git push -q -f origin HEAD:refs/heads/merged && env HPC_GUARD_REF=origin/merged "$@"
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
path_without_agent_clis() { PATH=$(path_without claude); PATH=$(path_without codex); path_without cursor-agent; }
PATH=$(path_without_agent_clis)
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

# The v7 cases share this fixture and each other's state, so they run in the order the v7 suite had; a case a unit
# retires is skipped by its absence. Every other case runs after them, in name order, from $tmp.
v7=(survey archive init merge-the-guard preflight ripples manifest code launch fence init-update harness-pin
  fence-workflow update-moves v6.1-to-v7 merge-policy doctor config review pr-open merge tiers batch atlas quickstart
  needs-you hooks-install gateway guard-enter-broker plan-status budget)
for name in "${v7[@]}"; do
  # shellcheck source=/dev/null
  [ ! -e "$here/tests/cases/v7-$name.sh" ] || . "$here/tests/cases/v7-$name.sh"
done
for case in "$here"/tests/cases/[0-9]*.sh; do
  [ -e "$case" ] || continue
  cd "$tmp" || exit 1
  # shellcheck source=/dev/null
  . "$case"
done

echo; echo "$pass passed, $fail failed$([ "$skipped" -eq 0 ] || echo ", $skipped skipped")"
[ $fail -eq 0 ]
