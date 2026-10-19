# shellcheck shell=bash
# Sourced by tests/run.sh: U9's signed receipts. The broker publishes each receipt as one signed commit on
# guard/receipts; lib/guard/receipts-check.sh dereferences an id against broker_key: on the base branch's card; the
# forge hook refuses an unsigned, foreign-signed, rewound or deleted guard/receipts; local mode publishes nothing.
echo "== receipts"
R=$tmp/receipts; mkdir -p "$R"
check=$here/lib/guard/receipts-check.sh
export FORGE_LOG=$R/forge.log
ssh-keygen -q -t ed25519 -N "" -C guard-broker -f "$R/key"
ssh-keygen -q -t ed25519 -N "" -C evil -f "$R/evil"
printf 'broker namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$R/key.pub")" > "$R/signers"

git init -q --bare -b main "$R/origin.git"
cp "$here/eval/env/forge-pre-receive.sh" "$R/origin.git/hooks/pre-receive"; chmod +x "$R/origin.git/hooks/pre-receive"
git clone -q "$R/origin.git" "$R/proj" 2>/dev/null
mkdir -p "$R/proj/guard"
printf 'account: g\nbroker_key: %s\n' "$(cat "$R/key.pub")" > "$R/proj/guard/budget.card"
git -C "$R/proj" add -A; git -C "$R/proj" commit -q -m init; git -C "$R/proj" push -q origin HEAD:main

# r <origin> <state> <cmd> [args]: one call into lib/broker/receipts.py against a broker for <origin> holding $R/key.
cat > "$R/r.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["HARNESS"], "lib"))
import _path  # noqa: F401
from broker import local, receipts, scheduler, server

origin, state, cmd, *args = sys.argv[1:]
key = os.environ["R"] + "/key"
cfg = {"session": "s1", "project": state, "paths": [[state, state]], "origin": origin, "slurm_bin": None,
       "slurm_env": {}, "user": "t", "compute_bwrap": False, "signing_key": key,
       "receipts_email": os.environ.get("RECEIPTS_EMAIL")}
if cmd.startswith("local-"):
    b = local.project_broker(origin)
    cmd = cmd[len("local-"):]
else:
    b = scheduler.Broker(state, cfg)
try:
    if cmd == "add":
        print(receipts.receipt_add(b, args[0], args[1] or None, json.loads(args[2])).id)
    elif cmd == "status":
        print(receipts.status_line(b))
    elif cmd == "show":
        r = server.answer(b, "records", {"verb": "receipt", "action": "show", "id": args[0]})
        sys.stdout.write(r.get("out", "")); sys.stderr.write(r.get("err", "")); sys.exit(r["rc"])
    elif cmd == "verify":
        ok = receipts.verify(args[0], args[1], os.environ["R"] + "/signers", known=args[2] if len(args) > 2 else None)
        print("verified" if ok else "not verified"); sys.exit(0 if ok else 1)
except scheduler.Refused as e:
    sys.exit(f"refused: {e}")
PY
r() { HARNESS=$here R=$R python3 "$R/r.py" "$R/origin.git" "$R/state" "$@"; }

id1=$(r add holdout r1 '{"verdict": "pass", "solution_sha256": "abc"}')
id2=$(r add ask "" '{"question": "more?", "answer": "no"}')
expect receipts-add-id ok '^L[0-9a-f]{10} L[0-9a-f]{10}$' -- echo "$id1 $id2"
expect receipts-one-commit-per-row ok '^2$' -- git -C "$R/origin.git" rev-list --count refs/heads/guard/receipts
expect receipts-every-commit-signed ok '^2 signed$' -- bash -c '
  n=0; for c in $(git -C "$1" rev-list refs/heads/guard/receipts); do
    git -C "$1" -c gpg.ssh.allowedSignersFile="$2" verify-commit "$c" 2>/dev/null && n=$((n+1)); done; echo "$n signed"' _ "$R/origin.git" "$R/signers"
expect receipts-rows-on-origin ok "^\{\"id\": \"$id2\", .*\"kind\": \"ask\"" -- git -C "$R/origin.git" show guard/receipts:receipts.jsonl
expect receipts-show ok "\"id\": \"$id1\"" -- r show "$id1"
expect receipts-show-commit ok "on guard/receipts at $(git -C "$R/origin.git" rev-parse --short=12 guard/receipts)" -- r show "$id1"
expect receipts-show-unknown fail "no receipt L0000000000" -- r show L0000000000
expect receipts-status-names-head ok "^receipts: guard/receipts at $(git -C "$R/origin.git" rev-parse --short=12 guard/receipts), signed" -- r status

# The CI fence's view: a clone with origin/guard/receipts and broker_key: on origin/main's card.
git clone -q "$R/origin.git" "$R/ci" 2>/dev/null
cd "$R/ci" || exit 1
expect receipts-check-real ok - -- bash "$check" origin/main "$id1" "$id2"
expect receipts-check-no-ids ok - -- bash "$check" origin/main
expect_refusal receipts-check-made-up F04 -- bash "$check" origin/main "$id1" L0123456789
expect receipts-check-made-up-says fail '^H4R-F04 evidence-paths: L0123456789 \(no row on guard/receipts\)' -- bash "$check" origin/main L0123456789
expect_refusal receipts-check-local-id F04 -- bash "$check" origin/main l0123456789
expect receipts-check-local-id-says fail '^H4R-F04 .*l0123456789 \(a local unsigned receipt' -- bash "$check" origin/main l0123456789
expect_refusal receipts-check-not-an-id F04 -- bash "$check" origin/main Lxyz
expect receipts-check-line2-none fail '^none$' -- bash "$check" origin/main L0123456789
expect receipts-verify ok '^verified$' -- r verify "$R/ci/.git" refs/remotes/origin/guard/receipts

# A placeholder broker_key: on main refuses every id.
git init -q -b main "$R/ph"; mkdir -p "$R/ph/guard"
printf 'account: g\nbroker_key: <guard broker setup writes this>\n' > "$R/ph/guard/budget.card"
git -C "$R/ph" add -A; git -C "$R/ph" commit -q -m ph
git -C "$R/ph" fetch -q "$R/origin.git" +refs/heads/guard/receipts:refs/remotes/origin/guard/receipts
expect_refusal receipts-check-placeholder F04 -- bash -c 'cd "$1" && bash "$2" main "$3"' _ "$R/ph" "$check" "$id1"
expect receipts-check-placeholder-says fail 'no broker_key on main' -- bash -c 'cd "$1" && bash "$2" main "$3"' _ "$R/ph" "$check" "$id1"

# forged_commit <parent> <key or -> <row id>: a commit appending a row with <row id> to <parent>'s receipts.jsonl,
# signed with <key> or unsigned, in the current repository; prints its sha.
forged_commit() {
  local parent=$1 key=$2 id=$3 blob tree sign=()
  blob=$({ git show "$parent:receipts.jsonl"; printf '{"id": "%s", "ts": "2026-10-19T00:00:00Z", "kind": "holdout", "run_id": "r1", "session": "s1", "fields": {"verdict": "pass"}}\n' "$id"; } | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\treceipts.jsonl\n' "$blob" | git mktree)
  [ "$key" = - ] || sign=(-c gpg.format=ssh -c user.signingKey="$key")
  git "${sign[@]}" commit-tree $([ "$key" = - ] || echo -S) -p "$parent" -m "receipt $id" "$tree"
}
head2=$(git rev-parse refs/remotes/origin/guard/receipts)
head1=$(git rev-parse "$head2~1")
unsigned=$(forged_commit "$head2" - L00000000aa)
git update-ref refs/remotes/origin/guard/receipts "$unsigned"
expect_refusal receipts-check-unsigned-head F04 -- bash "$check" origin/main "$id1"
expect receipts-check-unsigned-says fail "head ${unsigned:0:12} is not signed by broker_key" -- bash "$check" origin/main "$id1"
expect_refusal receipts-check-forged-row F04 -- bash "$check" origin/main L00000000aa
expect receipts-verify-unsigned fail '^not verified$' -- r verify "$R/ci/.git" refs/remotes/origin/guard/receipts
own=$(forged_commit "$head2" "$R/evil" L00000000bb)
git update-ref refs/remotes/origin/guard/receipts "$own"
expect_refusal receipts-check-own-key F04 -- bash "$check" origin/main L00000000bb
# An unsigned row under a head the broker's key signed: the row's own commit is checked, not only the head.
over=$(forged_commit "$unsigned" "$R/key" L00000000cc)
git update-ref refs/remotes/origin/guard/receipts "$over"
expect receipts-check-signed-over-unsigned-real ok - -- bash "$check" origin/main "$id1" L00000000cc
expect_refusal receipts-check-signed-over-unsigned F04 -- bash "$check" origin/main L00000000aa
expect receipts-check-signed-over-unsigned-says fail "L00000000aa \(its commit ${unsigned:0:12} is not signed by broker_key\)" -- bash "$check" origin/main L00000000aa
# Rewound: the broker's last published head is no longer on the ref.
git update-ref refs/remotes/origin/guard/receipts "$head1"
expect receipts-verify-rewound fail '^not verified$' -- r verify "$R/ci/.git" refs/remotes/origin/guard/receipts "$head2"
expect receipts-verify-ancestor ok '^verified$' -- r verify "$R/ci/.git" refs/remotes/origin/guard/receipts "$head1"
expect_refusal receipts-check-rewound-drops F04 -- bash "$check" origin/main "$id2"

# The forge: pushes to guard/receipts that are unsigned, foreign-signed, not fast-forward or deletions are refused.
git fetch -q origin
expect receipts-forge-unsigned fail 'guard/receipts refused: commit [0-9a-f]{12} is not signed by broker_key' -- git push origin "$unsigned:refs/heads/guard/receipts"
expect receipts-forge-own-key fail 'is not signed by broker_key' -- git push origin "$own:refs/heads/guard/receipts"
expect receipts-forge-rewind fail 'not a fast-forward' -- git push -f origin "$head1:refs/heads/guard/receipts"
expect receipts-forge-delete fail 'never deleted' -- git push origin :refs/heads/guard/receipts
expect receipts-forge-unchanged ok "^$head2$" -- git -C "$R/origin.git" rev-parse refs/heads/guard/receipts
expect receipts-forge-logged ok '^4$' -- bash -c 'grep -c "refuse-receipts	refs/heads/guard/receipts" "$1"' _ "$R/forge.log"
expect receipts-forge-no-key fail 'no broker_key on main' -- bash -c '
  git init -q --bare -b main "$1/nokey.git" && cp "$2" "$1/nokey.git/hooks/pre-receive" &&
  git -C "$1/ph" push -q "$1/nokey.git" main && git push "$1/nokey.git" "$3:refs/heads/guard/receipts"' _ "$R" "$here/eval/env/forge-pre-receive.sh" "$head2"

# The broker builds only on its own signed history: an origin without the hook, whose ref someone rewrote unsigned.
git clone -q --bare "$R/origin.git" "$R/loose.git"
git push -q "$R/loose.git" "$unsigned:refs/heads/guard/receipts"
expect receipts-broker-refuses-unsigned-head fail 'refused: guard/receipts on origin at [0-9a-f]{12} is not the broker' -- \
  env HARNESS="$here" R="$R" python3 "$R/r.py" "$R/loose.git" "$R/loose-state" add job r1 '{"job": "1"}'
expect receipts-broker-published-nothing ok "^$unsigned$" -- git -C "$R/loose.git" rev-parse refs/heads/guard/receipts

# The fence workflow fetches guard/receipts, and says so when origin has none.
python3 -c '
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in wf["jobs"]["fence"]["steps"] if "guard/receipts" in s.get("name", "")]
yaml.safe_dump({"jobs": {"fence": {"steps": steps}}}, open(sys.argv[2], "w"))' \
  "$here/templates/github/workflows/guard-fence.yml" "$R/fetch.yml"
wfrun() {  # wfrun <origin> <workspace>: the workflow's guard/receipts step in a clone of <origin> without the ref
  rm -rf "${2:?}"; git clone -q "$1" "$2" 2>/dev/null; git -C "$2" update-ref -d refs/remotes/origin/guard/receipts 2>/dev/null
  env GITHUB_REPOSITORY=lab/fixture GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$1.insteadOf" \
    GIT_CONFIG_VALUE_0=https://x-access-token:tok@github.com/lab/fixture.git \
    python3 "$here/tests/workflow.py" "$R/fetch.yml" fence "$2" --ctx github.token=tok \
    && cd "$2" && bash "$check" origin/main "$id1"
}
expect receipts-workflow-fetches ok - -- wfrun "$R/origin.git" "$R/wf"
expect receipts-workflow-no-ref fail 'no guard/receipts on origin' -- wfrun "$R/nokey.git" "$R/wf2"

# Local mode: l<hex> rows in .git/guard/receipts.jsonl, nothing published.
git init -q --bare -b main "$R/plain-origin.git"
git clone -q "$R/plain-origin.git" "$R/plain" 2>/dev/null
git -C "$R/plain" commit -q --allow-empty -m init; git -C "$R/plain" push -q origin HEAD:main
lid=$(HARNESS=$here R=$R python3 "$R/r.py" "$R/plain" - local-add job r1 '{"job": "1"}')
expect receipts-local-id ok '^l[0-9a-f]{10}$' -- echo "$lid"
expect receipts-local-file ok "\"id\": \"$lid\"" -- cat "$R/plain/.git/guard/receipts.jsonl"
expect receipts-local-unpublished ok '^$' -- git -C "$R/plain-origin.git" for-each-ref refs/heads/guard
cat > "$R/send.py" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
import _path  # noqa: F401
from broker import transport
r = transport.send({"verb": "receipt", "action": "show", "id": sys.argv[2], "cwd": sys.argv[3]}, "records")
sys.stdout.write(r.get("out", "")); sys.stderr.write(r.get("err", "")); sys.exit(r["rc"])
PY
show_local() { (cd "$R/plain" && env -u GUARD_SESSION GUARD_SOCK_DIR="$R/nosock" python3 "$R/send.py" "$here" "$1" "$R/plain"); }
expect receipts-local-show ok "^\{\"id\": \"$lid\"" -- show_local "$lid"
expect receipts-local-show-unsigned ok 'local and unsigned' -- show_local "$lid"
expect receipts-local-status ok '^receipts: local, unsigned' -- env HARNESS="$here" R="$R" python3 "$R/r.py" "$R/plain" - local-status
expect_refusal receipts-local-cited F04 -- bash -c 'cd "$1" && bash "$2" origin/main "$3"' _ "$R/ci" "$check" "$lid"

# A person's verified email for GitHub's signed-commit rule replaces the broker's committer email.
RECEIPTS_EMAIL=pi@lab.example r add job r1 '{"job": "2"}' >/dev/null
expect receipts-committer-email ok '^pi@lab.example$' -- git -C "$R/origin.git" log -1 --format=%ce refs/heads/guard/receipts
unset FORGE_LOG
cd "$tmp" || exit 1

# The forge's own refusals carry codes (design-v8 section 6): an unsigned card is F03, a moved main S03.
fz=$tmp/forge-codes; git init -q --bare -b main "$fz/origin.git"
cp "$here/eval/env/forge-pre-receive.sh" "$fz/origin.git/hooks/pre-receive"; chmod +x "$fz/origin.git/hooks/pre-receive"
git -C "$fz/origin.git" config guard.records signed
git clone -q "$fz/origin.git" "$fz/w" 2>/dev/null
git -C "$fz/w" commit -q --allow-empty -m one; git -C "$fz/w" commit -q --allow-empty -m two; git -C "$fz/w" push -q origin HEAD:main
mkdir -p "$fz/w/runs/r1"; echo "why: w" > "$fz/w/runs/r1/question.card"
git -C "$fz/w" add -A; git -C "$fz/w" commit -q -m card
expect forge-f03-unsigned-card fail '^remote: H4R-F03 runs/r1/question.card is a card only the broker writes' -- \
  git -C "$fz/w" push origin HEAD:refs/heads/run/r1
expect forge-s03-force fail '^remote: H4R-S03 force push to main is refused' -- \
  git -C "$fz/w" push -f origin HEAD~2:main
