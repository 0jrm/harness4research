# Sourced by bin/guard and lib/init.sh, after they set $here to the harness root.
# A guard/VERSION without a schema line was written by schema 1.
h_schema=$(cat "$here/SCHEMA")

# project_version <repo>: sets p_base, p_guarded (0 or 1), p_from (installer commit, may be empty or unknown), p_schema.
project_version() {
  local v
  p_base=$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  p_guarded=0; git -C "$1" cat-file -e "$p_base:guard/run" 2>/dev/null && p_guarded=1
  v=$(git -C "$1" show "$p_base:guard/VERSION" 2>/dev/null || true)
  p_from=$(awk -F': *' '$1=="installer" {print $2; exit}' <<<"$v")
  p_schema=$(awk -F': *' '$1=="schema" {print $2; exit}' <<<"$v"); p_schema=${p_schema:-1}
}

# skew, after project_version: prints current, project-older, harness-older, or unknown-install.
skew() {
  case $p_from in ''|unknown) echo unknown-install; return ;; esac
  if [ "$p_schema" -gt "$h_schema" ] || ! git -C "$here" cat-file -e "$p_from^{commit}" 2>/dev/null \
    || ! git -C "$here" merge-base --is-ancestor "$p_from" HEAD; then echo harness-older
  elif [ "$p_schema" -lt "$h_schema" ] || ! git -C "$here" diff --quiet "$p_from" HEAD -- templates; then echo project-older
  else echo current; fi
}

harness_release() { git -C "$here" describe --tags --always 2>/dev/null || echo unknown; }
