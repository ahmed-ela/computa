"""HTTP and source-shape contract for the safe, crowded email regression fixture."""
import json
from html.parser import HTMLParser
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class Markup(HTMLParser):
    def __init__(self, document):
        super().__init__()
        self.elements = []
        self.feed(document)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))


class CrowdedBrowserMailboxTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="crowded-mailbox-")
        self.addCleanup(self.temporary.cleanup)
        self.evidence = Path(self.temporary.name) / "evidence"
        self.launcher = Path(__file__).with_name("crowded_browser_mailbox.py")
        self.recipient = "regression-7a64@example.invalid"
        self.argv = [sys.executable, str(self.launcher), "--evidence-dir", str(self.evidence),
                     "--recipient", self.recipient]
        self.server = subprocess.Popen(self.argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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

    def post(self, path, fields):
        request = Request(self.origin + path, data=urlencode(fields).encode())
        with urlopen(request, timeout=5) as response:
            self.assertEqual(response.status, 200)
            return response.read().decode()

    def events(self):
        path = self.evidence / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def fields(self):
        return {"to": self.recipient, "subject": "REGRESSION_7A64", "body": "Hello from the safe fixture."}

    def test_compose_is_after_a_large_readable_inbox_with_aggregate_container(self):
        document = self.get("/crowded")
        elements = Markup(document).elements
        self.assertEqual(sum(tag == "article" for tag, _ in elements), 1200)
        self.assertGreater(document.index("id='compose'"), 220000)
        self.assertLess(document.index("</main>"), document.index("id='compose'"))
        self.assertIn(("div", {"role": "row"}), elements)
        dialog = next(attrs for tag, attrs in elements if attrs.get("id") == "compose")
        self.assertEqual(dialog["role"], "dialog")
        self.assertEqual(dialog["aria-modal"], "false")
        self.assertIn("hidden", dialog)
        self.assertIn("document.getElementById('compose').hidden=false", document)
        self.assertIn("document.getElementById('recipient').focus()", document)
        inputs = [(tag, attrs) for tag, attrs in elements if tag in {"input", "textarea"}]
        self.assertEqual([attrs["name"] for _, attrs in inputs], ["to", "subject", "body"])
        self.assertTrue(all("required" in attrs for _, attrs in inputs))
        self.assertNotIn("<iframe", document)
        self.assertEqual([e["method"] for e in self.events()], ["GET"])

    def test_no_focus_and_prefilled_variants_preserve_late_dialog(self):
        document = self.get("/crowded?focus=none&prefill=1")
        self.assertNotIn("document.getElementById('recipient').focus()", document)
        self.assertIn("value='old-draft@example.invalid'", document)
        self.assertIn("value='Old unsent draft'", document)
        self.assertIn(">Replace this old draft.</textarea>", document)
        self.assertGreater(document.index("id='compose'"), 220000)
        self.assertEqual(self.events()[0]["query"], {"focus": ["none"], "prefill": ["1"]})

    def test_missing_send_is_an_observable_restriction_not_a_hidden_send_target(self):
        document = self.get("/crowded?variant=missing-send")
        elements = Markup(document).elements
        actions = [attrs.get("formaction") for tag, attrs in elements if tag == "button"]
        self.assertNotIn("/send", actions)
        self.assertIn("/draft", actions)
        self.assertIn("Sending is unavailable in this restricted form.", document)
        self.assertIn("No messages sent.", self.get("/sent"))
        self.assertFalse(any(e["method"] == "POST" for e in self.events()))

    def test_accepted_send_has_exact_payload_and_an_independent_receipt(self):
        expected = self.fields()
        document = self.post("/send", expected)
        events = self.events()
        self.assertEqual(len(events), 1)
        self.assertEqual((events[0]["method"], events[0]["path"], events[0]["accepted"]), ("POST", "/send", True))
        delivery = events[0]["delivery"]
        self.assertEqual({key: delivery[key] for key in expected}, expected)
        self.assertRegex(delivery["receipt"], r"^LOCAL-[0-9a-f]{16}$")
        for value in [*expected.values(), delivery["receipt"]]:
            self.assertIn(value, document)
            self.assertIn(value, self.get("/sent"))
        self.assertIn("No drafts saved.", self.get("/drafts"))
        self.assertEqual(sum(e["method"] == "POST" for e in self.events()), 1)

    def test_duplicate_submissions_are_recorded_not_silently_deduplicated(self):
        for _ in range(2):
            self.post("/send", self.fields())
        deliveries = [e["delivery"] for e in self.events() if e.get("delivery")]
        self.assertEqual(len(deliveries), 2)
        self.assertNotEqual(deliveries[0]["receipt"], deliveries[1]["receipt"])
        self.assertEqual(self.get("/sent").count("LOCAL-"), 2)

    def test_draft_saves_exact_values_without_a_delivery(self):
        expected = self.fields()
        document = self.post("/draft", expected)
        event = self.events()[0]
        self.assertEqual((event["path"], event["accepted"]), ("/draft", True))
        self.assertNotIn("delivery", event)
        self.assertEqual({key: event["draft"][key] for key in expected}, expected)
        self.assertIn("This draft has not been sent.", document)
        self.assertIn(event["draft"]["receipt"], self.get("/drafts"))
        self.assertIn("No messages sent.", self.get("/sent"))

    def test_rejects_wrong_recipient_missing_or_duplicate_fields_and_external_addresses(self):
        invalid = [
            {**self.fields(), "to": "someone@example.com"},
            {**self.fields(), "to": "other@example.invalid"},
            {**self.fields(), "subject": ""},
            {"to": self.recipient, "subject": "Present"},
            list(self.fields().items()) + [("to", self.recipient)],
        ]
        for values in invalid:
            with self.assertRaises(HTTPError) as caught:
                self.post("/send", values)
            self.assertEqual(caught.exception.code, 400)
            caught.exception.close()
        self.assertEqual(len(self.events()), len(invalid))
        self.assertTrue(all(e["accepted"] is False and "delivery" not in e for e in self.events()))
        self.assertIn("No messages sent.", self.get("/sent"))

    def test_configuration_is_loopback_unique_and_rejects_external_recipient(self):
        connection = json.loads((self.evidence / "connection.json").read_text())
        self.assertEqual(connection, {"origin": self.origin, "recipient": self.recipient,
                                     "inboxRows": 1200, "externalDelivery": False, "duplicatesRetained": True})
        repeated = subprocess.run(self.argv, capture_output=True, timeout=5)
        self.assertNotEqual(repeated.returncode, 0)
        invalid = subprocess.run([sys.executable, str(self.launcher), "--evidence-dir",
                                  str(Path(self.temporary.name) / "external"), "--recipient", "recipient@example.com"],
                                 capture_output=True, timeout=5)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn(b"synthetic @example.invalid", invalid.stderr)
        self.assertFalse((Path(self.temporary.name) / "external").exists())

    def test_identity_records_header_without_changing_page_or_browser(self):
        request = Request(self.origin + "/identity", headers={"User-Agent": "Synthetic-UA/1.0"})
        with urlopen(request, timeout=5) as response:
            document = response.read().decode()
        self.assertIn("Synthetic-UA/1.0", document)
        self.assertIn("navigator.userAgent", document)
        self.assertEqual(self.events()[0]["userAgent"], "Synthetic-UA/1.0")


if __name__ == "__main__":
    unittest.main()
