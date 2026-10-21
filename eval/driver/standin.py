"""A stand-in for Codex's command tools inside an episode's sandbox, driven by eval/replay.py with no model.

One JSON request per stdin line, one JSON reply per stdout line:
  {"op": "exec", "id": S, "cmd": C, "workdir": W, "login": true, "tty": false, "wait": seconds}
  {"op": "poll", "id": S, "chars": C, "wait": seconds}
  {"op": "end"}
exec starts `bash -lc C` (or -c) as Codex's exec_command does, with stdin closed unless tty; poll is write_stdin. Each waits up to
`wait` seconds for the process to exit and replies {"exit": code or null, "output": what it printed since the last
reply}. A process still running stays a session under the id the record gave it; a poll of one that has exited
replies with its exit code and no output, since in the record it was still running there."""
import json
import os
import signal
import subprocess
import sys
import threading
import time

ENV = {"NO_COLOR": "1", "TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat"}
MAX_OUTPUT = 256 * 1024


class Session:
    def __init__(self, cmd, workdir, login, tty):
        self.proc = subprocess.Popen(["bash", "-lc" if login else "-c", cmd], cwd=workdir,
                                     stdin=subprocess.PIPE if tty else subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                                     env={**os.environ, **ENV})
        self.chunks, self.lock = [], threading.Lock()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for chunk in iter(lambda: self.proc.stdout.read1(65536), b""):
            with self.lock:
                self.chunks.append(chunk)

    def reply(self, wait):
        deadline = time.time() + wait
        while self.proc.poll() is None and time.time() < deadline:
            time.sleep(0.05)
        code = self.proc.poll()
        if code is not None:
            self.reader.join(2)
        with self.lock:
            out, self.chunks = b"".join(self.chunks), []
        return {"exit": code, "output": out[-MAX_OUTPUT:].decode("utf-8", "replace")}


def main(project):
    sessions, finished = {}, {}
    for line in sys.stdin:
        req = json.loads(line)
        if req["op"] == "end":
            break
        if req["op"] == "exec":
            workdir = req.get("workdir") or project
            if not os.path.isdir(workdir):
                reply = {"exit": None, "output": "", "error": f"no directory {workdir}"}
            else:
                s = Session(req["cmd"], workdir, req.get("login", True), req.get("tty", False))
                reply = s.reply(req["wait"])
                if reply["exit"] is None:
                    sessions[req["id"]] = s
                else:
                    finished[req["id"]] = reply["exit"]
        else:
            s = sessions.get(req["id"])
            if s is None and req["id"] in finished:
                reply = {"exit": finished[req["id"]], "output": ""}
            elif s is None:
                reply = {"exit": None, "output": "", "error": "unknown session"}
            else:
                if req.get("chars") and s.proc.stdin:
                    try:
                        s.proc.stdin.write(req["chars"].encode())
                        s.proc.stdin.flush()
                    except (BrokenPipeError, ValueError):
                        pass
                reply = s.reply(req["wait"])
                if reply["exit"] is not None:
                    del sessions[req["id"]]
                    finished[req["id"]] = reply["exit"]
        print(json.dumps(reply), flush=True)
    end_all()


def end_all():
    """Kill every other process in the sandbox, background work included, so that nothing outlives the replay."""
    for pid in [int(p) for p in os.listdir("/proc") if p.isdigit()]:
        if pid not in (1, os.getpid()):
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    while True:
        try:
            if os.waitpid(-1, 0)[0] == 0:
                break
        except ChildProcessError:
            break


if __name__ == "__main__":
    main(sys.argv[1])
