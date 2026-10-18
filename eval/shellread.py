"""Shell command text from the tool-call log, read without running it: its simple commands, its here-documents, and
the script files it writes, copies and runs. The t1 and t3 scorers use it to follow a command into the scripts it
runs. Standard library only."""
import os
import re
import shlex

WRAPPERS = {"time", "timeout", "nohup", "env", "nice", "stdbuf", "exec", "command", "builtin", "setsid"}
SHELLS = {"bash", "sh", "zsh", "dash"}
PYTHON = re.compile(r"python[\d.]*")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
AGENT_PATHS = ("./", "../", "~/", "/home/agent/", "/tmp/")
REDIRECT = re.compile(r"(?<![<>&\d])>>?\s*([^\s;&|<>()]+)")


def split_commands(text):
    """The simple commands in shell text: split at unquoted ;, &, |, newlines and parentheses."""
    parts, cur, quote, i = [], [], None, 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < len(text):
                cur.append(text[i:i + 2])
                i += 2
                continue
            quote = None if ch == quote else quote
            cur.append(ch)
        elif ch in "'\"":
            quote = ch
            cur.append(ch)
        elif ch == "\\" and i + 1 < len(text):
            cur.append(text[i:i + 2])
            i += 2
            continue
        elif ch in ";&|\n()":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def heredocs(cmd):
    """cmd without its here-document bodies, and each body as (the text before its << on the opening line, the rest
    of that line, the body)."""
    lines, kept, docs = cmd.split("\n"), [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = HEREDOC.search(line)
        kept.append(HEREDOC.sub("", line))
        i += 1
        if not m:
            continue
        body = []
        while i < len(lines) and lines[i].strip() != m.group(2):
            body.append(lines[i])
            i += 1
        i += 1
        docs.append((line[:m.start()], line[m.end():], "\n".join(body)))
    return "\n".join(kept), docs


def fed_to(before):
    """The program a here-document feeds, from the text before its <<: python3 in `python3 - <<EOF`."""
    words = before.split()
    return os.path.basename(words[-2] if len(words) > 1 and words[-1] == "-" else words[-1]) if words else ""


def words_of(simple):
    """The words of a simple command from its program on: leading assignments and wrappers such as timeout 120 go, and
    env -u NAME with its name."""
    try:
        words = shlex.split(simple)
    except ValueError:
        words = simple.split()
    while words and ("=" in words[0] and not words[0].startswith("-") or words[0] in WRAPPERS
                     or re.fullmatch(r"-\S*|\d+[smhd]?", words[0])):
        words = words[2:] if words[0] in ("-u", "--unset") else words[1:]
    return words


def inline_code(args):
    """The code after -c (or a flag cluster ending in c, such as -lc), or None."""
    for i, a in enumerate(args):
        if re.fullmatch(r"-\w*c", a):
            return args[i + 1] if i + 1 < len(args) else ""
    return None


def script_run(words):
    """("python" or "shell", path) when the simple command runs a script file, else None: an interpreter given a
    file, source, or a program named *.py or *.sh or found under the agent's own paths (AGENT_PATHS); /usr/bin/sbatch
    is a system program. A command under a scheduler (sbatch run.sh) runs no file here: its head is the scheduler."""
    if not words:
        return None
    head, args = os.path.basename(words[0]), words[1:]
    if PYTHON.fullmatch(head) or head in SHELLS:
        if inline_code(args) is not None or "-m" in args:
            return None
        script = next((a for a in args if not a.startswith("-")), "")
        return ("python" if PYTHON.fullmatch(head) else "shell", script) if script else None
    if head in ("source", ".") and args:
        return "shell", args[0]
    if head.endswith((".py", ".sh")) or words[0].startswith(AGENT_PATHS):
        return "python" if head.endswith(".py") else "shell", words[0]
    return None


def scripts_run(cmd):
    """Every (kind, path) a command runs as a script file, here-document bodies left out."""
    text, _ = heredocs(cmd)
    return [run for run in map(script_run, map(words_of, split_commands(text))) if run]


class Scripts:
    """The agent's script files as the tool calls go by. A file's body is the one the log last wrote to it by
    here-document (cat > f <<EOF, tee f <<EOF) or copied into it with cp or mv, else the file in the final tree, else
    None: no record holds it. origin names the file a copy came from, so a copy of sim.py is still sim.py."""

    def __init__(self, ep):
        self.ep, self.written, self.origins = ep, {}, {}

    def note(self, cmd):
        """Record the files a command writes."""
        text, docs = heredocs(cmd)
        for before, after, body in docs:
            simple = (split_commands(before) or [""])[-1]
            head = (words_of(simple) or [""])[0]
            if head == "cat":
                targets = REDIRECT.findall(before + " " + after)
            elif head == "tee":
                targets = [w for w in words_of(simple)[1:] if not w.startswith("-")]
            else:
                continue
            for target in targets:
                self.written[os.path.basename(target)] = body
                self.origins.pop(os.path.basename(target), None)
        for simple in split_commands(text):
            words = [w for w in words_of(simple) if not w.startswith("-")]
            if len(words) == 3 and words[0] in ("cp", "mv"):
                src, dst = words[1], words[2]
                name = os.path.basename(src) if dst.endswith(("/", ".")) else os.path.basename(dst)
                self.origins[name] = self.origin(src)
                body = self.body(src)
                if body is not None:
                    self.written[name] = body

    def origin(self, path):
        name = os.path.basename(path)
        return self.origins.get(name, name)

    def body(self, path):
        name = os.path.basename(path)
        if name in self.written:
            return self.written[name]
        project = "/home/agent/" + self.ep.meta["project"] + "/"
        for prefix in (project, "~/" + self.ep.meta["project"] + "/", "./"):
            if path.startswith(prefix):
                path = path[len(prefix):]
        found = self.ep.read(path)
        return found if found is not None else self.ep.read(name)
