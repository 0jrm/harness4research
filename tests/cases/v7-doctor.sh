# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== doctor"
D=$tmp/doc
git init -q --bare -b main "$D.git"; git clone -q "$D.git" "$D" 2>/dev/null
git -C "$D" checkout -q -b main; echo "# d" > "$D/README.md"; git -C "$D" add -A; git -C "$D" commit -q -m init
git -C "$D" push -q -u origin main; git -C "$D" remote set-head origin -a >/dev/null
"$guard" init "$D" --worktree "$D.wt" --offline >/dev/null 2>&1
git -C "$D" update-ref refs/remotes/origin/main guard/init
git -C "$D" remote set-url origin https://github.com/lab/proj.git
mkdir -p "$tmp/home/.agents/skills" "$tmp/home-bare"
for s in "$here"/skills/*/; do ln -s "${s%/}" "$tmp/home/.agents/skills/"; done
printf '#!/bin/sh\necho ready\n' > "$tmp/doctor-reviewer"; chmod +x "$tmp/doctor-reviewer"
mkdir -p "$tmp/xdg-doctor/guard"; echo "reviewer_cmd_proprietary: $tmp/doctor-reviewer -p" > "$tmp/xdg-doctor/guard/config"
setup=(XDG_CONFIG_HOME="$tmp/xdg-doctor" MOCK_GH_TOKEN=github_pat_agent MOCK_GH_ADMIN=false MOCK_GH_RULES=$'pull_request\ncheck fence'
  "MOCK_GH_RUNS=success 2026-10-01T12:00:00Z https://github.com/lab/proj/actions/runs/1" MOCK_SACCTMGR_ASSOC='|cpu=600000')
doctor() { env -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK -u GUARD_CONFIG HOME="$tmp/home" "${setup[@]}" "$@" "$guard" doctor "$D"; }
expect doctor-placeholders fail '^FAIL  guard/budget.card on origin/main still has placeholders: account start_date stop_date' -- doctor
expect doctor-placeholder-account fail '^FAIL  guard/budget.card on origin/main sets no account$' -- doctor
expect doctor-remedy-links-readme fail '^      Replace each <placeholder> .*: https://github.com/0jrm/harness4research#3-fill-in-the-guard-and-merge-it$' -- doctor
git -C "$tmp/proj" show "$good:guard/budget.card" > "$D.wt/guard/budget.card"
git -C "$D.wt" commit -q -am "chore(guard): set budget"; git -C "$D" update-ref refs/remotes/origin/main guard/init
expect doctor-clean-card ok '^pass  guard/budget.card on origin/main has no placeholders$' -- doctor
expect doctor-all-pass ok '^16 passed, 0 failed, 0 cannot check from here$' -- doctor
expect doctor-version ok '^pass  guard schema [0-9]+ \(release .*\) against harness schema [0-9]+ .*: current$' -- doctor
expect doctor-version-once ok - -- bash -c '! grep -E "\(release ([^ )]+)\1\)" <<<"$1"' _ "$(doctor)"
expect doctor-workflow ok '^pass  .github/workflows/guard-fence.yml on origin/main defines guard-fence / fence$' -- doctor
doctor > "$tmp/doctor-out"
expect onboard-names-real-doctor-lines ok - -- bash -c 'out=$1; shift; grep -ho "\`pass  [^\`]*\`" "$@" | tr -d "\`" | sed -e "s/<[^>]*>/.*/g" -e "s/\.\.\./.*/g" |
  while IFS= read -r line; do grep -qE "^$line" "$out" || { echo "not in doctor output: $line"; exit 1; }; done' _ "$tmp/doctor-out" "$here/skills/guard-onboard/SKILL.md" "$here"/skills/guard-onboard/references/*.md
expect onboard-doctor-lines-counted ok '^([6-9]|[1-9][0-9]+)$' -- bash -c 'grep -ho "\`pass  [^\`]*\`" "$@" | wc -l' _ "$here/skills/guard-onboard/SKILL.md" "$here"/skills/guard-onboard/references/*.md
expect doctor-no-colour-in-pipe fail - -- grep -q $'\e' "$tmp/doctor-out"
expect doctor-no-gh ok '^cannot check from here  whether guard-fence / fence has run on GitHub: gh is not on PATH$' -- doctor PATH="$(path_without gh)"
expect doctor-cannot-is-not-pass ok '^14 passed, 0 failed, 2 cannot check from here$' -- doctor PATH="$(path_without gh)"
expect doctor-gh-logged-out ok '^cannot check from here  whether main has an active ruleset requiring guard-fence / fence: gh is not logged in$' -- doctor MOCK_GH_TOKEN=
expect doctor-not-github ok '^cannot check from here  .*: origin is not a github.com remote$' -- \
  doctor GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.url GIT_CONFIG_VALUE_0="$D.git"
expect doctor-ruleset ok '^pass  main has an active ruleset requiring a pull request and guard-fence / fence$' -- doctor
expect doctor-ruleset-full-name ok '^pass  main has an active ruleset' -- doctor MOCK_GH_RULES=$'pull_request\ncheck guard-fence / fence'
expect doctor-ruleset-no-check fail '^FAIL  main has no active rule requiring guard-fence / fence$' -- doctor MOCK_GH_RULES=$'pull_request\ncheck lint'
expect doctor-ruleset-none fail '^FAIL  main has no active rule requiring a pull request and guard-fence / fence$' -- doctor MOCK_GH_RULES=
expect doctor-ruleset-free-plan fail '^FAIL  GitHub offers no rulesets on lab/proj: Upgrade to GitHub Pro' -- \
  doctor MOCK_GH_RULES='!Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
expect doctor-policy-free-plan fail '^FAIL  merge_policy is autonomous .*, but GitHub offers no rulesets on lab/proj, so guard merge refuses every merge$' -- \
  doctor MOCK_GH_RULES="$free_plan"
expect doctor-policy-free-plan-fix fail '^      Set merge_policy: semi-manual in guard/budget.card in a pull request a person merges, or give lab/proj rulesets: ' -- \
  doctor MOCK_GH_RULES="$free_plan"
expect doctor-fence-never-ran fail '^FAIL  guard-fence / fence has never completed a run on GitHub$' -- doctor MOCK_GH_RUNS=
expect doctor-fence-failure-ran ok '^pass  guard-fence / fence has run on GitHub \(last completed run: failure, ' -- doctor "MOCK_GH_RUNS=failure 2026-10-01T12:00:00Z https://x/1"
expect doctor-fence-broken fail '^FAIL  guard-fence / fence last completed run ended startup_failure' -- doctor "MOCK_GH_RUNS=startup_failure 2026-10-01T12:00:00Z https://x/1"
expect doctor-ssh fail '^FAIL  SSH_AUTH_SOCK is set in this shell' -- doctor SSH_AUTH_SOCK=/tmp/agent.sock
expect doctor-classic-token fail '^FAIL  the GitHub token in this shell is a classic or OAuth token with scopes repo, workflow,' -- \
  doctor MOCK_GH_TOKEN=gho_x MOCK_GH_SCOPES='repo, workflow'
expect doctor-admin fail '^FAIL  the GitHub login in this shell administers lab/proj' -- doctor MOCK_GH_ADMIN=true
expect doctor-admin-protected fail '^FAIL  the GitHub login in this shell administers lab/proj' -- doctor MOCK_GH_ADMIN=true MOCK_GH_PROTECTION='{}'
expect doctor-admin-fine-grained ok '^pass  the GitHub login in this shell does not administer lab/proj$' -- \
  doctor MOCK_GH_ADMIN=true MOCK_GH_PROTECTION='!Resource not accessible by personal access token'
expect doctor-admin-forbidden-otherwise fail '^FAIL  the GitHub login in this shell administers lab/proj' -- \
  doctor MOCK_GH_ADMIN=true MOCK_GH_PROTECTION='!API rate limit exceeded (HTTP 403)'
expect doctor-no-token ok '^pass  no GitHub token in this shell' -- doctor MOCK_GH_TOKEN=
expect doctor-cap ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- doctor
expect doctor-user-cap ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\ntester|cpu=600000'
expect doctor-no-cap fail '^FAIL  Slurm sets no GrpTRESMins cap on account gom$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\ntester|'
expect doctor-other-user-cap fail '^FAIL  Slurm sets no GrpTRESMins cap on account gom$' -- doctor MOCK_SACCTMGR_ASSOC=$'|\nalice|cpu=100\ntester|'
expect doctor-no-user-var ok '^pass  Slurm caps account gom at GrpTRESMins=cpu=600000$' -- env -u USER -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK HOME="$tmp/home" "${setup[@]}" "$guard" doctor "$D"
expect doctor-no-account fail '^FAIL  Slurm has no account gom$' -- doctor MOCK_SACCTMGR_ASSOC=
expect doctor-no-sacctmgr ok '^cannot check from here  whether Slurm caps account gom: sacctmgr is not on this host$' -- doctor PATH="$(path_without sacctmgr)"
expect doctor-skills-missing fail '^FAIL  skills in ~/.agents/skills do not link to this harness: .*present \(missing\)' -- doctor HOME="$tmp/home-bare"
mkdir -p "$tmp/home/.claude"
expect doctor-skills-claude fail '^FAIL  skills in ~/.claude/skills do not link to this harness' -- doctor
rmdir "$tmp/home/.claude"
expect doctor-unguarded fail '^FAIL  guard/run is not on origin/main$' -- env HOME="$tmp/home" "$guard" doctor "$tmp/agents"
expect doctor-not-a-repo fail 'is not a git repository' -- "$guard" doctor "$tmp/home"
git -C "$D" status --porcelain > "$tmp/doctor-status"; touch "$tmp/doctor-before"
doctor >/dev/null; doctor MOCK_GH_TOKEN= SSH_AUTH_SOCK=/x >/dev/null; doctor PATH="$(path_without gh)" >/dev/null
expect doctor-writes-nothing ok '^$' -- find "$D" "$D.wt" "$tmp/home" -newer "$tmp/doctor-before"
expect doctor-status-unchanged ok '^$' -- bash -c 'git -C "$1" status --porcelain | diff - "$2"' _ "$D" "$tmp/doctor-status"
expect doctor-reviewer ok "^pass  reviewer is proprietary: $tmp/doctor-reviewer -p, and $tmp/doctor-reviewer is an executable file$" -- doctor
expect doctor-reviewer-answers ok "^pass  the reviewer $tmp/doctor-reviewer starts and answers on skynet$" -- doctor
xdg() {  # xdg <name> <config line>...: prints a fresh XDG_CONFIG_HOME whose guard config holds the lines
  mkdir -p "$tmp/xdg-$1/guard"; printf '%s\n' "${@:2}" > "$tmp/xdg-$1/guard/config"; echo "$tmp/xdg-$1"
}
mkdir -p "$tmp/probe"
stand_in() {  # stand_in <name> <script body>: prints an XDG_CONFIG_HOME whose reviewer is a stand-in running the body
  printf '#!/bin/bash\n%s\n' "$2" > "$tmp/probe/$1"; chmod +x "$tmp/probe/$1"; xdg "probe-$1" "reviewer_cmd_proprietary: $tmp/probe/$1 -p"
}
expect doctor-probe-login fail '^FAIL  no reviewer answers on skynet: login is not logged in \(Error: Authentication required\)$' -- \
  doctor XDG_CONFIG_HOME="$(stand_in login 'echo "Error: Authentication required" >&2; exit 1')"
expect doctor-probe-login-fix fail '^      Log in to login\. A CLI on a host without internet access can say this too, so check that first$' -- \
  doctor XDG_CONFIG_HOME="$(stand_in login 'echo "Error: Authentication required" >&2; exit 1')"
expect doctor-probe-memory fail '^FAIL  no reviewer answers on skynet: oom ran out of memory \(RangeError: WebAssembly\.instantiate\(\): Out of memory\) under a soft ulimit -v of ' -- \
  doctor XDG_CONFIG_HOME="$(stand_in oom 'printf "/opt/a.js:2\n  ^\n\nRangeError: WebAssembly.instantiate(): Out of memory\n\nNode.js v24.5.0\n" >&2; exit 1')"
expect doctor-probe-memory-fix fail '^      Raise the soft limit in the shell that runs guard review and guard ship, with ulimit -v unlimited; the hard limit here is ' -- \
  doctor XDG_CONFIG_HOME="$(stand_in oom 'echo "RangeError: Out of memory" >&2; exit 1')"
expect doctor-probe-network fail '^FAIL  no reviewer answers on skynet: offline cannot reach its service \(Error: getaddrinfo ENOTFOUND api\.example\.com\)$' -- \
  doctor XDG_CONFIG_HOME="$(stand_in offline 'echo "Error: getaddrinfo ENOTFOUND api.example.com" >&2; exit 1')"
expect doctor-probe-timeout fail '^FAIL  no reviewer answers on skynet: slow did not answer within 1 seconds$' -- \
  doctor HPC_REVIEWER_PROBE_SECONDS=1 XDG_CONFIG_HOME="$(stand_in slow 'sleep 10')"
expect doctor-probe-silent fail '^FAIL  no reviewer answers on skynet: silent exited 0 with an empty reply$' -- \
  doctor XDG_CONFIG_HOME="$(stand_in silent 'true')"
mkdir -p "$tmp/probe-chain"; printf '#!/bin/bash\n[ "$*" = "auth status" ] && exit 0; echo "Failed to authenticate. API Error: 401" >&2; exit 1\n' > "$tmp/probe-chain/claude"
chmod +x "$tmp/probe-chain/claude"; ln -sf "$tmp/doctor-reviewer" "$tmp/probe-chain/cursor-agent"
expect doctor-probe-fallback ok '^pass  the reviewer cursor-agent starts and answers on skynet; claude is not logged in \(Failed to authenticate\. API Error: 401\); so reviews fall back to it$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/probe-chain:$PATH"
mkdir -p "$tmp/claude-bin"; ln -s "$tmp/doctor-reviewer" "$tmp/claude-bin/claude"
expect doctor-reviewer-default ok '^pass  reviewer is proprietary: claude -p --permission-mode acceptEdits --strict-mcp-config --setting-sources project --disable-slash-commands --tools=Bash,Read,Edit,Grep,Glob --allowedTools=Bash, and claude is on PATH$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-bin:$PATH"
expect doctor-reviewer-missing fail '^FAIL  reviewer is proprietary, and none of claude or cursor-agent is on PATH$' -- doctor XDG_CONFIG_HOME="$(xdg empty)"
expect doctor-reviewer-missing-hint fail "^      Install Claude Code or Cursor's agent CLI, or name a command: guard config set reviewer_cmd_proprietary '<command>'$" -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)"
mkdir -p "$tmp/cursor-bin" "$tmp/claude-auth"; ln -s "$tmp/doctor-reviewer" "$tmp/cursor-bin/cursor-agent"
cat > "$tmp/claude-auth/claude" <<'FAKE'
#!/bin/sh
if [ "$*" = "auth status" ]; then printf '{\n  "loggedIn": %s,\n  "authMethod": "none"\n}\n' "$MOCK_CLAUDE_LOGGED_IN"; else echo ready; fi
FAKE
chmod +x "$tmp/claude-auth/claude"
expect doctor-reviewer-chain ok '^pass  reviewer is proprietary: claude, then cursor-agent, and claude is on PATH$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-bin:$tmp/cursor-bin:$PATH"
expect doctor-reviewer-cursor-only ok '^pass  reviewer is proprietary: cursor-agent -p --force --trust, and cursor-agent is on PATH$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/cursor-bin:$PATH"
expect doctor-claude-signed-in ok '^pass  reviewer is proprietary: claude, then cursor-agent, and claude is on PATH$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-auth:$tmp/cursor-bin:$PATH" MOCK_CLAUDE_LOGGED_IN=true
expect doctor-claude-signed-out-falls-back ok '^pass  reviewer is proprietary: claude, then cursor-agent, and claude is on PATH; claude is not signed in, so reviews fall back to cursor-agent; run claude auth login$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-auth:$tmp/cursor-bin:$PATH" MOCK_CLAUDE_LOGGED_IN=false
expect doctor-claude-signed-out-alone fail '^FAIL  reviewer is proprietary: claude -p --permission-mode acceptEdits --strict-mcp-config --setting-sources project --disable-slash-commands --tools=Bash,Read,Edit,Grep,Glob --allowedTools=Bash, and claude is not signed in$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-auth:$PATH" MOCK_CLAUDE_LOGGED_IN=false
expect doctor-claude-signed-out-remedy fail '^      Run claude auth login$' -- \
  doctor XDG_CONFIG_HOME="$(xdg empty)" PATH="$tmp/claude-auth:$PATH" MOCK_CLAUDE_LOGGED_IN=false
expect doctor-reviewer-not-on-path fail '^FAIL  reviewer is proprietary: no-such-reviewer -p, and no-such-reviewer is not on PATH$' -- \
  doctor XDG_CONFIG_HOME="$(xdg gone 'reviewer_cmd_proprietary: no-such-reviewer -p')"
expect doctor-local-no-command fail "^      Set one: guard config set reviewer_cmd_local 'codex exec --oss -m <model> --sandbox danger-full-access'$" -- \
  doctor XDG_CONFIG_HOME="$(xdg local 'reviewer: local')"
expect doctor-local-no-command-line fail '^FAIL  reviewer is local and no local command is set$' -- doctor XDG_CONFIG_HOME="$(xdg local 'reviewer: local')"
mkdir -p "$tmp/home/bin"; ln -s "$tmp/doctor-reviewer" "$tmp/home/bin/local-reviewer"
expect doctor-local-tilde ok "^pass  reviewer is local: ~/bin/local-reviewer --oss, and $tmp/home/bin/local-reviewer is an executable file$" -- \
  doctor XDG_CONFIG_HOME="$(xdg local-cmd 'reviewer: local' 'reviewer_cmd_local: ~/bin/local-reviewer --oss')"
expect doctor-policy-card ok '^pass  merge_policy is autonomous by default, since guard/budget.card on origin/main does not set it, so guard merge also needs the ruleset and non-admin login items above to pass$' -- \
  doctor XDG_CONFIG_HOME="$(xdg semi 'merge_policy: semi-manual' "reviewer_cmd_proprietary: $tmp/doctor-reviewer -p")"
git -C "$D.wt" switch -q -c doctor-semi guard/init; sed -i '/^merge_policy:/d' "$D.wt/guard/budget.card"; echo "merge_policy: semi-manual" >> "$D.wt/guard/budget.card"
git -C "$D.wt" commit -q -am "semi-manual"; git -C "$D" update-ref refs/remotes/origin/main doctor-semi
expect doctor-policy-card-semi ok '^pass  merge_policy is semi-manual in guard/budget.card on origin/main, so guard merge queues every merge for a human$' -- doctor
git -C "$D" update-ref refs/remotes/origin/main guard/init; git -C "$D.wt" switch -q guard/init
expect doctor-policy-config fail "^pass  merge_policy is semi-manual in $tmp/xdg-semi/guard/config, so guard merge queues every merge for a human$" -- \
  env HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/xdg-semi" "$guard" doctor "$tmp/agents"
expect doctor-policy-config-autonomous fail "^pass  merge_policy is autonomous by default, since $tmp/xdg/guard/config does not set it, so guard merge also needs the non-admin login item above and a ruleset requiring a pull request$" -- \
  env HOME="$tmp/home" "$guard" doctor "$tmp/agents"
git -C "$D.wt" switch -q -c doctor-no-card guard/init; git -C "$D.wt" rm -q guard/budget.card
git -C "$D.wt" commit -q -m "no card"; git -C "$D" update-ref refs/remotes/origin/main doctor-no-card
expect doctor-no-card fail '^FAIL  origin/main has no guard/budget.card$' -- doctor
expect doctor-no-card-finishes fail '^[0-9]+ passed, [0-9]+ failed, ' -- doctor
git -C "$D" update-ref refs/remotes/origin/main guard/init; git -C "$D.wt" switch -q guard/init
expect doctor-hook-skipped-without-claude ok - -- bash -c '! grep -q "Claude Code" "$1"' _ "$tmp/doctor-out"
mkdir -p "$tmp/hook-home/.agents/skills" "$tmp/hook-home/.claude/skills"
for s in "$here"/skills/*/; do ln -s "${s%/}" "$tmp/hook-home/.agents/skills/"; ln -s "${s%/}" "$tmp/hook-home/.claude/skills/"; done
expect doctor-hook-missing fail "^FAIL  Claude Code does not show open needs-you items: neither ~/.claude/settings.json nor $D/.claude/settings.json runs guard needs-you --remind on SessionStart and UserPromptSubmit$" -- doctor HOME="$tmp/hook-home"
expect doctor-hook-missing-remedy fail '^      Run guard hooks install claude$' -- doctor HOME="$tmp/hook-home"
echo '{"permissions": {"allow": ["Bash(guard needs-you --remind*)"]}}' > "$tmp/hook-home/.claude/settings.json"
expect doctor-hook-not-in-hooks fail '^FAIL  Claude Code does not show open needs-you items' -- doctor HOME="$tmp/hook-home"
echo '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "guard needs-you --remind --format claude-hook"}]}]}}' > "$tmp/hook-home/.claude/settings.json"
expect doctor-hook-one-event fail '^FAIL  Claude Code does not show open needs-you items' -- doctor HOME="$tmp/hook-home"
rm "$tmp/hook-home/.claude/settings.json"
(cd "$D" && HOME="$tmp/hook-home" "$guard" hooks install claude --project >/dev/null 2>&1)
expect doctor-hook-project ok "^pass  Claude Code shows open needs-you items: $D/.claude/settings.json runs guard needs-you --remind on SessionStart and UserPromptSubmit$" -- doctor HOME="$tmp/hook-home"
rm -r "$D/.claude"; HOME="$tmp/hook-home" "$guard" hooks install claude >/dev/null 2>&1
expect doctor-hook-user ok '^pass  Claude Code shows open needs-you items: ~/.claude/settings.json runs guard needs-you --remind on SessionStart and UserPromptSubmit$' -- doctor HOME="$tmp/hook-home"
expect doctor-needs-you-none ok '^pass  no open needs-you items$' -- doctor
for t in one two three; do (cd "$D" && "$guard" needs-you add --kind check --title "$t" >/dev/null); done
(cd "$D" && "$guard" needs-you ack n1 >/dev/null)
expect doctor-needs-you-open ok '^pass  2 open needs-you items; guard needs-you lists them$' -- doctor
(cd "$D" && "$guard" needs-you "done" n2 >/dev/null)
expect doctor-needs-you-one ok '^pass  1 open needs-you item; guard needs-you lists it$' -- doctor
rm "$D/.git/guard/needs-you.tsv"
cd "$tmp/wt" || exit 1
