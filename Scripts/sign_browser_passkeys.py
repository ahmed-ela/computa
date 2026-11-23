"""Seal the staged macOS browser with an approved Developer ID passkey profile."""
import hashlib
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory

TEAM = "MSMG8CJLB3"
BUNDLE = "com.ahmedelamin.LocalCodex"
PASSKEY = "com.apple.developer.web-browser.public-key-credential"


def signing_entitlements(profile, identity, now):
    grants = profile["Entitlements"]
    if ("OSX" not in profile["Platform"] or profile.get("ProvisionsAllDevices") is not True
            or "ProvisionedDevices" in profile or grants.get("com.apple.security.get-task-allow")
            or profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= now):
        raise ValueError("Expected a current Developer ID distribution profile for macOS")
    if (profile["TeamIdentifier"] != [TEAM] or grants.get("com.apple.developer.team-identifier") != TEAM
            or grants.get(PASSKEY) is not True):
        raise ValueError("Profile does not grant browser passkeys to the Kolmogor team")
    app_id = grants.get("com.apple.application-identifier")
    if app_id not in [f"{prefix}.{BUNDLE}" for prefix in profile["ApplicationIdentifierPrefix"]]:
        raise ValueError("Expected a profile for the explicit Kolmogor app ID")
    # codesign identifies the installed signing certificate by its SHA-1 fingerprint.
    if not any(hashlib.sha1(cert).hexdigest().lower() == identity.lower()
               for cert in profile["DeveloperCertificates"]):
        raise ValueError("The selected signing certificate is absent from the profile")
    return {"com.apple.application-identifier": app_id, "com.apple.developer.team-identifier": TEAM, PASSKEY: True}


def sign(app, profile_path, identity):
    raw = profile_path.read_bytes()
    decoded = subprocess.run(["/usr/bin/security", "cms", "-D"], input=raw, stdout=subprocess.PIPE, check=True)
    entitlements = signing_entitlements(plistlib.loads(decoded.stdout), identity, datetime.now(timezone.utc))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    schemes = {s for handler in info.get("CFBundleURLTypes", []) for s in handler.get("CFBundleURLSchemes", [])}
    if info.get("CFBundleIdentifier") != BUNDLE or not {"http", "https"}.issubset(schemes):
        raise ValueError("The staged Kolmogor app must handle HTTP and HTTPS addresses")
    with TemporaryDirectory() as directory:
        requested = Path(directory) / "passkeys.plist"
        requested.write_bytes(plistlib.dumps(entitlements))
        (app / "Contents/embedded.provisionprofile").write_bytes(raw)
        subprocess.run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--entitlements",
                        requested, "--sign", identity, app], check=True)
    actual = subprocess.check_output(["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", app])
    if plistlib.loads(actual) != entitlements:
        raise ValueError("Signed app entitlements differ from the requested browser capability")


if __name__ == "__main__":
    sign(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
