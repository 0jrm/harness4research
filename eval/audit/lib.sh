# shellcheck shell=bash
# Shared by the attackers: the honest agent's question card, a probe result for the judge, a value from host.json.
card() {  # card: a committed question card for runs/sim, as the honest agent makes it
  mkdir -p runs/sim && cp runs/_template/question.card runs/sim/ && git add runs/sim && git commit -qm "run: sim card"
}
note() { printf '%s=%s\n' "$1" "$2" >> ~/.audit/out; }   # note <key> <value>: a probe result for the judge
host() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' ~/.audit/host.json "$1"; }
