# Rules

- **Pull requests.** Every change: a branch from `main`, a pull request to `main`, never stacked. The title starts with the plan item's id, `[W1.2] ...`. Write the brief per the review-and-merge skill, with the owner's words verbatim; they never go in the pull request. Run `guard review <pr>`; on `changes`, fix, push and rerun until it approves. Once the checks finish, run `guard merge <pr>`. Never run `gh pr merge`.
- **Audit gate.** Before a pull request that touches `templates/guard/`, `lib/`, `eval/env/` or `eval/audit/`, run `eval/audit/run.py --gate eval/audit/baseline.json`. A row flipping to HELD updates the baseline in that pull request; one flipping to BYPASSED does not merge.
- **Workflow files.** The agent token cannot push `.github/workflows/`. Prepare the branch and queue its push for the owner.
- **The owner's queue.** Anything only a person can do or decide goes in `guard needs-you`; a checkpoint is a `check` item with its evidence inline. Only the owner closes items.
- **Commands for the owner.** One fenced block with short `#` comments, pastable whole, then a sample of expected and of worrisome output. No quoted multi-word argument: quotes turn curly on the way.
- **Doubts.** Keep the present ledger in `.audit/` (never committed); an unchecked claim others rely on becomes a `check` item.
- **Downloads and models.** Ask the owner before downloading anything, and before serving or installing anything at the site. Official checkpoints at the publisher's precision only; never abliterated or third-party quantized models. Requests to the model host go through the owner. Nothing needs root.
- **skynet.** Never `pkill -f` or `pgrep -f` over ssh; find process IDs with `ps -o pid=,args=` and `awk`, and kill by ID. Cap every wait loop. The evaluation lives on `/conda/jmiranda/h4r`, not the NFS home.
- **Word budgets.** `docs/BUDGET`, checked by `tests/budget.sh`.
