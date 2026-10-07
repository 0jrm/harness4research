#!/usr/bin/env bash
# usage: guard config [list | get KEY | set KEY VALUE]
# Per-user settings, flat `key: value` lines like the budget card; the first match wins. An empty VALUE removes the key.
config_file=${XDG_CONFIG_HOME:-$HOME/.config}/guard/config
config_keys=(reviewer reviewer_cmd_proprietary reviewer_cmd_local review_rounds merge_policy)
declare -A config_default=([reviewer]=proprietary [review_rounds]=2 [merge_policy]=autonomous)

config_get() {
  local v
  v=$(awk -v k="$1:" 'index($0, k) == 1 { sub(/^[^:]*: */, ""); print; f = 1; exit } END { exit !f }' "$config_file" 2>/dev/null) \
    || v=${config_default[$1]:-}
  printf '%s\n' "$v"
}

config_check() {
  case $1:$2 in
    reviewer:proprietary|reviewer:local|merge_policy:autonomous|merge_policy:semi-manual) ;;
    reviewer:*) echo "reviewer is proprietary or local, not '$2'" ;;
    merge_policy:*) echo "merge_policy is autonomous or semi-manual, not '$2'" ;;
    review_rounds:*) [[ $2 =~ ^[1-9][0-9]*$ ]] || echo "review_rounds is a whole number of at least 1, not '$2'" ;;
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
