# shellcheck shell=bash
# usage: bash /run/box/inside.sh [--probe] [--relay PORT[:NAME]]... -- <command...>
# The first process lib/box.sh starts inside the sandbox: the pre-flight probe, then the relays, then the command.
probe=0 relays=()
while [ $# -gt 0 ]; do
  case $1 in
    --probe) probe=1; shift ;;
    --relay) relays+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) echo "inside.sh: unknown option $1" >&2; exit 64 ;;
  esac
done
if [ $probe = 1 ] && ! /usr/bin/python3 -I /run/box/probe.py <&4; then
  echo "guard box: the pre-flight probe failed inside the new sandbox, so nothing started" >&2
  exit 70
fi
exec 4<&-
for r in "${relays[@]}"; do
  port=${r%%:*} name=net.sock
  [ "$port" = "$r" ] || name=${r#*:}
  /usr/bin/python3 -I /run/box/netrelay.py "$port" "/run/guard/$name" < /dev/null &
  listening=$(printf ':%04X 00000000:0000 0A' "$port")
  for _ in $(seq 100); do grep -q "$listening" /proc/net/tcp && break; sleep 0.02; done
done
exec "$@"
