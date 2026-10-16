#!/usr/bin/env python3
"""usage: proxy.py --upstream URL --alias NAME --log FILE (--port-file FILE | --unix PATH) [--seed N] [--sampling JSON]
                [--fold-developer] [--text-into-reasoning]

A logging proxy between one episode's agent client and the model server. It runs outside the sandbox, on
127.0.0.1 at a free port, which it writes to --port-file once it listens, or on the unix socket --unix, which
the sandbox binds in place of a network (driver/netrelay.py carries the client's TCP to it). For every request it:

- pins the model: a JSON body's "model" becomes --alias, so the agent cannot pick another GPU or model;
- adds a seed: with --seed, a body without "seed" gets one, as the model host asked for per-request seeds;
- pins sampling: with --sampling '{"temperature": 1.0, ...}', every body gets those values, replacing the client's,
  so every model runs at settings the question card chose rather than at its server's defaults;
- folds the developer role: with --fold-developer, the leading developer and system messages of a Responses
  request become one system message, and a later developer message becomes a user message, for chat templates
  such as Qwen's that refuse the developer role and a system message anywhere but first;
- moves the agent's own past text into its reasoning: with --text-into-reasoning, an assistant message that follows
  a reasoning item in a Responses request is appended to that reasoning. vLLM 0.21 turns every Responses item into
  its own assistant turn, so a model turn of reasoning, a sentence and tool calls reached the model as separate
  turns, some ending in plain text, and Qwen learned to end its turns with a sentence and no tool call. The same
  flag gives the first function call after each reasoning item an id with vLLM's "mcp_" prefix, the one case where
  vLLM merges a reasoning item and the tool call after it into one assistant turn; only the first, because the merge
  replaces the turn's tool call, so a second would erase the first;
- streams the reply back unchanged, server-sent events included;
- appends one JSON line to --log: the time, path, status, the request as sent upstream, the reply as received,
  the token usage the reply reports, and the repairs it made to that request, with counts.

The model host keeps no request bodies for shared traffic, so this log is the record of what the model saw and
said. The forwarding is lib/gateway.py's, the broker's model gateway, with no key. Standard library only.
"""
import argparse
import http.server
import json
import os
import sys
import threading

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import gateway  # noqa: E402  lib/gateway.py, the broker's model gateway


def fold_developer(items):
    """Responses input items with the leading developer and system messages merged into one system message, and
    any later developer message sent as a user message."""
    def text(item):
        content = item.get("content")
        return content if isinstance(content, str) else "\n\n".join(c.get("text", "") for c in content or [])
    lead = 0
    while lead < len(items) and items[lead].get("type", "message") == "message" \
            and items[lead].get("role") in ("developer", "system"):
        lead += 1
    folded = []
    if lead:
        joined = "\n\n".join(text(i) for i in items[:lead])
        folded.append({"type": "message", "role": "system", "content": [{"type": "input_text", "text": joined}]})
    for item in items[lead:]:
        if item.get("type", "message") == "message" and item.get("role") == "developer":
            item = dict(item, role="user")
        folded.append(item)
    return folded


def text_into_reasoning(items):
    """Responses input items with each assistant message that follows a reasoning item appended to that item's text,
    where vLLM reads it (content[0], else summary[0]); other assistant messages stay as they are."""
    out = []
    for item in items:
        prev = out[-1] if out else None
        if item.get("type", "message") == "message" and item.get("role") == "assistant" \
                and prev is not None and prev.get("type") == "reasoning" and (prev.get("content") or prev.get("summary")):
            content = item.get("content")
            text = (content if isinstance(content, str) else "".join(c.get("text", "") for c in content or [])).strip()
            if text:
                prev = json.loads(json.dumps(prev))
                part = (prev.get("content") or prev.get("summary"))[0]
                part["text"] = part.get("text", "") + "\n\n" + text
                out[-1] = prev
            continue
        if item.get("type") == "function_call" and prev is not None and prev.get("type") == "reasoning":
            item = dict(item, id="mcp_" + str(item.get("id") or item.get("call_id")))
        out.append(item)
    return out


class Handler(gateway.ModelHandler):
    """lib/gateway.py's handler, with the evaluation's repairs and every request and reply in full in the log."""

    def rewrite(self, body):
        cfg = self.server.cfg
        self.request_json, self.repairs = None, {}
        if not body or "json" not in (self.headers.get("Content-Type") or ""):
            return body
        try:
            request_json = json.loads(body)
        except ValueError:
            return body
        self.request_json = request_json
        if not (isinstance(request_json, dict) and self.command == "POST"):
            return body
        if "model" in request_json:
            request_json["model"] = cfg.alias
        if cfg.seed is not None and "seed" not in request_json:
            request_json["seed"] = cfg.seed
        request_json.update(cfg.sampling)
        items = request_json.get("input")
        if cfg.fold_developer and isinstance(items, list):
            folded = fold_developer(items)
            self.repairs["fold_developer"] = sum(1 for i in items if i.get("type", "message") == "message"
                                                 and i.get("role") == "developer")
            items = request_json["input"] = folded
        if cfg.text_into_reasoning and isinstance(items, list):
            moved = text_into_reasoning(items)
            self.repairs["text_into_reasoning"] = len(items) - len(moved)
            self.repairs["mcp_merge"] = sum(1 for i in moved if str(i.get("id", "")).startswith("mcp_")) \
                - sum(1 for i in items if str(i.get("id", "")).startswith("mcp_"))
            request_json["input"] = moved
        return json.dumps(request_json).encode()

    def entry(self, entry, body, received):
        request_json = getattr(self, "request_json", None)
        return {**entry, "path": self.path,
                "request": request_json if request_json is not None else body.decode(errors="replace"),
                "response": received, "repairs": getattr(self, "repairs", {})}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--alias", required=True)
    ap.add_argument("--log", required=True)
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--port-file")
    where.add_argument("--unix")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--sampling", type=json.loads, default={})
    ap.add_argument("--fold-developer", action="store_true")
    ap.add_argument("--text-into-reasoning", action="store_true")
    ap.add_argument("--timeout", type=float, default=600)
    cfg = ap.parse_args()
    if cfg.unix:
        if os.path.exists(cfg.unix):
            os.unlink(cfg.unix)
        server = gateway.UnixModelServer(cfg.unix, Handler)
    else:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        with open(cfg.port_file, "w") as f:
            f.write(str(server.server_address[1]))
    server.daemon_threads = True
    server.cfg, server.lock = cfg, threading.Lock()
    server.upstream, server.key, server.header = cfg.upstream, None, "authorization"
    server.upstream_timeout = cfg.timeout

    def record(entry):
        with server.lock:
            with open(cfg.log, "a") as f:
                f.write(json.dumps(entry) + "\n")
    server.record = record
    server.serve_forever()


if __name__ == "__main__":
    main()
