"""The logging proxy's record, state/model/requests.jsonl, read as the model requests an episode made.

Each request carries the whole history back to the model, so what is new in a request is what caused it: the tool
calls of the reply before it and their outputs. A request is harness-triggered when one of those calls is a harness
command or a read of the harness's files, or one of those outputs is a harness refusal. harness_reads counts the
calls that read or search a harness file. harness_share, the standing
cost metric, is harness-triggered requests over all requests. Ported from the first-qwen3.6-r2 report kit's
forensics.py. Standard library only."""
import json
import os
import re
from typing import NamedTuple, Optional

HARNESS = re.compile(r"guard|AGENTS\.md|\.agents/skills|SKILL\.md|FACTS\.md|question\.card|budget\.card|watch\.list|"
                     r"needs-you|ripples|preflight|incidents|\bgpg\b|card/|/run/guard|git tag")
REFUSAL = re.compile(r"^[\w ./-]{1,40}: refused\b|^remote: (FAIL\b|.*\brefused\b|.*check failed)|"
                     r"question\.card is not approved", re.M)


class Call(NamedTuple):
    number: int
    name: Optional[str]
    args: dict
    output: Optional[str]

    @property
    def rejected(self):
        """The client refused to start the command (Codex rejects rm -f, for one), so it never ran."""
        return (self.output or "").startswith("exec_command failed: CreateProcess")


class Request(NamedTuple):
    prompt_tokens: int
    cached_tokens: int
    output_tokens: int
    seconds: float
    calls: list
    outputs: list


def parse_args(text):
    try:
        args = json.loads(text or "")
    except ValueError:
        return {}
    return args if isinstance(args, dict) else {}


def read(path):
    """The POST requests in the log, in order, each with the calls (name, args) and outputs (text) new in it."""
    if not os.path.exists(path):
        return []
    out, seen_calls, seen_outputs = [], set(), set()
    with open(path) as f:
        for line in f:
            e = json.loads(line)
            if e.get("method") != "POST" or not isinstance(e.get("request"), dict):
                continue
            calls, outputs = [], []
            for item in e["request"].get("input") or []:
                if not isinstance(item, dict):
                    continue
                cid = item.get("call_id")
                if item.get("type") == "function_call" and cid not in seen_calls:
                    seen_calls.add(cid)
                    calls.append((cid, item.get("name"), parse_args(item.get("arguments"))))
                elif item.get("type") == "function_call_output" and cid not in seen_outputs:
                    seen_outputs.add(cid)
                    outputs.append((cid, str(item.get("output") or "")))
            u = e.get("usage") or {}
            out.append(Request(
                prompt_tokens=u.get("input_tokens", u.get("prompt_tokens", 0)) or 0,
                cached_tokens=(u.get("input_tokens_details") or {}).get("cached_tokens") or 0,
                output_tokens=u.get("output_tokens", u.get("completion_tokens", 0)) or 0,
                seconds=e.get("seconds") or 0.0, calls=calls, outputs=outputs))
    return out


def calls(requests):
    """Every tool call the requests carried back, numbered from 1 in order, with its output when one came back. The
    calls in the last reply, which no request carried back, are not among them."""
    outputs = {cid: text for r in requests for cid, text in r.outputs}
    numbered = [(cid, name, args) for r in requests for cid, name, args in r.calls]
    return [Call(n, name, args, outputs.get(cid)) for n, (cid, name, args) in enumerate(numbered, 1)]


def command(args):
    cmd = args.get("cmd")
    return " ".join(map(str, cmd)) if isinstance(cmd, list) else cmd if isinstance(cmd, str) else ""


def is_harness_call(name, args):
    return name == "exec_command" and bool(HARNESS.search(command(args)))


READERS = {"cat", "sed", "head", "tail", "nl", "less", "more", "grep", "rg", "ls", "find", "awk", "wc", "cut", "bat", "tree"}


def is_harness_read(name, args):
    """A call that reads a harness file or searches for one: a file-reading command whose own words name the harness.
    `guard/run preflight` and `guard needs-you` act on the harness and are not reads; `cat guard/budget.card` is."""
    if name != "exec_command":
        return False
    cmd = command(args)
    if "<<" in cmd or ">" in re.sub(r"\d?&?>+\s*(/dev/null|&\d)", "", cmd):
        return False
    for part in re.split(r"&&|\|\||;|\|", cmd):
        words = part.split()
        while words and re.fullmatch(r"\w+=\S*", words[0]):
            words = words[1:]
        if words and os.path.basename(words[0]) in READERS and HARNESS.search(part):
            return True
    return False


def is_harness_refusal(text):
    return bool(REFUSAL.search(text))


def harness_triggered(request):
    return (any(is_harness_call(name, args) for _, name, args in request.calls)
            or any(is_harness_refusal(text) for _, text in request.outputs))


def costs(path):
    """The cost fields of a verdict row, from the proxy log at path."""
    rs = read(path)
    return {"requests": len(rs), "input_tokens": sum(r.prompt_tokens for r in rs),
            "output_tokens": sum(r.output_tokens for r in rs),
            "max_prompt_tokens": max((r.prompt_tokens for r in rs), default=0),
            "cached_tokens": sum(r.cached_tokens for r in rs), "model_seconds": round(sum(r.seconds for r in rs), 3),
            "harness_requests": sum(harness_triggered(r) for r in rs),
            "harness_reads": sum(is_harness_read(name, args) for r in rs for _, name, args in r.calls)}
