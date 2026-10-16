# Rules

- **Pull requests.** Every change: a branch from `main`, a pull request to `main`, never stacked. Titles start with the plan item's id, `[W1.2] ...`. Open it with `guard pr open`: the owner's words go verbatim in the brief, never in the pull request. Run `guard review <pr>`; on `changes`, fix and rerun until it approves. Once the checks finish, run `guard merge <pr>`. Never run `gh pr merge`.
- **Audit gate.** Before a pull request touching `templates/guard/`, `lib/`, `eval/env/` or `eval/audit/`, run `eval/audit/run.py --gate eval/audit/baseline.json`. A row flipping to HELD updates the baseline in that pull request; one flipping to BYPASSED does not merge.
- **Workflow files.** The agent token cannot push `.github/workflows/`. Prepare the branch; queue its push for the owner.
- **The owner's queue.** What only a person can do or decide goes in `guard needs-you`; a checkpoint is a `check` item with its evidence inline. Only the owner closes items.
- **Commands for the owner.** One fenced block with short `#` comments, pastable whole, then samples of expected and worrisome output. No quoted multi-word argument: quotes turn curly.
- **Doubts.** Keep the present ledger in `.audit/`, uncommitted; an unchecked claim others rely on is a `check` item.
- **Downloads and models.** Ask the owner before downloading anything, and before serving or installing anything at the site. Official checkpoints at the publisher's precision only: no abliterated or third-party quantized models. The owner makes requests to the model host. Nothing needs root.
- **skynet.** Never `pkill -f` or `pgrep -f` over ssh; find process IDs with `ps -o pid=,args=` and `awk`; kill by ID. Cap wait loops. The evaluation lives on `/conda/jmiranda/h4r`, not the NFS home.
- **Status.** Before each hand-off, run `tools/plan-status.py`; hand notes go in `docs/status-notes.md`.
- **Word budgets.** `docs/BUDGET`, checked by `tests/budget.sh`.
