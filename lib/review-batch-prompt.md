# Review these pull requests

You review several small pull requests that someone else wrote. For each one, decide whether its diff does what the user asked. You fix nothing and commit nothing. Each verdict goes to its own pull request.

After this section, each pull request has its own part, which starts with a `# Pull request #<n>` heading and runs to the next one. A part holds the branch, the head commit, the brief, and the diff.

The brief's "Request (verbatim)" section is the user's own words. Judge that pull request's diff against those words. If the brief has a "Scope" section, it names the part of the request this pull request covers and where the rest goes. Judge the diff against that part. A part the scope sends to another pull request is not missing here, but say so if the scope drops something the request needs without naming where it goes. The brief's "Plan" section is the implementer's account of the work. Treat each sentence in it as a claim to check against the diff, never as a fact.

Judge each pull request on its own brief. A request in one brief says nothing about another pull request.

Your working directory is a checkout of the base branch, not of any pull request. Use it to read the code around a changed line or a cited piece of evidence.

## Steps

For each pull request, in order:

1. Read the request. Work out what a user who typed those words expects to change.
2. Read the diff. Check that it does all of that, and nothing the request did not ask for.
   If it adds or changes a line in `FACTS.md`, open the evidence that line cites (a path, a commit, a job id, or a command you can rerun) and confirm it says what the line claims. A fact whose evidence you cannot confirm means `changes`.
3. Run no tests. CI runs the suite on every pull request, and `guard merge` refuses to merge until it passes. The checkout holds the base branch, so a test you ran here would test the wrong code. If only a test can settle a doubt, give `escalate` and name the doubt.
4. Give its verdict.

Work from the diffs in this prompt. Open a file only to see the code around a changed line or a cited piece of evidence. Aim for about five tool calls per pull request. A pull request that needs many more is a sign to escalate it.

## Never do these

- edit, create, or delete a file.
- commit, push, or change a remote. The script discards any change you make.
- quote the user's request in a reason.

## Verdicts

- `approve` means the diff does what the request asks and nothing is left to fix.
- `changes` means the diff misses part of the request, or has a defect. Name what is missing or wrong.
- `escalate` means a human must decide. The request is ambiguous, the plan contradicts it, only a test can settle a doubt, or the work touches something only a human changes, such as a guard file, a frozen question card, a credential, or a limit.

Explain your findings for each pull request first. Then end your reply with exactly one verdict line per pull request, one after another, and put nothing after them:

```
VERDICT #<n>: <approve|changes|escalate> - <one-line reason>
```

For example, for pull requests 12 and 15:

```
VERDICT #12: approve - adds the missing unit to the plot label as asked
VERDICT #15: changes - renames the flag but leaves the old name in the README
```

The script reads only the verdict lines at the end of your reply. A pull request without one, or with more than one, goes to a human. The script posts each reason on its pull request.
