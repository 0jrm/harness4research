"""The logging proxy's record, state/model/requests.jsonl, read as the model requests an episode made.

Each request carries the whole history back to the model, so what is new in a request is what caused it: the tool
calls of the reply before it and their outputs. A request is harness-triggered when one of those calls is a harness
command or a read of the harness's files, or one of those outputs is a harness refusal. harness_share, the standing
cost metric, is harness-triggered requests over all requests. Ported from the first-qwen3.6-r2 report kit's
forensics.py. Standard library only."""
import json
import os
import re
from typing import NamedTuple, Optional

HARNESS = re.compile(r"guard|AGENTS\.md|\.agents/skills|SKILL\.md|FACTS\.md|question\.card|budget\.card|watch\.list|"
                     r"needs-you|ripples|preflight|incidents|\bgpg\b|card/|/run/guard|git tag")
REFUSAL = re.compile(r"^[\w ./-]{1,40}: refused\b|^remote: (FAIL\b|.*\brefused\b|.*check failed)|"
                     r"question\.card is not approved|^(?:remote: )?H4R-[A-Z][0-9]{2} ", re.M)


class Call(NamedTuple):
    number: int
    name: Optional[str]
    args: dict
    output: Optional[str]

    @property
    def rejected(self):
        """The client refused to start the command (Codex rejects rm -f, for one), so it never ran."""
        return (self.output or "").startswith("exec_command failed: CreateProcess")


COMPACTION = "CONTEXT CHECKPOINT COMPACTION"


class Request(NamedTuple):
    prompt_tokens: int
    cached_tokens: int
    output_tokens: int
    seconds: float
    calls: list
    outputs: list
    compaction: bool = False
    unanswered: tuple = ()


def is_compaction(items):
    """Codex compacts its context by sending the history with a last user message asking for a hand-off summary
    ("You are performing a CONTEXT CHECKPOINT COMPACTION..."); the next request starts over from that summary."""
    last = items[-1] if items and isinstance(items[-1], dict) else {}
    return last.get("type") == "message" and last.get("role") == "user" and any(
        COMPACTION in (part.get("text") or "") for part in last.get("content") or [] if isinstance(part, dict))


def reply_calls(response):
    """The function calls in a streamed reply (the proxy keeps its server-sent events as text), as (id, name, args)."""
    found = []
    for block in (response if isinstance(response, str) else "").split("\n\n"):
        data = next((line[5:] for line in block.split("\n") if line.startswith("data:")), "")
        if '"response.output_item.done"' not in data:
            continue
        try:
            item = json.loads(data).get("item") or {}
        except ValueError:
            continue
        if item.get("type") == "function_call":
            found.append((item.get("call_id"), item.get("name"), parse_args(item.get("arguments"))))
    return found


def parse_args(text):
    try:
        args = json.loads(text or "")
    except ValueError:
        return {}
    return args if isinstance(args, dict) else {}


def read(path):
    """The POST requests in the log, in order, each with the calls (name, args) and outputs (text) new in it, and
    whether it asked for a compaction. The last request also holds the calls of its reply, which no request carried
    back (unanswered): the episode ended while they ran or before they started."""
    if not os.path.exists(path):
        return []
    out, seen_calls, seen_outputs, last_response = [], set(), set(), None
    with open(path) as f:
        for line in f:
            e = json.loads(line)
            if e.get("method") != "POST" or not isinstance(e.get("request"), dict):
                continue
            calls, outputs = [], []
            items = [i for i in e["request"].get("input") or [] if isinstance(i, dict)]
            for item in items:
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
                seconds=e.get("seconds") or 0.0, calls=calls, outputs=outputs, compaction=is_compaction(items)))
            last_response = e.get("response")
    if out:
        unanswered = tuple(c for c in reply_calls(last_response) if c[0] not in seen_calls)
        out[-1] = out[-1]._replace(unanswered=unanswered)
    return out


def calls(requests):
    """Every tool call the requests carried back, numbered from 1 in order, with its output when one came back, then
    the calls of the last reply, which no request carried back, with no output."""
    outputs = {cid: text for r in requests for cid, text in r.outputs}
    numbered = [(cid, name, args) for r in requests for cid, name, args in (*r.calls, *r.unanswered)]
    return [Call(n, name, args, outputs.get(cid)) for n, (cid, name, args) in enumerate(numbered, 1)]


def command(args):
    cmd = args.get("cmd")
    return " ".join(map(str, cmd)) if isinstance(cmd, list) else cmd if isinstance(cmd, str) else ""


def is_harness_call(name, args):
    return name == "exec_command" and bool(HARNESS.search(command(args)))


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
            "compactions": sum(r.compaction for r in rs)}
