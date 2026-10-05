#!/usr/bin/env python3
"""usage: guard atlas [repo] [--out FILE | --serve PORT|SOCKET [--every SECONDS]] [--json FILE] [--no-ripples]
                   [--head-only] [--runs GLOB]... [--title NAME] [--code NAME[=PATH]]...

Writes one self-contained HTML page of a guarded project: whether anything is wrong, the budget and what
needs you, then compute hosts and their fences, every run's safety checks, the question cards in the order
they froze, and per run its card, a timeline and the receipts of every evidence row. atlas_render.py draws
the page from the data collect() returns, which --json writes out.

Read-only. Guard inputs come from the protected branch through git show. Runs come from HEAD plus the
working tree, so uncommitted run dirs and manifests show up; --head-only reads HEAD alone.
Ripples come from the project's own guard/run, so the page shows exactly what the agent sees.
--serve takes a port, bound to 127.0.0.1, or a socket path (anything containing "/"). On a shared login
node use a socket: it is created 0600, so only you can reach it, and ssh -L 8765:/path/to/sock host
forwards it. Python 3 standard library only.
"""
import argparse, datetime as dt, fnmatch, glob, json, os, re, signal, socket, socketserver, stat, subprocess, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from atlas_render import render

ATLAS_SCHEMA = 1  # of the --json data; bump on a renamed or removed field, never for an added one

def git(top, *args, ok=False):
    p = subprocess.run(["git", "-C", top, "--no-optional-locks", *args], capture_output=True, text=True)
    if p.returncode and not ok:
        return None
    return p.stdout

def ls(top, cmd, *args):
    return [f for f in (git(top, cmd, "-z", *args) or "").split("\0") if f]

def show(top, ref, path):
    return git(top, "show", f"{ref}:{path}")

def kv(text):
    out = {}
    for line in (text or "").splitlines():
        m = re.match(r"^([a-z_]+):\s*(.*)$", line)
        if m and m.group(1) not in out:
            out[m.group(1)] = m.group(2).strip()
    return out

def bullet(text, labels):
    for m in re.finditer(r"^\s*[-*]\s+\*\*([^*]+?)\*\*:?\s*(.*)$", text or "", re.M):
        if m.group(1).lower().startswith(labels):
            return m.group(2).strip()
    return ""

def unset(v):
    return v is None or v == "" or bool(re.fullmatch(r"<[^>]*>", v))

def when(s):
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
        return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)
    except (ValueError, AttributeError):
        return None

def commits(top, path, ref="HEAD"):
    out = git(top, "log", "--reverse", "--format=%H\t%cI\t%s", ref, "--", path) or ""
    return [dict(zip(("sha", "time", "subject"), l.split("\t", 2))) for l in out.splitlines() if l]

def section(md, title):
    m = re.search(rf"^## {re.escape(title)}[^\n]*\n(.*?)(?=^## |\Z)", md or "", re.M | re.S)
    return m.group(1).strip() if m else ""

def table_rows(block):
    rows = []
    for line in block.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        if not all(re.fullmatch(r":?-+:?", c) for c in cells):
            rows.append(cells)
    return rows

EVIDENCE = ("claim", "value", "artifact", "job", "commit")

def evidence_rows(block):
    rows = table_rows(block)
    if not rows:
        return []
    head = [h.lower() for h in rows[0]]
    col = {k: next((i for i, h in enumerate(head) if k in h), None) for k in EVIDENCE}
    if all(i is None for i in col.values()):
        col = dict(zip(EVIDENCE, range(len(EVIDENCE))))
    return [{k: r[i] if i is not None and i < len(r) else "" for k, i in col.items()} for r in rows[1:]]

LEDGER = ("id", "ts", "field", "value", "why", "evidence")

def ledger(text):
    lines = [l.split("\t") for l in (text or "").splitlines() if l.strip()]
    header_ok = bool(lines) and tuple(lines[0]) == LEDGER
    rows = [dict(zip(LEDGER, l + [""] * len(LEDGER))) for l in lines[1:]] if header_ok else []
    return header_ok, rows

def ripples(top, base, run_dir):
    env = dict(os.environ, HPC_GUARD_REF=base, GIT_OPTIONAL_LOCKS="0")
    try:
        p = subprocess.run(["bash", "guard/run", "ripples", run_dir], cwd=top, env=env,
                           capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return [{"status": "UNCHECKED", "check": "ripples", "detail": "guard/run ripples timed out"}]
    lines = [l.split("\t", 2) for l in p.stdout.splitlines() if l.count("\t") >= 2]
    if not lines:
        return [{"status": "UNCHECKED", "check": "ripples", "detail": (p.stderr.strip() or "no output")[:200]}]
    return [{"status": s, "check": c, "detail": d.strip()} for s, c, d in lines]

def repo_at(path):
    found = (git(path, "rev-parse", "--show-toplevel") or "").strip() if os.path.isdir(path) else ""
    return path if found and os.path.realpath(found) == os.path.realpath(path) else None

def find_code(top, names, given):
    code = {}
    for name in sorted(set(names) | set(given)):
        if given.get(name):
            code[name] = repo_at(os.path.abspath(given[name]))
        else:
            code[name] = next(filter(None, (repo_at(os.path.join(d, name)) for d in (top, os.path.dirname(top)))), None)
    return code

def mtime(top, path):
    try:
        return dt.datetime.fromtimestamp(os.path.getmtime(os.path.join(top, path)), dt.timezone.utc).isoformat()
    except OSError:
        return ""

def collect(top, base, run_ripples=True, worktree=True, globs=(), given_code=None, title=None):
    head = git(top, "rev-parse", "HEAD").strip()
    base_sha = (git(top, "rev-parse", base) or "").strip()
    behind = int((git(top, "rev-list", "--count", f"HEAD..{base}") or "0").strip() or 0)
    ahead_refs = {}
    for ref in (git(top, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin") or "").split():
        if ref in (base, "origin/HEAD", "origin") or ref.endswith("/HEAD"):
            continue
        ahead = int((git(top, "rev-list", "--count", f"{base}..{ref}") or "0").strip() or 0)
        if ahead:
            ahead_refs[ref] = ahead
    elsewhere = {ref: set(ls(top, "ls-tree", "-r", "--name-only", ref, "--", "runs/")) for ref in [base, *ahead_refs]}
    budget = kv(show(top, base, "guard/budget.card"))
    version = kv(show(top, base, "guard/VERSION"))
    watch = [l.split("#")[0].strip() for l in (show(top, base, "guard/watch.list") or "").splitlines()]
    watch = [w for w in watch if w]
    files = set(ls(top, "ls-tree", "-r", "--name-only", "HEAD"))
    tree = set(files)
    for f in files:
        d = os.path.dirname(f)
        while d and d not in tree:
            tree.add(d); d = os.path.dirname(d)
    loose = set(ls(top, "ls-files", "--others", "--exclude-standard", "--", "runs/")) | \
        set(ls(top, "diff", "--name-only", "HEAD", "--", "runs/")) if worktree else set()
    names = {f.split("/")[1] for f in files | loose if f.startswith("runs/") and f.count("/") >= 2}
    if worktree and os.path.isdir(os.path.join(top, "runs")):
        names |= {d for d in os.listdir(os.path.join(top, "runs")) if os.path.isdir(os.path.join(top, "runs", d))}
    names = sorted(r for r in names - {"_template"} if not globs or any(fnmatch.fnmatchcase(r, g) for g in globs))

    def read(path):
        if worktree and os.path.isfile(os.path.join(top, path)):
            with open(os.path.join(top, path), errors="replace") as f:
                return f.read()
        return show(top, "HEAD", path)

    def born(path, hist, last=False):
        return hist[-1 if last else 0]["time"] if hist else (mtime(top, path) if worktree else "")

    runs = []
    for rid in names:
        d = f"runs/{rid}/"
        committed = sorted(f for f in files if f.startswith(d))
        uncommitted = sorted(f for f in loose if f.startswith(d))
        paths = sorted(set(committed) | set(uncommitted))
        card_path = d + "question.card"
        card_from = "here" if card_path in paths else base if card_path in elsewhere[base] else None
        card = kv(read(card_path) if card_from == "here" else show(top, base, card_path) if card_from else None)
        on_disk = worktree and os.path.isfile(os.path.join(top, card_path))
        blob = (git(top, "hash-object", card_path) if on_disk else
                git(top, "rev-parse", f"{'HEAD' if card_from == 'here' else base}:{card_path}", ok=True)) or ""
        execution = None
        if d + "execution.tsv" in paths:
            header_ok, rows = ledger(read(d + "execution.tsv"))
            execution = {"path": d + "execution.tsv", "committed": d + "execution.tsv" in files, "header_ok": header_ok, "rows": rows}
        manifests = []
        for f in paths:
            if re.search(r"/manifest-[^/]+\.txt$", f):
                text = read(f) or ""
                m = kv(text); m["path"] = f; m["committed"] = f in files
                m["inputs"] = [l[7:] for l in text.splitlines() if l.startswith("input: ")]
                manifests.append(m)
        manifests.sort(key=lambda m: m.get("time", ""))
        incidents = []
        for f in paths:
            if "/incidents/" in f and f.endswith(".md"):
                text = read(f); i = kv(text)
                cause = i.get("root_cause") if not unset(i.get("root_cause")) else bullet(text, ("cause", "root cause"))
                fix = i.get("fix") if not unset(i.get("fix")) else bullet(text, ("fix",))
                incidents.append({"path": f, "job": i.get("job", ""), "root_cause": cause, "fix": fix,
                                  "time": born(f, commits(top, f))})
        stray = [f for f in paths if re.fullmatch(re.escape(d) + r"incident[^/]*\.md", f)]
        report_text = read(d + "report.md") if d + "report.md" in paths else None
        report = None
        if report_text:
            rk = kv(report_text)
            verdict = re.search(r"^Verdict against kill criteria:\s*(.*)$", report_text, re.M)
            dev = [l.lstrip("-* ").strip() for l in section(report_text, "Deviations").splitlines() if l.strip()]
            report = {"hypothesis": rk.get("hypothesis", ""), "verdict": verdict.group(1).strip() if verdict else "",
                      "evidence": evidence_rows(section(report_text, "Evidence")), "deviations": dev,
                      "time": born(d + "report.md", commits(top, d + "report.md"), last=True),
                      "next": section(report_text, "Next step")}
        report_refs = [] if report else [ref for ref, have in elsewhere.items() if d + "report.md" in have]
        hist, frozen_on = commits(top, card_path), "HEAD"
        if not hist and card_path in elsewhere[base]:
            hist, frozen_on = commits(top, card_path, base), base
        runs.append({"id": rid, "card": card, "card_blob": blob.strip(), "card_from": card_from,
                     "card_history": hist, "card_frozen_on": frozen_on if hist else None,
                     "manifests": manifests, "incidents": incidents, "stray_incidents": stray, "execution": execution, "report": report,
                     "report_refs": report_refs, "ripples": [],
                     "committed_files": committed, "uncommitted_files": uncommitted,
                     "checks": sorted(f.split("/")[-1] for f in paths if "/checks/" in f)})
    if run_ripples:
        with ThreadPoolExecutor(max_workers=8) as ex:
            for r, rip in zip(runs, ex.map(lambda r: ripples(top, base, f"runs/{r['id']}"), runs)):
                r["ripples"] = rip
    cited = [m.group(1) for r in runs for e in (r["report"]["evidence"] if r["report"] else [])
             for m in [COMMIT.fullmatch(clean(e["commit"]))] if m and m.group(1)]
    code = find_code(top, cited, given_code or {})
    for r in runs:
        trace_evidence(top, r, tree, code, worktree)
        r["outcome"], r["outcome_detail"] = outcome(r, runs, base)
        r["violations"] = violations(r, base, behind)
        r["severity"] = severity(r)
        r["needs_you"] = needs_you(r, base)
        last = max((e for e in events(r) if e[1]), key=lambda e: e[1], default=None)
        r["last_event"] = {"type": EVENT_TYPE.get(last[2], EVENT_TYPE.get(last[0])), "what": last[3],
                           "time": last[1].astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")} if last else None
    branches = []
    for ref, ahead in ahead_refs.items():
        changed = (git(top, "diff", "--name-only", f"{base}...{ref}") or "").split()
        drawer = []
        for f in changed:
            if not f.startswith(("guard/", ".github/")):
                continue
            if f.endswith(".card"):
                old, new = kv(show(top, base, f)), kv(show(top, ref, f))
                diffs = [f"{k} {old.get(k, 'unset')} to {new.get(k, 'unset')}" for k in sorted(set(old) | set(new)) if old.get(k) != new.get(k)]
                drawer.append(f + (" (" + "; ".join(diffs) + ")" if diffs else ""))
            else:
                drawer.append(f)
        watched = (git(top, "diff", "--name-only", f"{base}...{ref}", "--", *watch) or "").split() if watch else []
        last = (git(top, "log", "-1", "--format=%cI\t%s", ref) or "\t").strip().split("\t", 1)
        branches.append({"name": ref, "ahead": ahead, "changed": len(changed), "drawer": drawer,
                         "watched": watched, "time": last[0], "subject": last[-1]})
    origin = (git(top, "remote", "get-url", "origin") or top).strip().rstrip("/")
    project = re.sub(r"\.git$", "", re.split(r"[/:]", origin)[-1])
    now = dt.datetime.now(dt.timezone.utc)
    data = {"atlas_schema": ATLAS_SCHEMA, "project": project, "title": title or project, "globs": list(globs), "top": top, "base": base,
            "base_sha": base_sha, "head": head, "behind_base": behind, "worktree": worktree,
            "uncommitted": sum(len(r["uncommitted_files"]) for r in runs), "code": code, "rippled": run_ripples,
            "budget": budget, "version": version, "watch": watch, "runs": runs, "branches": branches,
            "generated": now.strftime("%Y-%m-%d %H:%M UTC"), "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {"runs": len(runs), "ripples": sum(r["severity"] == "ripple" for r in runs),
                        "handled": sum(any(l["status"] == "HANDLED" for l in r["ripples"]) for r in runs),
                        "unchecked": sum(any(l["status"] == "UNCHECKED" for l in r["ripples"]) for r in runs),
                        "needs_you": sum(bool(r["needs_you"]) for r in runs)}}
    data["waters"] = waters(data)
    data["lineage"] = lineage(runs)
    return data

SLURM = re.compile(r"[0-9][0-9_]*")
COMMIT = re.compile(r"(?:([\w.-]+)\s+)?([0-9a-f]{7,40})")

def clean(cell):
    return cell.strip().strip("`").strip()

def link(kind, value, state, note):
    return {"kind": kind, "value": value, "state": state, "note": note}

def exists(path):
    return os.path.exists(path) or (any(c in path for c in "*?[") and bool(glob.glob(path)))

def artifact_link(cell, head_tree, top):
    tokens = re.findall(r"`([^`]+)`", cell) or [cell]
    path = next((t.strip() for t in tokens if "/" in t), None)
    if not path:
        return link("artifact", cell or "none", "unknown", "not a path")
    if os.path.isabs(path):
        if exists(path):
            return link("artifact", path, "local", "on disk here, not committed")
        return link("artifact", path, "unknown", "absolute path not on this host")
    rel = os.path.normpath(path)
    if rel in head_tree:
        return link("artifact", path, "ok", "committed at HEAD")
    if top and exists(os.path.join(top, rel)):
        return link("artifact", path, "local", "on disk here, not committed")
    return link("artifact", path, "broken", "not in the repository or on disk")

def job_link(cell, manifests_by_job):
    v = clean(cell)
    if v.lower() in ("", "none", "n/a"):
        return link("job", v or "none", "unknown", "no job cited")
    if not SLURM.fullmatch(v):
        return link("job", v, "unknown", "no scheduler job id, so no manifest to match")
    m = manifests_by_job.get(v)
    if not m:
        return link("job", v, "broken", "no manifest with this job id in the run")
    return link("job", v, "ok", f"manifest on {m.get('host', '?')}" + ("" if m["committed"] else " (uncommitted)"))

def commit_link(cell, top, code):
    v = clean(cell)
    m = COMMIT.fullmatch(v)
    if not m:
        return link("commit", v or "none", "broken", "no commit sha in the cell")
    name, sha = m.groups()
    resolves = lambda repo: git(repo, "rev-parse", "--verify", "-q", f"{sha}^{{commit}}") is not None
    if name:
        if not code.get(name):
            return link("commit", v, "unknown", f"{name} is not checked out here")
        return link("commit", v, "ok", f"resolves in {name}") if resolves(code[name]) else \
            link("commit", v, "broken", f"does not resolve in {name}")
    if resolves(top):
        return link("commit", v, "ok", "resolves in the project")
    hit = next((n for n, p in code.items() if p and resolves(p)), None)
    if hit:
        return link("commit", v, "ok", f"resolves in {hit}")
    missing = [n for n, p in code.items() if not p]
    if missing:
        return link("commit", v, "unknown", f"not in the project; {', '.join(missing)} not checked out here")
    return link("commit", v, "broken", "does not resolve in the project" + "".join(f" or {n}" for n in code))

def trace_evidence(top, run, tree, code, worktree):
    by_job = {m.get("job_id"): m for m in run["manifests"]}
    for e in run["report"]["evidence"] if run["report"] else []:
        links = [artifact_link(e["artifact"], tree, top if worktree else None), job_link(e["job"], by_job),
                 commit_link(e["commit"], top, code)]
        m = by_job.get(clean(e["job"]))
        if m and m.get("card"):
            same = run["card_blob"].startswith(m["card"])
            links.append(link("card", m["card"][:12], "ok" if same else "broken",
                              "matches the card read here" if same else "the card changed after this job"))
        else:
            links.append(link("card", "not recorded", "unknown", "manifests record the card hash from roadmap item 3"))
        if m:
            links.append(link("inputs", f"{len(m['inputs'])} listed", "ok" if m["inputs"] else "unknown",
                              "; ".join(m["inputs"]) or "no inputs.list for this run"))
        e["links"] = links

OUTCOMES = {
    "explore": "explore run, so no card and no verdict",
    "supported": "report verdict: continue",
    "negative": "report verdict: kill, a clean negative",
    "escalated": "report verdict: escalate, so a human decides",
    "reported": "report has no verdict the atlas knows",
    "report unmerged": "report on {ref}, unmerged",
    "report not pulled": "report on {ref}; this checkout is behind it, run git pull",
    "superseded": "superseded by {ref}",
    "open": "jobs recorded by a scheduler, no report yet",
    "recorded by hand": "ran without a scheduler record; known only from execution.tsv rows or an incident",
    "no scheduler record": "card frozen, but no manifest, ledger row or incident, so the atlas cannot tell whether it ran",
    "not run": "card not committed and no record of any run",
}

def outcome(r, runs, base):
    def said(key, ref=""):
        return key, OUTCOMES[key].format(ref=ref)
    if r["id"].startswith("explore-"):
        return said("explore")
    rep = r["report"]
    if rep:
        v = re.sub(r"\W", "", (rep["verdict"].split() or [""])[0].lower())
        return said({"kill": "negative", "continue": "supported", "escalate": "escalated"}.get(v, "reported"))
    if r["report_refs"]:
        ref = r["report_refs"][0]
        return said("report not pulled" if ref == base else "report unmerged", ref)
    by = next((o["id"] for o in runs if o["card"].get("supersedes") == r["id"]), None)
    if by:
        return said("superseded", by)
    if r["manifests"]:
        return said("open")
    if (r["execution"] and r["execution"]["rows"]) or r["incidents"] or r["stray_incidents"]:
        return said("recorded by hand")
    return said("no scheduler record" if r["card_history"] else "not run")

def violations(r, base, behind):
    out = []
    explore = r["id"].startswith("explore-")
    frozen = when(r["card_history"][0]["time"]) if r["card_history"] else None
    if not explore and r["card_frozen_on"] == base:
        out.append(f"card exists on {base}; " + (f"this checkout is {n(behind, 'commit')} behind, run git pull" if behind
                                                    else "this checkout does not have it, run git pull"))
    elif not explore and not frozen:
        out.append("question card is not committed, so nothing froze it")
    for f in r["stray_incidents"]:
        out.append(f"{f.split('/')[-1]} is a write-up not where the guard looks; move it to incidents/<date>-<job>.md")
    if r["execution"] and not r["execution"]["header_ok"]:
        out.append(f"execution.tsv header is not {' '.join(LEDGER)}, so neither the guard nor this page reads its rows")
    for m in r["manifests"] if not explore else []:
        t = when(m.get("time", ""))
        if frozen and t and t < frozen:
            out.append(f"job {m.get('job_id')} started before the card was committed")
    if len(r["card_history"]) > 1:
        out.append(f"card edited {len(r['card_history']) - 1} time(s) after its first commit")
    for i in r["incidents"]:
        if unset(i["root_cause"]):
            out.append(f"{i['path'].split('/')[-1]} names no root cause")
    if not explore and unset(r["card"].get("partner_metric")):
        out.append("no partner metric, so doing less could satisfy the metric")
    return out

def severity(r):
    seen = {l["status"] for l in r["ripples"]}
    return "ripple" if "RIPPLE" in seen else "handled" if "HANDLED" in seen else "warn" if r["violations"] else "quiet"

def needs_you(r, base):
    out = []
    if r["outcome"] == "escalated" or (r["report"] and not r["report"]["verdict"]):
        out.append("awaiting verdict")
    if r["outcome"] == "report unmerged":
        out.append(f"report waits for review on {r['report_refs'][0]}")
    if r["outcome"] == "report not pulled" or r["card_frozen_on"] == base:
        out.append(f"checkout behind {base}, run git pull")
    if not r["id"].startswith("explore-") and not r["card_frozen_on"]:
        out.append("uncommitted card")
    if r["stray_incidents"]:
        out.append("move the incident write-up to incidents/")
    rippled = [l["check"] for l in r["ripples"] if l["status"] == "RIPPLE"]
    if {"guard-untouched", "watched-paths"} & set(rippled):
        out.append("guard touched")
    rest = sorted(set(rippled) - {"guard-untouched", "watched-paths"})
    if rest:
        out.append(f"ripple on {', '.join(rest)}, so stop spending")
    return out

EVENT_TYPE = {"frozen": "card frozen", "edit": "card edited", "hand": "execution row", "jobs": "job", "incidents": "incident", "report": "report"}

def events(r):
    """(lane, time, state, label) for everything the run left behind."""
    hist = r["card_history"]
    ev = [("card", when(hist[0]["time"]), "frozen", "card frozen")] if hist else []
    ev += [("card", when(h["time"]), "edit", h["subject"]) for h in hist[1:]]
    failed = set()
    for l in r["ripples"]:
        if l["check"] == "job-states" and l["status"] in ("RIPPLE", "HANDLED"):
            failed |= {x.split(":")[0] for x in l["detail"].split(" (", 1)[0].split()}
    ev += [("jobs", when(m.get("time", "")), "fail" if m.get("job_id") in failed else "ok", m.get("job_id", "?")) for m in r["manifests"]]
    ev += [("jobs", when(x["ts"]), "hand", f"execution.tsv {x['id']}: {x['field']} {x['value']}") for x in (r["execution"] or {}).get("rows", [])]
    ev += [("incidents", when(i["time"]), "ok" if not unset(i["root_cause"]) else "fail", i["job"] or i["path"].split("/")[-1]) for i in r["incidents"]]
    if r["report"]:
        ev.append(("report", when(r["report"]["time"]), "ok", "report.md"))
    return ev

def waters(data):
    launch = set(data["budget"].get("launch_hosts", "").replace(",", " ").split())
    slurm, other = {}, {}
    for r in data["runs"]:
        for m in r["manifests"]:
            jid, h = m.get("job_id", ""), m.get("host", "?")
            (slurm if SLURM.fullmatch(jid) else other).setdefault(h, {}).setdefault(r["id"], "manifest")
        for x in (r["execution"] or {}).get("rows", []) if not r["manifests"] else []:
            if x["field"] == "host" and x["value"]:
                other.setdefault(x["value"], {}).setdefault(r["id"], "ledger")
    out = []
    if slurm:
        runs = sorted({x for v in slurm.values() for x in v})
        out.append({"name": "Slurm cluster", "fence": "bank", "runs": runs, "hand": [],
                    "desc": "Account " + data["budget"].get("account", "?") + ", preflight and a capped sub-account",
                    "count": f"{n(len(slurm), 'node')}, {n(len(runs), 'run')}"})
    for h, rs in sorted(other.items()):
        hand = sorted(k for k, v in rs.items() if v == "ledger")
        fenced = h in launch
        desc = ("Listed in launch_hosts: launch gates and a GPU-hour count, no scheduler" if fenced
                else "Not in launch_hosts: compute here passed no gate")
        if hand:
            desc += f". {', '.join(hand)} placed here by execution.tsv rows, recorded by hand, not by a scheduler, and not counted in the budget"
        out.append({"name": h, "fence": "bump" if fenced else "none", "runs": sorted(rs), "hand": hand, "desc": desc,
                    "count": n(len(rs), "run") if fenced else f"{n(len(rs), 'run')}: {', '.join(sorted(rs))}"})
    return out

def n(k, word):
    return f"{k} {word}" if k == 1 else f"{k} {word}{'es' if word.endswith('ch') else 's'}"

LINEAGE = ("supersedes", "spawned_from")

def name_parent(rid, ids):
    """The id rid most plausibly grew out of, judged by name alone, or None."""
    longer = [a for a in ids if rid.startswith(a + "-")]
    if longer:
        return max(longer, key=len)
    m = re.fullmatch(r"(.*\d)([a-z])", rid)
    if m:
        stem, letter = m.groups()
        prev = [stem + chr(c) for c in range(ord(letter) - 1, ord("a") - 1, -1)]
        return next((p for p in prev + [stem] if p in ids), None)
    m = re.fullmatch(r"(.*?)(\d+)", rid)
    if m and int(m.group(2)):
        prev = m.group(1) + str(int(m.group(2)) - 1).zfill(len(m.group(2)))
        return prev if prev in ids else None
    return None

def lineage(runs):
    cards = {r["id"]: r for r in runs if not r["id"].startswith("explore-")}
    frozen = {k: r["card_history"][0]["time"] if r["card_history"] else "" for k, r in cards.items()}
    edges = [{"from": r["card"][key], "to": k, "kind": key, "lineage_inferred": False}
             for k, r in cards.items() for key in LINEAGE if r["card"].get(key) in cards]
    for k, r in cards.items():
        if any(not unset(r["card"].get(key)) for key in LINEAGE):
            continue
        p = name_parent(k, set(cards) - {k})
        if p and not (frozen[p] and frozen[k] and when(frozen[k]) < when(frozen[p])):
            edges.append({"from": p, "to": k, "kind": "inferred", "lineage_inferred": True})
    return edges

class UnixServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "unix", 0

def unix_server(path, handler):
    try:
        if not stat.S_ISSOCK(os.lstat(path).st_mode):
            sys.exit(f"guard atlas: {path} exists and is not a socket")
        os.unlink(path)
    except FileNotFoundError:
        pass
    old = os.umask(0o077)
    try:
        srv = UnixServer(path, handler)
    except OSError as e:
        sys.exit(f"guard atlas: cannot bind {path}: {e}")
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    return srv

def serve(where, every, survey):
    lock, cache = threading.Lock(), {}

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?")[0]
            if path not in ("/", "/atlas.json"):
                return self.send_error(404)
            with lock:
                if not cache or time.monotonic() - cache["at"] > every:
                    try:
                        data = dict(survey(), every=every)
                    except Exception as e:
                        return self.send_error(500, f"atlas could not survey the project: {e}")
                    cache.update(at=time.monotonic(), data=data, html=render(data))
                body = (cache["html"] if path == "/" else json.dumps(cache["data"], indent=1, default=str)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8" if path == "/" else "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return unix_server(where, Page) if isinstance(where, str) else ThreadingHTTPServer(("127.0.0.1", where), Page)

def main():
    ap = argparse.ArgumentParser(prog="guard atlas", description=__doc__.split("\n\n")[1])
    ap.add_argument("repo", nargs="?", default=".")
    where = ap.add_mutually_exclusive_group()
    where.add_argument("--out", default=None, help="HTML path, default atlas.html in the current directory")
    where.add_argument("--serve", metavar="PORT|SOCKET", help="serve the page live instead of writing it: on 127.0.0.1:PORT, or on a unix socket "
                       "at SOCKET (a value containing /), created 0600 so only you can reach it")
    ap.add_argument("--every", type=int, default=300, metavar="SECONDS", help="with --serve, re-survey at most this often (default 300)")
    ap.add_argument("--json", default=None, help="also write the collected data as JSON")
    ap.add_argument("--no-ripples", action="store_true", help="skip running guard/run ripples")
    ap.add_argument("--head-only", action="store_true", help="read runs from HEAD only, ignoring the working tree")
    ap.add_argument("--runs", action="append", default=[], metavar="GLOB", help="only runs whose id matches GLOB (repeatable)")
    ap.add_argument("--title", default=None, help="page title, default the project name")
    ap.add_argument("--code", action="append", default=[], metavar="NAME[=PATH]", help="a code repository commit cells may cite (repeatable)")
    a = ap.parse_args()
    if a.serve is not None and "/" not in a.serve:
        try:
            a.serve = int(a.serve)
        except ValueError:
            ap.error(f"--serve takes a port number or a socket path containing '/', not {a.serve!r}")
    if a.serve is not None and a.json:
        ap.error("--json writes a file once; with --serve, read /atlas.json instead")
    bare = (git(a.repo, "rev-parse", "--is-bare-repository") or "").strip() == "true"
    top = (git(a.repo, "rev-parse", "--absolute-git-dir" if bare else "--show-toplevel") or "").strip()
    if not top:
        sys.exit(f"guard atlas: {a.repo} is not a git repository")
    base = os.environ.get("HPC_GUARD_REF") or (git(top, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD") or "origin/main").strip()
    if git(top, "cat-file", "-e", f"{base}:guard/run") is None:
        sys.exit(f"guard atlas: {top} has no guard/run on {base}; run guard init first")
    code = dict((c.split("=", 1) + [""])[:2] for c in a.code)
    survey = lambda: collect(top, base, not (a.no_ripples or bare), not (a.head_only or bare), a.runs, code, a.title)
    if a.serve is not None:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        srv = serve(a.serve, a.every, survey)
        at = f"unix:{a.serve}" if isinstance(a.serve, str) else f"http://127.0.0.1:{a.serve}/"
        try:
            print(f"atlas: serving {at} from {top}", flush=True)
            srv.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            srv.server_close()
            if isinstance(a.serve, str):
                try:
                    os.unlink(a.serve)
                except FileNotFoundError:
                    pass
        return
    data = survey()
    out = a.out or os.path.join(os.getcwd(), "atlas.html")
    with open(out, "w") as f:
        f.write(render(data))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(data, f, indent=1, default=str)
    print(f"atlas: {out} ({n(len(data['runs']), 'run')}, {n(len(data['branches']), 'branch')} ahead of {base})")

if __name__ == "__main__":
    main()
