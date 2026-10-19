# shellcheck shell=bash disable=SC2034,SC2154  # sourced: the caller sets $here and reads the p_* results
# Sourced by bin/guard and lib/init.sh, after they set $here to the harness root.
# A guard/VERSION without a schema line was written by schema 1.
h_schema=$(cat "$here/SCHEMA")

# project_version <repo>: sets p_base, p_guarded (0 or 1), p_from (installer commit, may be empty or unknown), p_schema,
# p_release (empty for a guard installed before release stamps), p_pin (the harness: line of guard/budget.card, empty
# before the pin) and p_mode: offline when guard/harness-<pin>.sh is on the base branch, online for another pin, and
# bin for a project without a pin, whose scripts are guard/bin/.
project_version() {
  local v
  p_base=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  p_guarded=0; git -C "$1" cat-file -e "$p_base:guard/run" 2>/dev/null && p_guarded=1
  v=$(git -C "$1" show "$p_base:guard/VERSION" 2>/dev/null || true)
  p_from=$(awk -F': *' '$1=="installer" {print $2; exit}' <<<"$v")
  p_schema=$(awk -F': *' '$1=="schema" {print $2; exit}' <<<"$v"); p_schema=${p_schema:-1}
  p_release=$(awk -F': *' '$1=="release" {print $2; exit}' <<<"$v")
  v=$(git -C "$1" show "$p_base:guard/budget.card" 2>/dev/null || true)
  p_pin=$(awk -F': *' '$1=="harness" {print $2; exit}' <<<"$v")
  if [ -z "$p_pin" ]; then p_mode=bin
  elif git -C "$1" cat-file -e "$p_base:guard/harness-$p_pin.sh" 2>/dev/null; then p_mode=offline
  else p_mode=online; fi
}

# skew, after project_version: prints current, project-older, harness-older, or unknown-install. A pinned project is
# current while its schema is this harness's and its pin's lib/guard/ and templates/ match this harness's HEAD, older
# when its schema is lower or the pin is an earlier commit of this harness, and harness-older when this harness lacks
# the pin or is behind it.
skew() {
  local c
  if [ -n "$p_pin" ]; then
    if [ "$p_schema" -gt "$h_schema" ] || ! c=$(git -C "$here" rev-parse -q --verify "$p_pin^{commit}" 2>/dev/null) \
      || ! git -C "$here" merge-base --is-ancestor "$c" HEAD; then echo harness-older
    elif [ "$p_schema" -lt "$h_schema" ]; then echo project-older
    elif git -C "$here" diff --quiet "$c" HEAD -- lib/guard templates; then echo current
    else echo project-older; fi
    return
  fi
  case $p_from in ''|unknown) echo unknown-install; return ;; esac
  if [ "$p_schema" -gt "$h_schema" ] || ! git -C "$here" cat-file -e "$p_from^{commit}" 2>/dev/null \
    || ! git -C "$here" merge-base --is-ancestor "$p_from" HEAD; then echo harness-older
  elif [ "$p_schema" -lt "$h_schema" ] || ! git -C "$here" diff --quiet "$p_from" HEAD -- templates; then echo project-older
  else echo current; fi
}

harness_release() { git -C "$here" describe --tags --always 2>/dev/null || echo unknown; }
