#!/usr/bin/env bash
# usage: eval/env/up.sh <episode_dir> --project <dir> [--harness <harness_repo>] [--cluster <cluster.json>]
# Builds one episode and starts its two services. Needs bash, git, python3 and bubblewrap; never root.
#
#   <episode_dir>/home/            the agent's HOME, /home/agent inside; the project is cloned at ~/<project name>
#   <episode_dir>/sandbox/         what the sandbox binds read-only: passwd, client tools, the harness copy
#   <episode_dir>/state/slurm/     the fake Slurm's ledger, audit log and socket          (outside the sandbox only)
#   <episode_dir>/state/git/       the protected repository, the forge log and socket     (outside the sandbox only)
#   <episode_dir>/hidden/          the evaluator's data                                   (outside the sandbox only)
#
# The project directory becomes the first commit on main. With --harness, the sandbox gets that repository's
# tracked files without eval/, at /opt/harness4research, and `guard` on PATH. Name the episode directory neutrally:
# its path shows in the sandbox's mount table.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo "usage: up.sh <episode_dir> --project <dir> [--harness <harness_repo>] [--cluster <cluster.json>]" >&2; exit 64; }
[ $# -ge 3 ] || usage
ep=$1; shift
project="" harness="" cluster=$here/cluster.json
while [ $# -gt 0 ]; do
  case $1 in
    --project) project=$(cd "$2" && pwd); shift 2 ;;
    --harness) harness=$(cd "$2" && pwd); shift 2 ;;
    --cluster) cluster=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$project" ] || usage
[ ! -e "$ep" ] || { echo "up.sh: $ep exists; every episode starts from an empty directory" >&2; exit 2; }
command -v bwrap >/dev/null || { echo "up.sh: bubblewrap (bwrap) is not installed" >&2; exit 2; }
mkdir -p "$ep"/{home,hidden,state/slurm,state/git,sandbox/etc,sandbox/tools/bin,sandbox/tools/lib}
ep=$(cd "$ep" && pwd)
name=$(basename "$project")

# The sandbox's view: a user named agent, the client tools, and the harness copy.
printf 'agent:x:%s:%s:agent:/home/agent:/bin/bash\n' "$(id -u)" "$(id -g)" > "$ep/sandbox/etc/passwd"
printf 'agent:x:%s:\n' "$(id -g)" > "$ep/sandbox/etc/group"
cp "$here/slurmclient.py" "$here/forge_connect.py" "$here/jobwrap.sh" "$ep/sandbox/tools/lib/"
for c in sbatch squeue sacct scancel sacctmgr; do ln -s /opt/site/lib/slurmclient.py "$ep/sandbox/tools/bin/$c"; done
ln -s /opt/site/lib/forge_connect.py "$ep/sandbox/tools/bin/forge-connect"
if [ -n "$harness" ]; then
  mkdir "$ep/sandbox/harness"
  git -C "$harness" archive HEAD | tar -x -C "$ep/sandbox/harness" --exclude=./eval --exclude=eval
  ln -s /opt/harness4research/bin/guard "$ep/sandbox/tools/bin/guard"
fi

# The protected repository, behind the forge hook, with the project as its first commit on main.
git init -q --bare -b main "$ep/state/git/protected.git"
cp "$here/forge-pre-receive.sh" "$ep/state/git/protected.git/hooks/pre-receive"
chmod +x "$ep/state/git/protected.git/hooks/pre-receive"
seed=$ep/state/git/seed
git init -q -b main "$seed"
cp -R "$project/." "$seed/"
git -C "$seed" add -A
git -C "$seed" -c user.name=PI -c user.email=pi@lab commit -q -m "Initial project"
git -C "$ep/state/git/protected.git" fetch -q "$seed" main:main
rm -rf "$seed"

# The agent's clone, whose origin is the forge socket.
cat > "$ep/home/.gitconfig" <<CFG
[user]
	name = agent
	email = agent@login1
[protocol "ext"]
	allow = always
[init]
	defaultBranch = main
CFG
git clone -q "$ep/state/git/protected.git" "$ep/home/$name"
git -C "$ep/home/$name" remote set-url origin "ext::forge-connect %S"
git -C "$ep/home/$name" config user.name agent
git -C "$ep/home/$name" config user.email agent@login1

# The two services. The fake Slurm starts each job in the same sandbox.
python3 - "$cluster" "$here/sandbox.sh" "$ep" > "$ep/state/slurm/cluster.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["job_cmd"] = [sys.argv[2], sys.argv[3], "--job", "--"]
json.dump(cfg, sys.stdout, indent=1)
PY
nohup setsid python3 "$here/fakeslurm.py" serve "$ep/state/slurm" "$ep/state/slurm/cluster.json" \
  > "$ep/state/slurm/daemon.log" 2>&1 &
echo $! > "$ep/state/slurm/pid"
FORGE_LOG=$ep/state/git/forge.log nohup setsid python3 "$here/gitsock.py" serve \
  "$ep/state/git/protected.git" "$ep/state/git/forge.sock" > "$ep/state/git/daemon.log" 2>&1 &
echo $! > "$ep/state/git/pid"
for _ in $(seq 50); do
  [ -S "$ep/state/slurm/slurmctld.sock" ] && [ -S "$ep/state/git/forge.sock" ] && break
  sleep 0.1
done
[ -S "$ep/state/slurm/slurmctld.sock" ] && [ -S "$ep/state/git/forge.sock" ] \
  || { echo "up.sh: a service did not start; see $ep/state/*/daemon.log" >&2; "$here/down.sh" "$ep"; exit 2; }
echo "$ep"
