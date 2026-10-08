# shellcheck shell=bash disable=SC2034,SC2154
# Sourced inside the pull request's repository. Sets top, the repository root, and state, the per-repository local state
# that every worktree shares and git never commits.
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "guard: run this inside the pull request's repository" >&2; exit 2; }
state=$(cd "$(git rev-parse --git-common-dir)" && pwd)/guard

brief_path() { echo "$state/briefs/${1//\//-}.md"; }

# brief_problem <head ref>: prints why guard review cannot use the branch's brief, or nothing when it can.
brief_problem() {
  local brief request
  brief=$(brief_path "$1")
  [ -f "$brief" ] || { echo "no brief for $1. Write $brief with the user's request copied word for word under '## Request (verbatim)', then the plan under '## Plan'. The review-and-merge skill gives the format."; return; }
  request=$(awk '/^## / { on = ($0 == "## Request (verbatim)"); next } on' "$brief")
  [[ $request =~ [^[:space:]] ]] || echo "the '## Request (verbatim)' section of $brief is empty. Copy the user's request into it word for word."
}

queue() {
  local id
  if id=$("$here/bin/guard" needs-you add "$@"); then echo; "$here/bin/guard" needs-you show "$id"
  else echo "Could not queue this for a human. Tell them directly." >&2; fi
}

# pr_tier <base> <head>: prints how guard review --batch treats the change from base to head.
#   human    a path under guard/ or .github/workflows/, or a new runs/<id>/question.card. No model reviews it.
#   records  every path is under runs/<id>/, and none is a question card, a report, or an incident note, since an
#            incident clears a ripple once it merges.
#   small    at most review_small_lines added and deleted lines.
#   large    anything else.
pr_tier() {
  git -C "$top" -c core.quotePath=false diff --no-renames --raw --numstat "$1...$2" | awk -F'\t' -v small="$(config_get review_small_lines)" '
    /^:/ { status = substr($1, length($1)); path = $2; paths++
      if (path ~ /^(guard|\.github\/workflows)\//) human = 1
      run = path ~ /^runs\/[^\/]+\// && path !~ /^runs\/_template\//
      if (status == "A" && run && path ~ /^runs\/[^\/]+\/question\.card$/) human = 1
      if (!run || path ~ /(^|\/)(question\.card|report\.md)$/ || path ~ /^runs\/[^\/]+\/incidents\//) other = 1
      next }
    NF >= 3 { lines += ($1 == "-" ? 0 : $1) + ($2 == "-" ? 0 : $2) }
    END { print human ? "human" : (paths && !other) ? "records" : lines <= small ? "small" : "large" }'
}

# added_cards <base> <head>: prints each question card the change adds, one path per line.
added_cards() {
  git -C "$top" -c core.quotePath=false diff --no-renames --name-only --diff-filter=A "$1...$2" -- 'runs/*/question.card' \
    | grep -E '^runs/[^/]+/question\.card$' | grep -v '^runs/_template/' || true
}

# run_reviewer <worktree> <log> <ask> <label>: runs each of reviewer_cmds in the worktree until one exits 0, with its
# reply in <log>. Between tries it resets the worktree to the commit it started at. The reviewer runs without GH_TOKEN,
# GITHUB_TOKEN or SSH_AUTH_SOCK, and its pushes to origin or anywhere on GitHub fail; pushes the project's own tests
# make to local repositories still work. Sets candidate, the command that ran last, rc, its exit status, and err, its
# last line.
run_reviewer() {
  local wt=$1 log=$2 ask=$3 label=$4 before i n prefix no_push=(GIT_CONFIG_COUNT=4)
  for prefix in "$(git -C "$top" remote get-url origin)" https://github.com/ git@github.com: ssh://git@github.com/; do
    n=$(( (${#no_push[@]} - 1) / 2 ))
    no_push+=("GIT_CONFIG_KEY_$n=url.guard-review-never-pushes:.pushInsteadOf" "GIT_CONFIG_VALUE_$n=$prefix")
  done
  before=$(git -C "$wt" rev-parse HEAD)
  for ((i = 0; i < ${#reviewer_cmds[@]}; i++)); do
    candidate=${reviewer_cmds[i]}
    echo "guard review: $label: $candidate" >&2
    rc=0
    (cd "$wt" && env -u GH_TOKEN -u GITHUB_TOKEN -u SSH_AUTH_SOCK "${no_push[@]}" \
      bash -c "$candidate \"\$@\"" reviewer "$ask") < /dev/null > "$log" 2> "$log.err" || rc=$?
    err=$(cat "$log.err" "$log" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r' || true)
    [ $rc -ne 0 ] && [ $((i + 1)) -lt ${#reviewer_cmds[@]} ] || break
    echo "guard review: ${candidate%% *} failed (${err:-exit $rc}); trying ${reviewer_cmds[i + 1]%% *}" >&2
    git -C "$wt" reset -q --hard "$before"; git -C "$wt" clean -qfdx -e .guard-review
  done
}

# reply_lines <log>: prints the reviewer's reply without blank lines, code fences, carriage returns or trailing spaces.
reply_lines() {
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*```[[:space:]]*$' "$1" | tr -d '\r' | sed 's/[[:space:]]*$//' || true
}

# one_line <text>: prints the text as a reason that fits a reviews.tsv cell and a needs-you field.
one_line() { sed -e 's/;;*/;/g' -e 's/^[; ]*//' -e 's/[; ]*$//' <<<"${1//[$'\t\n']/ }"; }

# record_verdict <pr> <head> <verdict> <reviewer> <reason>: appends the verdict to reviews.tsv and comments it on the
# pull request.
record_verdict() {
  [ -s "$state/reviews.tsv" ] || printf 'ts\tpr\thead\tverdict\treviewer\treason\n' > "$state/reviews.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$@" >> "$state/reviews.tsv"
  gh pr comment "$1" --body "guard review: $3 at ${2:0:7}. $5" >/dev/null || echo "note: could not comment on pull request #$1." >&2
}

# last_review <pr>: prints the head, verdict and reason of the pull request's last row in reviews.tsv, tab-separated.
last_review() {
  awk -F'\t' -v pr="$1" '$2 == pr { r = $3 "\t" $4 "\t" $6 } END { print r }' "$state/reviews.tsv" 2>/dev/null || true
}

# queue_verdict <pr> <verdict> <reason> <path>...: queues a changes or escalate verdict for a human.
queue_verdict() {
  local pr=$1 verdict=$2 why=$3 paths=() p; shift 3
  for p in "$@"; do paths+=(--path "$p"); done
  case $verdict in
    changes) queue --kind check --title "Review of PR #$pr asks for changes" --why "$why" "${paths[@]}" --source "guard review" ;;
    escalate) queue --kind approve --title "Review of PR #$pr needs your decision" --why "$why" "${paths[@]}" --source "guard review" ;;
  esac
}

# queue_merge <pr> <why> <head ref>: queues the merge of one pull request for a human.
queue_merge() {
  local brief files=()
  brief=$(brief_path "$3"); [ ! -f "$brief" ] || files=(--path "$brief")
  queue --kind approve --title "Merge PR #$1" --why "$2" "${files[@]}" \
    --run "cd $top" --run "gh pr merge $1 --squash" --expect "\"Squashed and merged pull request #$1\"." \
    --undo "git revert <merge commit> on a new branch, then open a pull request." --source "guard merge"
}
