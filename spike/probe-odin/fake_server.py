#!/usr/bin/env python3
# Local fake of the Copilot Messages route, for step 1 only. Binds 127.0.0.1 and nothing else.
# The bearer token picks the reply, so each fixture auth file drives one status:
#   fixture-ok-token 200, fixture-429-token 429, fixture-401-token 401, fixture-500-token 500.
# It checks the request shape like pi sends it and answers 400 when a check fails.
# Usage: python3 fake_server.py <port>   (logs one line per request: no tokens, no bodies)
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PROMPT = "Reply with the single word OK."
OK_BODY = {
    "id": "msg_fixture", "type": "message", "role": "assistant", "model": "claude-haiku-5.5",
    "content": [{"type": "text", "text": "OK"}], "stop_reason": "end_turn",
    "usage": {"input_tokens": 12, "output_tokens": 2},
}
ERRORS = {
    "fixture-429-token": (429, {"type": "error", "error": {"type": "rate_limit_error", "message": "fixture"}}, {"Retry-After": "30"}),
    "fixture-401-token": (401, {"type": "error", "error": {"type": "authentication_error", "message": "fixture"}}, {}),
    "fixture-500-token": (500, {"type": "error", "error": {"type": "api_error", "message": "fixture"}}, {}),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # keep stdout to our own lines
        pass

    def _send(self, status, obj, extra=None):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length)
        auth = self.headers.get("authorization", "")
        token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        status, obj, extra = 200, OK_BODY, {}

        ok_shape = (
            self.path == "/v1/messages"
            and self.headers.get("x-initiator") == "user"
            and self.headers.get("openai-intent") == "conversation-edits"
            and self.headers.get("copilot-integration-id") == "vscode-chat"
            and self.headers.get("anthropic-version") == "2023-06-01"
        )
        try:
            body = json.loads(raw)
            ok_body = body.get("model") == "claude-haiku-5.5" and body["messages"][0]["content"] == PROMPT
        except (ValueError, KeyError, IndexError, TypeError):
            ok_body = False
        if not (ok_shape and ok_body):
            status, obj = 400, {"error": "request shape check failed"}
        elif token in ERRORS:
            status, obj, extra = ERRORS[token]
        elif token != "fixture-ok-token":
            status, obj = 403, {"error": "unknown fixture token"}

        print(f"POST {self.path} {status}", flush=True)
        self._send(status, obj, extra)


if __name__ == "__main__":
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
