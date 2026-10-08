#!/usr/bin/env bash
# usage: ./install.sh [--pstack link|skip] [--latest] [--skills-dir DIR]... [--bin-dir DIR]
# Skips anything that already exists. Re-run it any time; it converges.
# pstack is opt-in: --pstack link fetches github.com/cursor/plugins at the commit this repository records (or its
# newest with --latest) and links pstack's skills, and its agents for Claude Code.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
latest=0; pstack="skip"; bindir=$HOME/.local/bin; dirs=()
while [ $# -gt 0 ]; do
  case $1 in
    --latest) latest=1; shift ;;
    --pinned) shift ;;
    --pstack) pstack=$2; shift 2 ;;
    --skills-dir) dirs+=("$2"); shift 2 ;;
    --bin-dir) bindir=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
done
if [ ${#dirs[@]} -eq 0 ]; then
  dirs=("$HOME/.agents/skills")
  [ -d "$HOME/.claude" ] && dirs+=("$HOME/.claude/skills")
  [ -d "$HOME/.cursor" ] && dirs+=("$HOME/.cursor/skills")
fi

cd "$here"

link() {
  local src=$1 dst=$2
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then return; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then echo "  skip $dst (exists; inspect it before replacing)"; return; fi
  mkdir -p "$(dirname "$dst")"; ln -s "$src" "$dst"; echo "  link $dst"
}
for d in "${dirs[@]}"; do
  echo "skills in $d"
  for s in "$here"/skills/*/; do link "${s%/}" "$d/$(basename "$s")"; done
done
# Links an earlier install made into vendor/pstack, which moved to vendor/cursor-plugins, now point nowhere.
for d in "${dirs[@]}" "$HOME/.agents/skills"; do
  for l in "$d"/*; do
    if [ -L "$l" ] && [[ $(readlink "$l") == "$here/vendor/pstack/"* ]]; then rm "$l"; echo "  unlink $l (old pstack location)"; fi
  done
done
if [ "$pstack" = link ]; then
  if [ $latest = 1 ]; then git submodule update --init --remote vendor/cursor-plugins
  else git submodule update --init vendor/cursor-plugins; fi
  p=vendor/cursor-plugins/pstack
  echo "pstack $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$p/.cursor-plugin/plugin.json") from cursor/plugins at $(git -C vendor/cursor-plugins log -1 --format='%h %ad' --date=short)"
  for d in "${dirs[@]}"; do
    echo "pstack skills in $d"
    for s in "$p"/skills/*/; do link "$here/${s%/}" "$d/$(basename "$s")"; done
  done
  if [ -d "$HOME/.claude" ]; then
    echo "pstack agents in $HOME/.claude/agents"
    for a in "$p"/agents/*.md; do link "$here/$a" "$HOME/.claude/agents/$(basename "$a")"; done
  fi
fi
echo "command in $bindir"
link "$here/bin/guard" "$bindir/guard"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "  add $bindir to PATH to call guard by name" ;; esac

cat <<'DONE'

Done. pstack (github.com/cursor/plugins, Lauren Tan) is optional:
  Cursor:               /add-plugin pstack
  Claude Code, Codex:   ./install.sh --pstack link
Its skills are written for Cursor, so a few steps (Cursor's transcript folder, the generalPurpose subagent,
the create-skill and cursor-team-kit skills, grok as a default model) do not apply outside it.
Next: guard survey <your repo>, then guard init <your repo>.
DONE
