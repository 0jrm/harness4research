#!/usr/bin/env bash
# usage: guard survey <repo>
# Read-only inventory of what a repository carries. Prints markdown. Findings are leads, not verdicts.
set -uo pipefail
repo=${1:?usage: guard survey <repo>}
cd "$repo" || exit 2
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $repo" >&2; exit 2; }
base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git rev-parse --verify -q "$base" >/dev/null || base=HEAD
name=$(basename "$(git rev-parse --show-toplevel)")
docs() { git ls-files -- '*.md' '*.mdc' '*.txt' '.cursorrules' | grep -v '^vendor/\|^node_modules/'; }

echo "# Survey of $name"
echo
echo "Generated $(date -u +%FT%TZ) against \`$base\` at \`$(git rev-parse --short "$base")\`. Nothing was changed."
echo "Each finding is a lead for a human or agent to check, not a verdict."

echo; echo "## Branches"; echo
echo "| Branch | Last commit | Commits not on $base |"
echo "|---|---|---|"
git for-each-ref --format='%(refname:lstrip=2)' refs/remotes | grep -v -e '/HEAD$' -e "^$base\$" | while read -r b; do
  printf '| `%s` | %s | %s |\n' "$b" "$(git log -1 --format=%ad --date=short "$b")" "$(git rev-list --count "$base..$b")"
done
merged=$(git for-each-ref --format='%(refname:lstrip=2)' refs/remotes | grep -v -e '/HEAD$' -e "^$base\$" \
  | while read -r b; do [ "$(git rev-list --count "$base..$b")" = 0 ] && echo x; done | wc -l)
echo; echo "$merged branches carry nothing that is not already on \`$base\`. \`guard archive\` tags them before any cleanup."

echo; echo "## Agent context files"; echo
echo "Agents read these as instructions. Long or stale ones cost tokens and steer agents wrong."; echo
found=0
for f in AGENTS.md CLAUDE.md GEMINI.md .cursorrules .github/copilot-instructions.md; do
  [ -f "$f" ] && { found=1; echo "- \`$f\`, $(wc -l <"$f") lines"; }
done
while read -r f; do found=1; echo "- \`$f\`, $(wc -l <"$f") lines"; done < <(git ls-files -- '.cursor/rules/*' '.claude/*' '*/AGENTS.md' '*/CLAUDE.md' | grep -v '^vendor/')
while read -r f; do found=1; echo "- \`$f\`, $(wc -l <"$f") lines (handoff or status file)"; done < <(git ls-files | grep -i -E '(^|/)(handoff|status|todo|next[-_]?steps|notes)[^/]*\.md$')
[ $found = 1 ] || echo "- none"

echo; echo "## Documents that point at missing files"; echo
echo "A doc that names a path which no longer exists usually describes an old version of the project."; echo
n=0
tops=$(git ls-files | awk -F/ 'NF>1{print $1}' | sort -u)
while read -r f; do
  while IFS=: read -r ln p; do
    p=${p#\`}; p=${p%\`}; p=${p%%#*}; p=${p%%:*}
    [[ $p =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*/[A-Za-z0-9_./-]+$ ]] || continue
    grep -qx "${p%%/*}" <<<"$tops" || continue
    [ -e "$p" ] || { echo "- \`$f:$ln\` names \`$p\`"; n=$((n+1)); }
  done < <(grep -n -o '`[^` ]\+`' "$f")
done < <(docs)
[ $n -gt 0 ] || echo "- none found"

echo; echo "## Undecided or temporary language in documents"; echo
echo "Phrases that describe a choice as still open or a hack as temporary. Check each against what was actually decided."; echo
pat='pick one|not (yet )?implemented|none of (the|these).*implemented|\bTBD\b|temporary|placeholder|smoke[- ]test|hack|for now|FIXME|XXX|to be decided|do not use yet'
res=$(docs | xargs -r grep -n -i -E "$pat" 2>/dev/null | cut -c1-160 | head -40)
if [ -n "$res" ]; then sed 's/^\([^:]*:[0-9]*\):\(.*\)$/- `\1` \2/' <<<"$res"; else echo "- none found"; fi

echo; echo "## Temporary markers in code"; echo
res=$(git grep -n -I -E '\b(HACK|FIXME|XXX|TEMPORARY)\b' -- ':!*.md' ':!vendor' 2>/dev/null | cut -c1-160 | head -30)
if [ -n "$res" ]; then sed 's/^\([^:]*:[0-9]*\):\(.*\)$/- `\1` \2/' <<<"$res"; else echo "- none found"; fi

echo; echo "## Duplicate trees and nested repositories"; echo
res=$(find . -mindepth 2 -name .git -not -path './vendor/*' -not -path './.git/*' 2>/dev/null | sed 's|/\.git$||')
if [ -n "$res" ]; then sed 's/^/- nested git repository `/; s/$/`/' <<<"$res"; else echo "- no nested repositories"; fi
dups=$(git ls-files -z | xargs -0 -r sh -c 'for f; do [ -f "$f" ] && [ "$(wc -c <"$f")" -gt 1024 ] && echo "$(git hash-object "$f") $f"; done' sh \
  | sort | awk '{ if ($1==h) { if (!p) print prev; print; p=1 } else p=0; h=$1; prev=$0 }' | awk '{print "- identical content: `"$2"`"}' | head -20)
[ -z "$dups" ] || echo "$dups"

echo; echo "## Commit subjects that look like prompts"; echo
res=$(git log --format='%h %s' "$base" | grep -E ' (You are|Read |Implement |On latest main|Please )|^.{9}.{90,}' | head -15 | cut -c1-120)
if [ -n "$res" ]; then sed 's/^\([0-9a-f]*\) /- `\1` /' <<<"$res"; else echo "- none found"; fi

echo; echo "## Tracked files that look like secrets"; echo
res=$(git ls-files | grep -E '(^|/)(\.env(\..*)?|id_(rsa|ed25519|ecdsa)|.*\.pem|credentials(\.json)?|.*\.key)$' | head)
if [ -n "$res" ]; then sed 's/^/- `/; s/$/`/' <<<"$res"; else echo "- none found"; fi
