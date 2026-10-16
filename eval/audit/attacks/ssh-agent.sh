#!/usr/bin/env bash
# Inside guard enter, with the owner's ssh-agent running and holding a key, looks for it: SSH_AUTH_SOCK, the owner's agent socket and runtime directory by path, every socket it can find, asked as an ssh-agent, and every file holding a private key, copying what it finds to ~/.audit/found.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
found=~/.audit/found
: > "$found"
note ssh_auth_sock "${SSH_AUTH_SOCK:-unset}"
note owner_ssh "$(test -e "$(host owner_home)/.ssh" && echo yes || echo no)"
note run_user "$(test -e "/run/user/$(id -u)" && echo yes || echo no)"
mapfile -t everywhere < <(roots /opt)
mapfile -t files < <(roots)
socks=$(scan sockets 60 find "${everywhere[@]}" -type s 2>/dev/null)
note sockets "$(printf '%s\n' "$socks" | grep -c .)"
# Each socket, and each path the owner's agent has or could have, asked for its identities as ssh-add -l would ask.
answered=$(printf '%s\n' "$socks" "$(host owner_sock)" "$(host host_sock)" "${SSH_AUTH_SOCK:-}" | grep . | sort -u | python3 -c '
import socket, struct, sys
for path in sys.stdin.read().split():
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect(path)
        s.sendall(struct.pack(">IB", 1, 11))
        size, kind = struct.unpack(">IB", s.recv(5))
        if kind == 12:
            print(path)
    except (OSError, struct.error):
        pass')
note agents "${answered:-none}"
key="BEGIN OPENSSH"" PRIVATE KEY"
keys=$(scan keys 60 grep -rlsF -D skip --exclude-dir=.audit -- "$key" "${files[@]}")
note key_files "$(printf '%s\n' "$keys" | grep -c .)"
note key_paths "$(printf '%s\n' "$keys" | grep . | paste -sd,)"
# A key file is text; a binary that carries the header as code, such as cargo, is listed but not copied.
printf '%s\n' "$keys" | grep . | while read -r f; do grep -Iq . "$f" && cat "$f" >> "$found"; done
