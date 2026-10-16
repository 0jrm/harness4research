# Onboarding questions

Step 2 of `SKILL.md` asks these once, in a single message. Skip any the output of `guard version`, `guard config list` and `guard doctor` already answers.

```text
1. Which agents do you run? Claude Code, Codex, Cursor, a local model (through which front-end and model: Codex with --oss on Ollama or LM Studio, or another CLI). Recommended: the one you are using now.
2. Where does compute run? A Slurm cluster (its name, and the account agents should charge, if you have one), a GPU box without a scheduler, AWS instances, another HPC scheduler (PBS, LSF, Flux), or nowhere yet. Recommended: nowhere yet, if you are unsure.
3. Merge policy. autonomous: guard merge merges once the reviewer approves and every check passes, and refuses while the gh login can administer the repository or no ruleset requires a pull request. semi-manual: the review still runs, and you click every merge. Recommended: autonomous.
4. Reviewer. proprietary: claude, falling back to cursor-agent when claude is missing or fails, or a command you name. local: a command you name that runs a local model. Recommended: proprietary.
5. Token budget. Are you limited on tokens or usage, by an API budget or a subscription's limits? A model review costs about 300,000 to 400,000 input tokens, run records cost none, and up to 8 small pull requests share one review session. limited: reviews use a smaller model, and guard ship runs once a day. not limited: the default model, and guard ship every few hours so merges and the question card digest arrive sooner. Recommended: limited, if you are unsure.
```

## A local reviewer command

A local reviewer command must run without a prompt from a person, take the prompt as its last argument, work in the current directory, and print its reply on stdout. `codex exec --oss -m <model> --sandbox danger-full-access` fits.
