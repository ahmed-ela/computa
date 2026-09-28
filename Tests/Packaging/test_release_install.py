"""No downloads, builds, signature operations or real user installation."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_install", ROOT / "Scripts/distribution/install-release.py")
INSTALLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALLER)


class ReleaseInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mactopus-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.package = self.root / "package"
        self.home = self.root / "user"
        self.home.mkdir()
        self.source = self.package / "Mactopus.app"
        self.make_app(self.source, b"new app")
        (self.package / "Installer").mkdir()
        self.manifest = {"schemaVersion": 1, "bundleIdentifier": INSTALLER.BUNDLE_ID,
                         "architecture": "arm64", "minimumMacOS": "14.0",
                         "appFiles": INSTALLER.bundle_files(self.source)}
        (self.package / "release-manifest.json").write_text(json.dumps(self.manifest))
        self.calls = []
        self.running = False
        self.fail_runtime = False

    def make_app(self, app, text):
        (app / "Contents/MacOS").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": INSTALLER.BUNDLE_ID, "CFBundleExecutable": "Mactopus"}, handle)
        (app / "Contents/MacOS/Mactopus").write_bytes(text)

    def run_command(self, command, *, env=None):
        command = [str(item) for item in command]
        self.calls.append((command, env))
        if command[0] == "/usr/bin/pgrep":
            if not self.running:
                raise subprocess.CalledProcessError(1, command)
        if command[0] == "/usr/bin/ditto":
            shutil.copytree(command[-2], command[-1], symlinks=True)
        if self.fail_runtime and command[0] == "/bin/zsh":
            raise subprocess.CalledProcessError(1, command)
        return ""

    def install(self, **options):
        return INSTALLER.install(self.package, self.home, self.root / "verified-uv",
                                 download_model=True, run=self.run_command, system="Darwin",
                                 architecture="arm64", mac_version="14.0", **options)

    def test_install_preserves_old_app_and_state_and_launches_only_after_provisioning(self):
        previous = self.home / "Applications/Mactopus.app"
        self.make_app(previous, b"previous app")
        support = self.home / "Library/Application Support/LocalCodex"
        support.mkdir(parents=True)
        (support / "private-chats").write_text("untouched fixture")
        installed, backup = self.install()
        self.assertEqual((installed / "Contents/MacOS/Mactopus").read_bytes(), b"new app")
        self.assertEqual((backup / "Contents/MacOS/Mactopus").read_bytes(), b"previous app")
        self.assertEqual((support / "private-chats").read_text(), "untouched fixture")
        commands = [call for call, _ in self.calls]
        self.assertEqual(commands[-1], ["/usr/bin/open", str(installed)])
        self.assertTrue(any("--model-only" in command for command in commands))
        self.assertFalse(any("--sign" in command or command[0].endswith("/xattr") for command in commands))
        runtime_env = next(env for command, env in self.calls if command[0] == "/bin/zsh")
        self.assertEqual(runtime_env["UV_NO_CONFIG"], "1")
        self.assertNotIn("HF_TOKEN", runtime_env)

    def test_runtime_failure_preserves_existing_app_and_never_launches(self):
        previous = self.home / "Applications/Mactopus.app"
        self.make_app(previous, b"previous app")
        self.fail_runtime = True
        with self.assertRaisesRegex(RuntimeError, "not replaced"):
            self.install()
        self.assertEqual((previous / "Contents/MacOS/Mactopus").read_bytes(), b"previous app")
        self.assertFalse(any(command[0] == "/usr/bin/open" for command, _ in self.calls))

    def make_existing_runtime(self):
        runtime = self.home / "Library/Application Support/LocalCodex/MLX"
        python = runtime / "venv/bin/python"
        python.parent.mkdir(parents=True)
        python.write_bytes(b"existing inert runtime")
        python.chmod(0o700)
        (runtime / "installation.json").write_text("existing receipt")
        return runtime

    def test_existing_runtime_is_verified_without_sync_and_its_receipt_is_preserved(self):
        runtime = self.make_existing_runtime()
        self.install(launch=False)
        commands = [command for command, _ in self.calls]
        verification = next(command for command in commands if "verify-runtime" in command)
        self.assertIn("-B", verification)
        receipt = Path(verification[verification.index("--receipt") + 1])
        self.assertTrue(receipt.parent.name.startswith(".mactopus-install-"))
        self.assertEqual((runtime / "installation.json").read_text(), "existing receipt")
        self.assertEqual((runtime / "venv/bin/python").read_bytes(), b"existing inert runtime")
        self.assertTrue(any(command[1:3] == ["pip", "check"] for command in commands))
        self.assertFalse(any(command[0] == "/bin/zsh" or "sync" in command for command in commands))

    def test_existing_runtime_survives_verification_and_later_model_failures(self):
        previous = self.home / "Applications/Mactopus.app"
        self.make_app(previous, b"previous app")
        runtime = self.make_existing_runtime()
        before = {str(path.relative_to(runtime)): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
        original_run = self.run_command
        for failing_argument in ("verify-runtime", "--model-only"):
            with self.subTest(failing_argument=failing_argument):
                self.calls = []
                def fail(command, *, env=None):
                    result = original_run(command, env=env)
                    if failing_argument in command:
                        raise subprocess.CalledProcessError(1, command)
                    return result
                self.run_command = fail
                with self.assertRaisesRegex(RuntimeError, "not replaced"):
                    self.install()
                after = {str(path.relative_to(runtime)): path.read_bytes() for path in runtime.rglob("*") if path.is_file()}
                self.assertEqual(after, before)
                self.assertEqual((previous / "Contents/MacOS/Mactopus").read_bytes(), b"previous app")
                commands = [command for command, _ in self.calls]
                self.assertFalse(any(command[0] in ("/bin/zsh", "/usr/bin/open") or "sync" in command for command in commands))
                if failing_argument == "verify-runtime":
                    self.assertFalse(any("--model-only" in command for command in commands))

    def test_bundle_manifest_uses_full_utf8_path_order_for_prefixes(self):
        for relative in ("Contents/Resources/a", "Contents/Resources.plist", "Contents/Resources-Info.plist", "Contents/Resources/é"):
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        paths = [entry["path"] for entry in INSTALLER.bundle_files(self.source)]
        self.assertEqual(paths, sorted(paths, key=lambda path: path.encode("utf-8")))
        self.assertLess(paths.index("Contents/Resources.plist"), paths.index("Contents/Resources/a"))

    def test_failed_final_move_rolls_back_without_deleting_either_bundle(self):
        previous = self.home / "Applications/Mactopus.app"
        self.make_app(previous, b"previous app")
        def move(source, destination):
            if source.parent.name.startswith(".mactopus-install-"):
                raise OSError("injected final move failure")
            os.rename(source, destination)
        with self.assertRaisesRegex(RuntimeError, "previous app was preserved"):
            self.install(move=move)
        self.assertEqual((previous / "Contents/MacOS/Mactopus").read_bytes(), b"previous app")
        self.assertEqual(len(list((self.home / "Applications").glob(".mactopus-install-*/Mactopus.app"))), 1)

    def test_running_app_blocks_before_staging_or_runtime_changes(self):
        self.running = True
        with self.assertRaisesRegex(ValueError, "Quit Mactopus"):
            self.install()
        self.assertFalse((self.home / "Applications").exists())
        self.assertFalse(any(command[0] in ("/usr/bin/ditto", "/bin/zsh") for command, _ in self.calls))

    def test_starting_app_during_provisioning_blocks_replacement(self):
        previous = self.home / "Applications/Mactopus.app"
        self.make_app(previous, b"previous app")
        run = self.run_command
        def start_during_provision(command, *, env=None):
            result = run(command, env=env)
            if str(command[0]) == "/bin/zsh":
                self.running = True
            return result
        self.run_command = start_during_provision
        with self.assertRaisesRegex(RuntimeError, "not replaced"):
            self.install()
        self.assertEqual((previous / "Contents/MacOS/Mactopus").read_bytes(), b"previous app")

    def test_app_manifest_tampering_symlinked_destination_and_old_macos_fail_closed(self):
        (self.source / "Contents/MacOS/Mactopus").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differs"):
            self.install()
        self.assertEqual(self.calls, [])
        with self.assertRaisesRegex(ValueError, "macOS 14"):
            INSTALLER.install(self.package, self.home, "uv", download_model=True, run=self.run_command,
                              system="Darwin", architecture="arm64", mac_version="13.6")
        (self.source / "Contents/MacOS/Mactopus").write_bytes(b"new app")
        (self.home / "Applications").symlink_to(self.package, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlinked"):
            self.install()

    def test_model_download_is_explicit_and_no_launch_option_is_honored(self):
        with self.assertRaisesRegex(ValueError, "authorize"):
            INSTALLER.install(self.package, self.home, "uv", run=self.run_command)
        self.assertEqual(self.calls, [])
        self.install(launch=False)
        self.assertFalse(any(command[0] == "/usr/bin/open" for command, _ in self.calls))

    def test_model_retry_reuses_cache_and_original_verifier_publishes_only_complete_files(self):
        shutil.copyfile(ROOT / "Scripts/mlx-runtime-install.py", self.package / "Installer/mlx-runtime-install.py")
        files = {"config.json": b"{}", "model.safetensors": b"inert weights", "tokenizer.json": b"{}"}
        manifest = {"schemaVersion": 1, "repo": "lmstudio-community/Qwen3.5-4B-MLX-4bit",
                    "revision": "a" * 40, "totalBytes": sum(map(len, files.values())),
                    "files": [{"path": name, "size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
                              for name, value in files.items()]}
        (self.package / "Installer/mlx-model.lock.json").write_text(json.dumps(manifest))
        runtime = self.home / "Library/Application Support/LocalCodex/MLX"
        runtime.mkdir(parents=True)
        fetched = []
        should_fail = True
        def download(*, repo_id, revision, filename, cache_dir, token):
            nonlocal should_fail
            self.assertFalse(token)
            self.assertEqual(revision, "a" * 40)
            if filename == "model.safetensors" and should_fail:
                should_fail = False
                raise OSError("interrupted download")
            cached = Path(cache_dir) / filename
            if not cached.exists():
                cached.write_bytes(files[filename]); fetched.append(filename)
            return str(cached)
        with patch.dict(sys.modules, {"huggingface_hub": types.SimpleNamespace(hf_hub_download=download)}):
            with self.assertRaisesRegex(OSError, "interrupted"):
                INSTALLER.install_model(self.package, self.home)
            destination = runtime / "models" / manifest["repo"]
            self.assertFalse(destination.exists())
            self.assertTrue((runtime / "model-download-cache/config.json").exists())
            INSTALLER.install_model(self.package, self.home)
            self.assertEqual(fetched.count("config.json"), 1)
            for name, value in files.items():
                self.assertEqual((destination / name).read_bytes(), value)
            INSTALLER.install_model(self.package, self.home)
            self.assertEqual(len(fetched), 3)


if __name__ == "__main__":
    unittest.main()
