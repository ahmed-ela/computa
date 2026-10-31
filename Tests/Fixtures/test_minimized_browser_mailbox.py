"""Transport and structural contract for the separate minimized mailbox fixture."""
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

import test_crowded_browser_mailbox as crowded_tests


class MinimizedBrowserMailboxTests(crowded_tests.CrowdedBrowserMailboxTests):
    # Share the real loopback POST checks, but launch this distinct page variant.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="minimized-mailbox-")
        self.addCleanup(self.temporary.cleanup)
        self.evidence = Path(self.temporary.name) / "evidence"
        self.launcher = Path(__file__).with_name("minimized_browser_mailbox.py")
        self.recipient = "regression-7a64@example.invalid"
        self.argv = [sys.executable, str(self.launcher), "--evidence-dir", str(self.evidence),
                     "--recipient", self.recipient]
        self.server = subprocess.Popen(self.argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_server)
        self.assertTrue(select.select([self.server.stdout], [], [], 5)[0], "Fixture did not start")
        self.origin = self.server.stdout.readline().strip()
        self.assertTrue(self.origin.startswith("http://127.0.0.1:"))

    def test_compose_is_after_a_large_readable_inbox_with_aggregate_container(self):
        document = self.get("/crowded?focus=none")
        elements = crowded_tests.Markup(document).elements
        self.assertEqual(sum(attrs.get("role") == "row" for _, attrs in elements), 5001)
        self.assertGreater(document.index("id='compose'"), 220000)
        self.assertIn("<div>" * 12 + "<div id='compose'", document)
        panel = next(attrs for _, attrs in elements if attrs.get("id") == "compose")
        self.assertEqual(panel["aria-label"], "Compose: New Message")
        self.assertNotIn("role", panel)
        self.assertIn("hidden", panel)
        self.assertNotIn(".focus()", document)
        self.assertIn("id='maximize'", document)
        self.assertIn("id='full-screen'", document)
        self.assertIn("Save &amp; close", document)
        self.assertLess(document.index("id='compose'"), document.index("<template id='composer-fields'>"))
        self.assertIn("panel.append(document.getElementById('composer-fields').content.cloneNode(true))", document)
        self.assertIn("panel.dataset.maximizeAttempts", document)
        self.assertNotIn("formaction='/send'", document)

    def test_no_focus_and_prefilled_variants_preserve_late_dialog(self):
        document = self.get("/crowded?focus=none&prefill=1")
        self.assertNotIn(".focus()", document)
        self.assertIn("value='old-draft@example.invalid'", document)
        self.assertIn("value='Old unsent draft'", document)
        self.assertIn(">Replace this old draft.</textarea>", document)
        self.assertGreater(document.index("id='compose'"), 220000)

    def test_missing_send_is_an_observable_restriction_not_a_hidden_send_target(self):
        # This variant always offers only a local unsent draft operation.
        document = self.get("/crowded")
        elements = crowded_tests.Markup(document).elements
        forms = [attrs for tag, attrs in elements if tag == "form"]
        self.assertEqual(len(forms), 1)
        self.assertEqual(forms[0]["action"], "/draft")
        self.assertNotIn("formaction='/send'", document)
        self.assertIn("No messages sent.", self.get("/sent"))
        self.assertFalse(any(e["method"] == "POST" for e in self.events()))

    def test_configuration_is_loopback_unique_and_rejects_external_recipient(self):
        connection = json.loads((self.evidence / "connection.json").read_text())
        self.assertEqual(connection, {"origin": self.origin, "recipient": self.recipient,
                                     "inboxRows": 5001, "externalDelivery": False, "duplicatesRetained": True})
        repeated = subprocess.run(self.argv, capture_output=True, timeout=5)
        self.assertNotEqual(repeated.returncode, 0)
        invalid = subprocess.run([sys.executable, str(self.launcher), "--evidence-dir",
                                  str(Path(self.temporary.name) / "external"), "--recipient", "recipient@example.com"],
                                 capture_output=True, timeout=5)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn(b"synthetic @example.invalid", invalid.stderr)
        self.assertFalse((Path(self.temporary.name) / "external").exists())

if __name__ == "__main__":
    unittest.main()
