#!/usr/bin/env bash
# usage: eval/episode.sh <family> <variant> <arm> <episode_dir> [--seed N]
# Builds one episode of a task: the project, the hidden evaluator data, the prompt, and the harness for the arm.
#   family    a directory under eval/tasks, such as t1-walltime
#   variant   trap or control
#   arm       A (no harness) or E (the full harness: guard, AGENTS.md, the skills, needs-you)
# After it, run the agent with eval/env/sandbox.sh <episode_dir> -- ..., give it <episode_dir>/prompt.md, then run
# eval/env/down.sh <episode_dir> and eval/score.py <episode_dir>. Arms B to D come with the first result.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: episode.sh <family> <trap|control> <A|E> <episode_dir> [--seed N]" >&2; exit 64; }
[ $# -ge 4 ] || usage
family=$1 variant=$2 arm=$3 ep=$4; shift 4
seed=0
while [ $# -gt 0 ]; do
  case $1 in --seed) seed=$2; shift 2 ;; *) usage ;; esac
done
task=$here/tasks/$family
[ -f "$task/task.json" ] || { echo "episode.sh: no task $family under $here/tasks" >&2; exit 2; }
case $variant in trap|control) ;; *) usage ;; esac
case $arm in A|E) ;; *) usage ;; esac
j() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); [v := v[k] for k in sys.argv[2:]]; print(v if isinstance(v, str) else json.dumps(v))' "$task/task.json" "$@"; }

# The task's own build: project/, hidden/ and prompt.md, from the variant and the seed.
stage=$(mktemp -d "${TMPDIR:-/tmp}/stage.XXXXXX"); trap 'rm -rf "$stage"' EXIT
python3 "$task/build.py" "$variant" "$seed" "$stage"
project=$stage/$(j project)
mv "$stage/project" "$project"
python3 - "$here/env/cluster.json" "$task/task.json" > "$stage/cluster.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.update(json.load(open(sys.argv[2])).get("cluster", {}))
json.dump(cfg, sys.stdout, indent=1)
PY
harness=(); [ "$arm" = E ] && harness=(--harness "$(cd "$here/.." && pwd)")
"$here/env/up.sh" "$ep" --project "$project" --cluster "$stage/cluster.json" "${harness[@]}" > /dev/null
ep=$(cd "$ep" && pwd)
cp -R "$stage/hidden/." "$ep/hidden/"
cp "$stage/prompt.md" "$ep/prompt.md"
name=$(basename "$project")

if [ "$arm" = E ]; then
  # guard init runs inside the sandbox, as an agent or a person on the login node would run it.
  "$here/env/sandbox.sh" "$ep" -- bash -c "guard init ~/$name > /dev/null && cd ~/$name.guard-init \
    && git add -A && { git diff --cached --quiet || git commit -qm 'chore(guard): add guard'; } \
    && git push -q origin guard/init"
  # The human fills the budget card and the watch list, and merges past the fence as a ruleset bypass would.
  human=$stage/human
  git clone -q "$ep/state/git/protected.git" "$human"
  git -C "$human" switch -q guard/init
  python3 - "$task/task.json" "$human/guard/budget.card" "$human/guard/watch.list" <<'PY'
import datetime, json, sys
task = json.load(open(sys.argv[1]))
values = dict(task["arm_e"]["budget"])
values.setdefault("start_date", (datetime.date.today() - datetime.timedelta(days=7)).isoformat())
lines = open(sys.argv[2]).read().splitlines()
out = [f"{l.split(':', 1)[0]}: {values.pop(l.split(':', 1)[0])}" if l.split(":", 1)[0] in values else l for l in lines]
out += [f"{k}: {v}" for k, v in values.items()]
open(sys.argv[2], "w").write("\n".join(out) + "\n")
open(sys.argv[3], "w").write("".join(p + "\n" for p in task["arm_e"].get("watch", [])))
PY
  git -C "$human" add -A
  git -C "$human" -c user.name=PI -c user.email=pi@lab commit -qm "chore(guard): set budget and watched paths"
  git -C "$ep/state/git/protected.git" fetch -q "$human" guard/init:main
  git -C "$ep/state/git/protected.git" branch -q -D guard/init  # merged; the scorer diffs every branch tip
  "$here/env/sandbox.sh" "$ep" -- bash -c "cd ~/$name && git pull -q && rm -rf ~/$name.guard-init && git worktree prune"
  # The skills, where Codex and other Agent Skills readers look for them.
  mkdir -p "$ep/home/.agents/skills"
  for s in "$ep"/sandbox/harness/skills/*/; do
    ln -s "/opt/harness4research/skills/$(basename "$s")" "$ep/home/.agents/skills/$(basename "$s")"
  done
fi

python3 - "$ep/meta.json" "$family" "$variant" "$arm" "$seed" "$name" "$(git -C "$here/.." rev-parse HEAD)" <<'PY'
import json, sys, time
keys = ["family", "variant", "arm", "seed", "project", "harness_commit"]
meta = dict(zip(keys, sys.argv[2:]))
meta["seed"] = int(meta["seed"])
meta["built"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(meta, open(sys.argv[1], "w"), indent=1)
PY
git -C "$ep/home/$name" rev-parse HEAD > "$ep/state/git/start-commit"
echo "$ep"
