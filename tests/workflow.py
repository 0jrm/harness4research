#!/usr/bin/env python3
"""usage: tests/workflow.py <workflow.yml> <job> <workspace> [--ctx NAME=VALUE]... [--repo OWNER/NAME=PATH]...

Runs one job of a GitHub Actions workflow on this host, for the fixture tests. Each `run` step runs as GitHub runs it,
under `bash -e` in <workspace>, with the step's env, GITHUB_OUTPUT and GITHUB_WORKSPACE; `${{ NAME }}` takes its value
from --ctx, from github.workspace, or from an earlier step's output (steps.<id>.outputs.<key>). An actions/checkout
step clones the local repository that --repo names for its `repository` (GITHUB_REPOSITORY when it names none) into
its `path` and checks out its `ref`, like the action, which leaves no origin/HEAD. A step's `if` may be one comparison
of an expression with a string, == or !=. Prints each step's name and output; exits with the first failing step's code.
"""
import os
import re
import subprocess
import sys
import tempfile

import yaml

EXPR = re.compile(r"\$\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}")
COND = re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*(==|!=)\s*'([^']*)'\s*$")


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.splitlines()[0])
    path, job, workspace = argv[:3]
    ctx, repos, rest = {}, {}, argv[3:]
    while rest:
        flag, pair, rest = rest[0], rest[1], rest[2:]
        key, _, value = pair.partition("=")
        {"--ctx": ctx, "--repo": repos}[flag][key] = value
    workspace = os.path.abspath(workspace)
    ctx["github.workspace"] = workspace
    os.makedirs(workspace, exist_ok=True)
    steps = yaml.safe_load(open(path))["jobs"][job]["steps"]

    def value(name):
        if name not in ctx:
            sys.exit(f"workflow.py: no value for ${{{{ {name} }}}}")
        return ctx[name]

    def fill(text):
        return EXPR.sub(lambda m: value(m.group(1)), str(text))

    for n, step in enumerate(steps, 1):
        name = step.get("name") or step.get("uses") or f"step {n}"
        cond = step.get("if")
        if cond is not None:
            m = COND.match(str(cond))
            if not m:
                sys.exit(f"workflow.py: cannot evaluate if: {cond}")
            if (ctx.get(m.group(1), "") == m.group(3)) != (m.group(2) == "=="):
                print(f"-- {name}: skipped")
                continue
        print(f"-- {name}", flush=True)
        if "uses" in step:
            rc = checkout(step, workspace, repos, fill)
        else:
            rc = run(step, workspace, ctx, fill)
        if rc != 0:
            return rc
    return 0


def checkout(step, workspace, repos, fill):
    if not step["uses"].startswith("actions/checkout@"):
        sys.exit(f"workflow.py: no stand-in for {step['uses']}")
    with_ = {k: fill(v) for k, v in (step.get("with") or {}).items()}
    repository = with_.get("repository") or os.environ["GITHUB_REPOSITORY"]
    if repository not in repos:
        sys.exit(f"workflow.py: no local repository for {repository}; pass --repo {repository}=PATH")
    dest = os.path.join(workspace, with_.get("path", "."))
    for cmd in (["git", "clone", "-q", repos[repository], dest],
                ["git", "-C", dest, "checkout", "-q", with_["ref"]] if with_.get("ref") else None,
                ["git", "-C", dest, "remote", "set-head", "origin", "-d"]):
        if cmd and subprocess.call(cmd) != 0:
            return 1
    return 0


def run(step, workspace, ctx, fill):
    with tempfile.NamedTemporaryFile("r", suffix=".out") as out:
        env = dict(os.environ, GITHUB_OUTPUT=out.name, GITHUB_WORKSPACE=workspace)
        env.update({k: fill(v) for k, v in (step.get("env") or {}).items()})
        rc = subprocess.call(["bash", "-e", "-c", fill(step["run"])], cwd=workspace, env=env)
        if "id" in step:
            for line in out.read().splitlines():
                key, _, val = line.partition("=")
                ctx[f"steps.{step['id']}.outputs.{key}"] = val
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
