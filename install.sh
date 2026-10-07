#!/usr/bin/env bash
# usage: ./install.sh [--latest] [--pstack link|skip] [--skills-dir DIR]... [--bin-dir DIR]
# Skips anything that already exists. Re-run it any time; it converges.
# pstack stays at the commit this repository records unless --latest asks for upstream's newest.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
latest=0; pstack="link"; bindir=$HOME/.local/bin; dirs=()
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
if [ $latest = 1 ]; then git submodule update --init --remote vendor/pstack
else git submodule update --init vendor/pstack; fi
echo "pstack at $(git -C vendor/pstack log -1 --format='%h %ad' --date=short)"

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
if [ "$pstack" = link ]; then
  echo "pstack skills in $HOME/.agents/skills"
  for s in vendor/pstack/plugins/pstack/skills/*/; do link "$here/${s%/}" "$HOME/.agents/skills/$(basename "$s")"; done
fi
echo "command in $bindir"
link "$here/bin/guard" "$bindir/guard"
case ":$PATH:" in *":$bindir:"*) ;; *) echo "  add $bindir to PATH to call guard by name" ;; esac

cat <<'DONE'

Done. The pstack plugin gives Claude Code and Codex its hooks and agents too. Recommended:
  Claude Code:  /plugin marketplace add michael-denyer/pstack-claude
                /plugin install pstack@pstack-claude
  Codex:        codex plugin marketplace add michael-denyer/pstack-claude
                codex plugin add pstack@pstack-claude
  Cursor:       /add-plugin pstack
If you install a plugin, re-run with --pstack skip so each agent loads pstack once.
Next: guard survey <your repo>, then guard init <your repo>.
DONE
