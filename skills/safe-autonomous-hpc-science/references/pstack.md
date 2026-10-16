# Compose with pstack

Read this before you plan, wake, pause, or resume a run, with or without pstack.

If pstack is installed, route the work there and apply this skill on top. Otherwise follow the fallback in each line.

- A run that optimizes one metric uses poteto-mode's Hillclimb playbook. Its frozen harness is this skill's verifier, and its stop predicate lives in the question card. Fallback is to follow the run lifecycle in SKILL.md.
- An unattended run uses the Autonomous run playbook for the wake mechanism. Wake on scheduler events (`--dependency`, `sbatch --wait`, job-end hooks), with `sacct` heartbeats minutes apart. Never write tight `squeue` loops.
- The decision trail uses **show-me-your-work**. One row per submission, verdict, pivot, and ripple. That TSV is the run ledger. Failed and abandoned runs get rows too.
- `FACTS.md` holds only facts whose evidence a reviewer checked. Treat any other doc, handoff, or old prompt as a claim to check against artifacts.
- Resume and pause use the Session pickup and Pause safely playbooks. On resume, confirm job state from `sacct` and the run directory, not from the handoff.
- Review the question card with **interrogate** before the first full-scale submission. A preregistration nobody challenged is the cheapest place to lose a month.
- Before editing model code, run **how** on the code path, so you know which conserved quantities and constants you might touch.
- Job scripts are idempotent (**principle-make-operations-idempotent**). A resubmit resumes from checkpoint or exits cleanly when outputs are complete.
- Every run owns `runs/<run_id>/` in the repo and `$SCRATCH/<project>/runs/<run_id>/` on disk. Parallel hypotheses get separate worktrees and run ids (**principle-separate-before-serializing-shared-state**).
