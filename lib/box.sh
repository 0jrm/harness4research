#!/usr/bin/env bash
# usage: lib/box.sh [options] -- <command...>
# The sandbox every agent runs in, without root, through bubblewrap: guard enter's sessions, the broker's reviewer and
# the episodes under eval/ all start here (design increment 4).
#
# Always: its own user, PID, IPC, UTS and network namespaces (loopback only, so no host network), /usr and /etc
# read-only, its own /proc and /dev (no GPUs), /tmp and /run in memory at 1 GiB each, a cleared environment, and per
# process caps of 4 GiB per file and 32 GiB of address space. Nothing else of the host exists inside unless an option
# binds it, so the host's home, ~/.ssh, ~/.config/gh, ~/.config/guard, /run/user/$UID (ssh-agent, dbus), /run/munge
# (without which a real sbatch cannot authenticate), other sockets and the broker's state are all absent.
#
# Resources, all processes together (design increment 5): where systemd's user manager answers and delegates the
# memory and pids controllers, the sandbox runs in a transient scope with MemoryMax, MemorySwapMax=0 and TasksMax, a
# wall the kernel keeps for the sandbox as a whole. Elsewhere, as on skynet, whose user manager answers only in
# interactive logins, prlimit --nproc caps processes and threads at your count now plus the allowance: a speed bump,
# since the kernel counts them per uid, your own shells included, and memory stays capped per process only.
# GUARD_BOX_LIMITS=prlimit picks the second where the first would apply. --record says which one applied.
#
# Options, applied in the order given; bind a parent before what goes inside it:
#   --home DIR AT       DIR read-write at AT, and HOME=AT
#   --tmp-home AT       an empty home in memory at AT
#   --bind DIR AT       read-write
#   --ro PATH AT        read-only; --ro-try skips a PATH that does not exist
#   --sock-dir DIR      DIR at /run/guard: the broker's sockets for this session
#   --sock FILE AT      one socket, at AT
#   --path DIR          on PATH before the system's directories, the first given searched first
#   --env NAME=VALUE    one variable; HOME, USER, LOGNAME, PATH, LANG and TERM are set already
#   --user NAME         USER and LOGNAME (default: the caller's)
#   --hostname NAME     (default: this host's name)
#   --chdir DIR         where the command starts (default: the home)
#   --no-tty            always a new session, as unattended callers want; without it a session keeps the caller's
#                       terminal for job control, but only where the kernel refuses TIOCSTI (legacy_tiocsti 0)
#   --probe             first run the pre-flight probe (box_probe.py) inside, and start nothing if one check fails
#   --hide PATH         with --probe: a host path the sandbox must not reach
#   --relay PORT        127.0.0.1:PORT inside carries each connection to /run/guard/net.sock, the broker's proxy
#   --as BYTES|none     the address-space cap, per process
#   --mem BYTES         the memory of all processes together, in the scope (default: half this host's, at most 32 GiB)
#   --tasks N           the processes and threads allowed (default 512)
#   --record FILE       append one JSON line saying which limits applied, outside the sandbox
#   --print             print bwrap's arguments, one per line, instead of starting anything
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "box.sh: $*" >&2; exit 64; }
arity() { [ "$1" -ge "$2" ] || die "$3 takes $(($2 - 1)) value(s)"; }

argv=("$@")
user=${USER:-$(id -un)} host=$(hostname 2>/dev/null || uname -n) home=/ chdir="" tty=1 probe=0 relay="" print=0
as=$((32 << 30)) binds=() envs=() path=() hide=() ro_paths=(/usr /etc) socks=() home_src=""
mem=$(($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) << 9)) tasks=512 record=""
[ "$mem" -le $((32 << 30)) ] || mem=$((32 << 30))
while [ $# -gt 0 ]; do
  case $1 in
    --home) arity $# 3 "$1"; binds+=(--bind "$2" "$3"); home=$3 home_src=$2; shift 3 ;;
    --tmp-home) arity $# 2 "$1"; binds+=(--dir "$2"); home=$2; shift 2 ;;
    --bind) arity $# 3 "$1"; binds+=(--bind "$2" "$3"); shift 3 ;;
    --ro) arity $# 3 "$1"; binds+=(--ro-bind "$2" "$3"); ro_paths+=("$3"); shift 3 ;;
    --ro-try) arity $# 3 "$1"; [ ! -e "$2" ] || { binds+=(--ro-bind "$2" "$3"); ro_paths+=("$3"); }; shift 3 ;;
    --sock-dir) arity $# 2 "$1"; binds+=(--bind "$2" /run/guard); socks+=(/run/guard/); shift 2 ;;
    --sock) arity $# 3 "$1"; binds+=(--bind "$2" "$3"); socks+=("$3"); shift 3 ;;
    --path) arity $# 2 "$1"; path+=("$2"); shift 2 ;;
    --env) arity $# 2 "$1"; [[ $2 == [A-Za-z_]*=* ]] || die "--env takes NAME=VALUE, not $2"
      envs+=(--setenv "${2%%=*}" "${2#*=}"); shift 2 ;;
    --user) arity $# 2 "$1"; user=$2; shift 2 ;;
    --hostname) arity $# 2 "$1"; host=$2; shift 2 ;;
    --chdir) arity $# 2 "$1"; chdir=$2; shift 2 ;;
    --no-tty) tty=0; shift ;;
    --probe) probe=1; shift ;;
    --hide) arity $# 2 "$1"; hide+=("$2"); shift 2 ;;
    --relay) arity $# 2 "$1"; [[ $2 =~ ^[0-9]+$ ]] || die "--relay takes a port"; relay=$2; shift 2 ;;
    --as) arity $# 2 "$1"; as=$2; shift 2 ;;
    --mem) arity $# 2 "$1"; [[ $2 =~ ^[0-9]+$ ]] || die "--mem takes bytes"; mem=$2; shift 2 ;;
    --tasks) arity $# 2 "$1"; [[ $2 =~ ^[0-9]+$ ]] || die "--tasks takes a count"; tasks=$2; shift 2 ;;
    --record) arity $# 2 "$1"; record=$2; shift 2 ;;
    --print) print=1; shift ;;
    --) shift; break ;;
    *) die "unknown option $1 (see the usage at the top of lib/box.sh)" ;;
  esac
done
[ $# -gt 0 ] || die "usage: box.sh [options] -- <command...>"

# Resource limits (see the top). Where a scope applies, this script runs again inside it, and that run checks the
# scope's own cgroup before anything starts, so a scope that does not hold the limits starts nothing.
mem=$((mem >> 20 << 20))
scope=(-p MemoryMax="$mem" -p MemorySwapMax=0 -p TasksMax="$tasks") limits="" why=""
in_cgroup() { cat "/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/$1" 2>/dev/null || echo none; }
pick_limits() {  # sets limits to scope or prlimit, and why when prlimit
  local cg ctl
  limits=prlimit
  if [ "${GUARD_BOX_LIMITS:-}" = prlimit ]; then why="GUARD_BOX_LIMITS=prlimit"; return; fi
  command -v systemd-run > /dev/null || { why="no systemd-run on this host"; return; }
  cg=$(systemctl --user show -p ControlGroup --value 2> /dev/null) && [ -n "$cg" ] \
    || { why="no systemd user manager answers"; return; }
  ctl=" $(cat "/sys/fs/cgroup$cg/cgroup.controllers" 2> /dev/null) "
  [[ $ctl == *" memory "* && $ctl == *" pids "* ]] \
    || { why="the user manager does not delegate the memory and pids controllers"; return; }
  # OOMPolicy=continue kills only the process past the limit, not the whole sandbox; older systemd lacks it for scopes.
  if systemd-run --user --scope --quiet --collect "${scope[@]}" -p OOMPolicy=continue -- true 2> /dev/null; then
    scope+=(-p OOMPolicy=continue)
  elif ! systemd-run --user --scope --quiet --collect "${scope[@]}" -- true 2> /dev/null; then
    why="systemd-run --user --scope refused"; return
  fi
  limits=scope
}
if [ $print = 0 ] && [ -n "${GUARD_BOX_SCOPE:-}" ]; then
  # Without swap accounting there is no memory.swap.max, which is fine only on a host with no swap to spill into.
  swap=0; [ "$(wc -l < /proc/swaps)" -gt 1 ] || [ -e "/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)/memory.swap.max" ] || swap=none
  have="memory.max $(in_cgroup memory.max), memory.swap.max $(in_cgroup memory.swap.max), pids.max $(in_cgroup pids.max)"
  want="memory.max $mem, memory.swap.max $swap, pids.max $tasks"
  if [ "$have" != "$want" ]; then
    echo "box.sh: the scope holds $have, not $want; nothing started" >&2
    exit 70
  fi
  limits=scope
elif [ $print = 0 ]; then
  pick_limits
  if [ "$limits" = scope ]; then
    exec systemd-run --user --scope --quiet --collect "${scope[@]}" -- \
      env GUARD_BOX_SCOPE=1 bash "${BASH_SOURCE[0]}" "${argv[@]}"
  fi
fi

# /tmp and /run are in memory; cap them at 1 GiB each where bwrap can (0.10 and later). They mount before anything
# bound under them.
tmpfs=(--tmpfs /tmp --tmpfs /run)
bwrap --help 2>&1 | grep -q -- '--size' && tmpfs=(--size $((1 << 30)) --tmpfs /tmp --size $((1 << 30)) --tmpfs /run)
session=(--new-session)
[ $tty = 0 ] || [ "$(cat /proc/sys/dev/tty/legacy_tiocsti 2>/dev/null)" != 0 ] || session=()
system=/usr/local/bin:/usr/bin:/bin
args=(
  --unshare-all --die-with-parent "${session[@]}"
  --hostname "$host"
  --ro-bind /usr /usr
  --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib
  --ro-bind /etc /etc
  --proc /proc --dev /dev "${tmpfs[@]}"
)
[ -e /lib64 ] && args+=(--symlink usr/lib64 /lib64)
args+=(
  "${binds[@]}"
  --ro-bind "$here/box_inside.sh" /run/box/inside.sh
  --ro-bind "$here/box_probe.py" /run/box/probe.py
  --ro-bind "$here/../eval/driver/netrelay.py" /run/box/netrelay.py
  --clearenv
  --setenv HOME "$home" --setenv USER "$user" --setenv LOGNAME "$user"
  --setenv LANG C.UTF-8 --setenv TERM "${TERM:-xterm}"
  --setenv PATH "$(IFS=:; echo "${path[*]}${path[*]:+:}$system")"
  "${envs[@]}"
  --chdir "${chdir:-$home}"
)
inner=(bash /run/box/inside.sh)
[ $probe = 0 ] || inner+=(--probe)
[ -z "$relay" ] || inner+=(--relay "$relay")
inner+=(-- "$@")

# The probe's checks, as NUL-separated key and value pairs: read-only paths, the sockets allowed, the home's inode,
# and each hidden path with the device and inode it has here, so only the host's own object counts as reached.
checks=()
for p in "${ro_paths[@]}"; do checks+=(ro "$p"); done
for p in "${socks[@]}"; do checks+=(sock "$p"); done
[ -z "$home_src" ] || checks+=(home_ino "$(stat -L -c %i -- "$home_src")")
for p in "${hide[@]}"; do
  id=$(stat -L -c %d:%i -- "$p" 2>/dev/null) || continue
  checks+=(hide "$p" hide_id "$id")
done

if [ $print = 1 ]; then printf '%s\n' "${args[@]}" -- "${inner[@]}"; exit 0; fi
caps=(--fsize=$((4 << 30)))
[ "$as" = none ] || caps+=(--as="$as")
if [ "$limits" = prlimit ]; then
  yours=$(ps -L -U "$(id -u)" -o lwp= | wc -l)
  caps+=(--nproc=$((yours + tasks)))
fi
if [ -n "$record" ]; then
  if [ "$limits" = scope ]; then
    printf '{"ts": %s, "limits": "scope", "cgroup": "%s", "memory_max": %s, "swap_max": 0, "tasks_max": %s, "as": "%s"}\n' \
      "$(date +%s)" "$(sed -n 's/^0:://p' /proc/self/cgroup)" "$mem" "$tasks" "$as"
  else
    printf '{"ts": %s, "limits": "prlimit", "why": "%s", "nproc": %s, "yours": %s, "tasks": %s, "as": "%s"}\n' \
      "$(date +%s)" "$why" $((yours + tasks)) "$yours" "$tasks" "$as"
  fi >> "$record"
fi
bwrap=$(command -v bwrap) prlimit=$(command -v prlimit)
# bwrap stays in the sandbox as PID 1, where /proc/1 shows its arguments and environment to everything inside. So its
# arguments, which name host paths, go through a file descriptor; the probe's through a pipe that inside.sh closes
# once the probe has read it; and it starts with an empty environment, since the caller's may hold a token.
exec env -i "$prlimit" "${caps[@]}" "$bwrap" --args 3 -- "${inner[@]}" \
  3< <(printf '%s\0' "${args[@]}") 4< <(printf '%s\0' "${checks[@]}")
