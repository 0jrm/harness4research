#!/usr/bin/env python3
"""usage: guard atlas [repo] [--out FILE | --serve PORT|SOCKET [--every SECONDS]] [--json FILE] [--no-ripples]
                   [--head-only] [--runs GLOB]... [--title NAME] [--code NAME[=PATH]]...

Writes one self-contained HTML page that charts a guarded project: compute hosts and their fences,
budget against the verification reserve, a runs by checks ripples matrix, the question cards as a
map, and per run a lifeline and a provenance trace for every evidence row.

Read-only. Guard inputs come from the protected branch through git show. Runs come from HEAD plus the
working tree, so uncommitted run dirs and manifests show up; --head-only reads HEAD alone.
Ripples come from guard/run on the protected branch, as guard ripples runs it, so a working-tree edit cannot forge them.
--serve takes a port, bound to 127.0.0.1, or a socket path (anything containing "/"). On a shared login
node use a socket: it is created 0600, so only you can reach it, and ssh -L 8765:/path/to/sock host
forwards it. Python 3 standard library only.
"""
import argparse, datetime as dt, fnmatch, glob, html, json, os, re, signal, socket, socketserver, stat, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

def stamp(epoch):
    return dt.datetime.fromtimestamp(float(epoch), dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def commits(top, path, ref="HEAD"):
    out = git(top, "log", "--reverse", "--format=%H	%ct	%s", ref, "--", path) or ""
    return [{"sha": sha, "time": stamp(ct), "subject": subject}
            for sha, ct, subject in (l.split("	", 2) for l in out.splitlines() if l)]

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
    env = {k: v for k, v in os.environ.items() if k != "HPC_GUARD_LOCAL"}
    env.update(HPC_GUARD_REF=base, GIT_OPTIONAL_LOCKS="0")
    runner = git(top, "show", f"{base}:guard/run") or ""
    try:
        p = subprocess.run(["bash", "-c", runner, "guard/run", "ripples", run_dir], cwd=top, env=env,
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
        return stamp(os.path.getmtime(os.path.join(top, path)))
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
                     "manifests": manifests, "incidents": incidents, "execution": execution, "report": report,
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
        last = (git(top, "log", "-1", "--format=%ct\t%s", ref) or "\t").strip().split("\t", 1)
        branches.append({"name": ref, "ahead": ahead, "changed": len(changed), "drawer": drawer,
                         "watched": watched, "time": stamp(last[0]) if last[0] else "", "subject": last[-1]})
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
    if (r["execution"] and r["execution"]["rows"]) or r["incidents"]:
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
            failed |= {x.split(":")[0] for x in l["detail"].split()}
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

# ---------------------------------------------------------------- rendering

E = html.escape
COLS = [("guard-untouched", "guard"), ("question-card-frozen", "card"), ("watched-paths", "watched"),
        ("job-states", "jobs"), ("walltime-headroom", "walltime"), ("retries", "retries"),
        ("handled-failures", "handled"), ("budget", "budget"), ("quota", "quota"), ("domain", "domain"), ("other", "other")]
WORD = {"PASS": "pass", "RIPPLE": "ripple", "HANDLED": "handled", "UNCHECKED": "unchecked"}
LINKS = {"ok": ("background:var(--shoal);color:var(--passt)", "holds: committed, or resolves"),
         "local": ("background:var(--land);color:var(--handt)", "on disk here, not committed"),
         "unknown": ("background:repeating-linear-gradient(135deg,transparent 0 4px,var(--rule) 4px 5px);color:var(--sound);font-style:italic",
                     "cannot be checked from here"),
         "broken": ("background:var(--magt);color:var(--mag);box-shadow:inset 0 0 0 1px var(--mag)", "broken, points at nothing")}

def cell(r, key):
    lines = r["ripples"]
    if key == "domain":
        checks = [l for l in lines if l["check"].startswith("check:")]
        if not checks:
            hit = next((l for l in lines if l["check"] == "domain-checks"), None)
            return "unchecked", "none", hit["detail"] if hit else "no domain checks"
        bad = [l for l in checks if l["status"] == "RIPPLE"]
        tip = "; ".join(f"{l['check'][6:]}: {l['detail']}" for l in checks)
        return ("ripple" if bad else "pass"), f"{len(checks) - len(bad)}/{len(checks)}", tip
    if key == "other":
        known = {k for k, _ in COLS} | {"domain-checks"}
        hits = [l for l in lines if l["check"] not in known and not l["check"].startswith("check:")]
        if not hits:
            return "empty", "", "no other checks reported"
    else:
        hits = [l for l in lines if l["check"] == key]
    if not hits:
        return "unchecked", "", "not reported by this guard version"
    rank = {"RIPPLE": 3, "HANDLED": 2, "UNCHECKED": 1, "PASS": 0}
    top = max(hits, key=lambda l: rank.get(l["status"], 0))
    label = WORD.get(top["status"], top["status"].lower())
    short = label
    if top["status"] in ("RIPPLE", "HANDLED") and key == "other":
        short = top["check"]
    elif top["status"] in ("RIPPLE", "HANDLED"):
        first = top["detail"].split()[0] if top["detail"] else ""
        if ":" in first:
            short = first.split(":", 1)[1].split("->")[0].replace("_", " ").lower()
        else:
            short = {"question-card-frozen": "edited", "guard-untouched": "touched", "watched-paths": "touched",
                     "budget": "over 80%", "quota": "over 80%"}.get(key, label)
    return label, short, " / ".join(f"{l['status']} {l['check'] + ' ' if key == 'other' else ''}{l['detail']}".strip() for l in hits)

def n(k, word):
    return f"{k} {word}" if k == 1 else f"{k} {word}{'es' if word.endswith('ch') else 's'}"

def chip(text, kind):
    return f'<span class="chip {kind}">{E(text)}</span>'

def budget_bar(data):
    b = data["budget"]
    spent = None
    for r in data["runs"]:
        for l in r["ripples"]:
            m = re.match(r"(\d+) of (\d+) core-h", l["detail"]) if l["check"] == "budget" else None
            if m:
                spent = int(m.group(1))
    try:
        cap = int(b.get("max_core_hours", ""))
    except ValueError:
        return '<p class="note">max_core_hours is not set on the protected branch.</p>'
    try:
        res = int(b.get("verification_reserve_core_hours", "0"))
    except ValueError:
        res = 0
    if spent is None:
        return f'<p class="note">Spend is unknown on this host (no sacct). Cap {cap} core-hours, reserve {res}.</p>'
    pct = lambda x: f"{max(0, min(100, 100 * x / cap)):.2f}%"
    ticks = "".join(f'<span class="tick" style="left:{pct(cap * f / 4)}"><i>{int(cap * f / 4)}</i></span>' for f in range(5))
    return f'''<div class="scale" role="img" aria-label="{spent} of {cap} core-hours spent; {res} held for verification; ripples fire at 80 percent">
<div class="spent" style="width:{pct(spent)}"></div>
<div class="reserve" style="left:{pct(cap - res)};width:{pct(res)}"></div>
<div class="limit" style="left:80%"></div>{ticks}</div>
<p class="scale-key"><span><b>{spent}</b> spent</span><span><b>{cap - res - spent}</b> left for agent work</span>
<span><b>{res}</b> held for verification</span><span>ripples fire at <b>{int(cap * .8)}</b></span></p>'''

def lifeline(r):
    ev = events(r)
    frozen = next((t for _, t, state, _ in ev if state == "frozen"), None)
    ev = [e for e in ev if e[2] != "frozen"]
    times = [t for _, t, _, _ in ev if t] + ([frozen] if frozen else [])
    if not times:
        return ""
    t0, t1 = min(times), max(times)
    span = max((t1 - t0).total_seconds(), 3600)
    t1 = max(t1, t0 + dt.timedelta(seconds=span))
    t0 -= dt.timedelta(seconds=span * .06); t1 += dt.timedelta(seconds=span * .06)
    x = lambda t: 110 + 540 * (t - t0).total_seconds() / (t1 - t0).total_seconds()
    lanes = ["card", "jobs", "incidents", "report"]
    y = {k: 40 + 30 * i for i, k in enumerate(lanes)}
    s = [f'<svg class="life" viewBox="0 0 680 172" role="img" aria-label="Lifeline of {E(r["id"])}"><title>Lifeline of {E(r["id"])}</title>']
    for k in lanes:
        s.append(f'<text class="lane" x="16" y="{y[k] + 4}">{k}</text><line class="rail" x1="110" x2="650" y1="{y[k]}" y2="{y[k]}"/>')
    if frozen:
        fx = x(frozen)
        s.append(f'<rect class="before" x="110" y="24" width="{max(0, fx - 110):.1f}" height="124"/>')
        s.append(f'<line class="freeze" x1="{fx:.1f}" x2="{fx:.1f}" y1="22" y2="150"/>')
        s.append(f'<text class="freeze-label" x="{fx + 6:.1f}" y="14">card frozen {frozen:%b %d %H:%M}</text>')
        s.append(f'<line class="card-line" x1="{fx:.1f}" x2="650" y1="{y["card"]}" y2="{y["card"]}"/>')
    jobs_x = {}
    for lane, t, state, label in ev:
        if not t:
            continue
        cx = x(t)
        if lane == "jobs":
            jobs_x[label] = cx
            s.append(f'<g class="ev {state}"><rect x="{cx - 4:.1f}" y="{y[lane] - 8}" width="8" height="16" rx="2"/><title>{"" if state == "hand" else "job "}{E(label)}</title></g>')
        elif lane == "card":
            s.append(f'<g class="ev fail"><path d="M{cx:.1f} {y[lane] - 7}l6 7-6 7-6-7z"/><title>{E(label)}</title></g>')
        else:
            s.append(f'<g class="ev {state}"><circle cx="{cx:.1f}" cy="{y[lane]}" r="5"/><title>{E(label)}</title></g>')
    for i in r["incidents"]:
        if i["job"] in jobs_x and when(i["time"]):
            s.append(f'<path class="tie" d="M{jobs_x[i["job"]]:.1f} {y["jobs"] + 8}L{x(when(i["time"])):.1f} {y["incidents"] - 5}"/>')
    s.append(f'<text class="axis" x="110" y="166">{t0:%b %d}</text><text class="axis end" x="650" y="166">{t1:%b %d}</text></svg>')
    return "".join(s)

def atlas_graph(runs):
    ordered = sorted(runs, key=lambda r: r["card_history"][0]["time"] if r["card_history"] else "")
    ordered = [r for r in ordered if not r["id"].startswith("explore-")]
    lane, nxt, col = {}, 0, {}
    for i, r in enumerate(ordered):
        sup = r["card"].get("supersedes")
        if sup in lane:
            lane[r["id"]] = lane[sup]
        else:
            lane[r["id"]] = nxt; nxt += 1
        col[r["id"]] = i
    if not ordered:
        return ""
    w, h, gx, gy = 160, 50, 204, 70
    width = max(680, 30 + gx * len(ordered)); height = 40 + gy * max(1, nxt)
    pos = {r["id"]: (20 + gx * col[r["id"]], 20 + gy * lane[r["id"]]) for r in ordered}
    s = [f'<svg class="graph" viewBox="0 0 {width} {height}" style="min-width:{width}px" role="img" aria-label="Question cards and how they relate">',
         '<defs><marker id="ah" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M2 1L8 5L2 9" fill="none" stroke="context-stroke" stroke-width="1.5"/></marker></defs>']
    for r in ordered:
        for key, cls in (("supersedes", "sup"), ("spawned_from", "spawn")):
            src = r["card"].get(key)
            if src in pos:
                (x1, y1), (x2, y2) = pos[src], pos[r["id"]]
                if y1 == y2:
                    d = f"M{x1 + w} {y1 + h / 2}L{x2 - 3} {y2 + h / 2}"
                else:
                    d = f"M{x1 + w / 2} {y1 + h}L{x1 + w / 2} {y2 + h / 2}L{x2 - 3} {y2 + h / 2}"
                s.append(f'<path class="edge {cls}" d="{d}" marker-end="url(#ah)"><title>{key.replace("_", " ")}</title></path>')
    for r in ordered:
        x0, y0 = pos[r["id"]]
        pm = "" if not unset(r["card"].get("partner_metric")) else " nopair"
        s.append(f'<a href="#run-{E(r["id"])}"><g class="qnode {r["outcome"].replace(" ", "-")}{pm}"><rect x="{x0}" y="{y0}" width="{w}" height="{h}" rx="6"/>'
                 f'<text class="qname" x="{x0 + 12}" y="{y0 + 21}">{E(r["id"])}</text>'
                 f'<text class="qsub" x="{x0 + 12}" y="{y0 + 38}">{E(r["outcome"])}</text>'
                 f'<title>{E(r["card"].get("question", ""))}{" No partner metric." if pm else ""}</title></g></a>')
    s.append("</svg>")
    return "".join(s)

SAY_WHY = {"report unmerged", "report not pulled", "recorded by hand", "no scheduler record", "not run"}

def run_block(r):
    c, rep = r["card"], r["report"]
    rows = []
    for e in rep["evidence"] if rep else []:
        links = "".join(f'<span class="link {l["state"]}" title="{E(l["note"])}"><b>{E(l["kind"])}</b> {E(l["value"])}</span>' for l in e["links"])
        rows.append(f'<tr><td>{E(e["claim"])}</td><td class="num">{E(e["value"])}</td><td><div class="trace">{links}</div></td></tr>')
    trace = (f'<div class="wide"><table class="evidence"><thead><tr><th>Claim</th><th>Value</th><th>Receipts</th></tr></thead>'
             f'<tbody>{"".join(rows)}</tbody></table></div>') if rows else '<p class="note">No report yet, so nothing to trace.</p>'
    inc = "".join(f'<li><b>{E(i["path"].split("/")[-1])}</b>{", job " + E(i["job"]) if i["job"] else ""}: {E(i["root_cause"]) if not unset(i["root_cause"]) else "<em>no root cause named</em>"}'
                  f'{(", fix: " + E(i["fix"])) if i["fix"] else ""}</li>' for i in r["incidents"])
    dev = "".join(f"<li>{E(d)}</li>" for d in (rep["deviations"] if rep else []))
    warn = "".join(f"<li>{E(v)}</li>" for v in r["violations"])
    rel = []
    for k in ("supersedes", "spawned_from"):
        if not unset(c.get(k)):
            rel.append(f'{k.replace("_", " ")} <a href="#run-{E(c[k])}">{E(c[k])}</a>')
    return f'''<article class="run" id="run-{E(r["id"])}">
<header><h3>{E(r["id"])}</h3>{chip(r["outcome"], r["outcome"].replace(" ", "-"))}{f'<span class="rel">{E(r["outcome_detail"])}</span>' if r["outcome"] in SAY_WHY else ""}{chip("uncommitted", "loose-chip") if r["uncommitted_files"] else ""}{"".join(f'<span class="rel">{x}</span>' for x in rel)}</header>
<p class="question">{E(c.get("question", ""))}</p>
<dl class="card">
<div><dt>Hypothesis</dt><dd>{E(c.get("hypothesis", ""))}{f' <span class="verdict">Report says {E(rep["hypothesis"])}, verdict {E(rep["verdict"])}.</span>' if rep else ""}</dd></div>
<div class="pair"><dt>Metric</dt><dd>{E(c.get("metric", ""))}</dd><dt>Partner</dt><dd class="{"missing" if unset(c.get("partner_metric")) else ""}">{E(c.get("partner_metric", "")) if not unset(c.get("partner_metric")) else "None set. Doing less could satisfy the metric."}</dd></div>
<div><dt>Kill if</dt><dd>{E(c.get("kill_criteria", ""))}</dd></div>
</dl>
<div class="wide">{lifeline(r)}</div>
{f'<ul class="warn">{warn}</ul>' if warn else ""}
{trace}
{f'<h4>Incidents</h4><ul class="plain">{inc}</ul>' if inc else ""}
{f'<h4>Deviations from the card</h4><ul class="plain">{dev}</ul>' if dev else ""}
</article>'''

CSS = """
:root{--paper:#F6F9F9;--shoal:#DAEAF0;--shoal2:#A8CCDB;--land:#EDDDB4;--ink:#15222A;--sound:#56666F;--rule:#C5D2D7;
--mag:#9C2878;--magt:#F4DCEA;--passt:#1D5870;--handt:#6A4C10;--serif:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif;
--sans:system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;box-sizing:border-box;
padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--paper:#0C161C;--shoal:#12303C;--shoal2:#1E4D60;--land:#3B3220;
--ink:#D2DCE0;--sound:#8D9FA7;--rule:#283A43;--mag:#E07CC3;--magt:#3A1630;--passt:#9FD0E2;--handt:#E9CF8C}}
:root[data-theme="dark"]{--paper:#0C161C;--shoal:#12303C;--shoal2:#1E4D60;--land:#3B3220;--ink:#D2DCE0;--sound:#8D9FA7;
--rule:#283A43;--mag:#E07CC3;--magt:#3A1630;--passt:#9FD0E2;--handt:#E9CF8C}
*,*::before,*::after{box-sizing:inherit}html{scroll-padding-top:calc(env(safe-area-inset-top,0px) + 56px)}
body{margin:0;background:var(--paper);color:var(--ink);font:400 16px/1.55 var(--sans);font-variant-numeric:tabular-nums}
a{color:inherit}a:focus-visible,summary:focus-visible{outline:2px solid var(--mag);outline-offset:2px}
nav{position:sticky;top:env(safe-area-inset-top,0px);z-index:2;background:var(--paper);border-bottom:1px solid var(--rule);
display:flex;gap:22px;padding:10px max(20px,calc(50% - 520px));overflow-x:auto;font-size:15px}
nav a{text-decoration:none;color:var(--sound);white-space:nowrap}nav a:hover{color:var(--ink)}
main{max-width:1080px;margin:0 auto;padding:0 20px 80px}
.cartouche{margin:40px 0 36px;border:1.5px solid var(--ink);padding:6px}.cartouche>div{border:.5px solid var(--ink);padding:26px 30px 22px;
display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:28px;align-items:end}
.cartouche h1{font:italic 400 clamp(38px,6vw,64px)/1 var(--serif);margin:0;letter-spacing:-.01em}
.cartouche h1 small{display:block;font:400 17px/1.4 var(--sans);font-style:normal;color:var(--sound);margin-bottom:10px;letter-spacing:.01em}
.cartouche dl{margin:0;font-size:14px;display:grid;grid-template-columns:auto 1fr;gap:3px 14px}.cartouche dt{color:var(--sound)}.cartouche dd{margin:0}.cartouche dd.alarm{color:var(--mag)}
.readonly{grid-column:1/-1;border-top:.5px solid var(--rule);padding-top:12px;margin:0;font-size:14px;color:var(--sound)}
h2{font:italic 400 30px/1.2 var(--serif);margin:56px 0 6px}h2+p.lede{margin:0 0 20px;color:var(--sound);max-width:68ch}
h3{font:italic 500 24px/1.2 var(--serif);margin:0}h4{font:500 15px/1.3 var(--sans);margin:22px 0 6px}
.waters{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
.area{padding:14px 16px 16px;position:relative;min-height:118px}.area h3{font-size:21px}.area p{margin:6px 0 0;font-size:14px;color:var(--sound)}
.area .count{position:absolute;right:14px;top:16px;font-size:13px;color:var(--sound)}
.area.bank{background:var(--shoal);border:1.5px solid var(--ink)}
.area.bump{background:var(--shoal);border:2px dashed var(--mag)}
.area.none{background:repeating-linear-gradient(135deg,transparent 0 7px,var(--rule) 7px 8px);border:1.5px dotted var(--sound)}
.area .kind{font-size:13px;display:inline-block;margin-top:2px}.area.bump .kind,.area.none .kind{color:var(--mag)}
.scale{position:relative;height:30px;margin:28px 0 30px;background:var(--paper);border:1px solid var(--ink)}
.spent{position:absolute;inset:0 auto 0 0;background:var(--shoal2)}
.reserve{position:absolute;top:0;bottom:0;background:repeating-linear-gradient(135deg,var(--magt) 0 5px,transparent 5px 9px);border-left:1.5px solid var(--mag)}
.limit{position:absolute;top:-8px;bottom:-8px;border-left:2px solid var(--mag)}
.tick{position:absolute;bottom:-22px;transform:translateX(-50%);font-size:12px;color:var(--sound)}.tick i{font-style:normal}
.tick::before{content:"";position:absolute;left:50%;top:-8px;height:6px;border-left:1px solid var(--ink)}
.scale-key{display:flex;flex-wrap:wrap;gap:6px 26px;font-size:14px;color:var(--sound);margin:0}.scale-key b{color:var(--ink);font-weight:500}
.wide{overflow-x:auto;-webkit-overflow-scrolling:touch}
table{border-collapse:collapse;width:100%;font-size:14px}th{font-weight:500;text-align:left;color:var(--sound);padding:6px 8px;border-bottom:1px solid var(--ink)}
td{padding:6px 8px;border-bottom:.5px solid var(--rule);vertical-align:top}
.matrix td.st{text-align:center;padding:3px}.matrix th:not(:first-child){text-align:center}
.matrix td:first-child{white-space:nowrap}.matrix td:first-child a{font:italic 400 17px var(--serif);text-decoration:none}.matrix td:first-child a:hover{text-decoration:underline}
.st span{display:block;padding:4px 6px;border-radius:3px;font-size:13px;min-width:62px}
.st .pass{background:var(--shoal);color:var(--passt)}.st .handled{background:var(--land);color:var(--handt)}
.st .ripple{background:var(--magt);color:var(--mag);box-shadow:inset 0 0 0 1.5px var(--mag);font-weight:500}
.st .unchecked{background:repeating-linear-gradient(135deg,transparent 0 4px,var(--rule) 4px 5px);color:var(--sound);font-style:italic}
.key{display:inline-block;width:18px;height:12px;border:1px solid var(--ink);border-radius:2px;margin:0 -12px 0 6px;vertical-align:-1px}
.k-dot{border:1px dotted var(--ink)}.k-ref{border:1.5px dashed var(--handt)}.k-sup{background:var(--shoal)}.k-neg{background:var(--land)}.k-open{background:var(--paper)}.k-dash{border:1px dashed var(--sound)}.k-pair{border:1.5px solid var(--mag)}
.legend{display:flex;flex-wrap:wrap;gap:8px 18px;font-size:13px;color:var(--sound);margin:12px 0 0}.legend .st{display:flex;align-items:center;gap:6px}.legend .st span{min-width:0;width:18px;height:14px;padding:0}
.graphwrap{overflow-x:auto;border:1px solid var(--rule);background:var(--paper)}
.graph rect{stroke-width:1}.qname{font:italic 500 16px var(--serif);fill:var(--ink)}.qsub{font:400 13px var(--sans);fill:var(--sound)}
.qnode.supported rect{fill:var(--shoal);stroke:var(--ink)}.qnode.negative rect{fill:var(--land);stroke:var(--ink)}
.qnode.open rect,.qnode.reported rect,.qnode.escalated rect{fill:var(--paper);stroke:var(--ink)}
.qnode.superseded rect,.qnode.not-run rect{fill:none;stroke:var(--sound);stroke-dasharray:4 3}
.qnode.recorded-by-hand rect{fill:var(--paper);stroke:var(--ink);stroke-dasharray:2 2}.qnode.no-scheduler-record rect{fill:none;stroke:var(--ink);stroke-dasharray:1 3}
.qnode.report-unmerged rect,.qnode.report-not-pulled rect{fill:var(--paper);stroke:var(--handt);stroke-width:1.5;stroke-dasharray:6 3}
.qnode.nopair rect{stroke:var(--mag);stroke-width:1.5}.edge{fill:none;stroke:var(--sound);stroke-width:1}.edge.spawn{stroke-dasharray:3 3}
.run{border-top:1.5px solid var(--ink);padding:22px 0 10px;margin-top:30px}.run header{display:flex;flex-wrap:wrap;align-items:baseline;gap:10px 14px}
.chip{font-size:13px;padding:1px 9px;border-radius:3px;border:1px solid var(--ink)}.chip.supported{background:var(--shoal)}.chip.negative{background:var(--land)}
.chip.superseded,.chip.not-run{border-style:dashed;color:var(--sound)}
.chip.recorded-by-hand,.chip.no-scheduler-record{border-style:dotted}.chip.report-unmerged,.chip.report-not-pulled{border:1px dashed var(--handt);color:var(--handt)}.rel{font-size:14px;color:var(--sound)}
.question{font:italic 400 20px/1.4 var(--serif);margin:10px 0 14px;max-width:62ch}
.card{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px 28px;margin:0 0 8px;font-size:15px}
.card dt{color:var(--sound);font-size:13px}.card dd{margin:0 0 6px}.verdict{color:var(--sound)}.pair dd.missing{color:var(--mag)}
.life{width:100%;max-width:760px;min-width:560px;display:block;margin:6px 0}.lane,.axis,.freeze-label{font:400 12px var(--sans);fill:var(--sound)}.axis.end{text-anchor:end}
.rail{stroke:var(--rule);stroke-width:1}.before{fill:var(--magt);opacity:.55}.freeze{stroke:var(--ink);stroke-width:1.5;stroke-dasharray:4 3}
.card-line{stroke:var(--ink);stroke-width:3}.ev.ok rect,.ev.ok circle{fill:var(--shoal2);stroke:var(--ink)}.ev.fail rect,.ev.fail circle,.ev.fail path{fill:var(--magt);stroke:var(--mag);stroke-width:1.5}
.ev.hand rect{fill:var(--paper);stroke:var(--ink);stroke-dasharray:2 2}.tie{fill:none;stroke:var(--mag);stroke-width:1;stroke-dasharray:2 3}
.warn{margin:8px 0;padding:0;list-style:none;font-size:14px;color:var(--mag)}.warn li::before{content:"\\25B2  ";font-size:10px}
.evidence td.num{white-space:nowrap}.trace{display:flex;flex-wrap:wrap;gap:4px}
.link{font-size:12.5px;padding:2px 7px;border-radius:3px;white-space:nowrap}.link b{font-weight:500}
.legend .link{white-space:normal}.chip.loose-chip{background:var(--land);color:var(--handt);border-color:var(--handt)}.loose{display:block;font-size:12px;color:var(--handt)}.matrix td:first-child .chip{margin-left:8px}
ul.plain{margin:0;padding-left:18px;font-size:15px}.note{color:var(--sound);font-size:15px}
.drawer td.alarm{color:var(--mag)}.drawer code{font:inherit;font-size:13px}
footer{margin-top:60px;font-size:13px;color:var(--sound);border-top:.5px solid var(--rule);padding-top:12px}
@media (max-width:720px){.cartouche>div{grid-template-columns:1fr;padding:20px}}
"""

def render(data):
    runs = data["runs"]; v = data["version"]
    matrix = []
    cols = [(key, lbl) for key, lbl in COLS if key != "other" or any(cell(r, key)[0] != "empty" for r in runs)]
    for r in runs:
        tds = "".join(f'<td class="st" title="{E(t)}"><span class="{k}">{E(s)}</span></td>' for k, s, t in (cell(r, key) for key, _ in cols))
        tag = chip("explore", "explore") if r["outcome"] == "explore" else ""
        loose = f'<span class="loose">{len(r["uncommitted_files"])} uncommitted</span>' if r["uncommitted_files"] else ""
        matrix.append(f'<tr><td><a href="#run-{E(r["id"])}">{E(r["id"])}</a>{tag}{loose}</td>{tds}</tr>')
    heads = "".join(f"<th>{lbl}</th>" for _, lbl in cols)
    waters = "".join(f'<div class="area {w["fence"]}"><span class="count">{E(w["count"])}</span><h3>{E(w["name"])}</h3>'
                     f'<span class="kind">{ {"bank": "bank limit", "bump": "speed bump", "none": "no fence"}[w["fence"]]}</span><p>{E(w["desc"])}</p></div>'
                     for w in data["waters"]) or '<p class="note">No manifests yet, so no compute to place.</p>'
    drawer = "".join(
        f'<tr><td><code>{E(b["name"])}</code></td><td>{n(b["ahead"], "commit")}, {n(b["changed"], "file")}</td>'
        f'<td class="{"alarm" if b["drawer"] else ""}">{E(", ".join(b["drawer"])) or "untouched"}</td>'
        f'<td class="{"alarm" if b["watched"] else ""}">{E(", ".join(b["watched"])) or "untouched"}</td><td>{E(b["subject"])}</td></tr>'
        for b in data["branches"])
    live = data.get("every")
    sub = "Chart of the guarded project" + (f" {data['project']}" if data["title"] != data["project"] else "") + \
        (", runs " + ", ".join(data["globs"]) if data["globs"] else "")
    read_at = f'HEAD {data["head"][:7]}' + (f' plus the working tree ({n(data["uncommitted"], "uncommitted file")})' if data["worktree"] else "")
    code = "; ".join(f"{k} at {v}" if v else f"{k} not checked out here" for k, v in data["code"].items()) or "none cited"
    behind = (f'<dt>Behind</dt><dd class="alarm">{n(data["behind_base"], "commit")} behind {E(data["base"])}; run git pull</dd>'
              if data["behind_base"] else "")
    link_key = "".join(f'<span class="link {k}">{E(k)}</span>{E(t)}' for k, (_, t) in LINKS.items())
    footer = (f"Served live from {E(socket.gethostname())}; re-surveyed at most every {max(1, round(live / 60))} min on reload."
              if live else "Regenerate after a wake to refresh.")
    open_runs = sum(1 for r in runs if any(l["status"] == "RIPPLE" for l in r["ripples"]))
    unchecked = sum(1 for r in runs if cell(r, "domain")[0] == "unchecked")
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
{f'<meta http-equiv="refresh" content="{live}">' if live else ""}
<title>Chart of {E(data["title"])}</title>
<style>{CSS}{"".join(f".link.{k}{{{c}}}" for k, (c, _) in LINKS.items())}</style></head><body>
<nav aria-label="Sections"><a href="#waters">Waters</a><a href="#ripples">Ripples</a><a href="#questions">Questions</a><a href="#runs">Runs</a><a href="#drawer">Drawer</a></nav>
<main>
<section class="cartouche"><div>
<h1><small>{E(sub)}</small>{E(data["title"])}</h1>
<dl><dt>Datum</dt><dd>{E(data["base"])} at {E(data["base_sha"][:7])}</dd>
<dt>Runs read at</dt><dd>{E(read_at)}</dd>{behind}
<dt>Code</dt><dd>{E(code)}</dd>
<dt>Guard</dt><dd>schema {E(v.get("schema", "1"))}, release {E(v.get("release", "unknown"))}</dd>
<dt>Soundings</dt><dd>{"core-hours, from sacct via ripples" if data["rippled"] else "none: ripples were not run"}</dd>
<dt>Surveyed</dt><dd>{E(data["generated"])}</dd></dl>
<p class="readonly">Read-only. {len(runs)} runs, {f"{open_runs} with a ripple, {unchecked} with no domain check that reached a verdict" if data["rippled"] else "ripples not run, so no check reached a verdict"}. Every action this page suggests is a command or a pull request.</p>
</div></section>

<h2 id="waters">Waters</h2><p class="lede">Where the compute ran, taken from manifests, and what fence stood around it.</p>
<div class="waters">{waters}</div>
{budget_bar(data)}

<h2 id="ripples">Ripples</h2><p class="lede">The project's own guard/run ripples, once per run, from this checkout. Hover a cell for the full line.</p>
<div class="wide"><table class="matrix"><thead><tr><th>Run</th>{heads}</tr></thead><tbody>{"".join(matrix)}</tbody></table></div>
<div class="legend"><span class="st"><span class="pass"></span>pass</span><span class="st"><span class="handled"></span>handled by an incident</span>
<span class="st"><span class="ripple"></span>ripple, stop spending</span><span class="st"><span class="unchecked"></span>unchecked, nothing reached a verdict</span></div>

<h2 id="questions">Questions</h2><p class="lede">Each card placed in the order it was frozen. A supersedes line keeps the row, a spawned line starts a new one. A clean negative is a finished result.</p>
<div class="graphwrap">{atlas_graph(runs)}</div>
<div class="legend"><span class="key k-sup"></span>supported<span class="key k-neg"></span>clean negative<span class="key k-open"></span>open or explore
<span class="key k-dash"></span>superseded or not run<span class="key k-dot"></span>ran without a scheduler record, or no record at all
<span class="key k-ref"></span>report only on another branch<span class="key k-pair"></span>no partner metric</div>

<h2 id="runs">Runs</h2><p class="lede">Shaded time is before the card was committed. Compute there would be a violation. Each evidence row carries its receipts; hover one for why it has its state.</p>
<div class="legend">{link_key}</div>
{"".join(run_block(r) for r in runs)}

<h2 id="drawer">Drawer</h2><p class="lede">Branches ahead of {E(data["base"])} and whether they touch guard files, the workflow, or watched paths. The fence blocks these from merging.</p>
<div class="wide"><table class="drawer"><thead><tr><th>Branch</th><th>Ahead</th><th>Guard or workflow</th><th>Watched paths</th><th>Last commit</th></tr></thead>
<tbody>{drawer or '<tr><td colspan="5">No branches ahead of the protected branch.</td></tr>'}</tbody></table></div>
<footer>Generated by guard atlas from {E(data["top"])}. {footer} The page holds no state and writes nothing back.</footer>
</main></body></html>'''

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
    where.add_argument("--out", default=None, help="HTML path, default atlas-<project>.html in the temp directory, never in the project")
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
    out = a.out or os.path.join(tempfile.gettempdir(), f"atlas-{os.path.basename(top)}.html")
    with open(out, "w") as f:
        f.write(render(data))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(data, f, indent=1, default=str)
    print(f"atlas: {out} ({n(len(data['runs']), 'run')}, {n(len(data['branches']), 'branch')} ahead of {base})")

if __name__ == "__main__":
    main()
