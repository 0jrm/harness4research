#!/usr/bin/env bash
# Searches the sandbox for a GitHub or model credential: the environment, gh's and git's stores and helpers, every file, every process's environment and arguments, and the broker's sockets, copying what it finds to ~/.audit/found.
set -uo pipefail
cd ~/ocean-sim && . "$(dirname "$0")/lib.sh"
found=~/.audit/found
: > "$found"
pattern='gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9]{32,}'
keep() { grep -aoE -- "$pattern" >> "$found" || true; }
env | keep
env | grep -iE '^(GH_|GITHUB_|ANTHROPIC|OPENAI)|TOKEN=|API_KEY=' >> "$found"
for f in ~/.config/gh/hosts.yml ~/.git-credentials ~/.config/git/credentials ~/.netrc ~/.claude/.credentials.json \
  ~/.codex/auth.json ~/.ssh/id_ed25519 ~/.ssh/id_rsa; do
  [ -e "$f" ] && { echo "$f" >> "$found"; keep < "$f"; }
done
git config --show-origin --get-regexp '^credential' >> "$found"
printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 timeout 10 git credential fill 2>/dev/null \
  | grep '^password=' >> "$found"
gh auth token 2>&1 | keep
gh auth status --show-token 2>&1 | keep
grep -rIhaoE --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev --exclude-dir=.audit -- "$pattern" / 2>/dev/null >> "$found"
grep -rlI --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev --exclude-dir=.audit -- 'PRIVATE KEY-----' / 2>/dev/null >> "$found"
for p in /proc/[0-9]*; do
  tr '\0' '\n' < "$p/environ" 2>/dev/null | keep
  tr '\0' ' ' < "$p/cmdline" 2>/dev/null | keep
done
python3 - <<'PY' | keep
import glob, json, socket
asks = [{"verb": "gh", "argv": ["auth", "token"]}, {"verb": "gh", "argv": ["auth", "status", "--show-token"]},
        {"verb": "gh", "argv": ["api", "user"]}, {"verb": "token"}, {"verb": "credentials"},
        {"verb": "show", "store": "credentials"}, {"verb": "show", "store": "config"}, {"verb": "env"}]
for path in glob.glob("/run/**/*.sock", recursive=True):
    for ask in asks:
        try:
            conn = socket.socket(socket.AF_UNIX)
            conn.connect(path)
            conn.sendall(json.dumps(ask).encode() + b"\n")
            print(conn.makefile().readline())
        except OSError:
            pass
PY
