# shellcheck shell=bash
# The branch-name rule. A name is <type>/<slug>: type from branch_types, slug lowercase kebab-case with at least two
# words of three or more letters and no hash-like run (six or more hex characters mixing digits and letters).
# run/, card/ and report/ need only the hash check, since their slug is the run id and records already ride them.
# release/v<version>, guard/init and guard/update pass as they are.

branch_types=(feature feat fix docs refactor test chore perf ci eval exp rec run card report talk)

# branch_name_problem <name>: prints why the name is not descriptive, or nothing when it passes.
branch_name_problem() {
  local name=$1 type slug word hex words=0
  [[ $name =~ ^release/v[0-9]+(\.[0-9]+)*$ || $name == guard/init || $name == guard/update ]] && return
  type=${name%%/*} slug=${name#*/}
  if [[ $name != */* || " ${branch_types[*]} " != *" $type "* ]]; then
    echo "$name does not start with a known type. Use one of: ${branch_types[*]/%//}."; return
  fi
  if [[ ! $slug =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "$slug is not lowercase kebab-case: lowercase letters, digits, and single hyphens between words."; return
  fi
  for hex in $(grep -oE '[0-9a-f]{6,}' <<<"$slug"); do
    [[ $hex =~ [0-9] && $hex =~ [a-f] ]] && { echo "$slug holds a hash or random suffix, $hex. Name the change, not its id."; return; }
  done
  case $type in run|card|report) return 0 ;; esac
  for word in ${slug//-/ }; do [[ $word =~ ^[a-z]{3,}$ ]] && words=$((words + 1)); done
  [ "$words" -ge 2 ] || echo "$slug does not say what the branch does. Use at least two words of three or more letters, such as cram-transfer."
}
