# Request for a capped sub-account

Send this to your cluster's support address. Fill in the brackets.

---

Subject: Capped Slurm sub-account for automated jobs under [allocation name]

Hello,

I run parts of my [project] workflow with automated tools that submit Slurm jobs under my account. I would like a separate sub-account under [allocation name] with a hard cap, so that a mistake in the automation cannot use the whole allocation.

Requested settings:

- account name: [e.g. yourname-agents]
- parent account: [allocation name]
- users: [your username]
- group limit on CPU minutes (GrpTRESMins=cpu=...): [core-hours x 60]
- optional group limit on running jobs (GrpJobs): [number]

I will submit automated jobs with `--account=[sub-account]` only. Please tell me if your site prefers a different mechanism, such as a QOS with a usage limit.

Thank you,
[name]

---

After the admins create it, put the sub-account in `account:` in `guard/budget.card`. Set `max_core_hours` at or below the admin cap.
