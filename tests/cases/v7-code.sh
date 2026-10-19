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
unset HPC_CODE_ROOT
