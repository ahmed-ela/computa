"""Loopback Responses fixture for CodexDesktopSidebarTests' two-app model switch."""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

folder = Path(sys.argv[1])
port = int(sys.argv[2]) if len(sys.argv) > 2 else 0


class Responses(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("input", [])
        user_text = [
            part.get("text", "")
            for item in messages if item.get("role") == "user"
            for part in item.get("content", []) if isinstance(part, dict)
        ]
        prompt = next((text for text in reversed(user_text) if re.fullmatch(r"SWITCH_[A-Fa-f0-9-]{36}", text)), None)
        text = "PROBE-REPLY-1"
        if prompt:
            previous = any(
                part.get("text") == text for item in messages if item.get("role") == "assistant"
                for part in item.get("content", []) if isinstance(part, dict)
            )
            receipt = {"model": request["model"], "prompt": prompt, "hasOriginalReply": str(previous).lower()}
            (folder / "switch-receipt").write_text(json.dumps(receipt))
            text = "PROBE-REPLY-AFTER-SWITCH"
        elif "Fixture one" in user_text:
            (folder / "initial-model").write_text(request["model"])
        uid = str(time.time_ns())
        item = {"type": "message", "role": "assistant", "id": "msg_" + uid, "status": "completed",
                "phase": "final_answer", "content": [{"type": "output_text", "text": text, "annotations": []}]}
        reply = {"id": "resp_" + uid, "object": "response", "created_at": int(time.time()), "model": request["model"],
                 "status": "completed", "output": [item], "usage": {"input_tokens": 20, "output_tokens": 8, "total_tokens": 28}}
        events = [{"type": "response.created", "response": dict(reply, status="in_progress", output=[])},
                  {"type": "response.output_item.done", "output_index": 0, "item": item},
                  {"type": "response.completed", "response": reply}]
        body = "".join(f"event: {e['type']}\ndata: {json.dumps(dict(e, sequence_number=i))}\n\n"
                       for i, e in enumerate(events)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


with ThreadingHTTPServer(("127.0.0.1", port), Responses) as server:
    (folder / "endpoint").write_text(f"http://127.0.0.1:{server.server_port}/v1")
    server.serve_forever()
