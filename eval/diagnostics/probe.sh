#!/usr/bin/env bash
# usage: eval/diagnostics/probe.sh <scratch dir> [url ...]
# Builds a throwaway arm A episode in <scratch dir> and, from inside its sandbox, tries each URL (default: the
# model host's control API, our vLLM server and the internet), lists the GPUs and checks real Slurm, the host's
# /conda and the sizes of /tmp and the home. Every URL should print "blocked". Tears the episode down after.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { sed -n 2,5p "$0" >&2; exit 64; }
ep=$1/probe-$$; shift
urls=("$@"); [ ${#urls[@]} -gt 0 ] || urls=(http://127.0.0.1:32553/health http://127.0.0.1:9185/v1/models https://pypi.org/simple/)
"$here/episode.sh" t1-walltime trap A "$ep" --seed 1 > /dev/null 2>&1 < /dev/null || { echo "probe: episode.sh failed" >&2; exit 1; }
"$here/env/sandbox.sh" "$ep" -- bash -c '
for u in "$@"; do echo "$u: $(curl -s -m 5 -o /dev/null "$u" && echo REACHED || echo blocked)"; done
echo "gpu devices: $(ls /dev | grep -c nvidia)"
echo "real slurm: $(/usr/bin/squeue > /dev/null 2>&1 && echo WORKS || echo unusable)"
echo "/conda: $(ls /conda > /dev/null 2>&1 && echo VISIBLE || echo absent)"
echo "/tmp: $(df -h /tmp | tail -1 | tr -s " " | cut -d" " -f2)  home free: $(df -h ~ | tail -1 | tr -s " " | cut -d" " -f4)"
' probe "${urls[@]}" < /dev/null
"$here/env/down.sh" "$ep" > /dev/null 2>&1 < /dev/null
rm -rf "$ep"
