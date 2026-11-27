#!/usr/bin/env python3
"""Throwaway OpenAI-compatible LLM stub for end-to-end sandbox tests.

Serves just enough of the Chat Completions API for an agent turn:
  GET  /v1/models             -> one canned model
  POST /v1/chat/completions   -> a canned assistant message

Reply text embeds a token derived from the LAST user message so tests can
prove the request body actually made the round trip: the model "answers"
'PONG' when the last user message contains 'PONG', otherwise a fixed line.

Stdlib only. Usage: stub-llm.py [port]   (default 8080, binds 127.0.0.1)
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
MODEL = "stub-model"


def completion_reply(body: bytes) -> str:
    try:
        req = json.loads(body)
        msgs = req.get("messages") or []
        last_user = next((m.get("content", "") for m in reversed(msgs)
                          if m.get("role") == "user"), "")
        if isinstance(last_user, list):  # content-part arrays
            last_user = " ".join(p.get("text", "") for p in last_user if isinstance(p, dict))
    except Exception:
        last_user = ""
    if "PONG" in str(last_user):
        return "PONG"
    return "stub-llm: no PONG in last user message"


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send_json({"object": "list",
                             "data": [{"id": MODEL, "object": "model", "owned_by": "stub"}]})
        elif self.path == "/health":
            self._send_json({"ok": True})
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self._send_json({"error": "not found"}, 404)
            return
        text = completion_reply(body)
        stream = False
        try:
            stream = bool(json.loads(body).get("stream"))
        except Exception:
            pass
        if stream:
            chunk = {"choices": [{"delta": {"content": text}, "index": 0}]}
            final = {"choices": [{"delta": {}, "index": 0, "finish_reason": "stop"}]}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for obj in (chunk, final):
                self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            return
        self._send_json({
            "id": "stub-1", "object": "chat.completion", "model": MODEL,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })

    def log_message(self, fmt, *args):
        sys.stderr.write("[stub-llm] " + (fmt % args) + "\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
