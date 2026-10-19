# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== atlas"
fx=$(mktemp -d "$here/.atlas-fixture.XXXXXX"); trap 'rm -rf "$tmp" "$fx"' EXIT
mkdir -p "$tmp/atlas"; bash "$here/tests/atlas-fixture.sh" "$fx" > "$tmp/atlas/env.sh"
atlas_before=$(git -C "$fx/casts-v4-training" status --porcelain)
expect atlas-renders ok '14 runs, 2 branches' -- bash -c '. "$1"; "$2" atlas --out "$3/atlas.html" --json "$3/atlas.json"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-catches-early-compute ok 'started before the card was committed' -- cat "$tmp/atlas/atlas.html"
expect atlas-broken-receipt ok '<li class="rc-broken"><span class="b b-broken">.*</span><span class="rc-kind">commit</span> <code>deadbee</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-drawer-key-diff ok 'max_walltime_minutes 240 to 600' -- cat "$tmp/atlas/atlas.html"
python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in ("atlas_schema", "behind_base", "generated_at"): print(" ~ ".join(["S", k, str(d[k])]))
for k, v in sorted(d["summary"].items()): print(" ~ ".join(["S", "summary." + k, str(v)]))
for e in d["lineage"]: print(" ~ ".join(["E", e["from"], e["to"], e["kind"], str(e["lineage_inferred"])]))
for w in d["waters"]: print(" ~ ".join(["W", w["name"], w["fence"], ",".join(w["hand"])]))
for q in d["queue"]: print(" ~ ".join(["Q", q["id"], q["state"], q["kind"], *q["paths"]]))
for r in d["runs"]:
    print(" ~ ".join(["O", r["id"], r["outcome"], r["outcome_detail"], r["severity"]]))
    for x in r["needs_you"]: print(" ~ ".join(["N", r["id"], x]))
    for v in r["violations"]: print(" ~ ".join(["V", r["id"], v]))
    for m in r["manifests"]: print(" ~ ".join(["M", r["id"], m["path"], str(m["committed"])]))
    for e in (r["report"] or {}).get("evidence", []):
        for l in e["links"]: print(" ~ ".join(["L", r["id"], e["claim"], l["kind"], l["value"], l["state"], l["note"]]))' "$tmp/atlas/atlas.json" > "$tmp/atlas/atlas.tsv"
expect atlas-escaped-pipe ok '^L ~ cosine-v2 ~ Max \|dT\| at the casts ~ commit ~ [0-9a-f]{7} ~ ok' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-note ok '^L ~ cosine-v2 ~ Max .* ~ artifact ~ runs/cosine-v2/manifest-4830.txt ~ ok ~ committed at HEAD$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-absent-host ok 'artifact ~ /unity/g9/nobody/casts-v4/pred.nc ~ unknown ~ absolute path not on this host$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-artifact-on-disk ok 'artifact ~ runs/cosine-v2/scores.csv ~ local ~ on disk here, not committed$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-job-not-slurm ok 'job ~ skynet interactive, GPU 2 ~ unknown ~ no scheduler job id' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-commit-in-code-repo ok 'commit ~ casts-loader [0-9a-f]{7} ~ ok ~ resolves in casts-loader$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-code-row ok '<dt>Code repositories</dt><dd><code>casts-loader</code> at <code>/' -- cat "$tmp/atlas/atlas.html"
expect atlas-cause-bullet ok '<code>rescore.md</code>: the scorer read the wrong month of casts. Fix: pinned the month' -- cat "$tmp/atlas/atlas.html"
expect atlas-cause-bullet-not-flagged ok - -- bash -c '! grep -q "rescore.md names no root cause" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-verdict-prose ok '^O ~ lr-sweep ~ supported ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-explore-outcome ok '<span class="id">explore-07</span><span class="o o-explore">explore</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-explore-no-card-violations ok - -- bash -c '! grep -Eq "^V ~ explore-07 ~ (question card|job .* started|card edited|no partner)" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-run ok '^V ~ q-batch ~ question card is not committed, so nothing froze it$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-manifest ok '^M ~ q-batch ~ runs/q-batch/manifest-4860.txt ~ False$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-uncommitted-note ok '<span class="id">q-batch</span>.*<span class="f">2 uncommitted</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-uncommitted-cartouche ok 'plus the working tree \(4 uncommitted files\)' -- cat "$tmp/atlas/atlas.html"
expect atlas-schema ok '^S ~ atlas_schema ~ 1$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-generated-at ok '^S ~ generated_at ~ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-summary ok '^S ~ summary.needs_you ~ [1-9]' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-severity ok '^O ~ explore-07 ~ explore ~ .* ~ ripple$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-last-event ok '"last_event": \{' -- cat "$tmp/atlas/atlas.json"
expect atlas-frozen-no-record ok '^O ~ skynet-train ~ no scheduler record ~ card frozen, but no manifest' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-not-run-is-rare ok - -- bash -c '! grep -q "^O ~ [^~]* ~ not run ~" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-ledger-by-hand ok '^O ~ hand-run ~ recorded by hand ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-incident-by-hand ok '^O ~ incident-only ~ recorded by hand ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-host ok '^W ~ skynet ~ none ~ hand-run$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-host-card ok 'hand-run is placed here only by execution.tsv rows: recorded by hand, not by a scheduler, and not counted in the budget' -- cat "$tmp/atlas/atlas.html"
expect atlas-report-unmerged ok '^O ~ report-branch ~ report unmerged ~ report on origin/docs/report-branch-report, unmerged ~ ' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-report-unmerged-needs-you ok '^N ~ report-branch ~ report waits for review on origin/docs/report-branch-report$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-behind-base ok '^S ~ behind_base ~ 1$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-behind-header ok '<p class="snap-behind">.* This checkout is 1 commit behind <code>origin/main</code>.*<code class="cmd">git pull</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-card-on-base ok '^V ~ behind-card ~ card exists on origin/main; this checkout is 1 commit behind, run git pull$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-card-on-base-not-uncommitted ok - -- bash -c '! grep -q "^V ~ behind-card ~ question card is not committed" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-report-not-pulled ok '^O ~ behind-card ~ report not pulled ~ report on origin/main;' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-ledger-bad-header ok '^V ~ behind-card ~ execution.tsv header is not id ts field value why evidence' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-no-launch-column ok - -- bash -c '! grep -q "execution-within-envelope" "$1"' _ "$tmp/atlas/atlas.html"
expect atlas-lineage-inferred ok '^E ~ lr-sweep ~ lr-sweep-fine ~ inferred ~ True$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-lineage-declared ok '^E ~ q-warmup-v2 ~ cosine-v2 ~ supersedes ~ False$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-lineage-declared-not-inferred ok - -- bash -c '! grep -q "^E ~ q-warmup ~ q-warmup-v2 ~ inferred" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-lineage-dotted ok '<ol class="lineage lineage-inferred"><li><div class="q"><span class="q-date">' -- cat "$tmp/atlas/atlas.html"
expect atlas-lineage-none-not-inferred ok - -- bash -c '! grep -q "^E ~ [^~]* ~ lr-sweep-2 ~" "$1"' _ "$tmp/atlas/atlas.tsv"
expect atlas-lineage-none-no-link ok - -- bash -c '! grep -q "href=\"#run-none\"" "$1"' _ "$tmp/atlas/atlas.html"
expect atlas-lineage-run-note ok '<span class="rel rel-inferred">follows <a class="id" href="#run-lr-sweep">lr-sweep</a>, inferred from name</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-lineage-names ok '^emu-b00-053-phys2<emu-b00-053 emu-b00-054<emu-b00-053 emu-b00-054b<emu-b00-054 emu-b00-e2b<emu-b00-e2 emu-b00-e2c<emu-b00-e2b $' -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import atlas
ids = {"emu-b00-053", "emu-b00-053-phys2", "emu-b00-054", "emu-b00-054b", "emu-b00-e2", "emu-b00-e2b", "emu-b00-e2c", "emu-store-054", "f2-train-deploy-shift", "f2b-past-only-inputs", "p1-lookahead"}
print("".join(f"{i}<{p} " for i in sorted(ids) for p in [atlas.name_parent(i, ids - {i})] if p))' "$here/lib"
expect atlas-stray-incident ok '^V ~ explore-07 ~ incident.md is a write-up not where the guard looks; move it to incidents/' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-stray-incident-keeps-ripple ok '^N ~ explore-07 ~ ripple on job-states, so stop spending$' -- cat "$tmp/atlas/atlas.tsv"
expect atlas-release-stamp ok '<dt>Guard version</dt><dd>schema [0-9]+, release ' -- cat "$tmp/atlas/atlas.html"
expect atlas-no-release-stamp ok "<dt>Guard version</dt><dd>schema 1, installed before release stamps; run <code>guard init $fx/casts-v4-training --update</code></dd>" -- python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import atlas
d = json.load(open(sys.argv[2])); d["version"] = {"installer": "b017edd"}; print(atlas.render(d))' "$here/lib" "$tmp/atlas/atlas.json"
expect atlas-verdict-stop ok '<p class="verdict-line">Stop spending on 2 runs: each has a ripple.</p>' -- cat "$tmp/atlas/atlas.html"
expect atlas-no-jobs-unchecked ok '^UNCHECKED$' -- python3 -c 'import json, sys
r = next(r for r in json.load(open(sys.argv[1]))["runs"] if r["id"] == "hand-run")
print(*{l["status"] for l in r["ripples"] if l["check"] in ("job-states", "walltime-headroom", "retries")})' "$tmp/atlas/atlas.json"
expect atlas-no-jobs-prose ok '</svg>jobs: unchecked</span> <span class="detail">no jobs yet: sacct lists [0-9]+ job\(s\) on account gom since 2026-09-01 from this host, none named hand-run' -- cat "$tmp/atlas/atlas.html"
# The skynet reproduction: sacct on PATH that lists nothing. No run may show a job or budget pass.
expect atlas-off-cluster ok 'Spend source</dt><dd>none: the budget ripple could not read sacct on this host</dd>' -- bash -c '. "$1"; MOCK_SACCT_ROWS=/dev/null MOCK_SACCT_CPUSECONDS= "$2" atlas --out "$3/off.html" >/dev/null && cat "$3/off.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-off-cluster-no-pass ok - -- bash -c '! grep -oE "aria-label=\"(job-states|walltime-headroom|retries|budget): pass\"" "$1"' _ "$tmp/atlas/off.html"
expect atlas-needs-you-incident ok 'Write up job 4840 at <code class="cmd">runs/explore-07/incidents/YYYY-MM-DD-4840.md</code>, or submit the next job with <code>guard run --cause</code>' -- python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import atlas
d = json.load(open(sys.argv[2]))
for r in d["runs"]: r["stray_incidents"] = []
print(atlas.render(d))' "$here/lib" "$tmp/atlas/atlas.json"
expect atlas-needs-you-branch ok 'review it as a pull request: <code class="cmd">git diff --stat origin/main...origin/agent/fp32-check</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-needs-you-await ok '<li class="todo-await">.*href="#run-skynet-train"' -- cat "$tmp/atlas/atlas.html"
atlas_group() {  # atlas_group <html> <group> <run id>: succeeds when the run sits in that run group
  python3 -c 'import re, sys
page, group, rid = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
m = re.search(r"<section class=\"rgroup\" id=\"runs-" + group + r"\".*?</section>", page, re.S)
sys.exit(0 if m and f"id=\"run-{rid}\"" in m.group(0) else 1)' "$@"
}
expect atlas-group-stop ok - -- atlas_group "$tmp/atlas/atlas.html" stop explore-07
expect atlas-group-stop-open ok '<details class="run" id="run-explore-07" open>' -- cat "$tmp/atlas/atlas.html"
expect atlas-group-rule ok - -- atlas_group "$tmp/atlas/atlas.html" rule q-batch
expect atlas-group-await ok - -- atlas_group "$tmp/atlas/atlas.html" await skynet-train
expect atlas-group-not-quiet ok - -- bash -c '! atlas_group "$1" quiet skynet-train' _ "$tmp/atlas/atlas.html"
expect atlas-no-tooltips ok '^abbr$' -- python3 -c 'import re, sys; print(" ".join(sorted(set(re.findall(r"<(\w+)[^>]* title=", open(sys.argv[1]).read())))))' "$tmp/atlas/atlas.html"
expect atlas-every-run-opens ok '^14$' -- grep -c '<details class="run" id="run-' <(sed 's/<details class="run"/\n&/g' "$tmp/atlas/atlas.html")
expect atlas-needs-you-stray ok 'A write-up exists at <code>runs/explore-07/incident.md</code>, but the guard does not count it there. Move it: <code class="cmd">git mv runs/explore-07/incident.md runs/explore-07/incidents/YYYY-MM-DD-4840.md</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-needs-you-unmerged ok 'href="#run-report-branch">report-branch</a> <span class="b b-handled">.*report unmerged</span><p>Its report is only on <code>origin/docs/report-branch-report</code>' -- cat "$tmp/atlas/atlas.html"
expect atlas-queue-json ok "^Q ~ n1 ~ open ~ run ~ $fx/casts-v4-training/guard/budget.card Q ~ n2 ~ acked ~ check ~ $fx/casts-v4-training/runs/cosine-v2/report.md ~ " -- bash -c 'grep "^Q ~" "$1" | tr "\n" " "' _ "$tmp/atlas/atlas.tsv"
expect atlas-queue-open-first ok '<ol class="todo"><li class="todo-you"><svg class="i" aria-hidden="true"><use href="#i-await"/></svg><div><span class="id">n1</span> <span class="o">run</span> <strong>Merge PR #7, agent/fp32-check \(autonomous merge refused\)</strong>' -- cat "$tmp/atlas/atlas.html"
expect atlas-queue-open-command ok '<p>Run, in order:</p><ol><li><code class="cmd">cd [^<]*/casts-v4-training</code></li><li><code class="cmd">git diff [^<]*</code></li><li><code class="cmd">gh pr merge 7 --squash</code></li></ol>' -- cat "$tmp/atlas/atlas.html"
expect atlas-queue-acked-last ok '<li class="todo-acked">.*<strong>Read the cosine-v2 report before the thesis figure</strong> <em class="q-state">acked, not done</em>.*</li></ol></section>' -- cat "$tmp/atlas/atlas.html"
expect atlas-queue-empty ok - -- python3 -c 'import json, re, sys; sys.path.insert(0, sys.argv[1]); import atlas
d = json.load(open(sys.argv[2])); d["queue"] = []
sys.exit(1 if re.search(r"class=\"todo-(you|acked)\"|needs-you done", atlas.render(d)) else 0)' "$here/lib" "$tmp/atlas/atlas.json"
expect atlas-timeline-ledger ok '<span>execution.tsv x1: host skynet, recorded by hand</span>' -- cat "$tmp/atlas/atlas.html"
expect atlas-golden ok - -- bash -c 'diff <("$1/tests/atlas-golden.sh") "$1/tests/golden/atlas-fixture.html"' _ "$here"
expect atlas-no-network ok - -- bash -c '! grep -Eiq "<link[^>]*https?://|src=\"?https?://" "$1"' _ "$tmp/atlas/atlas.html"
expect atlas-head-only ok '\(12 runs,' -- bash -c '. "$1"; "$2" atlas --no-ripples --head-only --out "$3/head.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-no-ripples-says-so ok 'Safety checks were not run for this render, so this page cannot say whether anything is wrong.' -- cat "$tmp/atlas/head.html"
expect atlas-verdict-unknown ok 'class="verdict verdict-unknown" role="status"' -- cat "$tmp/atlas/head.html"
expect atlas-head-only-hides-disk-run ok - -- bash -c '! grep -q "run-q-batch" "$1"' _ "$tmp/atlas/head.html"
expect atlas-read-only ok '^same$' -- bash -c '[ "$(git -C "$1" status --porcelain)" = "$2" ] && echo same' _ "$fx/casts-v4-training" "$atlas_before"
cp "$fx/casts-v4-training/guard/run" "$tmp/atlas/guard-run.kept"
printf '#!/bin/bash\ntouch "$HOME/forged"; printf "PASS\\tguard-untouched\\tforged\\n"\n' > "$fx/casts-v4-training/guard/run"
expect atlas-runs-protected-guard ok '^RIPPLE$' -- bash -c '. "$1"; HPC_GUARD_LOCAL=1 HOME="$2" "$3" atlas --runs lr-sweep --out "$2/forged.html" --json "$2/forged.json" > /dev/null
  python3 -c "import json, sys; print(*{l[\"status\"] for r in json.load(open(sys.argv[1]))[\"runs\"] for l in r[\"ripples\"] if l[\"check\"] == \"guard-untouched\"})" "$2/forged.json"' _ "$tmp/atlas/env.sh" "$tmp/atlas" "$guard"
expect atlas-forged-runner-not-run ok - -- test ! -e "$tmp/atlas/forged"
cp "$tmp/atlas/guard-run.kept" "$fx/casts-v4-training/guard/run"
expect atlas-default-out ok "atlas: $tmp/atlas/tmpdir/atlas-casts-v4-training-$(id -u).html" -- bash -c '. "$1"; mkdir -p "$2/tmpdir"; TMPDIR="$2/tmpdir" "$3" atlas --no-ripples' _ "$tmp/atlas/env.sh" "$tmp/atlas" "$guard"
expect atlas-default-out-private ok '^600$' -- stat -c %a "$tmp/atlas/tmpdir/atlas-casts-v4-training-$(id -u).html"
expect atlas-default-out-read-only ok '^same$' -- bash -c '[ "$(git -C "$1" status --porcelain)" = "$2" ] && echo same' _ "$fx/casts-v4-training" "$atlas_before"
expect atlas-runs-filter ok '\(2 runs,' -- bash -c '. "$1"; "$2" atlas --no-ripples --runs "cosine-*" --runs "explore-*" --title casts --out "$3/filtered.html"' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas"
expect atlas-runs-title ok '<p class="eyebrow">Guard atlas · project <code>casts-v4-training</code> · runs <code>cosine-\*</code>, <code>explore-\*</code></p>' -- cat "$tmp/atlas/filtered.html"
expect atlas-runs-title-h1 ok '<h1>casts</h1>' -- cat "$tmp/atlas/filtered.html"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
( . "$tmp/atlas/env.sh"; exec "$guard" atlas --serve "$port" --every 60 --no-ripples ) > "$tmp/atlas/serve.log" 2>&1 &
serve_pid=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$port/atlas.json" && break; sleep 0.2; done
expect atlas-serve-line ok "^atlas: serving http://127.0.0.1:$port/ from " -- cat "$tmp/atlas/serve.log"
expect atlas-serve-page ok '<meta http-equiv="refresh" content="60">' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-run ok 'id="run-cosine-v2"' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-footer ok 'Served live from .*; re-surveyed at most every 1 min on reload' -- curl -s "http://127.0.0.1:$port/"
expect atlas-serve-json ok '"id": "q-batch"' -- curl -s "http://127.0.0.1:$port/atlas.json"
kill "$serve_pid" 2>/dev/null; wait "$serve_pid" 2>/dev/null
sock="$tmp/atlas/atlas.sock"
( . "$tmp/atlas/env.sh"; exec "$guard" atlas --serve "$sock" --every 0 --no-ripples ) > "$tmp/atlas/sock.log" 2>&1 &
sock_pid=$!
for _ in $(seq 50); do [ -S "$sock" ] && curl -s -o /dev/null --unix-socket "$sock" http://atlas/atlas.json && break; sleep 0.2; done
expect atlas-sock-line ok "^atlas: serving unix:$sock from " -- cat "$tmp/atlas/sock.log"
expect atlas-sock-page ok 'id="run-cosine-v2"' -- curl -s --unix-socket "$sock" http://atlas/
queue_ids() { curl -s --unix-socket "$1" http://atlas/atlas.json | python3 -c 'import json, sys; print(*[q["id"] for q in json.load(sys.stdin)["queue"]])'; }
expect atlas-sock-queue ok '^n1 n2$' -- queue_ids "$sock"
(cd "$fx/casts-v4-training" && "$guard" needs-you "done" n1 > /dev/null)
expect atlas-sock-requeue ok '^n2$' -- queue_ids "$sock"
expect atlas-sock-mode ok '^600$' -- stat -c %a "$sock"
kill -TERM "$sock_pid" 2>/dev/null; wait "$sock_pid" 2>/dev/null
expect atlas-sock-removed ok '^gone$' -- bash -c '[ ! -e "$1" ] && echo gone' _ "$sock"
echo plain > "$tmp/atlas/not-a-socket"
expect atlas-sock-refuses-file fail 'not a socket' -- bash -c '. "$1"; "$2" atlas --serve "$3" --no-ripples' _ "$tmp/atlas/env.sh" "$guard" "$tmp/atlas/not-a-socket"
expect atlas-serve-bad-value fail "port number or a socket path" -- "$guard" atlas --serve nope
expect atlas-refuses-unguarded fail 'no guard/run' -- "$guard" atlas "$tmp/agents"
# The question map's lineage holds v7 question cards only: guard run's CardRecords have no supersedes or spawned_from,
# so no edge, inferred or named, reaches one; and the atlas docs name its own run checks, not guard/run ripples.
expect atlas-lineage-v7-only ok '^\[\]$' -- python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import atlas
rec = {"written_by": "guard run, local, unsigned", "why": "w"}
print(atlas.lineage([{"id": "r1", "card": rec, "card_history": []}, {"id": "r1-b", "card": rec, "card_history": []}]))' "$here"
expect atlas-docs-no-ripples-command ok - -- bash -c '! grep -n "guard/run ripples" "$1/docs/atlas.md" "$1/docs/atlas-json.md"' _ "$here"
