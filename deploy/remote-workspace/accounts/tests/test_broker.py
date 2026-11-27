import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "broker.py"
module = importlib.util.spec_from_file_location("broker", path)
broker = importlib.util.module_from_spec(module)
module.loader.exec_module(broker)


class BrokerTests(unittest.TestCase):
    def test_namespace_validation_happens_before_any_work(self):
        with patch.object(broker, "allocation") as allocation:
            for ns in ("kolmogor", "kube-system", "kolmogor-ws-u-deadbeef", "", None):
                with self.assertRaises(ValueError):
                    broker.dispatch(ns, "ensure")
            allocation.assert_not_called()

    def test_capacity_and_existing_workspaces_survive_a_broker_restart(self):
        a, b = "kolmogor-ws-u-" + "a" * 40, "kolmogor-ws-u-" + "b" * 40
        with tempfile.TemporaryDirectory() as root, patch.object(broker, "STATE", Path(root)), patch.object(broker, "MAX_WORKSPACES", 1):
            (Path(root) / a).mkdir()
            (Path(root) / a / "ready").touch()
            self.assertTrue(broker.allocation(a, ensure=True))
            with self.assertRaises(ValueError):
                broker.allocation(b, ensure=True)
            with self.assertRaises(ValueError):
                broker.dispatch(b, "display")

    def test_only_official_provider_authorization_links_are_forwarded(self):
        actual = "https://claude.ai/oauth/authorize?opaque_request"
        results = broker.sign_in_details("claude", "Open " + actual + "\nPaste code here")
        self.assertEqual(results["url"], actual)
        for foreign in ("https://elsewhere.invalid/oauth/authorize", "https://claude.ai/other",
                        "https://unrelated@claude.ai/oauth/authorize", "https://claude.ai:9443/oauth/authorize"):
            self.assertNotIn("url", broker.sign_in_details("claude", foreign))
        self.assertNotIn("url", broker.sign_in_details("claude", actual))
        self.assertNotIn("url", broker.sign_in_details("codex", "Visit https://auth.openai.com/codex/device\n"))
        device = broker.sign_in_details("codex", "Visit https://auth.openai.com/codex/device\nABCD-EFGH")
        self.assertIn("ABCD-EFGH", device["message"])

    def test_no_generic_exec_or_operations_for_the_display(self):
        ns = "kolmogor-ws-u-" + "f" * 40
        with patch.object(broker, "allocation", return_value=True), patch.object(broker, "run") as run:
            for op in ("run", "exec", "proxy", "delete"):
                with self.assertRaises(ValueError):
                    broker.dispatch(ns, op, "codex")
            with self.assertRaises(ValueError):
                broker.dispatch(ns, "code", "chrome", "abcdef012")
            run.assert_not_called()
