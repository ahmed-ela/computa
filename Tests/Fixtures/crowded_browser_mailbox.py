#!/usr/bin/env python3
"""Loopback mailbox with a late compose dialog behind a source-truncating inbox.

No message leaves this process. Each accepted /send POST creates a distinct local
receipt, so accidental duplicate sends stay visible. Start with a new evidence
directory; the event ledger is independent of model answers and browser tools.
"""
import argparse
from datetime import datetime, timezone
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import secrets
from threading import Lock
from urllib.parse import parse_qs, urlparse


INBOX_ROWS = 1200


def safe_recipient(value):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._+-]{0,100}@example\.invalid", value):
        raise argparse.ArgumentTypeError("Recipient must be a synthetic @example.invalid address")
    return value


def page(title, body, script=""):
    return ("<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width, initial-scale=1'>"
            f"<title>{html.escape(title)}</title><style>"
            "body{font:16px system-ui;margin:24px;background:#fafafa}button,input,textarea{font:inherit}"
            "button{padding:8px 14px}header{display:flex;gap:16px;align-items:center}"
            "#inbox{height:65vh;overflow:auto;padding:10px;border:1px solid #ddd}"
            "article{border-bottom:1px solid #ddd;padding:8px}"
            "#compose{position:fixed;right:24px;bottom:24px;width:min(480px,80vw);padding:20px;"
            "background:white;border:2px solid #555;box-shadow:0 2px 12px #777;z-index:2}"
            "[hidden]{display:none!important}label{display:block;margin:10px 0}"
            "input,textarea{box-sizing:border-box;display:block;width:100%;padding:8px}"
            "#compose h2{margin-top:0}form .actions{display:flex;gap:12px}"
            "</style></head><body>" + body + ("<script>" + script + "</script>" if script else "")
            + "</body></html>")


def crowded_document(*, focus=True, prefill=False, missing_send=False):
    # Every item has real layout and readable light-DOM text. Its scroll position
    # does not hide it from a semantic document capture. The compose dialog is
    # deliberately after enough inbox content to exhaust a DOM-order-only read.
    preview = ("Synthetic inbox preview for the local browser qualification fixture. "
               "This message has no requested form fields and no delivery action. "
               "To me, from fixture@example.invalid. ")
    rows = "".join(f"<article><h2>Fixture message {index:04d}</h2><p>{preview}</p></article>"
                   for index in range(INBOX_ROWS))
    old = {"to": "old-draft@example.invalid", "subject": "Old unsent draft", "body": "Replace this old draft."} if prefill else {}
    fields = ("<label>Recipients<input id='recipient' name='to' type='email' required value='"
              + html.escape(old.get("to", ""), quote=True) + "'></label>"
              "<label>Subject<input name='subject' required value='"
              + html.escape(old.get("subject", ""), quote=True) + "'></label>"
              "<label>Message body<textarea name='body' required rows='4'>"
              + html.escape(old.get("body", "")) + "</textarea></label>")
    send = ("<p role='status'>Sending is unavailable in this restricted form. You can save a draft only.</p>"
            if missing_send else "<button type='submit' formaction='/send'>Send</button>")
    body = ("<header><h1>Crowded local mailbox</h1><button id='open-compose' type='button'>Compose</button>"
            "<a href='/sent'>Sent</a><a href='/drafts'>Drafts</a></header>"
            "<main><h2>Inbox</h2><p>All messages and actions in this mailbox are synthetic and local.</p>"
            f"<section id='inbox' aria-label='Inbox messages'><div role='row'>{rows}</div></section></main>"
            "<section id='compose' role='dialog' aria-label='New message' aria-modal='false' hidden>"
            "<h2>New message</h2><form method='post' action='/draft'>" + fields
            + "<div class='actions'>" + send + "<button type='submit' formaction='/draft'>Save draft</button>"
            "<button type='button' id='close-compose'>Close</button></div></form></section>")
    script = ("document.getElementById('open-compose').addEventListener('click',()=>{"
              "document.getElementById('compose').hidden=false;"
              "history.replaceState(null,'',location.pathname+location.search+'#compose');"
              + ("document.getElementById('recipient').focus();" if focus else "") + "});"
              "document.getElementById('close-compose').addEventListener('click',()=>{"
              "document.getElementById('compose').hidden=true;document.getElementById('open-compose').focus();});")
    return page("Crowded local mailbox", body, script)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--recipient", type=safe_recipient, default="course-staff@example.invalid")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("Port must be between 0 and 65535")
    args.evidence_dir.mkdir(parents=True, exist_ok=False)
    deliveries, drafts, lock = [], [], Lock()

    def record(event):
        # Call only while holding lock so concurrent requests cannot interleave.
        with (args.evidence_dir / "events.jsonl").open("a") as stream:
            stream.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), **event}) + "\n")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, document, status=200):
            data = document.encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            request = urlparse(self.path)
            query = parse_qs(request.query)
            with lock:
                record({"method": "GET", "path": request.path, "query": query,
                        "userAgent": self.headers.get("User-Agent", "")[:4096]})
            if request.path in {"/", "/crowded"}:
                self.respond(crowded_document(focus=query.get("focus") != ["none"],
                                              prefill=query.get("prefill") == ["1"],
                                              missing_send=query.get("variant") == ["missing-send"]))
            elif request.path in {"/sent", "/drafts"}:
                is_sent = request.path == "/sent"
                with lock:
                    records = list(deliveries if is_sent else drafts)
                rows = "".join("<article>" + "".join(
                    f"<p>{key}: {html.escape(value)}</p>" for key, value in item.items()) + "</article>"
                               for item in records)
                empty = "<p>No messages sent.</p>" if is_sent else "<p>No drafts saved.</p>"
                self.respond(page("Sent messages" if is_sent else "Saved drafts", rows or empty))
            elif request.path == "/identity":
                self.respond(page("Browser identity",
                                  "<h1>Browser identity</h1><h2>HTTP User-Agent</h2><p>"
                                  + html.escape(self.headers.get("User-Agent", ""))
                                  + "</p><h2>JavaScript User-Agent</h2><p id='ua'></p>",
                                  "document.getElementById('ua').textContent=navigator.userAgent;"))
            else:
                self.respond(page("Not found", "<p>No such fixture page.</p>"), 404)

        def do_POST(self):
            def reject(reason):
                with lock:
                    record({"method": "POST", "path": self.path, "accepted": False, "reason": reason})
                self.respond(page("Rejected", "<p>Invalid local fixture request.</p>"), 400)
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                reject("invalid_length"); return
            if self.path not in {"/send", "/draft"} or not 0 < length <= 8192:
                reject("invalid_endpoint_or_length"); return
            try:
                values = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
            except UnicodeDecodeError:
                reject("invalid_encoding"); return
            if set(values) != {"to", "subject", "body"} or any(len(v) != 1 or not v[0].strip() for v in values.values()):
                reject("invalid_fields"); return
            item = {key: values[key][0] for key in ("to", "subject", "body")}
            if item["to"] != args.recipient:
                reject("recipient_mismatch"); return
            is_send = self.path == "/send"
            item["receipt"] = ("LOCAL-" if is_send else "DRAFT-") + secrets.token_hex(8)
            with lock:
                (deliveries if is_send else drafts).append(item)
                record({"method": "POST", "path": self.path, "accepted": True,
                        "delivery" if is_send else "draft": item})
            body = ("<h1>Message sent</h1><p>Message saved to the local Sent folder.</p>" if is_send else
                    "<h1>Draft saved</h1><p>This draft has not been sent.</p>")
            body += "".join(f"<p>{key}: {html.escape(value)}</p>" for key, value in item.items())
            self.respond(page("Message sent" if is_send else "Draft saved", body))

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    origin = f"http://127.0.0.1:{server.server_port}"
    (args.evidence_dir / "connection.json").write_text(json.dumps({
        "origin": origin, "recipient": args.recipient, "inboxRows": INBOX_ROWS,
        "externalDelivery": False, "duplicatesRetained": True}) + "\n")
    print(origin, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
