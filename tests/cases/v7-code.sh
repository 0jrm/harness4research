# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
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
# code_concurrent <root>: four calls at once for an absent checkout, as jobs 13239051/52 made; all must print one path.
code_concurrent() {
  local k rc=0
  for k in 1 2 3 4; do HPC_CODE_ROOT=$1 guard/run code "$tmp/model" "$code_sha" >"$1.out$k" 2>&1 & done
  wait
  for k in 1 2 3 4; do grep -qx "$(realpath -m "$1")/model-${code_sha:0:12}" "$1.out$k" || { cat "$1.out$k"; rc=1; }; done
  return $rc
}
expect code-concurrent-first-use ok - -- code_concurrent "$tmp/code-root-concurrent"
unset HPC_CODE_ROOT
