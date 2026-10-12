#!/usr/bin/env python3
"""usage: eval/serve/verify_weights.py <hf repo> <revision> <model dir>

Checks a local model folder against the files Hugging Face lists for that repository at that revision: every
large (LFS) file by its sha256, every small file by its git blob sha1. Prints one line per file that is missing
or differs, a line naming files the folder has and the revision does not, and a summary. Exit 0 only when every
listed file is present and matches. Standard library only; it downloads the file listing, not the files.
"""
import hashlib
import json
import os
import sys
import urllib.request


def listing(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=1"
    with urllib.request.urlopen(url, timeout=60) as r:
        return [e for e in json.load(r) if e["type"] == "file"]


def digest(path, blob_size=None):
    h = hashlib.sha1(f"blob {blob_size}\0".encode()) if blob_size is not None else hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    repo, revision, folder = sys.argv[1:]
    files = listing(repo, revision)
    bad = 0
    for e in files:
        path = os.path.join(folder, e["path"])
        if not os.path.isfile(path):
            print(f"missing  {e['path']}")
            bad += 1
            continue
        lfs = e.get("lfs")
        want = lfs["oid"] if lfs else e["oid"]
        got = digest(path) if lfs else digest(path, os.path.getsize(path))
        if got != want:
            print(f"differs  {e['path']}: {got} != {want}")
            bad += 1
    listed = {e["path"] for e in files}
    local = (os.path.relpath(os.path.join(d, n), folder) for d, _, ns in os.walk(folder) for n in ns)
    extra = sorted(p for p in local if p not in listed and not p.startswith(".cache/huggingface/"))
    if extra:
        print(f"extra    {', '.join(extra)} (not in the revision; the download tool's .cache/huggingface is not listed)")
    print(f"{len(files) - bad} of {len(files)} files match {repo} at {revision}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
