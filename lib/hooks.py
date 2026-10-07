#!/usr/bin/env python3
"""usage: guard hooks install claude [--user | --project] [--dry-run]

Adds SessionStart and UserPromptSubmit hooks that run `guard needs-you --remind --format claude-hook` to the
Claude Code settings in ~/.claude/settings.json (--user, the default) or in .claude/settings.json at the top of
the current git repository (--project). Every other key and hook stays. An event that already runs the reminder
is left alone, so a second run changes nothing. --dry-run prints the settings it would write and writes nothing.
Python 3 standard library only.
"""
import json, os, shutil, subprocess, sys, tempfile
from needs_you import Parser

COMMAND = "guard needs-you --remind --format claude-hook"
EVENTS = ("SessionStart", "UserPromptSubmit")

def settings_path(project):
    if not project:
        return os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
    p = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"guard hooks: --project needs a git repository, and {os.getcwd()} is not in one")
    return os.path.join(p.stdout.strip(), ".claude", "settings.json")

def well_formed(groups):
    return isinstance(groups, list) and all(
        isinstance(g, dict) and isinstance(g.get("hooks", []), list) and all(isinstance(h, dict) for h in g.get("hooks", []))
        for g in groups)

def load(path):
    try:
        with open(path) as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    try:
        settings = json.loads(text) if text.strip() else {}
    except ValueError as e:
        sys.exit(f"guard hooks: {path} is not valid JSON ({e}); fix it by hand, then rerun")
    hooks = settings.get("hooks", {}) if isinstance(settings, dict) else None
    if not isinstance(hooks, dict) or not all(well_formed(hooks.get(e, [])) for e in EVENTS):
        sys.exit(f"guard hooks: {path} does not have the shape Claude Code reads for hooks; fix it by hand, then rerun")
    return settings

def add_missing_reminders(settings):
    hooks = settings.setdefault("hooks", {})
    added = []
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if any("needs-you --remind" in str(h.get("command", "")) for g in groups for h in g.get("hooks", [])):
            continue
        groups.append({"hooks": [{"type": "command", "command": COMMAND}]})
        added.append(event)
    return added

def write(path, text):
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)

def main():
    ap = Parser(prog="guard hooks", description=__doc__.split("\n\n")[1])
    ap.add_argument("action", choices=("install",))
    ap.add_argument("agent", choices=("claude",))
    scope = ap.add_mutually_exclusive_group()
    scope.add_argument("--user", action="store_true")
    scope.add_argument("--project", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    path = settings_path(a.project)
    settings = load(path)
    added = add_missing_reminders(settings)
    text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    if a.dry_run:
        print(text, end="")
        return
    if not added:
        print(f"{path} already runs {COMMAND} on {' and '.join(EVENTS)}; nothing changed")
        return
    write(path, text)
    print(f"{path}: added {' and '.join(added)} hooks that run {COMMAND}")
    if not shutil.which("guard"):
        print("The hooks call guard by name, and guard is not on this PATH. Run install.sh, or add its bin directory to PATH.", file=sys.stderr)

if __name__ == "__main__":
    main()
