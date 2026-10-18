# Decisions 2026-10-16

Made by the owner with the reviewer through twelve option cards; recommendations were taken except D5. Each row is a standing rule for [plan-2026-10-16.md](archive/plan-2026-10-16.md). Edit a row to overrule it.

| id | decision |
|---|---|
| D1 | New subcommands allowed: `guard broker`, `guard enter`, `guard pr open`. Increments 1-3 land under `eval/`; subcommands at increment 4. |
| D2 | A card is approved when the signed tag `card/<run_id>` exists, created only by the owner's or the broker's key (tag ruleset); preflight runs `git verify-tag`. Optional `card_auto_max_core_hours` (default 0): the broker signs a card at or under it, logs and digests it. Closes n34. `guard broker setup` makes the key; revoke = delete the tag plus a `revoked` ledger row. |
| D3 | Unattended runs: API keys through the gateway. CLI login only in a session the owner starts with `guard enter`. |
| D4 | Network allowlist = PyPI, conda; jobs none. Key `net_allow:` in `guard/budget.card`. |
| D5 | Job sandbox where the compute node has bwrap; bare otherwise, including every multi-node job. Never silent: manifest records `job_sandbox: bare`, ripples counts bare jobs, the audit marks their rows unwalled, doctor reports nodes without bwrap. |
| D7 | Broker on skynet runs in tmux; `guard broker status` is liveness; sockets fail closed. |
| D8 | Never open an agent tree outside a sandbox; `guard enter <proj> -- bash` to look. |
| D9 | The agent never speaks sbatch. A request is card-format fields `time nodes tasks cpus_per_task mem gpus array dependency partition output`; the broker renders `sbatch --export=NONE`, its values last, plus `extra_sbatch:` from `budget.card` (person-owned site options, forwarded verbatim). `guard/run preflight <run_dir> <job.sh> [opts]` stays as a client that translates `#SBATCH` lines and refuses what it cannot map. The option table and its generator move into the broker, committed. |
| D10 | v7.0, schema 7: a project holds data, not code. `guard init` writes cards, `AGENTS.md`, `CLAUDE.md`, `FACTS.md`, `runs/_template/`, the workflow and a `guard/run` shim; no `guard/bin/`. Scripts run from the harness at the tag in `budget.card` `harness:`: online hosts from the tagged clone (wrong tag refuses, names the checkout); offline hosts from one vendored artifact `guard/harness-<tag>.sh`. `install.sh` and doctor pick the mode by reachability; `guard version` reports it. Update = one line by PR; rollback = revert. |
| D11 | Word budgets in `docs/BUDGET` (tokens about 1.3 x words), enforced by `tests/budget.sh`: `AGENTS.md` 250, each `SKILL.md` core 900 (rest in `references/`), `lib/review-prompt.md` 600, `docs/plan-*.md` 1200, `docs/decisions-*.md` 700, `docs/status.md` 600, `docs/rules.md` 300. Templates named by path, not quoted. |
| D12 | `guard ship` is due when any open PR is green in a model-free tier; `ship_interval_hours` is the longest wait for reviewed tiers. Parallel independent worktrees yes; stacking no. |
| D13 | The broker authors ledgers and cards: `guard ledger add`, `guard card add` validate, commit to the run branch and sign. The hook refuses unsigned commits to `runs/*/execution.tsv` and `runs/*/question.card`. Incidents and reports stay agent-authored prose the reviewer reads. |
| A3 | `guard pr open` writes the brief and opens the PR (closes n35): plain subcommand in W0.5, re-homed to the broker's gh stand-in in W1.3. |
| R | v6.2 after W0 (gates, budgets, prerequisites, `guard pr open`); the site reinstalls on it first. v7.0 after W2. n25-n28 unchanged; n28 is the owner's message. |
