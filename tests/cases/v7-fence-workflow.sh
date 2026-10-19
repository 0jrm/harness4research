# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== fence workflow at the pin"
# tests/workflow.py runs the fence job of a project's workflow on origin/main against pull request <n>. Its checkout of
# 0jrm/harness4research clones $th, a harness whose tag v99.0 has a fence that names the tag and whose HEAD's names HEAD.
th=$tmp/harness-tagged
git clone -q --shared "$here" "$th" 2>/dev/null; git -C "$th" checkout -q --detach "$pin_commit"
sed -i '1a echo "fence from the tag"' "$th/lib/guard/fence.sh"
git -C "$th" commit -q -am "fence from the tag"; git -C "$th" tag -a v99.0 -m v99.0
sed -i 's/fence from the tag/fence from HEAD/' "$th/lib/guard/fence.sh"; git -C "$th" commit -q -am "fence from HEAD"
fence_job() {  # fence_job <log> <project> <n> [--repo NAME=PATH...]: the job's output, also in <log>; its exit code
  local log=$1 p=$2 n=$3; shift 3
  rm -rf "$log.ws"
  env GITHUB_REPOSITORY=lab/fixture GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$p.git.insteadOf" \
    GIT_CONFIG_VALUE_0=https://x-access-token:tok@github.com/lab/fixture.git \
    python3 "$here/tests/workflow.py" <(git -C "$p" show origin/main:.github/workflows/guard-fence.yml) fence "$log.ws" \
    --ctx github.event.pull_request.base.ref=main --ctx github.event.pull_request.number="$n" --ctx github.token=tok \
    --repo lab/fixture="$p.git" "$@" 2>&1 | tee "$log"
}
pull_request() {  # pull_request <n> <file>: pushes refs/pull/<n>/head, origin/main plus a line in <file>
  git switch -q --detach origin/main; echo "pull request $1" >> "$2"; git add -A; git commit -q -m "pull request $1"
  git push -q origin "HEAD:refs/pull/$1/head"
}
W=$tmp/wf
pinned "$W" online
sed -i 's/^harness: .*/harness: v99.0/' guard/budget.card; git commit -q -am "pin v99.0"; git push -q origin HEAD:main; git fetch -q origin
pull_request 1 notes.md; pull_request 2 guard/watch.list
expect workflow-pin-from-tag ok '^fence from the tag$' -- fence_job "$tmp/wf1" "$W" 1 --repo 0jrm/harness4research="$th"
expect workflow-pin-not-head fail - -- grep -q 'fence from HEAD' "$tmp/wf1"
expect workflow-pin-says ok '^harness: v99\.0; the fence comes from clone$' -- cat "$tmp/wf1"
expect workflow-pin-clone-at-tag ok "^$(git -C "$th" rev-parse 'v99.0^{commit}')$" -- git -C "$tmp/wf1.ws/.guard-harness" rev-parse HEAD
expect workflow-pin-passes ok 'PASS	guard-untouched' -- cat "$tmp/wf1"
expect workflow-pin-fails-guard-edit fail 'FAIL	guard-untouched	.*guard/watch.list' -- fence_job "$tmp/wf2" "$W" 2 --repo 0jrm/harness4research="$th"
expect workflow-pin-public-repo fail 'no local repository for 0jrm/harness4research' -- fence_job "$tmp/wf3" "$W" 1
git switch -q --detach origin/main; sed -i 's/^harness: .*/harness: v99.1/' guard/budget.card; git commit -q -am "pin v99.1"
git push -q origin HEAD:main; git fetch -q origin; pull_request 3 notes.md
expect workflow-pin-missing-tag fail '^-- Check out harness4research at the pin$' -- fence_job "$tmp/wf4" "$W" 3 --repo 0jrm/harness4research="$th"
git switch -q --detach origin/main; sed -i '/^harness:/d' guard/budget.card; mkdir -p guard/bin
printf '#!/usr/bin/env bash\necho "fence from guard/bin"\n' > guard/bin/fence.sh; git add -A; git commit -q -m "a card without the pin"
git push -q origin HEAD:main; git fetch -q origin; pull_request 4 notes.md
expect workflow-no-pin ok '^fence from guard/bin$' -- fence_job "$tmp/wf5" "$W" 4
expect workflow-no-pin-no-checkout ok '^-- Check out harness4research at the pin: skipped$' -- cat "$tmp/wf5"
pinned "$tmp/wf-offline" offline
pull_request 1 notes.md
expect workflow-offline-vendored ok "^harness: $pin; the fence comes from vendored$" -- fence_job "$tmp/wf6" "$tmp/wf-offline" 1
expect workflow-offline-passes ok 'PASS	guard-untouched' -- cat "$tmp/wf6"
expect workflow-offline-no-checkout ok '^-- Check out harness4research at the pin: skipped$' -- cat "$tmp/wf6"
