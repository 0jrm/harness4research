# shellcheck shell=bash
# Sourced by tests/run.sh: U5's guard holdout. One broker serving the records socket in $tmp, a bare origin with the
# forge's pre-receive, and solutions run in lib/box.sh, so the cases that score need bubblewrap.
echo "== holdout"
hverb=$here/lib/verbs/holdout.py
hold=$tmp/hold; hstate=$hold/state; hsock=$hold/sock; hclone=$hold/clone; horigin=$hold/origin.git
mkdir -p "$hstate" "$hsock"
git init -q --bare -b main "$horigin"
cp "$here/eval/env/forge-pre-receive.sh" "$horigin/hooks/pre-receive"
git clone -q "$horigin" "$hclone" 2>/dev/null
hpy() {  # hpy <code> [args]: python with lib/ and the eval test's data and solutions (t)
  python3 -c 'import sys; sys.path[:0] = [sys.argv[1] + "/lib", sys.argv[1] + "/eval/tests"]; import _path
import test_holdout as t
exec(sys.argv[2])' "$here" "$@"
}
hpy 't.data(sys.argv[3] + "/data"); open(sys.argv[3] + "/clone/solution.py", "w").write(t.MEAN)' "$hold"
(cd "$hclone" && git add -A && git commit -qm start && git push -q origin HEAD:main)
python3 - "$hstate" "$hclone" "$horigin" <<'PY'
import json, sys
state, clone, origin = sys.argv[1:]
json.dump({"session": "s1", "project": clone, "paths": [[clone, clone]], "origin": origin, "slurm_bin": None},
          open(state + "/config.json", "w"))
PY
python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1] + "/lib"); import _path, json
from broker import scheduler, server
b = scheduler.Broker(sys.argv[2], json.load(open(sys.argv[2] + "/config.json")))
s = server.bind(os.path.join(sys.argv[3], "records.sock"), "records", b)
open(os.path.join(sys.argv[3], "ready"), "w").close()
s.serve_forever()' "$here" "$hstate" "$hsock" & hpid=$!
for _ in $(seq 50); do [ -e "$hsock/ready" ] && break; sleep 0.1; done
score() { (cd "$hclone" && env GUARD_SOCK_DIR="$hsock" GUARD_SESSION=s1 "$guard" holdout score); }
try() {  # try <solution name> <tag>: commits t.<name> with a tag line on branch try, pushes it to origin, scores it
  hpy 'open(sys.argv[3], "w").write(getattr(t, sys.argv[4]).replace("FALLBACK", "0.0") + "\n# " + sys.argv[5] + "\n")' \
    "$hclone/solution.py" "$1" "$2"
  (cd "$hclone" && git switch -qC try && git commit -qam "$2" && git push -qf origin HEAD:try) >/dev/null 2>&1
  score
}
to_main() {  # to_main <solution name> <tag>: pushes t.<name> to main; a refused push is undone; prints git's output
  (cd "$hclone" && git switch -qC main origin/main &&
    hpy 'open("solution.py", "w").write(getattr(t, sys.argv[3]).replace("FALLBACK", "0.0") + "\n# " + sys.argv[4] + "\n")' "$1" "$2" &&
    git commit -qam "$2" && { git push -q origin HEAD:main 2>&1 || { git reset -q --hard origin/main; exit 1; }; })
}
remote() {  # remote <push command...>: a refused push as the hook's lines, git's prefix and padding gone, exit 2
  local out; out=$("$@" 2>&1) && { printf '%s\n' "$out"; return 0; }
  sed -n 's/^remote: //p' <<<"$out" | sed 's/ *$//'; return 2
}
nodec() {  # nodec <command...>: its output and status, or status 99 when the output holds a decimal number
  local out rc; out=$("$@" 2>&1); rc=$?; printf '%s\n' "$out"
  if grep -qE '[0-9]+\.[0-9]+' <<<"$out"; then return 99; fi; return $rc
}

expect_refusal holdout-local-h05 H05 -- env -u GUARD_SESSION GUARD_SOCK_DIR="$hold/none" sh -c "cd '$hclone' && '$guard' holdout score"
expect_refusal holdout-unsealed-h04 H04 -- score
expect holdout-seal ok 'sealed [0-9a-f]{12} in .*; 3 scores a session; pushes checked at origin' -- \
  "$guard" holdout seal "$hold/data" --state "$hstate" --threshold 0.25 --max 3 --timeout 20 \
  --scorer "$(jq -r .holdout.scorer "$here/eval/tasks/t3-entity-overlap/task.json")"
expect holdout-seal-records-scorer ok 'spec_from_file_location' -- jq -r .scorer "$hstate/holdout/seal.json"
if ! bwrap --ro-bind / / true 2>/dev/null; then
  skip holdout-scores "bwrap cannot start a sandbox here"
else
  expect holdout-score-pass ok '^holdout l[0-9a-f]{10} pass; 2 of 3 submissions left$' -- try MEAN one
  expect_refusal holdout-score-fail-h01 H01 -- nodec try LOOKUP two
  expect holdout-score-third ok '^holdout l[0-9a-f]{10} pass; 0 of 3 submissions left$' -- try MEAN three
  expect_refusal holdout-fourth-score-h03 H03 -- try MEAN four
  expect holdout-h03-asks-the-human ok 'holdout_more' -- jq -r '.effect.kind // empty' "$hstate/records/asks.jsonl"
  expect_refusal holdout-cached-at-the-limit-h01 H01 -- nodec try LOOKUP two
  expect_refusal holdout-push-refused-h01 H01 -- nodec remote to_main LOOKUP lookup
  expect holdout-fourth-push-scored ok - -- to_main MEAN deliverable
  rm_solution() { (cd "$hclone" && git rm -q solution.py && git commit -qm gone && { git push -q origin HEAD:main 2>&1 ||
    { git reset -q --hard origin/main; exit 1; }; }); }
  expect_refusal holdout-push-layout-h02 H02 -- nodec remote rm_solution
  expect holdout-rows ok '^score pass 1,score fail 2,score pass 3,score limit -,score fail -,push fail -,push pass -,push unscorable -$' -- \
    sh -c "jq -r '[.via, .verdict, (.n // \"-\" | tostring)] | join(\" \")' '$hstate/holdout/log.jsonl' | paste -sd,"
  expect holdout-receipts ok '^8$' -- sh -c "grep -c '\"kind\": \"holdout\"' '$hstate/receipts.jsonl'"
fi
kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
