import hashlib
import plistlib
import unittest
from subprocess import CompletedProcess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from sign_browser_passkeys import BUNDLE, PASSKEY, TEAM, sign, signing_entitlements


class BrowserPasskeySigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.identity = hashlib.sha1(b"fixture certificate").hexdigest()
        self.grants = {"com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
                       "com.apple.developer.team-identifier": TEAM, PASSKEY: True}
        self.profile = {"DeveloperCertificates": [b"fixture certificate"], "Entitlements": self.grants.copy(),
                        "Platform": ["OSX"], "ProvisionsAllDevices": True, "TeamIdentifier": [TEAM],
                        "ApplicationIdentifierPrefix": [TEAM], "ExpirationDate": (self.now + timedelta(days=2)).replace(tzinfo=None)}

    def test_only_passkeys_and_app_identity_are_signed(self):
        self.profile["Entitlements"]["keychain-access-groups"] = ["*"]
        self.assertEqual(signing_entitlements(self.profile, self.identity.upper(), self.now), self.grants)

    def test_profile_must_be_for_this_app_team_certificate_and_distribution_method(self):
        for override in ({"ProvisionsAllDevices": False}, {"ProvisionedDevices": ["development"]},
                         {"ExpirationDate": self.now}, {"Platform": ["iOS"]}, {"TeamIdentifier": ["other"]},
                         {"DeveloperCertificates": [b"other signer"]}):
            with self.subTest(fields=list(override)), self.assertRaises(ValueError):
                signing_entitlements({**self.profile, **override}, self.identity, self.now)
        for override in ({PASSKEY: False}, {PASSKEY: 1}, {"com.apple.developer.team-identifier": "other"},
                         {"com.apple.application-identifier": f"{TEAM}.*"}, {"com.apple.security.get-task-allow": True}):
            with self.subTest(fields=list(override)), self.assertRaises(ValueError):
                signing_entitlements({**self.profile, "Entitlements": {**self.grants, **override}}, self.identity, self.now)

    def test_seals_validated_profile_and_checks_the_final_signature(self):
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            app = directory / "Kolmogor.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            info = {"CFBundleIdentifier": BUNDLE, "CFBundleURLTypes": [{"CFBundleURLSchemes": ["http", "https"]}]}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            profile = directory / "browser.provisionprofile"
            profile.write_bytes(b"fixture CMS envelope")

            def run(command, **kwargs):
                if command[:3] == ["/usr/bin/security", "cms", "-D"]:
                    self.assertEqual(kwargs["input"], profile.read_bytes())
                    return CompletedProcess(command, 0, plistlib.dumps(self.profile))
                self.assertEqual(command[-1], app)
                requested = command[command.index("--entitlements") + 1]
                self.assertEqual(plistlib.loads(requested.read_bytes()), self.grants)
                self.assertEqual((contents / "embedded.provisionprofile").read_bytes(), profile.read_bytes())

            with patch("sign_browser_passkeys.subprocess.run", side_effect=run), patch(
                    "sign_browser_passkeys.subprocess.check_output", return_value=plistlib.dumps(self.grants)) as display:
                sign(app, profile, self.identity)
                display.assert_called_once_with(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", app])
                display.return_value = plistlib.dumps({})
                with self.assertRaisesRegex(ValueError, "Signed app entitlements differ"):
                    sign(app, profile, self.identity)

    def test_app_declares_web_handler_without_claiming_default(self):
        path = Path(__file__).resolve().parents[1] / "Config/Kolmogor-Info.plist"
        handlers = plistlib.loads(path.read_bytes())["CFBundleURLTypes"]
        web = [h for h in handlers if "https" in h["CFBundleURLSchemes"]]
        self.assertEqual(len(web), 1)
        self.assertEqual(set(web[0]["CFBundleURLSchemes"]), {"https", "http"})
        self.assertEqual(web[0]["LSHandlerRank"], "Alternate")


if __name__ == "__main__":
    unittest.main()
