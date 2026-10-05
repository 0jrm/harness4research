# The atlas data contract

`guard atlas --json FILE` writes the data the page is drawn from, and `--serve` serves the same data at `/atlas.json`. The renderer reads nothing else, so a redesign can be built against this file alone.

`atlas_schema` is the version of this contract. A new field does not change it. A renamed or removed field, or a changed meaning, bumps it.

## Top level

| Field | Meaning |
|---|---|
| `atlas_schema` | `1` |
| `generated_at` | when the survey ran, ISO 8601 UTC, such as `2026-10-05T15:13:42Z` |
| `generated` | the same time for people, such as `2026-10-05 15:13 UTC` |
| `project`, `title`, `top` | project name from the origin URL, page title, and the checkout path |
| `base`, `base_sha` | the protected branch the guard inputs are read from, and its commit |
| `head`, `behind_base` | the checkout's HEAD, and how many commits of `base` it lacks. Above 0, the page tells the reader to pull |
| `worktree`, `uncommitted` | whether uncommitted run files were read, and how many there were |
| `rippled` | whether `guard/run ripples` ran. When false, no check reached a verdict |
| `summary` | counts of `runs`, of runs with a `ripple`, a `handled` failure or an `unchecked` line, and of runs where `needs_you` is not empty |
| `waters` | one entry per place compute ran: `name`, `fence` (`bank` Slurm with a capped account, `bump` a launch host, `none` no gate), `runs`, `hand` (runs placed only by `execution.tsv` rows), `desc` and `count` |
| `budget`, `version`, `watch`, `code`, `globs` | the budget card, `guard/VERSION`, the watch list, the code repositories reports cite, and the `--runs` filters |
| `branches` | remote branches ahead of `base`, with what they change under `guard/`, `.github/` and watched paths |
| `runs` | one object per run, below |

## Per run

| Field | Meaning |
|---|---|
| `id` | the run id, the folder under `runs/` |
| `outcome` | one state from the table below |
| `outcome_detail` | one sentence saying what the outcome means for this run |
| `severity` | `ripple` (a RIPPLE line, stop spending), `handled` (a failure an incident or ledger row handles), `warn` (a violation below), or `quiet` |
| `needs_you` | short reasons the reader has to act, such as `awaiting verdict`, `uncommitted card`, `guard touched`, `report waits for review on <branch>` or `checkout behind <base>, run git pull`. Empty when nothing waits on a person |
| `last_event` | the latest thing the run left behind: `type` (`card frozen`, `card edited`, `job`, `execution row`, `incident` or `report`), `time` in UTC, and `what` |
| `card`, `card_from`, `card_frozen_on` | the question card's keys; `here` when read from this checkout or the base branch's name when only `base` has it; the ref whose history froze it, or null when nothing committed it |
| `card_history`, `card_blob` | the card's commits, oldest first, and its blob hash |
| `manifests` | scheduler records, one per job |
| `execution` | the `execution.tsv` ledger: `path`, `committed`, `header_ok`, and `rows` with `id ts field value why evidence`. Null when the run has none |
| `incidents` | incident write-ups under `incidents/` |
| `report`, `report_refs` | the report read here, with its evidence rows and their receipts; when there is none here, the refs that have one |
| `ripples` | the run's `guard/run ripples` lines: `status`, `check`, `detail` |
| `violations` | sentences for what breaks the card discipline |
| `committed_files`, `uncommitted_files`, `checks` | the run's files and domain checks |

## Outcomes

| Outcome | When |
|---|---|
| `explore` | the id starts with `explore-` |
| `supported`, `negative`, `escalated`, `reported` | the report's verdict is continue, kill, escalate, or a word the atlas does not know |
| `report unmerged` | no report here, but a branch ahead of `base` has one |
| `report not pulled` | no report here, but `base` has one, so this checkout is behind |
| `superseded` | another card names this run in `supersedes` |
| `open` | jobs with manifests, no report yet |
| `recorded by hand` | no manifest, but `execution.tsv` rows or an incident show it ran |
| `no scheduler record` | the card is frozen and nothing else is recorded. The run may have happened where no scheduler writes a manifest |
| `not run` | the card is not committed and nothing shows a run |
