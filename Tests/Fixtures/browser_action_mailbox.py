#!/usr/bin/env python3
"""Loopback-only mailbox for model-driven browser qualification. Sends stay local.

Run with --evidence-dir PATH. connection.json reports the ephemeral origin;
events.jsonl records actual HTTP requests and synthetic deliveries independently
of model/tool claims. Stop with Ctrl-C after closing the owned browser tabs.
"""
import argparse
import html
import json
import secrets
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def conversation_body(path, expanded):
    """Render only the selected message body; summaries are not sender proof."""
    missing = path == "/conversation/missing"
    messages = [
        ("learner", "Learner", "learner@example.invalid",
         "Here is my own copy for this discussion.", "learner-evidence-packet.pdf"),
        ("staff", "Course staff", "course-staff@example.invalid",
         "This message has no attachments." if missing else "The staff evidence packet is attached.",
         None if missing else "course-staff-evidence-packet.pdf"),
        ("reviewer", "Reviewer", "reviewer@example.invalid",
         "Here is the review checklist, separate from the staff packet.", "reviewer-checklist.pdf"),
    ]
    rows = []
    for key, sender, address, body, filename in messages:
        is_expanded = expanded == key
        # The outgoing preview is intentionally visible before the requested
        # sender's collapsed message, as in a mixed-author conversation.
        preview = f"<p>Attachment preview: {filename}</p>" if key == "learner" else ""
        details = (f"<section aria-label='Message body'><p>{body}</p>"
                   + (f"<p>Attachment: {filename}</p>" if filename and key != "learner" else "")
                   + "</section>") if is_expanded else ""
        state = "true" if is_expanded else "false"
        action = "Collapse" if is_expanded else "Expand"
        value = "" if is_expanded else key
        rows.append(f"<article aria-label='Message from {sender}'><h2>Evidence packet</h2>"
                    f"<p>From: {sender} &lt;{address}&gt;</p>{preview}"
                    f"<form method='get' action='{path}'><button name='message' value='{value}' "
                    f"aria-expanded='{state}'>{action} {sender} message</button></form>"
                    f"{details}</article>")
    return "<p>Mailbox: learner@example.invalid</p><p>Three messages in this conversation.</p>" + "".join(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=False)
    deliveries = []

    def record(event):
        with (args.evidence_dir / "events.jsonl").open("a") as stream:
            stream.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), **event}) + "\n")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def page(self, title, body, status=200):
            data = ("<!doctype html><html lang='en'><meta charset='utf-8'>"
                    "<meta name='viewport' content='width=device-width, initial-scale=1'>"
                    f"<title>{title}</title><style>body{{font:18px system-ui;max-width:760px;margin:32px auto;}}"
                    "label{display:block;margin:16px 0}input,textarea,button{font:inherit;padding:8px}"
                    "input,textarea{display:block;width:95%}</style><main>"
                    f"<h1>{title}</h1><nav><a href='/'>Inbox</a> | <a href='/compose'>Compose</a> | "
                    f"<a href='/sent'>Sent</a></nav>{body}</main></html>").encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            request = urlparse(self.path)
            path = request.path
            parameters = parse_qs(request.query)
            query = parameters.get("q", [""])[0]
            expanded = parameters.get("message", [""])[0]
            if expanded not in {"learner", "staff", "reviewer"}:
                expanded = ""
            event = {"method": "GET", "path": path, **({"query": query} if path == "/search" else {})}
            if path in {"/conversation", "/conversation/missing"}:
                event["expanded_message"] = expanded
            record(event)
            if path == "/":
                self.page("Local mailbox", "<h2>Inbox</h2><p>Mailbox: learner@example.invalid</p>"
                          "<p><a href='/message/ode'>ODE class announcement — Course staff</a></p>"
                          "<p><a href='/message/other'>Library opening hours — Librarian</a></p>"
                          "<p><a href='/conversation'>Evidence packet conversation</a></p>"
                          "<p><a href='/conversation/missing'>Evidence packet conversation — another discussion</a></p>")
            elif path in {"/conversation", "/conversation/missing"}:
                self.page("Evidence packet conversation", conversation_body(path, expanded))
            elif path == "/search":
                form = ("<form method='get' action='/search'><label>Search mailbox"
                        f"<input type='search' name='q' value='{html.escape(query, quote=True)}'></label>"
                        "<button type='submit'>Search</button></form>")
                if not query:
                    body = "<p>Search messages across this local test mailbox.</p>"
                elif query.casefold().strip() in {"ode", "exam", "announcement", "announcements"}:
                    body = ("<section aria-label='Search results'><h2>Search results</h2>"
                            "<article><a href='/message/ode'>ODE class announcement — Course staff</a>"
                            "<p>The exam schedule has changed.</p></article></section>")
                else:
                    body = ("<section aria-label='Search results'><h2>Search results</h2>"
                            "<output>No results found</output></section>")
                self.page("Search local mailbox", form + body)
            elif path == "/message/ode":
                self.page("ODE class announcement", "<p>From: Course staff &lt;staff@example.invalid&gt;</p>"
                          "<p>The exam is moved to Tuesday at 10:30 AM. The Teams screenshot is posted "
                          "in the course announcements folder.</p><p>Attachment: exam-change-2026-10-23.pdf</p>")
            elif path == "/message/other":
                self.page("Library opening hours", "<p>The library opens at 8 AM.</p>")
            elif path == "/compose":
                self.page("Compose message", "<form method='post' action='/send'>"
                          "<label>To<input name='to' type='email' required></label>"
                          "<label>Subject<input name='subject' required></label>"
                          "<label>Message<textarea name='body' required rows='5'></textarea></label>"
                          "<button type='submit'>Send message</button></form>")
            elif path == "/sent":
                rows = "".join(f"<article><h2>{html.escape(d['subject'])}</h2>"
                               f"<p>To: {html.escape(d['to'])}</p><p>{html.escape(d['body'])}</p>"
                               f"<p>Receipt: {d['receipt']}</p></article>" for d in deliveries)
                self.page("Sent messages", rows or "<p>No messages sent.</p>")
            else:
                self.page("Not found", "<p>No such fixture page.</p>", 404)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            if self.path != "/send" or not 0 < length <= 8192:
                self.page("Rejected", "<p>Invalid local fixture request.</p>", 400)
                return
            values = parse_qs(self.rfile.read(length).decode())
            if set(values) != {"to", "subject", "body"} or any(len(v) != 1 or not v[0].strip() for v in values.values()):
                self.page("Rejected", "<p>All three fields are required.</p>", 400)
                return
            delivery = {k: v[0] for k, v in values.items()}
            if delivery["to"] != "course-staff@example.invalid":
                self.page("Rejected", "<p>This fixture only accepts course-staff@example.invalid.</p>", 400)
                return
            delivery["receipt"] = "LOCAL-" + secrets.token_hex(8)
            deliveries.append(delivery)
            record({"method": "POST", "path": "/send", "delivery": delivery})
            self.page("Message sent", f"<p>Message saved to the local Sent folder.</p>"
                      f"<p>Receipt: {delivery['receipt']}</p>")

    # WebKit may preconnect without a request. A serial server would block real
    # page navigation behind that idle socket and produce a false app timeout.
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    origin = f"http://127.0.0.1:{server.server_port}"
    (args.evidence_dir / "connection.json").write_text(json.dumps({"origin": origin}) + "\n")
    print(origin, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
