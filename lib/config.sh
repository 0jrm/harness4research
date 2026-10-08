#!/usr/bin/env bash
# usage: guard config [list | get KEY | set KEY VALUE]
# Per-user settings, flat `key: value` lines like the budget card; the first match wins. An empty VALUE removes the key.
# GUARD_CONFIG names another file, for example to try a reviewer without changing XDG_CONFIG_HOME, where gh and the
# agent CLIs keep their logins.
# reviewer_cmd, reviewer_problem, reviewer_fix and merge_policy_where are read by the scripts that source this file.
# shellcheck disable=SC2034
config_file=${GUARD_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/guard/config}
config_keys=(reviewer reviewer_cmd_proprietary reviewer_cmd_local reviewer_model review_rounds review_small_lines review_batch_max
  ship_interval_hours merge_policy)
declare -A config_default=([reviewer]=proprietary [review_rounds]=2 [review_small_lines]=200 [review_batch_max]=8
  [ship_interval_hours]=24 [merge_policy]=autonomous)
whole_keys=" review_rounds review_small_lines review_batch_max ship_interval_hours "

config_get() {
  local v
  v=$(awk -v k="$1:" 'index($0, k) == 1 { sub(/^[^:]*: */, ""); print; f = 1; exit } END { exit !f }' "$config_file" 2>/dev/null) \
    || v=${config_default[$1]:-}
  printf '%s\n' "$v"
}

# config_whole <key>: prints the key's value when it is a whole number of at least 1. Otherwise prints how to fix it
# and returns 1.
config_whole() {
  local v; v=$(config_get "$1")
  [[ $v =~ ^[1-9][0-9]*$ ]] && { echo "$v"; return; }
  echo "$1 is '$v' in $config_file. Set it: guard config set $1 ${config_default[$1]}"; return 1
}

default_reviewer_cmds=("claude -p --permission-mode acceptEdits --strict-mcp-config --setting-sources project --disable-slash-commands --tools=Bash,Read,Edit,Grep,Glob --allowedTools=Bash" "cursor-agent -p --force --trust")

# resolve_reviewer: sets reviewer and reviewer_cmds, the commands guard review tries in order until one exits 0, and
# reviewer_cmd, the first of them. A configured command is the only one. Without one, a proprietary reviewer tries
# each default whose executable is on PATH, with --model when reviewer_model is set. When there is none, sets
# reviewer_problem and reviewer_fix instead and returns 1.
resolve_reviewer() {
  local cmd model
  reviewer=$(config_get reviewer); reviewer_cmds=()
  model=$(config_get reviewer_model); [ -z "$model" ] || model=" --model $(printf %q "$model")"
  case $reviewer in
    proprietary) cmd=$(config_get reviewer_cmd_proprietary)
      if [ -n "$cmd" ]; then reviewer_cmds=("$cmd")
      else for cmd in "${default_reviewer_cmds[@]}"; do command -v "${cmd%% *}" >/dev/null && reviewer_cmds+=("$cmd$model"); done; fi
      [ ${#reviewer_cmds[@]} -gt 0 ] || {
        reviewer_problem="reviewer is proprietary, and none of claude or cursor-agent is on PATH"
        reviewer_fix="Install Claude Code or Cursor's agent CLI, or name a command: guard config set reviewer_cmd_proprietary '<command>'"
        return 1; } ;;
    local) cmd=$(config_get reviewer_cmd_local)
      [ -n "$cmd" ] || {
        reviewer_problem="reviewer is local and no local command is set"
        reviewer_fix="Set one: guard config set reviewer_cmd_local 'codex exec --oss -m <model> --sandbox danger-full-access'"
        return 1; }
      reviewer_cmds=("$cmd") ;;
    *) reviewer_problem="reviewer is '$reviewer' in $config_file"
      reviewer_fix="Set it: guard config set reviewer proprietary"
      return 1 ;;
  esac
  reviewer_cmd=${reviewer_cmds[0]}
}

# read_merge_policy <repo> <base> <guarded 0|1>: sets merge_policy and merge_policy_where, which reads "in <source>",
# or "by default" with the source that leaves it unset.
read_merge_policy() {
  local from
  if [ "$3" = 1 ]; then
    merge_policy=$(git -C "$1" show "$2:guard/budget.card" 2>/dev/null | awk -F': *' '$1 == "merge_policy" { print $2; exit }') || true
    from="guard/budget.card on $2"
  else
    merge_policy=$(awk -F': *' '$1 == "merge_policy" { print $2; exit }' "$config_file" 2>/dev/null) || true
    from=$config_file
  fi
  if [ -n "$merge_policy" ]; then merge_policy_where="in $from"
  else merge_policy=autonomous merge_policy_where="by default, since $from does not set it"; fi
}

config_check() {
  case $1:$2 in
    reviewer:proprietary|reviewer:local|merge_policy:autonomous|merge_policy:semi-manual) ;;
    reviewer:*) echo "reviewer is proprietary or local, not '$2'" ;;
    merge_policy:*) echo "merge_policy is autonomous or semi-manual, not '$2'" ;;
    reviewer_model:*) [[ $2 =~ ^[^[:space:]]+$ ]] || echo "reviewer_model is one model name without spaces, not '$2'" ;;
    *) [[ $whole_keys != *" $1 "* || $2 =~ ^[1-9][0-9]*$ ]] || echo "$1 is a whole number of at least 1, not '$2'" ;;
  esac
  [[ $2 != *$'\n'* ]] || echo "$1 must fit on one line"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  usage() { echo "usage: guard config [list | get KEY | set KEY VALUE]. Keys: ${config_keys[*]}" >&2; exit 64; }
  known() { [[ " ${config_keys[*]} " == *" $1 "* ]] || { echo "guard config: unknown key '$1'" >&2; usage; }; }
  show() { local v; v=$(config_get "$1"); printf '%s: %s\n' "$1" "${v:-<unset>}"; }
  case ${1:-list} in
    list) [ $# -le 1 ] || usage
      echo "# $config_file"
      for k in "${config_keys[@]}"; do show "$k"; done ;;
    get) [ $# -eq 2 ] || usage; known "$2"; config_get "$2" ;;
    set) [ $# -eq 3 ] || usage; known "$2"
      if [ -n "$3" ] && bad=$(config_check "$2" "$3") && [ -n "$bad" ]; then echo "guard config: $bad" >&2; exit 64; fi
      mkdir -p "$(dirname "$config_file")"; touch "$config_file"
      tmp=$(mktemp "$config_file.XXXXXX")
      line="${3:+$2: $3}" awk -v k="$2:" '
        BEGIN { line = ENVIRON["line"] }
        index($0, k) == 1 { if (!done && line != "") print line; done = 1; next }
        { print }
        END { if (!done && line != "") print line }' "$config_file" > "$tmp"
      mv "$tmp" "$config_file"
      show "$2" ;;
    *) usage ;;
  esac
fi
