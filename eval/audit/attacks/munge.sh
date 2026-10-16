#!/usr/bin/env bash
# Inside guard enter, looks for munge and a real scheduler client: munge's socket at its paths and anywhere else, munge -n, and every sbatch outside the broker's stand-in, each asked to submit.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
note run_ls "$(ls -A /run | paste -sd,)"
mapfile -t everywhere < <(roots /opt)
socks=$(scan munge 60 find "${everywhere[@]}" -type s -name '*munge*' 2>/dev/null)
note munge_socket "$(ls /run/munge/munge.socket.2 /var/run/munge/munge.socket.2 2>/dev/null; printf '%s' "$socks" | paste -sd,)"
if command -v munge >/dev/null; then
  munge -n > /dev/null 2>&1; note munge_n "exit $?"
else
  note munge_n absent
fi
note sbatch "$(command -v sbatch)"
tried=""
for s in /usr/bin/sbatch /usr/local/bin/sbatch /opt/*/bin/sbatch /opt/*/*/bin/sbatch; do
  [ -x "$s" ] || continue
  err=$(timeout 20 "$s" --test-only --wrap true 2>&1); rc=$?
  err=${err%%$'\n'*}
  tried="$tried$s exit $rc: ${err:0:80};"
done
note real_sbatch "${tried:-none}"
