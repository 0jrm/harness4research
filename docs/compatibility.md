# Compatibility contract

A guarded project must keep working when its harness clone is newer or older than the release that installed it, and after it runs `guard init --update`. This page lists what stays stable, how a release is versioned, how an update merges, and what a harness maintainer may change.

## What stays stable

Stable means additions only. Nothing on this list is renamed or removed.

| Surface | Stable part |
|---|---|
| Paths | `guard/run`, `guard/bin/{preflight,ripples,manifest,fence}.sh`, `guard/budget.card`, `guard/watch.list`, `guard/VERSION`, `runs/_template/{question.card,report.md}`, `runs/<id>/{question.card,report.md,checks/*,incidents/*.md}` |
| Workflow | `.github/workflows/guard-fence.yml`, workflow name `guard-fence`, job id `fence`. Rulesets require the check `guard-fence / fence`, so a renamed job leaves every pull request waiting. |
| Calling convention | `guard/run <command> args` runs the base branch's script as `bash -c "$script" guard/bin/<command>.sh args` from the repository top. Any `guard/run` must run any script version, because agent branches carry an older working-tree `guard/run`. |
| Environment | `HPC_GUARD_REF`, `HPC_GUARD_LOCAL`, `HPC_SPEND_RESERVE`, `HPC_LOCK_FILES`, `HPC_HASH_INPUTS` |
| Exit codes | 64 is a usage error everywhere. Preflight exits 2 when it refuses, otherwise with sbatch's code. Ripples exits 0, or 1 to stop submissions. The fence exits 0 or 1. `guard/run` exits 2 when the script is missing on the base branch or does not parse. `guard init --update` exits 3 when it proposes conflicts. |
| Output | Ripples and the fence print `STATUS<TAB>check<TAB>detail`. Ripples statuses are PASS, RIPPLE, HANDLED, UNCHECKED. Fence statuses are PASS, FAIL, WARN. Check names are never removed; a check that cannot run says UNCHECKED. Preflight keeps the `PREFLIGHT OK:` and `PREFLIGHT FAIL:` prefixes. |
| Card format | Flat `key: value` lines. The first match wins. `<...>` means unset. Manifests and incidents use the same format, and incidents keep `job: <id>`. |
| Required budget keys | `account`, `start_date`, `stop_date`, `max_core_hours`, `verification_reserve_core_hours`, `cores_per_node`, `max_nodes_per_job`, `max_walltime_minutes`, `max_concurrent_jobs`. No key is ever added to this list. |
| Fence rules | A rule judges files the pull request adds. It judges a modified file only if the file's merge-base copy already passed the rule. No rule scans the whole tree. |

Free to change: the detail column, message wording after the fixed prefixes, internal code, and template comments.

## Versions

`SCHEMA` at the repository root holds one integer. A commit without the file is schema 1. A release raises it when it adds a command, a check name, a status, a card key, a run-file key, or a fence rule. Bug fixes do not raise it. The skill states the schema it describes, and a test keeps the two equal.

Releases are annotated tags `vS.N`, where S is the schema. `v1.0` is the oldest release whose `guard init` works. `tests/oldest-supported` names the oldest release the upgrade tests build from.

`guard init` writes `guard/VERSION` in the project:

```text
schema: 3
installer: <full commit of the harness that wrote this file>
release: <git describe of that commit>
pstack: <commit>
installed: YYYY-MM-DD
```

A file without a `schema:` line was written by schema 1. Every release since `v1.0` writes `installer:`.

## How an update merges

`guard init <repo> --update` reads `guard/VERSION` from the project's default branch and proposes the result on a new branch, `guard/update`, in a separate worktree.

- It refuses when this harness does not contain the installer commit, or when the project's schema is newer, and says to pull the harness. `--force` proposes anyway.
- Each installer-owned file goes through `git merge-file`, with the template at the installer commit as the base. That covers the four scripts, `guard/run`, `guard/README.md`, and the workflow. A human's edit survives. An edit on lines the harness also changed becomes conflict markers, and the command exits 3.
- A template key that is new since the install is inserted next to its template neighbours. A budget key whose template value is a placeholder is listed, not inserted, because preflight refuses placeholders. A key that the template already had at install time and the project lacks stays out, because a human removed it.
- With no usable installer commit, each file merges against an empty base. That is clean when the file already matches the template and a whole-file conflict otherwise.
- `watch.list`, `FACTS.md`, and `AGENTS.md` are never touched. When `templates/AGENTS.md` changed since the install, the output prints the command to compare it.

`guard/run` refuses a base-branch script that has conflict markers or does not parse, so a conflicted file merged by mistake stops the guard instead of running half a script.

Rollback is a revert of the update pull request. `guard/run` reads the base branch, so every branch and clone runs the old scripts after its next fetch. The revert also restores the old `guard/VERSION`, so the next update finds the right base.

## Rules for the harness maintainer

- Add, never rename or remove, anything in the stable table.
- A new budget key is optional, and the script's default equals the template's value.
- A new fence rule follows the ratchet in the stable table.
- Keep template edits in small hunks and never re-indent unchanged lines. A re-indented line conflicts with every project that edited it.
- When a site difference is a value, add a card key with a default, as `quota_pct_cmd` does, instead of asking humans to edit a script.
- Raise `SCHEMA` and the schema the skill states together.
- Tag each release. The upgrade tests build a project from every tag since `tests/oldest-supported` and fail when no tags are present.

## Checking which side is behind

Inside a project, `guard version` prints this harness's release and schema, the project's schema and installer commit, and one verdict:

| Verdict | Meaning | Action |
|---|---|---|
| `current` | the project was installed by this harness's templates | none |
| `project older` | the project's schema is lower, or the templates changed since its install | `guard init <repo> --update` |
| `harness older or on another branch` | this harness lacks the installer commit, or knows a lower schema | `git -C <harness> pull` |
| `install commit unknown` | `guard/VERSION` has no usable installer commit | `guard init <repo> --update --force` |
