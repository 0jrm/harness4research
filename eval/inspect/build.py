#!/usr/bin/env python3
"""usage: eval/inspect/build.py <out_dir> <results_dir>... --episodes <dir>

Writes the inspector's bundle into out_dir, which it creates with mode 0700:

    index.html          the page; a placeholder until the views land
    data/runs.js        window.H4R_RUNS: run_index() of each results_dir, and one summary per episode
    data/ep/<id>.js     window.H4R_EP[<id>]: episode_index() of one episode, each text of 8 KB or more moved to a blob
    data/blob/<sha>.js  window.H4R_BLOB[<sha>]: one such text, named by its sha256, so a shared text is stored once
    manifest.json       every source read: path, size, modification time and sha256

The data files are scripts rather than JSON because browsers refuse fetch() from file://. The build only reads the
records. A rerun reindexes an episode only when one of its sources changed size or modification time, appeared or
went away, and drops an episode whose directory is gone; runs are reindexed every time. It refuses an out_dir inside
the episodes directory or a results directory, and fails when an episode's file passes 2 MB. Standard library only.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from index import SOURCES, episode_index, read_json, run_index  # noqa: E402

BLOB_MIN = 8192
EP_MAX = 2 * 2**20
PLACEHOLDER = """<!doctype html>
<meta charset="utf-8">
<title>Evaluation inspector</title>
<p>The views are not built yet. <code>data/runs.js</code> and <code>data/ep/</code> hold the index.</p>
"""


def stat_of(path):
    try:
        st = os.stat(path)
    except OSError:
        return {"size": None, "mtime_ns": None}
    return {"size": st.st_size, "mtime_ns": st.st_mtime_ns}


def sha256_of(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def blobbed(doc, blobs):
    """doc with each string of BLOB_MIN bytes or more replaced by {"$blob": its sha256}; the strings go to blobs."""
    if isinstance(doc, str):
        raw = doc.encode()
        if len(raw) < BLOB_MIN:
            return doc
        sha = hashlib.sha256(raw).hexdigest()
        blobs[sha] = doc
        return {"$blob": sha}
    if isinstance(doc, dict):
        return {k: blobbed(v, blobs) for k, v in doc.items()}
    if isinstance(doc, list):
        return [blobbed(v, blobs) for v in doc]
    return doc


def script(target, value):
    return f"window.{target} = {json.dumps(value, separators=(',', ':'))};\n"


def registry(name, key, value):
    return f"window.{name} = window.{name} || {{}};\n" + script(f"{name}[{json.dumps(key)}]", value)


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def inside(path, parent):
    return os.path.commonpath([path, parent]) == parent


def summary(doc, size):
    meta = doc["identity"]["meta"]["v"]
    return {"episode": doc["episode"], "state": doc["state"], "bytes": size,
            **{k: meta.get(k) for k in ("family", "variant", "arm", "seed", "harness_commit", "built", "run_id")},
            "turns": len(doc["turns"]), "calls": len(doc["calls"]),
            "checks": [{"name": c["name"], "ok": c["ok"], "detail": c["detail"]} for c in doc["checks"]],
            "moments": [m["kind"] for m in doc["moments"]]}


def build(out, results, episodes):
    out, episodes = os.path.realpath(out), os.path.realpath(episodes)
    for parent in [episodes, *map(os.path.realpath, results)]:
        if inside(out, parent):
            sys.exit(f"build.py: {out} is inside {parent}, which the build only reads")
    os.makedirs(out, mode=0o700, exist_ok=True)
    os.chmod(out, 0o700)
    for sub in ("data/ep", "data/blob"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    manifest = read_json(os.path.join(out, "manifest.json")) or {"sources": {}, "episodes": {}}
    sources, kept = manifest["sources"], manifest["episodes"]
    summaries, oversized, reindexed = [], [], 0
    for name in sorted(os.listdir(episodes)):
        ep = os.path.join(episodes, name)
        meta = read_json(os.path.join(ep, "meta.json"))
        if meta is None:
            continue
        paths = [os.path.join(ep, s.format(project=meta.get("project") or "")) for s in SOURCES]
        now = {p: stat_of(p) for p in paths}
        target = os.path.join(out, "data", "ep", f"{name}.js")
        old = kept.get(name)
        if old and os.path.exists(target) and all(
                {k: sources.get(p, {}).get(k) for k in ("size", "mtime_ns")} == now[p] for p in paths):
            summaries.append(old["summary"])
            continue
        doc = episode_index(ep)
        blobs = {}
        text = registry("H4R_EP", name, blobbed(doc, blobs))
        if len(text.encode()) > EP_MAX:
            oversized.append(f"{name}: {len(text.encode()):,} bytes")
            continue
        for sha, blob in blobs.items():
            path = os.path.join(out, "data", "blob", f"{sha}.js")
            if not os.path.exists(path):
                write(path, registry("H4R_BLOB", sha, blob))
        write(target, text)
        reindexed += 1
        for p in paths:
            sources[p] = {**now[p], "sha256": sha256_of(p)}
        kept[name] = {"sources": paths, "summary": summary(doc, len(text.encode()))}
        summaries.append(kept[name]["summary"])
    for name in set(kept) - {s["episode"] for s in summaries}:
        del kept[name]
        target = os.path.join(out, "data", "ep", f"{name}.js")
        if os.path.exists(target):
            os.remove(target)
    runs = []
    for results_dir in results:
        runs.append(run_index(results_dir, episodes))
        for p in (os.path.join(results_dir, "run.json"), os.path.join(results_dir, "verdicts.jsonl")):
            sources[os.path.abspath(p)] = {**stat_of(p), "sha256": sha256_of(p)}
    named = {c["episode"]: r["run_id"] for r in runs for c in r["cases"]}
    named.update({e["episode"]: r["run_id"] for r in runs for e in r["progress"]["running"]})
    for s in summaries:
        s["run"] = named.get(s["episode"])
    write(os.path.join(out, "data", "runs.js"), script("H4R_RUNS", {"runs": runs, "episodes": summaries}))
    write(os.path.join(out, "index.html"), PLACEHOLDER)
    write(os.path.join(out, "manifest.json"), json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    largest = max(summaries, key=lambda s: s["bytes"], default=None)
    print(f"{len(summaries)} episodes, {reindexed} reindexed; {len(runs)} runs; largest episode file "
          + (f"{largest['episode']}.js, {largest['bytes']:,} bytes" if largest else "none"))
    if oversized:
        sys.exit("build.py: episode files over 2 MB, not written:\n  " + "\n  ".join(oversized))


def main():
    args = sys.argv[1:]
    if "--episodes" not in args or args.index("--episodes") + 1 >= len(args):
        sys.exit(__doc__)
    i = args.index("--episodes")
    episodes = args[i + 1]
    rest = args[:i] + args[i + 2:]
    if len(rest) < 2 or any(a.startswith("-") for a in rest):
        sys.exit(__doc__)
    build(rest[0], rest[1:], episodes)


if __name__ == "__main__":
    main()
