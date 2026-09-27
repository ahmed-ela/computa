"""Offline installer tests: no actual model, environment install, or app access."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/mlx-runtime-install.py"
spec = importlib.util.spec_from_file_location("mlx_runtime_install", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ModelInstallationTests(unittest.TestCase):
    def fixture(self):
        contents = {"config.json": b"{}", "model.safetensors": b"synthetic weights", "tokenizer.json": b"{}"}
        files = [{"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                 for name, data in contents.items()]
        return {"schemaVersion": 1, "repo": "lmstudio-community/Qwen3.5-4B-MLX-4bit",
                "revision": "c43ee1d65576a5d98de1e8405cac93c371a655c1",
                "totalBytes": sum(map(len, contents.values())), "files": files}, contents

    def test_checked_in_pin_has_exact_immutable_revision_and_all_file_sizes(self):
        manifest = installer.load_manifest(ROOT / "Scripts/mlx-model.lock.json")
        self.assertEqual(manifest["revision"], "c43ee1d65576a5d98de1e8405cac93c371a655c1")
        self.assertEqual(manifest["totalBytes"], 3061140963)
        self.assertEqual(len(manifest["files"]), 12)

    def test_download_is_pinned_tokenless_verified_and_idempotent(self):
        manifest, contents = self.fixture()
        calls = []
        def download(**arguments):
            calls.append(arguments)
            for name, data in contents.items():
                (Path(arguments["local_dir"]) / name).write_bytes(data)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "models"
            destination = installer.install_model(root, manifest, download)
            installer.verify_model(destination, manifest)
            self.assertEqual(installer.install_model(root, manifest, download), destination)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]["revision"], manifest["revision"])
            self.assertIs(calls[0]["token"], False)
            self.assertEqual(set(calls[0]["allow_patterns"]), set(contents))
            self.assertNotIn("trust_remote_code", calls[0])
            self.assertEqual(list(destination.parent.iterdir()), [destination])

    def test_existing_changed_model_is_not_replaced_or_downloaded(self):
        manifest, contents = self.fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / manifest["repo"]
            destination.mkdir(parents=True)
            for name, data in contents.items():
                (destination / name).write_bytes(data)
            (destination / "config.json").write_bytes(b"[]")
            with self.assertRaises(ValueError):
                installer.install_model(root, manifest, lambda **_: self.fail("Must not download"))
            self.assertEqual((destination / "config.json").read_bytes(), b"[]")

    def test_invalid_download_is_not_published_and_stage_is_removed(self):
        manifest, _ = self.fixture()
        def incomplete(**arguments):
            (Path(arguments["local_dir"]) / "config.json").write_bytes(b"{}")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(FileNotFoundError):
                installer.install_model(root, manifest, incomplete)
            self.assertFalse((root / manifest["repo"]).exists())
            self.assertEqual(list((root / "lmstudio-community").iterdir()), [])

    def test_symlinked_or_extra_files_are_rejected_without_following_them(self):
        manifest, contents = self.fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "model"
            model.mkdir()
            for name, data in contents.items():
                (model / name).write_bytes(data)
            external = root / "external"
            external.write_bytes(b"{}")
            (model / "config.json").unlink()
            (model / "config.json").symlink_to(external)
            with self.assertRaises(ValueError):
                installer.verify_model(model, manifest)
            self.assertEqual(external.read_bytes(), b"{}")

    def test_git_blob_digest_uses_git_framing(self):
        manifest, contents = self.fixture()
        entry = manifest["files"][0]
        data = contents[entry["path"]]
        entry.pop("sha256")
        entry["gitBlobSHA1"] = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            for name, data in contents.items():
                (Path(temporary) / name).write_bytes(data)
            installer.verify_model(temporary, manifest)

    def test_manifest_rejects_traversal_missing_digests_and_inconsistent_sizes(self):
        manifest, _ = self.fixture()
        invalid = []
        for field, value in [("repo", "../private"), ("revision", "main"), ("totalBytes", 0)]:
            candidate = copy.deepcopy(manifest)
            candidate[field] = value
            invalid.append(candidate)
        candidate = copy.deepcopy(manifest)
        candidate["files"][0]["path"] = "../private"
        invalid.append(candidate)
        candidate = copy.deepcopy(manifest)
        candidate["files"][0].pop("sha256")
        invalid.append(candidate)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            for value in invalid:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    installer.load_manifest(path)

    def test_installer_help_and_bad_option_do_not_provision_anything(self):
        script = ROOT / "Scripts/install-mlx-runtime.sh"
        result = subprocess.run(["/bin/zsh", str(script), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--download-model", result.stdout)
        result = subprocess.run(["/bin/zsh", str(script), "--unknown"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

    def test_runtime_receipt_records_tested_versions_and_lock_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "requirements.lock"
            lock.write_text("mlx==0.32.2\nmlx-vlm==0.7.1\n")
            receipt = Path(temporary) / "installation.json"
            with patch.object(installer.platform, "python_version", return_value="3.12.13"), \
                 patch.object(installer.importlib.metadata, "version", side_effect=lambda name: {"mlx": "0.32.2", "mlx-vlm": "0.7.1"}[name]):
                installer.verify_runtime(lock, receipt)
            record = json.loads(receipt.read_text())
            self.assertEqual(record["requirementsSHA256"], hashlib.sha256(lock.read_bytes()).hexdigest())
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
