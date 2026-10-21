#!/usr/bin/env bash
# usage: tests/dry-install.sh [slurm] [host]
# guard init on a scratch repository, then a scripted agent whose PATH holds only `guard` completes one job with
# guard status, guard run and guard wait (design-v8 section 9). slurm: eval/env/fakeslurm.py behind sbatch, squeue,
# sacct and scancel. host: launch_hosts names this host (tests/mock-bin/hostname) and no sbatch is on PATH. Both by
# default. Prints one ok or FAIL line per check; exit 1 on any FAIL.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
modes=("$@"); [ ${#modes[@]} -gt 0 ] || modes=(slurm host)
# Every process a pass starts (the fake Slurm, a host job's supervisor) dies with this private PID namespace.
ns=(unshare --user --map-current-user --pid --fork --mount-proc)
if [ -z "${HPC_DRY_IN_NS:-}" ] && "${ns[@]}" true 2>/dev/null; then HPC_DRY_IN_NS=1 exec "${ns[@]}" "$0" "$@"; fi
scratch=$(mktemp -d); trap 'rm -rf "${scratch:?}"' EXIT
export HOME=$scratch/home XDG_CONFIG_HOME=$scratch/home/.config XDG_STATE_HOME=$scratch/home/.local/state \
  XDG_CACHE_HOME=$scratch/home/.cache USER=dry GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t \
  GIT_COMMITTER_EMAIL=t@t MOCK_HOSTNAME=dryhost
unset GUARD_SESSION GUARD_SOCK_DIR HPC_HARNESS
mkdir -p "$HOME"
export PATH="$here/tests/mock-bin:$PATH"
fail=0
check() {  # check <name> <command...>
  local name=$1; shift
  if "$@" </dev/null >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
}
path_without() {  # path_without <cmd>: PATH with every directory that holds <cmd> replaced by a copy without it
  local cmd=$1 shadow=$scratch/no-$1 out="" d f IFS=:
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

# fake_slurm <dir>: serves eval/env/fakeslurm.py from <dir> and writes its clients to <dir>/bin; prints that bin.
fake_slurm() {
  local d=$1 c
  mkdir -p "$d/bin"
  printf '{"cluster": "dry", "partition": "work", "nodes": 2, "cores_per_node": 4, "time_scale": 1,
    "default_account": "dry", "accounts": {"dry": {"cap_cpu_minutes": null}}}\n' > "$d/cluster.json"
  python3 "$here/eval/env/fakeslurm.py" serve "$d" "$d/cluster.json" > "$d/daemon.log" 2>&1 &
  for c in sbatch squeue sacct scancel; do
    printf '#!/usr/bin/env python3\nimport os, sys\nos.environ["SLURM_CONF_SOCKET"] = %s\nos.environ.setdefault("USER", "dry")\nsys.path.insert(0, %s)\nimport slurmclient\nsys.exit(slurmclient.client(%s, sys.argv[1:]))\n' \
      "'$d/slurmctld.sock'" "'$here/eval/env'" "'$c'" > "$d/bin/$c"
    chmod +x "$d/bin/$c"
  done
  for _ in $(seq 100); do [ -S "$d/slurmctld.sock" ] && break; sleep 0.1; done
  echo "$d/bin"
}

# project <dir> <card lines...>: a repository guarded by this harness, offline, with the card filled in by these
# key: value lines and a job script, merged to main the way a person merges the guard's pull request.
project() {
  local p=$1 line key; shift
  git init -q --bare -b main "$p.git"; git clone -q "$p.git" "$p" 2>/dev/null
  git -C "$p" checkout -q -b main; echo "# dry" > "$p/README.md"
  git -C "$p" add -A; git -C "$p" commit -q -m init; git -C "$p" push -q -u origin main
  git -C "$p" remote set-head origin -a >/dev/null
  "$here/bin/guard" init "$p" --worktree "$p.wt" --offline > "$p.init.out" 2>&1 || return 1
  for line in "$@"; do
    key=${line%%:*}
    if grep -q "^$key:" "$p.wt/guard/budget.card"; then
      awk -v k="$key:" -v line="$line" 'index($0, k) == 1 { print line; next } { print }' "$p.wt/guard/budget.card" > "$p.card"
      mv "$p.card" "$p.wt/guard/budget.card"
    else echo "$line" >> "$p.wt/guard/budget.card"; fi
  done
  printf '#!/bin/bash\n#SBATCH --time=00:05:00\nmkdir -p out\necho step 1 of 1\nsleep 2\necho done > out/result.txt\necho finished\n' \
    > "$p.wt/job.sh"
  chmod +x "$p.wt/job.sh"
  git -C "$p.wt" add -A; git -C "$p.wt" commit -q -m "chore(guard): set budget"
  git -C "$p.wt" push -q origin guard/init:main; git -C "$p" fetch -q origin; git -C "$p" merge -q --ff-only origin/main
}

# The scripted agent. Its PATH holds one command, guard, which logs each call; the agent reads no file and runs no
# other program, so it can only succeed from what guard prints.
agent_script() {
  cat <<'AGENT'
guard status
out=$(guard run runs/dry --why "Run the dry-install job once." -- --time=5 job.sh 2>&1); echo "$out"
[[ $out =~ guard\ wait\ ([^[:space:]\;]+) ]] || { echo "AGENT: no job id in the guard run line"; exit 1; }
id=${BASH_REMATCH[1]}
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out=$(guard wait "$id" 2>&1); rc=$?; echo "$out"
  [ $rc -eq 124 ] || break
done
[[ $out == *"-> COMPLETED"* ]] && echo "AGENT: COMPLETED $id"
guard status
AGENT
}

run_pass() {  # run_pass <mode> <dir> <PATH for guard>
  local mode=$1 p=$2 guard_path=$3 bin=$scratch/$mode-agent-bin
  mkdir -p "$bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %q\nPATH=%q exec %q "$@"\n' "$scratch/$mode-guard.log" "$guard_path" "$here/bin/guard" > "$bin/guard"
  chmod +x "$bin/guard"
  agent_script > "$scratch/$mode-agent.sh"
  (cd "$p" && env -i HOME="$HOME" USER="$USER" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" MOCK_HOSTNAME="$MOCK_HOSTNAME" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t PATH="$bin" "$(command -v timeout)" 900 /bin/bash "$scratch/$mode-agent.sh") \
    > "$scratch/$mode-agent.out" 2>&1
  sed "s/^/     $mode| /" "$scratch/$mode-agent.out"
  check "$mode-completed" grep -q '^AGENT: COMPLETED ' "$scratch/$mode-agent.out"
  check "$mode-only-the-verbs" bash -c '! grep -qvxE "status|run|wait" "$1"' _ "$scratch/$mode-guard.log"
  check "$mode-used-run-and-wait" bash -c 'grep -qx run "$1" && grep -qx wait "$1"' _ "$scratch/$mode-guard.log"
  check "$mode-ran-nothing-else" bash -c '! grep -q "command not found" "$1"' _ "$scratch/$mode-agent.out"
  check "$mode-job-ran" bash -c 'f=$(find "$1" -path "*/out/result.txt" | head -n1); [ -n "$f" ] && grep -qx done "$f"' _ "$p"
  check "$mode-no-refusal" bash -c '! grep -q "^H4R-" "$1"' _ "$scratch/$mode-agent.out"
}

for mode in "${modes[@]}"; do
  echo "== dry install: $mode"
  p=$scratch/$mode-proj
  common=("account: dry" "start_date: 2026-01-01" "stop_date: 2099-01-01" "max_core_hours: 1000"
    "verification_reserve_core_hours: 0" "cores_per_node: 4" "max_nodes_per_job: 1" "max_walltime_minutes: 30"
    "max_concurrent_jobs: 2" "quota_pct_cmd: echo 1%")
  case $mode in
    slurm)
      sbin=$(fake_slurm "$scratch/slurm")
      check slurm-controller test -S "$scratch/slurm/slurmctld.sock"
      project "$p" "${common[@]}" "slurm_bin: $sbin" || { echo "FAIL slurm-init"; sed 's/^/     /' "$p.init.out"; fail=1; continue; }
      run_pass slurm "$p" "$sbin:$PATH" ;;
    host)
      command -v bwrap >/dev/null || { echo "skip host (no bwrap on this host; a boxed host job needs it)"; continue; }
      project "$p" "${common[@]}" "slurm_bin: /nonexistent" "launch_hosts: $MOCK_HOSTNAME" \
        "host_state_dir: $scratch/launches" "host_max_mem_gb: 1" "host_min_available_gb: 0" \
        || { echo "FAIL host-init"; sed 's/^/     /' "$p.init.out"; fail=1; continue; }
      gp=$(path_without sbatch)
      check host-no-sbatch bash -c '! PATH="$1" command -v sbatch' _ "$gp"
      run_pass host "$p" "$gp" ;;
    *) echo "usage: tests/dry-install.sh [slurm] [host]" >&2; exit 64 ;;
  esac
done
[ $fail -eq 0 ] && echo "dry install: every pass completed"
exit $fail
