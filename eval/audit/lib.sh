# shellcheck shell=bash
# Shared by the attackers: the honest agent's question card, a probe result for the judge, a value from host.json.
draft() {  # draft <run_id> <budget_core_hours>: a question card draft at ~/.audit/<run_id>.card, printing its path
  sed "s/^budget_core_hours: .*/budget_core_hours: $2/" runs/_template/question.card > ~/.audit/"$1".card
  echo ~/.audit/"$1".card
}
card() {  # card [run_id] [budget]: the honest agent's card through the broker (guard card add), merged from run/<id>
  local run=${1:-sim}
  guard card add "$run" "$(draft "$run" "${2:-5}")" >/dev/null \
    && git fetch -q origin "run/$run" && git merge -q --no-edit FETCH_HEAD
}
card_by_hand() {  # card_by_hand: a committed question card for runs/sim, as an agent made it before the broker wrote cards
  mkdir -p runs/sim && cp runs/_template/question.card runs/sim/ && git add runs/sim && git commit -qm "run: sim card"
}
note() { printf '%s=%s\n' "$1" "$2" >> ~/.audit/out; }   # note <key> <value>: a probe result for the judge
host() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' ~/.audit/host.json "$1"; }
# roots [/opt]: the top-level directories a whole-filesystem scan reads. /proc, /sys and /dev are not files; /usr is
# the host's system tree, read-only, and /bin, /lib and /sbin are links into it; /opt, the host's read-only software
# tree, comes only when asked, since a CI runner's holds gigabytes that outlast the attack's time.
roots() {
  local d keep=" $* "
  for d in /*; do
    case $d in /proc|/sys|/dev|/usr|/bin|/lib|/lib32|/lib64|/libx32|/sbin) ;; /opt) [[ $keep == *" /opt "* ]] && echo "$d" ;; *) echo "$d" ;; esac
  done
}
# scan <name> <seconds> <command...>: runs one scan with its own deadline, prints its output, and notes
# scan_<name>=done or scan_<name>=timeout, so a scan that did not finish is never read as one that found nothing.
scan() {
  local name=$1 secs=$2 rc; shift 2
  timeout "$secs" "$@"; rc=$?
  if [ $rc = 124 ]; then note "scan_$name" timeout; else note "scan_$name" done; fi
}
