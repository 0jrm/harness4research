# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== hooks install"
home=$tmp/hooks-home; mkdir -p "$home/.claude" "$home/dotfiles"
cat > "$home/dotfiles/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "check-bash"}]}]
  }
}
JSON
ln -s "$home/dotfiles/settings.json" "$home/.claude/settings.json"
reminder_counts_and_kept_settings() {
  python3 -c 'import json, sys
s = json.load(open(sys.argv[1])); h = s["hooks"]
n = lambda e: sum("needs-you --remind --format claude-hook" in x["command"] for g in h.get(e, []) for x in g["hooks"])
print(n("SessionStart"), n("UserPromptSubmit"), s.get("model"), s.get("permissions"), [x["command"] for g in h.get("UserPromptSubmit", []) for x in g["hooks"]][0], h.get("PreToolUse"))' "$1"
}
expect hooks-dry-run ok '"command": "guard needs-you --remind --format claude-hook"' -- env HOME="$home" "$guard" hooks install claude --dry-run
expect hooks-dry-run-writes-nothing ok - -- bash -c '! grep -q needs-you "$1"' _ "$home/dotfiles/settings.json"
expect hooks-install-user ok 'added SessionStart and UserPromptSubmit hooks' -- env HOME="$home" "$guard" hooks install claude --user
expect hooks-install-keeps-settings ok "^1 1 opus \{'allow': \['Bash\(ls:\*\)'\]\} echo mine \[\{'matcher': 'Bash', 'hooks': \[\{'type': 'command', 'command': 'check-bash'\}\]\}\]$" -- reminder_counts_and_kept_settings "$home/.claude/settings.json"
expect hooks-install-keeps-symlink ok - -- test -L "$home/.claude/settings.json"
sum=$(sha256sum < "$home/dotfiles/settings.json")
expect hooks-install-idempotent ok 'nothing changed' -- env HOME="$home" "$guard" hooks install claude
expect hooks-install-unchanged ok - -- test "$sum" = "$(sha256sum < "$home/dotfiles/settings.json")"
expect hooks-install-project ok "^$ny/.claude/settings.json: added SessionStart and UserPromptSubmit" -- in_dir "$ny" env HOME="$home" "$guard" hooks install claude --project
expect hooks-install-project-shape ok '^1 1 None None ' -- reminder_counts_and_kept_settings "$ny/.claude/settings.json"
mkdir -p "$tmp/bad-home/.claude"; echo '{"hooks": ' > "$tmp/bad-home/.claude/settings.json"
expect hooks-refuse-bad-json fail 'is not valid JSON' -- env HOME="$tmp/bad-home" "$guard" hooks install claude
expect hooks-bad-json-untouched ok '^\{"hooks": $' -- cat "$tmp/bad-home/.claude/settings.json"
echo '{"hooks": {"SessionStart": [{"hooks": null}]}}' > "$tmp/bad-home/.claude/settings.json"
expect hooks-refuse-bad-shape fail 'does not have the shape Claude Code reads for hooks' -- env HOME="$tmp/bad-home" "$guard" hooks install claude
mkdir -p "$tmp/locked-home/.claude"; chmod 555 "$tmp/locked-home/.claude"
if [ "$(id -u)" -eq 0 ]; then skip hooks-unwritable "root writes through a read-only directory"
else expect hooks-unwritable fail "^guard hooks: cannot write $tmp/locked-home/.claude/settings.json: Permission denied$" -- env HOME="$tmp/locked-home" "$guard" hooks install claude; fi
chmod 755 "$tmp/locked-home/.claude"
expect hooks-unknown-agent fail 'invalid choice' -- "$guard" hooks install codex

expect eval-analyze-unit ok '^OK' -- python3 -m unittest discover -s "$here/eval/tests"
