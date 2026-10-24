"""Isolated HTTP contract for the synthetic conversation qualification pages."""
import json
from html.parser import HTMLParser
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlencode
from urllib.request import urlopen


class ConversationMarkup(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.articles = []
        self.current = None
        self.feed(document)

    def handle_starttag(self, tag, attrs):
        if tag == "article":
            self.current = {"text": "", "buttons": [], "forms": []}
            self.articles.append(self.current)
        elif self.current is not None and tag in {"button", "form"}:
            self.current["buttons" if tag == "button" else "forms"].append(dict(attrs))

    def handle_endtag(self, tag):
        if tag == "article":
            self.current = None

    def handle_data(self, data):
        if self.current is not None:
            self.current["text"] += data + " "


class BrowserActionMailboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mailbox-conversation-")
        self.addCleanup(self.temporary.cleanup)
        self.evidence = Path(self.temporary.name) / "evidence"
        launcher = Path(__file__).with_name("browser_action_mailbox.py")
        self.server = subprocess.Popen(
            [sys.executable, str(launcher), "--evidence-dir", str(self.evidence)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_server)
        self.assertTrue(select.select([self.server.stdout], [], [], 5)[0], "Fixture did not start")
        self.origin = self.server.stdout.readline().strip()
        self.assertTrue(self.origin.startswith("http://127.0.0.1:"))

    def stop_server(self):
        if self.server.poll() is None:
            self.server.terminate()
            try:
                self.server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.server.kill()
                self.server.wait(timeout=5)
        self.server.stdout.close()
        self.server.stderr.close()

    def get(self, path):
        with urlopen(self.origin + path, timeout=5) as response:
            self.assertEqual(response.status, 200)
            return response.read().decode()

    def expand_staff(self, path):
        initial = self.get(path)
        articles = ConversationMarkup(initial).articles
        self.assertEqual(len(articles), 3)
        self.assertTrue(all(a["buttons"][0]["aria-expanded"] == "false" for a in articles))
        self.assertTrue(all(a["forms"][0]["method"] == "get" for a in articles))
        self.assertIn("From: Learner <learner@example.invalid>", articles[0]["text"])
        self.assertIn("learner-evidence-packet.pdf", articles[0]["text"])
        self.assertIn("From: Course staff <course-staff@example.invalid>", articles[1]["text"])
        self.assertNotIn("course-staff-evidence-packet.pdf", initial)
        self.assertNotIn("reviewer-checklist.pdf", initial)
        self.assertNotIn("hidden", initial)
        button = articles[1]["buttons"][0]
        self.assertEqual(button["value"], "staff")
        expanded = self.get(articles[1]["forms"][0]["action"] + "?"
                            + urlencode({button["name"]: button["value"]}))
        current = ConversationMarkup(expanded).articles
        self.assertEqual([a["buttons"][0]["aria-expanded"] for a in current], ["false", "true", "false"])
        self.assertIn("From: Course staff <course-staff@example.invalid>", current[1]["text"])
        return current, expanded

    def assert_no_posts(self):
        events = [json.loads(line) for line in (self.evidence / "events.jsonl").read_text().splitlines()]
        self.assertTrue(events)
        self.assertEqual({event["method"] for event in events}, {"GET"})
        self.assertNotIn("Message saved", self.get("/sent"))
        self.assertIn("No messages sent.", self.get("/sent"))

    def test_requested_sender_attachment_requires_expanding_that_message(self):
        articles, expanded = self.expand_staff("/conversation")
        self.assertIn("course-staff-evidence-packet.pdf", articles[1]["text"])
        self.assertNotIn("learner-evidence-packet.pdf", articles[1]["text"])
        self.assertNotIn("reviewer-checklist.pdf", expanded)
        collapse = articles[1]["buttons"][0]
        collapsed = self.get("/conversation?" + urlencode({collapse["name"]: collapse["value"]}))
        self.assertNotIn("course-staff-evidence-packet.pdf", collapsed)
        self.assertIn("learner-evidence-packet.pdf", collapsed)
        events = [json.loads(line) for line in (self.evidence / "events.jsonl").read_text().splitlines()]
        self.assertEqual([event["expanded_message"] for event in events], ["", "staff", ""])
        self.assert_no_posts()

    def test_missing_sender_attachment_does_not_hide_other_participant_attachment(self):
        articles, expanded = self.expand_staff("/conversation/missing")
        self.assertIn("This message has no attachments.", articles[1]["text"])
        self.assertNotIn(".pdf", articles[1]["text"])
        self.assertNotIn("course-staff-evidence-packet.pdf", expanded)
        self.assertIn("learner-evidence-packet.pdf", articles[0]["text"])
        self.assert_no_posts()

    def test_original_routes_and_search_behavior_remain_available(self):
        home = self.get("/")
        self.assertIn("href='/conversation'", home)
        self.assertIn("href='/conversation/missing'", home)
        self.assertIn("href='/message/ode'", home)
        message = self.get("/message/ode")
        self.assertIn("Tuesday at 10:30 AM", message)
        self.assertIn("exam-change-2026-10-23.pdf", message)
        self.assertIn("The library opens at 8 AM.", self.get("/message/other"))
        self.assertIn("action='/send'", self.get("/compose"))
        self.assertIn("href='/message/ode'", self.get("/search?q=ode"))
        self.assertIn("No results found", self.get("/search?q=ODE+class+announcement"))
        self.assert_no_posts()


if __name__ == "__main__":
    unittest.main()
