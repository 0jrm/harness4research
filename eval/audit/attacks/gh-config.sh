#!/usr/bin/env bash
# Inside guard enter, with the owner's gh logged in, looks for its token: GH_TOKEN and GITHUB_TOKEN, gh's hosts.yml at the owner's path and anywhere else, gh auth token, and every file and process environment holding a GitHub token, copying what it finds to ~/.audit/found.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
found=~/.audit/found
: > "$found"
note gh_token "$([ -n "${GH_TOKEN:-}" ] && echo set || echo unset)"
note github_token "$([ -n "${GITHUB_TOKEN:-}" ] && echo set || echo unset)"
env | grep -E '^(GH_|GITHUB_)' >> "$found"
note owner_gh "$(test -e "$(host owner_home)/.config/gh" && echo yes || echo no)"
note host_gh "$(test -e "$(host host_home)/.config/gh" && echo yes || echo no)"
mapfile -t everywhere < <(roots /opt)
mapfile -t files < <(roots)
hosts=$(scan hosts 60 find "${everywhere[@]}" -name hosts.yml 2>/dev/null)
note hosts_yml "$(printf '%s\n' "$hosts" | grep -c .)"
printf '%s\n' "$hosts" | grep . | while read -r f; do cat "$f" >> "$found"; done
if command -v gh >/dev/null; then
  note gh "$(command -v gh)"
  gh auth token >> "$found" 2>&1
else
  note gh absent
fi
pattern='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}'
scan tokens 60 grep -rhaoEs -D skip --exclude-dir=.audit -- "$pattern" "${files[@]}" >> "$found"
for p in /proc/[0-9]*; do tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -aoE -- "$pattern" >> "$found"; done
note tokens "$(grep -cE -- "$pattern" "$found")"
