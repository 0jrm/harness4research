"""The atlas page: render(data) turns the --json data into one self-contained HTML string.

A port of the design reference render.js. The stylesheet, the icon sprite and the optional script are the files
atlas.css, atlas-sprite.svg and atlas.js next to this module, inlined at render time. Standard library only.
"""
import datetime as dt, html, math, os, re, socket

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = dt.timezone.utc
MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

def asset(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()

def E(s):
    return html.escape("" if s is None else str(s)).replace("&#x27;", "&#39;")

def unset(v):
    return v is None or v == "" or bool(re.fullmatch(r"<[^>]*>", v))

def parent_key(v):
    """A supersedes or spawned_from value that names a run: set, and not the declared none."""
    return not unset(v) and v != "none"

def when(s):
    if not s:
        return None
    s = re.sub(r"^(\d{4}-\d\d-\d\d) ", r"\1T", str(s).replace(" UTC", "Z"))
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (t if t.tzinfo else t.replace(tzinfo=UTC)).astimezone(UTC)

def fd(d):
    return f"{MON[d.month - 1]} {d.day}" if d else ""

def fdt(d):
    return f"{fd(d)}, {d.hour:02}:{d.minute:02}" if d else ""

def ymd(d):
    return d.date().isoformat() if d else ""

def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03}Z"

def num(x):
    return f"{int(x):,}"

def rnd(x):
    return int(math.floor(x + 0.5))

def n(k, w, pl=None):
    return f"{k} {w if k == 1 else (pl or (w + 'es' if w.endswith('ch') else w + 's'))}"

def up(s):
    """Capitalise a sentence, but not one that starts with a path, a file or a check name."""
    return s if re.match(r"[a-z][\w-]*[./:_]", s) else s[:1].upper() + s[1:]

def parse_int(s):
    m = re.match(r"\s*([+-]?\d+)", str(s or ""))
    return int(m.group(1)) if m else None

def inl(s):
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", re.sub(r"`([^`]+)`", r"<code>\1</code>", E(s)))

def md(s):
    out = []
    for p in (p for p in re.split(r"\n\s*\n", str(s or "")) if p.strip()):
        lines = p.strip().split("\n")
        if all(l.strip().startswith("|") for l in lines):
            rows = [[c.strip() for c in re.sub(r"^\||\|$", "", l.strip()).split("|")]
                    for l in lines if not re.match(r"^\|\s*:?-", l.strip())]
            head = "".join(f"<th>{inl(c)}</th>" for c in rows[0])
            body = "".join("<tr>" + "".join(f"<td>{inl(c)}</td>" for c in r) + "</tr>" for r in rows[1:])
            out.append(f'<div class="wide"><table class="mdt"><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>')
        else:
            out.append(f"<p>{inl(p.strip())}</p>")
    return "".join(out)

BICON = {"pass": "pass", "handled": "handled", "ripple": "ripple", "unchecked": "unchecked", "none": "none", "ok": "pass",
         "local": "local", "unknown": "unchecked", "broken": "broken", "rule": "rule"}

def icon(k, label=None):
    attrs = f'role="img" aria-label="{E(label)}"' if label else 'aria-hidden="true"'
    return f'<svg class="i" {attrs}><use href="#i-{k}"/></svg>'

def badge(st, word, extra=""):
    return f'<span class="b b-{st}{extra}">{icon(BICON.get(st, st))}{E(word)}</span>'

def wrap(head, body, tail):
    return head + body + tail if body else ""

def cmd(c):
    return f'<code class="cmd">{E(c)}</code>'

def idlink(i):
    return f'<a class="id" href="#run-{E(i)}">{E(i)}</a>'

# ---------------------------------------------------------------- checks

COLS = [("guard-untouched", "guard", "Guard files untouched"), ("question-card-frozen", "card", "Card frozen"),
        ("watched-paths", "watched", "Watched paths untouched"), ("job-states", "jobs", "Job states"),
        ("walltime-headroom", "walltime", "Walltime headroom"), ("retries", "retries", "Retries"),
        ("handled-failures", "failures", "Handled failures under the cap"), ("budget", "budget", "Budget under 80%"),
        ("quota", "quota", "Disk quota under 80%")]
KNOWN = {k for k, _, _ in COLS} | {"domain-checks"}
STW = {"pass": "pass", "ripple": "ripple", "handled": "handled", "unchecked": "unchecked", "none": "not reported"}
WORDS = {"job-states": {"ripple": "failed, no incident", "handled": "failed, handled"}, "handled-failures": {"ripple": "over the cap"},
         "question-card-frozen": {"ripple": "card edited"}, "guard-untouched": {"ripple": "guard touched"},
         "watched-paths": {"ripple": "watched path touched"}, "walltime-headroom": {"ripple": "near walltime"},
         "retries": {"ripple": "retried, no incident"}, "budget": {"ripple": "over 80% of cap"}, "quota": {"ripple": "disk over 80%"}}
RANK = {"RIPPLE": 3, "HANDLED": 2, "UNCHECKED": 1, "PASS": 0}
STATE = {"PASS": "pass", "RIPPLE": "ripple", "HANDLED": "handled", "UNCHECKED": "unchecked"}

def entries(d):
    """The job:STATE entries of a job-states line, without the next step ripples puts after them in parentheses."""
    return (d or "").split(" (", 1)[0].split()

def pretty(key, d, status):
    if not d:
        return ""
    if key == "job-states" and status in ("RIPPLE", "HANDLED"):  # an UNCHECKED line says why in prose, not job entries
        out = []
        for x in entries(d):
            i = x.find(":")
            st, *inc = x[i + 1:].split("->")
            out.append(f"job {x[:i]} {st}" + (f", written up in {inc[0]}" if inc else ""))
        return "; ".join(out)
    m = re.fullmatch(r"(\S+):(\d+%)(?: \((.*)\))?", d) if key == "walltime-headroom" else None
    if m:
        return f"job {m.group(1)} used {m.group(2)} of its walltime" + (f"; {m.group(3)}" if m.group(3) else "")
    return d.replace("max_handled_failures=", "max_handled_failures = ", 1)

def worst(hits):
    top = hits[0]
    for h in hits[1:]:
        if RANK.get(h["status"], 0) > RANK.get(top["status"], 0):
            top = h
    return STATE.get(top["status"], "unchecked"), top

def cell(r, key):
    hits = [l for l in r["ripples"] if l["check"] == key]
    if not hits:
        return {"st": "none", "word": "not reported", "detail": "not reported by this guard version"}
    st, _ = worst(hits)
    return {"st": st, "word": WORDS.get(key, {}).get(st) or STW[st],
            "detail": "; ".join(x for x in (pretty(key, h["detail"], h["status"]) for h in hits if h["status"] != "PASS" or h["detail"]) if x)}

def domain_cell(r):
    checks = [l for l in r["ripples"] if l["check"].startswith("check:")]
    if not checks:
        return {"st": "unchecked", "word": "no domain check", "detail": "", "none": True}
    bad = [l for l in checks if l["status"] == "RIPPLE"]
    return {"st": "ripple" if bad else "pass", "word": f"{len(bad)} of {len(checks)} failed" if bad else f"{len(checks)} of {len(checks)} pass",
            "detail": "; ".join(f"{l['check'][6:]}: {l['detail']}" for l in checks)}

def others(r):
    return [l for l in r["ripples"] if l["check"] not in KNOWN and not l["check"].startswith("check:")]

def other_cell(r):
    """Checks with no column of their own, such as execution-within-envelope or the launch-host checks."""
    hits = others(r)
    if not hits:
        return {"st": "none", "word": "none reported", "detail": "", "none": True}
    st, top = worst(hits)
    return {"st": st, "word": top["check"] if st != "pass" else "pass",
            "detail": "; ".join(f"{h['check']}: {h['detail']}" for h in hits if h["status"] != "PASS")}

# ---------------------------------------------------------------- the page

OUT = {"supported": "supported", "negative": "clean negative", "open": "open", "reported": "reported", "escalated": "escalated",
       "superseded": "superseded", "explore": "explore"}
NO_RECORD = {"not run", "no scheduler record", "recorded by hand"}
SAY_WHY = {"report unmerged", "report not pulled", "recorded by hand", "no scheduler record", "not run"}
GROUPS = [("stop", "Stop: a ripple fired"), ("rule", "A rule was broken"), ("look", "Worth a look"),
          ("await", "Awaiting a report"), ("quiet", "Nothing flagged")]
GI = {g: i for i, (g, _) in enumerate(GROUPS)}
SEVI = {"stop": "ripple", "rule": "rule", "branch": "branch", "await": "await", "file": "file"}
STATEW = {"ok": "holds", "local": "local", "unknown": "unknown", "broken": "broken"}

def render(data):
    runs, b, v = data["runs"], data["budget"], data["version"]
    explore = lambda r: r["outcome"] == "explore"
    out_word = lambda r: OUT.get(r["outcome"], r["outcome"])
    out_cls = lambda r: (r["outcome"] or "").replace(" ", "-")
    any_domain = any(l["check"].startswith("check:") for r in runs for l in r["ripples"])
    any_other = any(others(r) for r in runs)
    cols = COLS + ([("domain", "domain", "Domain checks")] if any_domain else []) + ([("other", "other", "Other checks")] if any_other else [])
    short = {k: s for k, s, _ in cols}
    n_checks = len(COLS)
    all_links = lambda r: [l for e in (r["report"]["evidence"] if r["report"] else []) for l in e.get("links", [])]

    F = {}
    for r in runs:
        cells = [(k, domain_cell(r) if k == "domain" else other_cell(r) if k == "other" else cell(r, k)) for k, _, _ in cols]
        ts = [t for t in [*(when(h["time"]) for h in r["card_history"]), *(when(m.get("time")) for m in r["manifests"]),
                          *(when(i["time"]) for i in r["incidents"]), r["report"] and when(r["report"]["time"])] if t]
        f = {"cells": cells, "ripples": [(k, c) for k, c in cells if c["st"] == "ripple"],
             "handled": [(k, c) for k, c in cells if c["st"] == "handled"],
             "broken": [l for l in all_links(r) if l["state"] == "broken"], "last": max(ts) if ts else None}
        f["group"] = ("stop" if f["ripples"] else "rule" if r["violations"] else "look" if f["handled"] or f["broken"]
                      else "await" if not explore(r) and not r["report"] else "quiet")
        F[r["id"]] = f
    srt = sorted(runs, key=lambda r: (GI[F[r["id"]]["group"]], -(F[r["id"]]["last"].timestamp() if F[r["id"]]["last"] else 0), r["id"]))
    ripple_runs = [r for r in runs if F[r["id"]]["ripples"]]
    rule_runs = [r for r in runs if r["violations"]]
    await_runs = [r for r in runs if not explore(r) and not r["report"]]
    alarm = [x for x in data["branches"] if x["drawer"] or x["watched"]]
    generated = when(data.get("generated_at") or data["generated"])

    # ---- budget
    spent = quota = None
    for r in runs:
        for l in r["ripples"]:
            m = re.search(r"(\d+) of (\d+) core-h", l["detail"]) if l["check"] == "budget" else None
            if m:
                spent = int(m.group(1))
            if l["check"] == "quota" and re.fullmatch(r"\d+%", l["detail"]):
                quota = l["detail"]
    cap, res = parse_int(b.get("max_core_hours")), parse_int(b.get("verification_reserve_core_hours") or "0") or 0

    def budget_bar():
        if cap is None:
            return '<p class="note">The core-hour cap (<code>max_core_hours</code>) is not set on the protected branch.</p>'
        pct = lambda x: f"{max(0, min(100, 100 * x / cap)) if cap else 0:.2f}%"
        line = rnd(cap * 0.8)
        label = (f"Spend unknown on this host. Cap {cap} core-hours, {res} held for verification, ripples fire at {line}." if spent is None else
                 f"{spent} of {cap} core-hours spent; {cap - res - spent} left for agent work; {res} held for verification; ripples fire at {line}.")
        ticks = "".join(f'<span style="left:{p}%">{num(rnd(cap * p / 100))}</span>' for p in (0, 25, 50, 75, 100))
        track = ('<span class="bar-unknown">spend unknown: no scheduler accounting on this host</span>' if spent is None
                 else f'<span class="bar-spent" style="width:{pct(spent)}"></span>')
        unknown = lambda x: "unknown" if spent is None else num(x)
        return f'''<figure class="bar" role="img" aria-label="{E(label)}">
<div class="bar-track">{track}<span class="bar-reserve" style="left:{pct(cap - res)};width:{pct(res)}"><em>verification reserve</em></span><span class="bar-line" style="left:80%"><em>ripples fire at {num(line)}</em></span></div>
<div class="bar-axis" aria-hidden="true">{ticks}</div><figcaption class="bar-unit">core-hours</figcaption></figure>
<dl class="bar-key"><div><dt>Spent</dt><dd>{unknown(spent or 0)}</dd></div><div><dt>Left for agent work</dt><dd>{unknown(cap - res - (spent or 0))}</dd></div><div><dt>Held for verification</dt><dd>{num(res)}</dd></div><div><dt>Cap</dt><dd>{num(cap)}</dd></div></dl>'''

    # ---- hosts, from the data's waters
    def hosts_of():
        out = []
        for w in data["waters"]:
            kind = {"bank": "fenced", "bump": "gated", "none": "open"}[w["fence"]]
            desc = {"fenced": f"Account {b.get('account') or '?'}: preflight checks and a capped sub-account.",
                    "gated": "Listed in launch_hosts: launch gates and a GPU-hour count, no scheduler.",
                    "open": "Not in launch_hosts: compute here passed no gate."}[kind]
            if w["hand"]:
                desc += (f" {', '.join(w['hand'])} {'is' if len(w['hand']) == 1 else 'are'} placed here only by execution.tsv rows:"
                         " recorded by hand, not by a scheduler, and not counted in the budget.")
            out.append({"name": w["name"], "kind": kind, "desc": desc, "runs": [] if kind == "fenced" else w["runs"],
                        "word": {"fenced": "Fenced", "gated": "Launch gate only", "open": "No fence"}[kind],
                        "count": w["count"] if kind == "fenced" else n(len(w["runs"]), "run")})
        return out
    unseen = [r for r in runs if not explore(r) and not r["manifests"] and r["report"]]

    # ---- status strip
    sub = " · ".join(x for x in [f"project <code>{E(data['project'])}</code>" if data["title"] != data["project"] else "",
                                 "runs " + ", ".join(f"<code>{E(g)}</code>" for g in data["globs"]) if data["globs"] else ""] if x)
    quiet_pass = sum(all(c["st"] == "pass" or c.get("none") for _, c in F[r["id"]]["cells"]) for r in runs)
    if not data["rippled"]:
        v_class, v_line = "unknown", "Safety checks were not run for this render, so this page cannot say whether anything is wrong."
        v_sub = "Ripples need the cluster’s scheduler records. Render the atlas on the cluster to get them."
    elif ripple_runs:
        v_class = "stop"
        v_line = f"Stop spending on {n(len(ripple_runs), 'run')}: {'it has' if len(ripple_runs) == 1 else 'each has'} a ripple."
        v_sub = (f"A <strong>ripple</strong> is a guard safety check that says stop spending compute on a run until a person has looked. "
                 f"{n(quiet_pass, 'run')} of {len(runs)} passed every check that ran.")
    elif rule_runs:
        v_class, v_line = "rule", f"No ripple, but {n(len(rule_runs), 'run')} broke a rule."
        v_sub = "A <strong>ripple</strong> is a guard safety check that says stop spending. None fired. The rule breaks are listed below."
    else:
        v_class, v_line = "quiet", "No ripple and no broken rule."
        v_sub = "A <strong>ripple</strong> is a guard safety check that says stop spending. None fired."
    if data["rippled"] and not any_domain:
        v_sub += " No run has a domain check, so nothing here tests the science itself."

    todo = []
    for r in ripple_runs:
        for k, c in F[r["id"]]["ripples"]:
            if k == "job-states":
                line = next((l["detail"] for l in r["ripples"] if l["check"] == k and l["status"] == "RIPPLE"), "")
                acts = []
                for j in (x.split(":")[0] for x in entries(line)):
                    m = next((m for m in r["manifests"] if m.get("job_id") == j), None)
                    path = f"runs/{r['id']}/incidents/{ymd(when(m.get('time'))) if m else 'YYYY-MM-DD'}-{j}.md"
                    stray = r.get("stray_incidents") or []
                    if stray:
                        acts.append(f"A write-up exists at <code>{E(stray[0])}</code>, but the guard does not count it there. "
                                    f"Move it: {cmd('git mv ' + stray[0] + ' ' + path)}, then re-check: {cmd('bash guard/run ripples runs/' + r['id'])}")
                    else:
                        acts.append(f"Write up job {E(j)} at {cmd(path)}, the only place the guard counts incidents. "
                                    f"Then re-check: {cmd('bash guard/run ripples runs/' + r['id'])}")
                act = "<br>".join(acts)
            elif k == "handled-failures":
                act = ("Decide whether this run should stop. To allow more failures, change <code>max_handled_failures</code> in "
                       "<code>guard/budget.card</code> by pull request.")
            else:
                act = f"Read the run, then re-check: {cmd('bash guard/run ripples runs/' + r['id'])}"
            todo.append(("stop", f'{idlink(r["id"])} {badge("ripple", short[k] + ": " + c["word"])}<p>{E(up(c["detail"]) + "." if c["detail"] else "")} {act}</p>'))
    for r in rule_runs:
        items = "".join(f"<li>{E(up(x))}.</li>" for x in r["violations"])
        todo.append(("rule", f'{idlink(r["id"])} {badge("rule", n(len(r["violations"]), "rule break"))}<ul>{items}</ul>'))
    for br in alarm:
        parts = " and ".join(x for x in [n(len(br["drawer"]), "guard or workflow file") if br["drawer"] else "",
                                         n(len(br["watched"]), "watched path") if br["watched"] else ""] if x)
        todo.append(("branch", f'<code class="id">{E(br["name"])}</code> {badge("handled", "touches the guard" if br["drawer"] else "touches a watched path")}'
                               f'<p>Changes {parts}. The fence blocks it from merging; review it as a pull request: {cmd("git diff --stat " + data["base"] + "..." + br["name"])}</p>'))
    for r in runs:
        if r["outcome"] == "report unmerged":
            ref = r["report_refs"][0]
            todo.append(("branch", f'{idlink(r["id"])} {badge("handled", "report unmerged")}<p>Its report is only on <code>{E(ref)}</code>. '
                                   f'Review and merge it to give the card a verdict: {cmd("git diff --stat " + data["base"] + "..." + ref + " -- runs/" + r["id"])}</p>'))
    if await_runs:
        todo.append(("await", f'<span class="id">{n(len(await_runs), "question card")} with no report</span><p>A card without a report has no verdict yet.</p>'
                              f'<p class="idlist">{"".join(idlink(r["id"]) for r in await_runs)}</p>'))
    if data["worktree"] and data["uncommitted"]:
        todo.append(("file", f'<span class="id">{n(data["uncommitted"], "uncommitted file")} in the working tree</span><p>Receipts that point at them grade '
                             f'<em>local</em>, not <em>ok</em>, until they are committed. {cmd("git status --short runs/")}</p>'))
    todo_html = wrap('<ol class="todo">', "".join(f'<li class="todo-{s}">{icon(SEVI[s])}<div>{h}</div></li>' for s, h in todo), "</ol>") \
        or '<p class="note">Nothing is waiting on you.</p>'

    def count(href, k, label, sev):
        return f'<a class="count{" count-" + sev if k else ""}" href="{href}"><b>{k}</b><span>{label}</span></a>'
    read_at = f'HEAD <code>{E(data["head"][:7])}</code>' + (f' plus the working tree ({n(data["uncommitted"], "uncommitted file")})' if data["worktree"] else "")
    behind = (f'<p class="snap-behind">{icon("rule")} This checkout is {n(data["behind_base"], "commit")} behind <code>{E(data["base"])}</code>, '
              f'so cards and reports merged there may be missing here. Run {cmd("git pull")}, then render again.</p>' if data.get("behind_base") else "")
    code = "; ".join(f"<code>{E(k)}</code> at <code>{E(p)}</code>" if p else f"<code>{E(k)}</code> not checked out here"
                     for k, p in data["code"].items()) or "none cited"
    release = (f'release {E(v["release"])}' if v.get("release")
               else f'installed before release stamps; run <code>guard init {E(data["top"])} --update</code>')
    status = f'''<header class="status" id="status">
<p class="eyebrow">Guard atlas{" · " + sub if sub else ""}</p>
<h1>{E(data["title"])}</h1>
<p class="snap">Snapshot taken <time datetime="{iso(generated) if generated else ""}" data-age>{E(data["generated"])}</time>. The page does not update itself.</p>{behind}
<div class="verdict verdict-{v_class}" role="status">{icon({"stop": "ripple", "rule": "rule", "unknown": "unchecked"}.get(v_class, "quiet"))}<div><p class="verdict-line">{E(v_line)}</p><p>{v_sub}</p></div></div>
<nav class="counts" aria-label="Counts">
{count("#checks", len(ripple_runs) if data["rippled"] else "?", "runs with a ripple" if data["rippled"] else "ripples: not run", "stop")}
{count("#runs-rule", len(rule_runs), "run broke a rule" if len(rule_runs) == 1 else "runs broke a rule", "rule")}
{count("#runs-await", len(await_runs), "cards with no report", "await")}
{count("#branches", len(alarm), "branch touches guarded files" if len(alarm) == 1 else "branches touch guarded files", "branch")}
{count("#about", data["uncommitted"], "uncommitted files", "file") if data["worktree"] else ""}
</nav>
<div class="status-budget"><h2 class="h-small">Budget, {E(b.get("start_date") or "?")} to {E(b.get("stop_date") or "?")}</h2>{budget_bar()}</div>
<section class="needs" aria-labelledby="needs-h"><h2 id="needs-h">Needs you</h2>{todo_html}</section>
<details class="about" id="about"><summary>About this render</summary>
<dl class="kv">
<div><dt>Protected branch</dt><dd><code>{E(data["base"])}</code> at <code>{E(data["base_sha"][:7])}</code></dd></div>
<div><dt>Runs read at</dt><dd>{read_at}</dd></div>
<div><dt>Code repositories</dt><dd>{code}</dd></div>
<div><dt>Guard version</dt><dd>schema {E(v.get("schema") or "1")}, {release}{", installed " + E(v["installed"]) if v.get("installed") else ""}</dd></div>
<div><dt>Spend source</dt><dd>{"none: ripples were not run" if not data["rippled"] else "none: the budget ripple could not read sacct on this host" if spent is None else "core-hours from sacct, through the budget ripple"}</dd></div>
<div><dt>Checkout</dt><dd><code>{E(data["top"])}</code></dd></div>
</dl>
<p class="note">Read-only. The page holds no state and writes nothing back; every action it suggests is a command to copy or a pull request. Earlier versions used a nautical vocabulary (Waters, Soundings, Datum, Drawer, Lifeline); <em>ripple</em> is kept because the guard prints it.</p>
</details>
</header>'''

    # ---- compute
    hs = hosts_of()
    host_html = "".join(
        f'<article class="host host-{h["kind"]}"><header><h3>{E(h["name"])}</h3><span class="fence fence-{h["kind"]}">'
        f'{icon({"fenced": "pass", "gated": "handled"}.get(h["kind"], "rule"))}{E(h["word"])}</span><span class="host-count">{E(h["count"])}</span></header>'
        f'<p>{E(h["desc"])}</p>' + wrap('<p class="host-runs idlist">', "".join(idlink(i) for i in h["runs"]), "</p>") + "</article>"
        for h in hs) or '<p class="note">No manifests yet, so there is no compute to place.</p>'
    unseen_html = (f'<article class="host host-unseen"><header><h3>Somewhere the guard cannot see</h3><span class="fence fence-unseen">{icon("unchecked")}No scheduler record</span>'
                   f'<span class="host-count">{n(len(unseen), "run")}</span></header><p>These runs have a report but no manifest, so their compute left no record the guard can check or count against the budget.</p>'
                   f'<p class="host-runs idlist">{"".join(idlink(r["id"]) for r in unseen)}</p></article>') if unseen else ""
    per_job = ", ".join(x for x in [b.get("max_nodes_per_job") and f"{b['max_nodes_per_job']} nodes",
                                    b.get("max_walltime_minutes") and f"{b['max_walltime_minutes']} min walltime"] if x)
    explore_cap = ", ".join(x for x in [b.get("explore_max_nodes") and n(parse_int(b["explore_max_nodes"]), "node"),
                                        b.get("explore_max_walltime_minutes") and f"{b['explore_max_walltime_minutes']} min"] if x)
    limits = [(k, x) for k, x in [("Account", b.get("account")), ("Per job", per_job), ("Concurrent jobs", b.get("max_concurrent_jobs")),
                                  ("Explore runs", explore_cap), ("Handled failures per run", b.get("max_handled_failures")),
                                  ("Disk quota used", quota)] if x and not unset(x)]
    compute = f'''<section id="compute" aria-labelledby="compute-h"><h2 id="compute-h">Compute and budget</h2>
<p class="lede">Where compute ran, read from job manifests, and what fence stood around it.</p>
<div class="hosts">{host_html}{unseen_html}</div>
<dl class="kv kv-limits">{"".join(f"<div><dt>{E(k)}</dt><dd>{E(x)}</dd></div>" for k, x in limits)}</dl>
</section>'''

    # ---- safety checks
    if not data["rippled"]:
        checks = f'''<section id="checks" aria-labelledby="checks-h"><h2 id="checks-h">Safety checks</h2>
<div class="empty">{icon("unchecked")}<p><strong>Ripples were not run for this render.</strong> No check on this page reached a verdict. Render on the cluster, where <code>sacct</code> is available, to fill this in.</p></div></section>'''
    else:
        failing = lambda r: [(k, c) for k, c in F[r["id"]]["cells"] if c["st"] != "pass" and not c.get("none")]
        flagged = [r for r in srt if failing(r)]
        clean = [r for r in runs if r not in flagged]
        head = "".join(f'<th scope="col" class="c"><abbr title="{E(long)}">{E(s)}</abbr></th>' for _, s, long in cols)
        rows = "".join(
            f'<tr><th scope="row">{idlink(r["id"])}</th>'
            + "".join(f'<td class="c c-{c["st"]}">{icon(BICON[c["st"]], k + ": " + c["word"])}</td>' for k, c in F[r["id"]]["cells"])
            + '<td class="what"><ul>' + "".join("<li>" + badge(c["st"], short[k] + ": " + c["word"]) + wrap(' <span class="detail">', E(c["detail"]), "</span>") + "</li>"
                                                for k, c in failing(r)) + "</ul></td></tr>"
            for r in flagged)
        notice = ('<p class="notice">' + icon("unchecked") + '<span><strong>No run has a domain check.</strong> Domain checks are human-owned scripts in '
                  '<code>runs/&lt;id&gt;/checks/</code> that test the science. Without them, the checks below cover process only: budget, jobs, and frozen cards.</span></p>'
                  if not any_domain else "")
        table = (f'<div class="wide"><table class="checks"><thead><tr><th scope="col">Run</th>{head}<th scope="col" class="what">Not passing</th></tr></thead><tbody>{rows}</tbody></table></div>'
                 if flagged else f'<p class="note">Every run passed all {n_checks} checks.</p>')
        fold = (f'<details class="fold"><summary>{n(len(clean), "more run")} passed all {n_checks} checks</summary><p class="idlist">{"".join(idlink(r["id"]) for r in clean)}</p></details>'
                if clean and flagged else "")
        checks = f'''<section id="checks" aria-labelledby="checks-h"><h2 id="checks-h">Safety checks</h2>
<p class="lede">The project’s own <code>guard/run ripples</code>, once per run, from this checkout. Runs with something other than a pass come first.</p>
{notice}
<p class="legend" aria-hidden="true">{badge("pass", "pass")}{badge("handled", "handled by an incident")}{badge("ripple", "ripple: stop spending")}{badge("unchecked", "unchecked")}{badge("none", "not reported")}</p>
{table}
{fold}
</section>'''

    # ---- questions
    far = dt.datetime.max.replace(tzinfo=UTC)
    qs = sorted((r for r in runs if not explore(r)),
                key=lambda r: ((when(r["card_history"][0]["time"]) or far) if r["card_history"] else far, r["id"]))
    ids = {r["id"] for r in qs}
    inferred = {e["to"]: e["from"] for e in data["lineage"] if e["lineage_inferred"] and e["from"] in ids}

    def parent_of(r):
        hit = next(((k, r["card"][k]) for k in ("supersedes", "spawned_from") if parent_key(r["card"].get(k)) and r["card"][k] in ids), None)
        return hit or (("inferred", inferred[r["id"]]) if r["id"] in inferred else None)
    edges = sum(1 for r in qs if parent_of(r) and parent_of(r)[0] != "inferred")
    guessed = sum(1 for r in qs if parent_of(r) and parent_of(r)[0] == "inferred")

    def rel_html(rel):
        if rel[0] == "inferred":
            return f'<span class="rel rel-inferred">follows {idlink(rel[1])}, inferred from name</span>'
        return f'<span class="rel">{E(rel[0].replace("_", " "))} {idlink(rel[1])}</span>'

    def q_row(r, rel):
        fz = when(r["card_history"][0]["time"]) if r["card_history"] else None
        flags = ((badge("unchecked", "no scheduler record") if not r["manifests"] and r["outcome"] not in NO_RECORD else "")
                 + (badge("rule", "no partner metric") if unset(r["card"].get("partner_metric")) else ""))
        date = f'<time datetime="{iso(fz)}">{fd(fz)}</time>' if fz else '<span class="q-nocard">card not committed</span>'
        text = f'<p class="q-text">{E(r["card"]["question"])}</p>' if r["card"].get("question") else '<p class="q-text q-missing">No question recorded.</p>'
        return (f'<div class="q"><span class="q-date">{date}</span>\n<div class="q-body"><p class="q-head">{idlink(r["id"])} '
                f'<span class="o o-{out_cls(r)}">{E(out_word(r))}</span>{flags}{rel_html(rel) if rel else ""}</p>\n{text}</div></div>')

    def q_item(r):
        kids = [x for x in qs if (parent_of(x) or ("", ""))[1] == r["id"]]
        named = [x for x in kids if parent_of(x)[0] != "inferred"]
        guess = [x for x in kids if parent_of(x)[0] == "inferred"]
        return (f"<li>{q_row(r, parent_of(r))}"
                + (f'<ol class="lineage">{"".join(q_item(x) for x in named)}</ol>' if named else "")
                + (f'<ol class="lineage lineage-inferred">{"".join(q_item(x) for x in guess)}</ol>' if guess else "") + "</li>")
    plain = "" if edges else (" No card names either here, so every nesting below is inferred from the ids, drawn dotted and marked so." if guessed
                              else " No card names either here, so this is a plain list.")
    questions = f'''<section id="questions" aria-labelledby="questions-h"><h2 id="questions-h">Questions</h2>
<p class="lede">Every question card in the order it was frozen. A card that names <code>supersedes</code> or <code>spawned_from</code> sits under the card it came from.{plain} Explore runs need no card and are left out.</p>
<p class="legend" aria-hidden="true"><span class="o o-supported">supported</span><span class="o o-negative">clean negative</span><span class="o o-open">open</span><span class="o o-superseded">superseded</span><span class="o o-no-scheduler-record">no scheduler record</span><span class="o o-recorded-by-hand">recorded by hand</span><span class="o o-report-unmerged">report unmerged</span></p>
<p class="note small"><strong>No scheduler record</strong> means the guard found no job manifest for the card. The run may still have happened on a host without a scheduler; the guard cannot tell. It does not mean “not run”. A dotted rule nests a card under the id it looks like it grew out of, when neither card names the other.</p>
{f'<ol class="lineage lineage-root">{"".join(q_item(r) for r in qs if not parent_of(r))}</ol>' if qs else '<p class="note">No question cards yet.</p>'}
</section>'''

    # ---- runs
    def timeline(r):
        hist = r["card_history"]
        frozen = when(hist[0]["time"]) if hist else None
        failed = set()
        for l in r["ripples"]:
            if l["check"] == "job-states" and l["status"] in ("RIPPLE", "HANDLED"):
                failed |= {x.split(":")[0] for x in entries(l["detail"])}
        ev = [("card", frozen, "freeze", f"card frozen ({hist[0]['sha'][:7]})")] if frozen else []
        ev += [("card", when(h["time"]), "edit", f"card edited: {h['subject']}") for h in hist[1:]]
        ev += [("jobs", when(m.get("time")), "jobfail" if m.get("job_id") in failed else "job",
                f"job {m.get('job_id')} on {m.get('host')}{', failed' if m.get('job_id') in failed else ''}") for m in r["manifests"]]
        ev += [("jobs", when(x["ts"]), "hand", f"execution.tsv {x['id']}: {x['field']} {x['value']}, recorded by hand")
               for x in (r.get("execution") or {}).get("rows", [])]
        ev += [("incidents", when(i["time"]), "incbad" if unset(i["root_cause"]) else "inc",
                f"incident {i['path'].split('/')[-1]}{' for job ' + i['job'] if i['job'] else ''}") for i in r["incidents"]]
        if r["report"]:
            ev.append(("report", when(r["report"]["time"]), "report", "report.md"))
        tev = [e for e in ev if e[1]]
        if not tev:
            return ""
        t0, t1 = min(e[1] for e in tev).timestamp(), max(e[1] for e in tev).timestamp()
        span = max(t1 - t0, 3600)
        t1 = max(t1, t0 + span); t0 -= span * .05; t1 += span * .05
        x = lambda t: f"{100 * (t.timestamp() - t0) / (t1 - t0):.2f}"
        lanes = [l for l in ("card", "jobs", "incidents", "report") if any(e[0] == l for e in tev)]
        fx = float(x(frozen)) if frozen else None
        fxs = x(frozen) if frozen else ""
        marks = lambda lane: "".join(f'<span class="m m-{k}" style="left:{x(t)}%"></span>' for l, t, k, _ in tev if l == lane and k != "freeze")
        before = frozen and any(l == "jobs" and t < frozen for l, t, _, _ in tev)
        band = (f'<span class="tl-before{" tl-before-hit" if before else ""}" style="width:{fxs}%"></span><span class="tl-freeze" style="left:{fxs}%"><em>'
                f'{"← before: compute here breaks the rule · " if fx > 55 else ""}card frozen {fdt(frozen)}{" · after: compute allowed →" if fx <= 55 else ""}</em></span>') if frozen else ""
        cardbar = f'<span class="tl-cardbar" style="left:{fxs}%"></span>' if frozen else ""
        rows = "".join(f'<div class="tl-lane">{cardbar if l == "card" else ""}{marks(l)}</div>' for l in lanes)
        ax = fdt if t1 - t0 < 2 * 86400 else fd
        at = lambda s: dt.datetime.fromtimestamp(s, UTC)
        has = lambda k: any(e[2] == k for e in tev)
        key = (('<span><i class="k k-before"></i>before the card was frozen</span>' if frozen else "<span>Explore run: no card to freeze.</span>")
               + ('<span><i class="k m-job"></i>job</span>' if has("job") else "") + ('<span><i class="k m-jobfail"></i>job failed</span>' if has("jobfail") else "")
               + ('<span><i class="k m-hand"></i>execution.tsv row, recorded by hand</span>' if has("hand") else "")
               + ('<span><i class="k m-inc"></i>incident</span>' if has("inc") else "") + ('<span><i class="k m-incbad"></i>incident, no root cause</span>' if has("incbad") else "")
               + ('<span><i class="k m-edit"></i>card edited</span>' if has("edit") else "") + ('<span><i class="k m-report"></i>report</span>' if has("report") else ""))
        evs = "".join(f'<li><time datetime="{iso(t)}">{fdt(t)}</time><span class="lane">{l}</span><span>{E(label)}</span></li>'
                      for l, t, _, label in sorted(tev, key=lambda e: e[1]))
        return (f'<figure class="tl"><div class="tl-grid" aria-hidden="true"><div class="tl-labels">{"".join(f"<span>{l}</span>" for l in lanes)}</div>\n'
                f'<div class="tl-plot" style="--rows:{len(lanes)}">{band}\n{rows}</div>\n'
                f'<div></div><div class="tl-axis"><span>{ax(at(t0))}</span><span>{ax(at(t1))}</span></div></div>\n'
                f'<figcaption class="tl-key">{key}</figcaption></figure>\n'
                f'<details class="fold events"><summary>{n(len(tev), "event")} in order</summary><ol class="evlist">{evs}</ol></details>')

    def receipts(r):
        if not r["report"] or not r["report"]["evidence"]:
            return ""
        card_links = [l for l in all_links(r) if l["kind"] == "card"]
        first = card_links[0] if card_links else None
        hoist = first if card_links and all((l["state"], l["note"], l["value"]) == (first["state"], first["note"], first["value"]) for l in card_links) else None
        order = {"broken": 0, "unknown": 1, "local": 2, "ok": 3}
        rows = []
        for e in r["report"]["evidence"]:
            ls = [l for l in e.get("links", []) if not (hoist and l["kind"] == "card")]
            ok, br = sum(l["state"] == "ok" for l in ls), sum(l["state"] == "broken" for l in ls)
            strip = "".join(f'<span class="rc-{l["state"]}">{icon(BICON[l["state"]])}</span>' for l in sorted(ls, key=lambda l: order[l["state"]]))
            items = "".join(f'<li class="rc-{l["state"]}">{badge(l["state"], STATEW[l["state"]])}<span class="rc-kind">{E(l["kind"])}</span> <code>{E(l["value"])}</code><span class="rc-note">{E(l["note"])}</span></li>' for l in ls)
            rows.append(f'<tr class="{"row-broken" if br else ""}"><td class="claim">{inl(e["claim"])}</td><td class="num">{inl(e["value"])}</td><td class="rcpt"><details class="rc"><summary>'
                        f'<span class="rc-strip" aria-hidden="true">{strip}</span><span>{ok} of {len(ls)} hold{f", <strong>{br} broken</strong>" if br else ""}</span></summary>\n<ul>{items}</ul></details></td></tr>')
        hoisted = (f'<p class="note small">{icon("unchecked")} Card hash on every receipt: <em>{E(hoist["value"])}</em>, {E(hoist["state"])}. {E(up(hoist["note"]))}.</p>' if hoist else "")
        return (f'<h4>Evidence</h4>\n<p class="legend legend-rc" aria-hidden="true">{badge("ok", "holds: committed, or resolves")}{badge("local", "local: on disk here, not committed")}'
                f'{badge("unknown", "unknown: cannot be checked from here")}{badge("broken", "broken: points at nothing")}</p>\n{hoisted}\n'
                f'<table class="ev"><thead><tr><th scope="col" class="h-claim">Claim</th><th scope="col" class="h-value">Value</th><th scope="col">Receipts</th></tr></thead><tbody>{"".join(rows)}</tbody></table>')

    def run_detail(r):
        c, rep, f = r["card"], r["report"], F[r["id"]]
        rest = [(k, l) for k, l in [("decision_this_informs", "Decision it informs"), ("setting", "Setting"), ("baseline", "Baseline"),
                                    ("baseline_tolerance", "Baseline tolerance"), ("negative_result_means", "A negative result means"),
                                    ("out_of_scope", "Out of scope")] if not unset(c.get(k))]
        rels = [(k, c[k]) for k in ("supersedes", "spawned_from") if parent_key(c.get(k))]
        if not rels and r["id"] in inferred:
            rels = [("inferred", inferred[r["id"]])]
        rel = "".join(rel_html(x) for x in rels)
        probs = ("".join(f'<li>{badge("ripple", short[k] + ": " + x["word"])} {E(x["detail"])}</li>' for k, x in f["ripples"])
                 + "".join(f'<li>{badge("rule", "rule")} {E(up(x))}.</li>' for x in r["violations"])
                 + "".join(f'<li>{badge("handled", short[k] + ": " + x["word"])} {E(x["detail"])}</li>' for k, x in f["handled"]))
        why = f'<p class="note">{E(up(r["outcome_detail"]))}.</p>' if r["outcome"] in SAY_WHY and r.get("outcome_detail") else ""
        if explore(r):
            cap_note = (f', capped at {n(parse_int(b["explore_max_nodes"]), "node")} and {E(b.get("explore_max_walltime_minutes"))} min per job'
                        if b.get("explore_max_nodes") else "")
            card_block = f'<p class="note">Explore run: exempt from question cards{cap_note}.</p>'
        else:
            verdict = ""
            if rep:
                said = f"Report: hypothesis {E(rep['hypothesis'])}. " if re.fullmatch(r"\w+", rep["hypothesis"] or "") else ""
                verdict = f'<span class="card-verdict">{said}Verdict: {E(rep["verdict"])}</span>'
            partner = (f'<span class="missing">{icon("rule")}None set. Doing less could satisfy the metric.</span>' if unset(c.get("partner_metric"))
                       else E(c["partner_metric"]))
            more = (f'<details class="fold"><summary>Rest of the card</summary><dl class="card">{"".join(f"<div><dt>{l}</dt><dd>{E(c[k])}</dd></div>" for k, l in rest)}</dl></details>'
                    if rest else "")
            card_block = (wrap('<p class="question">', E(c.get("question")), "</p>") + '\n<dl class="card">\n'
                          f'<div><dt>Hypothesis</dt><dd>{E(c.get("hypothesis"))}{verdict}</dd></div>\n<div><dt>Metric</dt><dd>{E(c.get("metric"))}</dd></div>\n'
                          f'<div><dt>Partner metric</dt><dd>{partner}</dd></div>\n<div><dt>Kill if</dt><dd>{E(c.get("kill_criteria"))}</dd></div>\n</dl>{more}')
        nocause = '<em class="missing">no root cause named</em>'
        inc = "".join(f'<li><code>{E(i["path"].split("/")[-1])}</code>{", job " + E(i["job"]) if i["job"] else ""}: '
                      f'{nocause if unset(i["root_cause"]) else E(i["root_cause"].rstrip("."))}{". Fix: " + E(i["fix"]) if i["fix"] else ""}</li>'
                      for i in r["incidents"])
        dev = "".join(f"<li>{inl(d)}</li>" for d in rep["deviations"]) if rep else ""
        files = (f'<details class="fold"><summary>{n(len(r["uncommitted_files"]), "uncommitted file")}</summary><ul class="files">'
                 f'{"".join(f"<li><code>{E(x)}</code></li>" for x in r["uncommitted_files"])}</ul></details>') if r["uncommitted_files"] else ""
        empty = "" if rep else ('<p class="note">' + ("Explore runs carry no report." if explore(r) else "Jobs ran, but there is no report yet, so no claim to trace."
                                                      if r["manifests"] else "No report and no scheduler record yet, so no claim to trace.") + "</p>")
        return ('<div class="run-body">' + wrap('<p class="rels">', rel, "</p>") + "\n" + why + wrap('<ul class="probs">', probs, "</ul>") + f"\n{card_block}\n"
                f"{timeline(r)}\n{receipts(r)}{empty}\n" + wrap('<h4>Incidents</h4><ul class="plain">', inc, "</ul>") + "\n"
                + wrap('<h4>Deviations from the card</h4><ul class="plain prose">', dev, "</ul>") + "\n"
                + wrap('<h4>Next step</h4><div class="prose">', md(rep["next"]) if rep and rep["next"] else "", "</div>") + f"\n{files}</div>")

    def run_summary(r):
        f = F[r["id"]]
        flags = "".join([f'<span class="f f-stop">{n(len(f["ripples"]), "ripple")}</span>' if f["ripples"] else "",
                         f'<span class="f f-rule">{n(len(r["violations"]), "rule break")}</span>' if r["violations"] else "",
                         f'<span class="f f-rule">{n(len(f["broken"]), "broken receipt")}</span>' if f["broken"] else "",
                         f'<span class="f">{n(len(r["incidents"]), "incident")}</span>' if r["incidents"] else "",
                         f'<span class="f">{len(r["uncommitted_files"])} uncommitted</span>' if r["uncommitted_files"] else ""])
        g_icon = {"stop": "ripple", "rule": "rule", "look": "handled", "await": "await", "quiet": "quiet"}[f["group"]]
        q = f'<span class="rs-q">{E(r["card"]["question"])}</span>' if r["card"].get("question") else ""
        last = f'<time datetime="{iso(f["last"])}">{fd(f["last"])}</time>' if f["last"] else "no dates"
        return (f'<summary><span class="rs-icon rs-{f["group"]}">{icon(g_icon)}</span><span class="rs-main"><span class="rs-line"><span class="id">{E(r["id"])}</span>'
                f'<span class="o o-{out_cls(r)}">{E(out_word(r))}</span>{flags}</span>{q}</span><span class="rs-when">{last}</span></summary>')

    groups_html = ""
    for g, label in GROUPS:
        rs = [r for r in srt if F[r["id"]]["group"] == g]
        if rs:
            groups_html += (f'<section class="rgroup" id="runs-{g}" aria-labelledby="runs-{g}-h"><h3 id="runs-{g}-h">{E(label)} <span class="n">{len(rs)}</span></h3>\n'
                            + "".join(f'<details class="run" id="run-{E(r["id"])}"{" open" if g == "stop" else ""}>{run_summary(r)}{run_detail(r)}</details>' for r in rs)
                            + "</section>")
    jump = "".join(f'<a href="#runs-{g}">{E(label)} <b>{k}</b></a>' for g, label in GROUPS
                   for k in [sum(F[r["id"]]["group"] == g for r in runs)] if k)
    runs_sec = f'''<section id="runs" aria-labelledby="runs-h"><h2 id="runs-h">Runs</h2>
<p class="lede">{n(len(runs), "run")}, grouped by what they need from you, then newest first. Open one for its card, timeline and receipts.</p>
{f'<nav class="jump" aria-label="Run groups">{jump}</nav>{groups_html}' if runs else '<p class="note">No runs yet.</p>'}
</section>'''

    # ---- branches
    def chips(lst, cls):
        li = lambda xs: "".join(f'<li class="{cls}"><code>{E(x)}</code></li>' for x in xs)
        if len(lst) > 6:
            return f'<ul class="chips">{li(lst[:6])}</ul><details class="fold"><summary>{len(lst) - 6} more</summary><ul class="chips">{li(lst[6:])}</ul></details>'
        return f'<ul class="chips">{li(lst)}</ul>'
    alarm_html = ""
    for br in alarm:
        gf = [x for x in br["drawer"] if not x.startswith(".github/")]
        wf = [x for x in br["drawer"] if x.startswith(".github/")]
        bs = "".join([badge("handled", f"touches {n(len(gf), 'guard file')}") if gf else "", badge("handled", f"touches {n(len(wf), 'workflow file')}") if wf else "",
                      badge("handled", f"touches {n(len(br['watched']), 'watched path')}") if br["watched"] else ""])
        alarm_html += (f'<article class="branch"><header><code class="id">{E(br["name"])}</code>{bs}</header><p class="meta">{n(br["ahead"], "commit")} ahead, '
                       f'{n(br["changed"], "file")} changed, last <time datetime="{E(br["time"])}">{fd(when(br["time"]))}</time>: {E(br["subject"])}</p>\n'
                       + (f"<h4>Guard files</h4>{chips(gf, 'chip-guard')}" if gf else "") + (f"<h4>Workflow files</h4>{chips(wf, 'chip-guard')}" if wf else "")
                       + (f"<h4>Watched paths</h4>{chips(br['watched'], 'chip-watch')}" if br["watched"] else "") + "</article>")
    quiet = sorted((x for x in data["branches"] if x not in alarm), key=lambda x: -(when(x["time"]).timestamp() if when(x["time"]) else 0))
    quiet_rows = "".join(f'<tr><td><code>{E(x["name"])}</code></td><td class="num">{n(x["ahead"], "commit")}, {n(x["changed"], "file")}</td>'
                         f'<td><time datetime="{E(x["time"])}">{fd(when(x["time"]))}</time> {E(x["subject"])}</td></tr>' for x in quiet)
    quiet_html = (f'<details class="fold"{"" if alarm else " open"}><summary>{n(len(quiet), "branch", "branches")} touch nothing guarded</summary><div class="wide"><table class="quiet">'
                  f'<thead><tr><th scope="col">Branch</th><th scope="col">Ahead</th><th scope="col">Last commit</th></tr></thead><tbody>{quiet_rows}</tbody></table></div></details>') if quiet else ""
    branch_body = ((alarm_html or '<p class="note">' + icon("pass") + " No branch touches the guard, the workflow or a watched path.</p>") + f"\n{quiet_html}"
                   if data["branches"] else '<p class="note">No branches ahead of the protected branch.</p>')
    branches = f'''<section id="branches" aria-labelledby="branches-h"><h2 id="branches-h">Unmerged branches</h2>
<p class="lede">Branches ahead of <code>{E(data["base"])}</code>. Any that change the guard, the workflow or a watched path come first; the fence blocks those from merging.</p>
{branch_body}
</section>'''

    live = data.get("every")
    refresh = (f"Served live from {E(socket.gethostname())}; re-surveyed at most every {max(1, round(live / 60))} min on reload."
               if live else "Regenerate after a wake to refresh.")
    dot = f' <b class="dot">{len(ripple_runs)}</b>' if data["rippled"] and ripple_runs else ""
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">{f'<meta http-equiv="refresh" content="{live}">' if live else ""}
<title>{E(data["title"])}: guard atlas</title>
<style>{asset("atlas.css")}</style></head><body>
<a class="skip" href="#status">Skip to status</a>
{asset("atlas-sprite.svg").rstrip()}
<nav class="top" aria-label="Sections"><span class="top-title">{E(data["title"])}</span><a href="#status">Status</a><a href="#compute">Compute</a><a href="#checks">Checks{dot}</a><a href="#questions">Questions</a><a href="#runs">Runs</a><a href="#branches">Branches</a><span class="top-snap">{E(data["generated"])}</span></nav>
<main>
{status}
{compute}
{checks}
{questions}
{runs_sec}
{branches}
<footer>Generated by guard atlas from <code>{E(data["top"])}</code>. {refresh} The page holds no state and writes nothing back.</footer>
</main>
<script>{asset("atlas.js").rstrip()}</script>
</body></html>'''
