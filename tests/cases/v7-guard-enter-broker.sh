# shellcheck shell=bash
# Sourced by tests/run.sh, in its fixture; split verbatim from the v7 suite.
echo "== guard enter and guard broker"
# An owner's home with what no sandbox may see, a project, and a host without sbatch; the broker runs detached, with
# its state in that home and its sockets under $tmp/rt.
eh=$tmp/enter-home ep_=$tmp/enter-proj
mkdir -p "$eh/.ssh" "$eh/.config/gh" "$ep_"; echo canary-key > "$eh/.ssh/id_ed25519"; echo login > "$eh/.fakelogin"
printf '{"keep": 1, "drop": "secret"}\n' > "$eh/seed.json"
git init -q "$ep_"
en() { env HOME="$eh" GUARD_RUNTIME_DIR="$tmp/rt" GUARD_BROKER_LAUNCH=detached GH_TOKEN=gho_owner \
  PATH="$(path_without sbatch)" "$guard" "$@"; }
expect enter-usage fail '^guard enter: usage: guard enter <project>' -- en enter "$ep_"
expect broker-usage fail 'usage: guard broker setup' -- en broker
expect broker-status-down fail '^guard broker: not running' -- en broker status
# The host's read-only /opt mounts before a project, a home or a git directory under it, and at one path the
# writable bind comes after it and wins.
mount_order='import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import enter
flat = enter.mounts("/opt/home/u", sys.argv[2], sys.argv[3], [], False, sys.argv[2])
dst = flat[2::3]
print(" ".join(d for d in dst if d.startswith("/opt")), *[k for k, d in zip(flat[0::3], dst) if d == sys.argv[3]])'
expect enter-mount-order ok '^/opt /opt/proj /opt/home/u --bind$' -- python3 -c "$mount_order" "$here" "$tmp" /opt/proj
expect enter-mount-same-path ok '^/opt /opt /opt/home/u --ro-try --bind$' -- python3 -c "$mount_order" "$here" "$tmp" /opt
if ! bwrap --unshare-user --ro-bind / / true 2>/dev/null; then
  skip enter-sandbox "bwrap cannot make a user namespace on this host"
else
  expect enter-before-setup fail 'run guard broker setup once' -- en enter "$ep_" -- true
  expect broker-setup ok '^self-test: a fresh sandbox passed the pre-flight probe$' -- en broker setup
  expect broker-setup-profiles ok '^claude codex cursor-agent$' -- bash -c 'ls "$1" | paste -sd " "' _ "$tmp/xdg/guard/agents"
  expect broker-setup-again ok 'claude \(kept yours\)' -- en broker setup
  printf 'binary: true\nlogin: .fakelogin\nseed-json: seed.json keep\nnet: 127.0.0.1:%s\nenv: FAKE_AGENT=1\n' 9 \
    > "$tmp/xdg/guard/agents/fake"
  expect enter-refuses-home fail 'holds your home' -- en enter "$eh/.." -- true
  expect enter-refuses-secret fail 'overlaps .*/\.ssh' -- en enter "$eh/.ssh" -- true
  expect enter-unknown-profile fail '^guard enter: no profile nope' -- en enter "$ep_" --agent nope -- true
  expect enter-runs ok '^inside$' -- en enter "$ep_" -- bash -c 'echo inside'
  expect enter-starts-broker ok '^guard broker: running' -- en broker status
  expect enter-exit-code fail - -- en enter "$ep_" -- bash -c 'exit 3'
  expect enter-project-writable ok - -- en enter "$ep_" -- touch "$ep_/made-inside"
  expect enter-project-written ok - -- test -f "$ep_/made-inside"
  expect enter-real-paths ok "^$eh $ep_\$" -- en enter "$ep_" -- bash -c 'echo "$HOME $PWD"'
  expect enter-no-owner-files ok '^none$' -- en enter "$ep_" -- bash -c 'ls ~/.ssh ~/.config/gh ~/.fakelogin 2>/dev/null || echo none'
  expect enter-no-token ok '^unset empty$' -- en enter "$ep_" -- bash -c 'echo "${GH_TOKEN:-unset} $(tr -d "\0" < /proc/1/environ | wc -c | sed "s/^0$/empty/")"'
  expect enter-no-network ok '^lo$' -- en enter "$ep_" -- bash -c 'tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d " "'
  expect enter-harness-readonly fail 'Read-only file system' -- en enter "$ep_" -- touch "$here/bin/guard"
  expect enter-broker-state-hidden fail - -- en enter "$ep_" -- test -e "$eh/.local/state/guard/key"
  expect enter-sockets ok '^scheduler.sock$' -- en enter "$ep_" -- ls /run/guard
  expect enter-stand-in ok '^/run/guard-bin/sbatch$' -- en enter "$ep_" -- bash -c 'command -v sbatch'
  expect enter-no-scheduler fail 'this host has no scheduler' -- en enter "$ep_" -- squeue
  expect broker-status-refusal ok 'scheduler: queue' -- en broker status
  expect enter-profile-login ok '^login 1$' -- en enter "$ep_" --agent fake -- bash -c 'echo "$(cat ~/.fakelogin) $FAKE_AGENT"'
  expect enter-profile-seed ok '^\{"keep": 1\}$' -- bash -c 'tr -d " \n" < "$1/.local/share/guard/homes/fake/seed.json" | sed "s/:/: /"' _ "$eh"
  expect enter-no-tty-no-login ok 'no CLI login is bound for fake' -- en enter "$ep_" --agent fake --no-tty -- bash -c 'test ! -s ~/.fakelogin'
  # The proxy lets the profile's one host through and refuses every other, and the relay carries both from inside.
  python3 -c 'import socket, time; s = socket.create_server(("127.0.0.1", 0)); open("'"$tmp"'/port", "w").write(str(s.getsockname()[1])); s.listen(); time.sleep(60)' & lsn=$!
  for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
  sed -i "s/^net: .*/net: 127.0.0.1:$(cat "$tmp/port")/" "$tmp/xdg/guard/agents/fake"
  connect='import socket, sys; s = socket.create_connection(("127.0.0.1", 3128)); s.sendall(b"CONNECT %s HTTP/1.1\r\n\r\n" % sys.argv[1].encode()); print(s.recv(100).split(b"\r\n")[0].decode())'
  expect enter-net-allowed ok '^HTTP/1.1 200 ' -- en enter "$ep_" --agent fake -- python3 -c "$connect" "127.0.0.1:$(cat "$tmp/port")"
  expect enter-net-refused ok '^HTTP/1.1 403 ' -- en enter "$ep_" --agent fake -- python3 -c "$connect" example.com:443
  expect enter-net-env ok '^http://127.0.0.1:3128$' -- en enter "$ep_" --agent fake -- bash -c 'echo "$HTTPS_PROXY"'
  kill $lsn 2>/dev/null
  expect broker-status-net ok 'net: CONNECT example.com:443 is not on this session.s allowlist' -- en broker status
  # An origin inside the project is the agent's own repository, however it is spelled; one outside is kept.
  inside_check='import sys; sys.path.insert(0, sys.argv[1] + "/lib"); import broker_host as b; p = sys.argv[2]
print(" ".join(str(b.inside(u, p)) for u in (p + "/.mine.git", "file://" + p + "/.mine.git", "file://localhost" + p + "/.mine",
      ".mine", "file:///tmp/../" + p + "/x.git", p + "/../elsewhere.git", "git@github.com:o/r.git", "https://h/r.git", "ext::x %S")))'
  expect broker-origin-inside ok '^True True True True True False False False False$' -- python3 -c "$inside_check" "$here" "$ep_"
  expect enter-net-no-card ok 'warning: no package hosts this session: the broker cannot read guard/budget.card on main' -- en enter "$ep_" --agent fake -- true
  # The model gateway: an upstream that echoes every header back, the key beside its model file, and a profile whose
  # model: line routes an unattended session through it. The key reaches the upstream and never the sandbox.
  echo_up='import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        open(sys.argv[1] + "/seen", "a").write(self.headers.get("x-api-key", "none") + " " + self.headers.get("authorization", "none") + "\n")
        data = json.dumps({"path": self.path, "headers": dict(self.headers.items())}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    do_POST = do_GET
s = http.server.HTTPServer(("127.0.0.1", 0), H); open(sys.argv[1] + "/up-port", "w").write(str(s.server_port)); s.serve_forever()'
  python3 -c "$echo_up" "$tmp" & up=$!
  for _ in $(seq 50); do [ -s "$tmp/up-port" ] && break; sleep 0.1; done
  models=$tmp/xdg/guard/models
  printf 'upstream: http://127.0.0.1:%s/v1\nkey: echo.key\nheader: x-api-key\n' "$(cat "$tmp/up-port")" > "$models/echo"
  echo sk-ant-canary-0123456789abcdefghijklmnop > "$models/echo.key"; chmod 644 "$models/echo.key"
  printf 'model: echo GW_URL GW_KEY\n' >> "$tmp/xdg/guard/agents/fake"
  ask='import os, urllib.request; r = urllib.request.Request(os.environ["GW_URL"] + "/messages", headers={"x-api-key": os.environ["GW_KEY"], "Authorization": "Bearer mine"}); print(urllib.request.urlopen(r).read().decode())'
  expect enter-model-key-mode ok 'no model gateway: .*echo.key must be yours and mode 0600' -- en enter "$ep_" --agent fake --no-tty -- true
  chmod 600 "$models/echo.key"
  expect enter-model-placeholder ok '^http://127.0.0.1:3129 guard-gateway-adds-the-key$' -- en enter "$ep_" --agent fake --no-tty -- bash -c 'echo "$GW_URL $GW_KEY"'
  expect enter-model-scrubbed ok '"x-api-key": "\[removed by the gateway\]"' -- en enter "$ep_" --agent fake --no-tty -- python3 -c "$ask"
  expect enter-model-path ok '"path": "/v1/messages"' -- en enter "$ep_" --agent fake --no-tty -- python3 -c "$ask"
  expect enter-model-key-upstream ok '^sk-ant-canary-0123456789abcdefghijklmnop none$' -- tail -1 "$tmp/seen"
  expect enter-model-logged ok '"model": "echo".*"path": "/messages", "status": 200' -- tail -1 "$eh/.local/state/guard/model.jsonl"
  expect enter-model-tty-none ok '^unset$' -- en enter "$ep_" --agent fake -- bash -c 'echo "${GW_URL:-unset}"'
  expect enter-model-key-hidden fail - -- en enter "$ep_" --agent fake --no-tty -- grep -rqs sk-ant-canary "$eh" /run /tmp
  # The evaluation's proxy is the same handler: it pins the model and the seed, and logs the request in full.
  python3 "$here/eval/driver/proxy.py" --upstream "http://127.0.0.1:$(cat "$tmp/up-port")/v1" --alias pinned --seed 7 \
    --log "$tmp/proxy.jsonl" --port-file "$tmp/proxy-port" & px=$!
  for _ in $(seq 50); do [ -s "$tmp/proxy-port" ] && break; sleep 0.1; done
  post='import json, sys, urllib.request; r = urllib.request.Request("http://127.0.0.1:" + sys.argv[1] + "/v2/x", data=b"{\"model\": \"mine\"}", headers={"Content-Type": "application/json"}); print(json.loads(urllib.request.urlopen(r).read())["path"])'
  expect proxy-forwards ok '^/v1/v2/x$' -- python3 -c "$post" "$(cat "$tmp/proxy-port")"
  expect proxy-pins ok '"request": \{"model": "pinned", "seed": 7\}' -- tail -1 "$tmp/proxy.jsonl"
  kill "$px" "$up" 2>/dev/null
  expect box-gpu-usage fail '^box.sh: --gpu takes a device index$' -- "$here/lib/box.sh" --gpu x -- true
  expect box-gpu-missing fail '^box.sh: no /dev/nvidia99 on this host$' -- "$here/lib/box.sh" --gpu 99 -- true
  if [ -e /dev/nvidia0 ]; then
    expect box-gpu-bound ok '^nvidia0 nvidiactl$' -- bash -c '"$1" --no-tty --gpu 0 -- ls /dev | grep -x -e nvidia0 -e nvidiactl | paste -sd " "' _ "$here/lib/box.sh"
    expect box-gpu-probe-allows ok - -- "$here/lib/box.sh" --no-tty --gpu 0 --probe -- true
  else
    skip box-gpu-bound "no /dev/nvidia0 here"; skip box-gpu-probe-allows "no /dev/nvidia0 here"
  fi
  expect box-relay-name fail 'box.sh: --relay takes PORT or PORT:NAME.sock' -- "$here/lib/box.sh" --relay 1:../x -- true
  mkdir -p "$ep_/.claude"; echo '{"env": {"GH_TOKEN": "x", "EDITOR": "vi"}}' > "$ep_/.claude/settings.local.json"
  expect enter-says-planted-token ok 'settings.local.json sets GH_TOKEN; the sandbox sees a copy without them' -- en enter "$ep_" -- true
  expect enter-hides-planted-token fail - -- en enter "$ep_" -- grep -q GH_TOKEN "$ep_/.claude/settings.local.json"
  expect enter-keeps-other-settings ok '"EDITOR": "vi"' -- en enter "$ep_" -- cat "$ep_/.claude/settings.local.json"
  expect enter-leaves-original ok GH_TOKEN -- cat "$ep_/.claude/settings.local.json"
  rm -rf "$ep_/.claude"
  mkdir -p "$tmp/hidden-x"
  expect box-probe-refuses fail 'probe: hidden: .*hidden-x is the host.s own' -- "$here/lib/box.sh" --no-tty --ro "$tmp/hidden-x" "$tmp/hidden-x" --probe --hide "$tmp/hidden-x" -- true
  expect box-probe-nothing-started ok '^70$' -- bash -c '"$1" --no-tty --ro "$2" "$2" --probe --hide "$2" -- touch "$3/started" 2>/dev/null; echo $?' _ "$here/lib/box.sh" "$tmp/hidden-x" "$tmp"
  expect box-probe-nothing-started-file fail - -- test -e "$tmp/started"
  # Resources: a scope where the user manager delegates memory and pids, else prlimit; either way --tasks caps forks,
  # prlimit with a few to spare, since the count it starts from includes the ps that took it.
  forks='import os
n = 0
for _ in range(100):
    try:
        pid = os.fork()
    except OSError:
        continue
    if pid == 0:
        os.execvp("sleep", ["sleep", "5"])
    n += 1
print("forked", n)'
  # A scope caps the sandbox's tasks; prlimit caps none, since a per-uid cap starves the sandbox when other work runs.
  "$here/lib/box.sh" --no-tty --tasks 40 --record "$tmp/limits.jsonl" -- python3 -c "$forks" > "$tmp/forked" 2>&1
  expect box-tasks-capped ok '^(scope forked ([0-9]|[1-5][0-9])|prlimit forked 100)$' -- bash -c 'printf "%s %s\n" "$(sed -n "s/.*\"limits\": \"\([a-z]*\)\".*/\1/p" "$1" | tail -1)" "$(cat "$2")"' _ "$tmp/limits.jsonl" "$tmp/forked"
  expect box-limits-record ok '"limits": "scope".*"tasks_max": 40|"limits": "prlimit".*"nproc": null' -- tail -1 "$tmp/limits.jsonl"
  nproc_inside='u=$(GUARD_BOX_LIMITS=prlimit "$1" --no-tty --tasks 40 --record "$2" -- bash -c "ulimit -u")
echo "inside $u, outside $(ulimit -u)"; [ "$u" = "$(ulimit -u)" ] && tail -1 "$2" | grep -q "\"nproc\": null"'
  expect box-limits-prlimit-no-nproc ok '^inside [0-9a-z]+, outside [0-9a-z]+$' -- bash -c "$nproc_inside" _ "$here/lib/box.sh" "$tmp/limits.jsonl"
  expect box-limits-prlimit-why ok '"why": "GUARD_BOX_LIMITS=prlimit"' -- tail -1 "$tmp/limits.jsonl"
  # A user manager that answers on a cgroup v1 host, whose cgroup has no cgroup.controllers, falls back to prlimit.
  mkdir -p "$tmp/v1-bin"
  printf '#!/bin/sh\necho /no/such/cgroup\n' > "$tmp/v1-bin/systemctl"; printf '#!/bin/sh\nexit 1\n' > "$tmp/v1-bin/systemd-run"
  chmod +x "$tmp/v1-bin/systemctl" "$tmp/v1-bin/systemd-run"
  expect box-limits-cgroup-v1 ok '^inside$' -- env PATH="$tmp/v1-bin:$PATH" "$here/lib/box.sh" --no-tty --record "$tmp/limits.jsonl" -- bash -c 'echo inside'
  expect box-limits-cgroup-v1-why ok '"limits": "prlimit", "why": "the user manager does not delegate the memory and pids controllers"' -- tail -1 "$tmp/limits.jsonl"
  expect box-limits-usage fail '^box.sh: --tasks takes a count$' -- "$here/lib/box.sh" --tasks many -- true
  en enter "$ep_" -- sleep 4 & slow=$!
  for _ in $(seq 40); do en broker status 2>/dev/null | grep -q 'limits: [ap]' && break; sleep 0.1; done
  expect broker-status-limits ok '^    limits: (a systemd user scope, MemoryMax .* TasksMax 512: a wall|prlimit .* no cap on the sandbox.s processes)' -- en broker status
  wait "$slow"
  expect broker-stop ok '^guard broker: stopped' -- en broker stop
  expect broker-down-after-stop fail '^guard broker: not running' -- en broker status
  expect broker-launch-unknown fail 'GUARD_BROKER_LAUNCH=bogus is not one of systemd, tmux, detached' -- env HOME="$eh" GUARD_RUNTIME_DIR="$tmp/rt" GUARD_BROKER_LAUNCH=bogus "$guard" enter "$ep_" -- true
fi
