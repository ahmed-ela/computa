#!/usr/bin/env python3
"""Validate pinned visual-grounder files and write deterministic receipts."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import sysconfig


GUI_OWL_SOURCE = {
    "id": "gui-owl-2b",
    "repo": "mPLUG/GUI-Owl-1.5-2B-Instruct",
    "revision": "528ceaec795bbfbe6103bd79e03db849feadfb24",
    "family": "gui_owl",
    "precision": "mlx-affine-4bit-group64-bfloat16",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def load_model_manifest(path: Path) -> tuple[dict, str]:
    data = path.read_bytes()
    manifest = json.loads(data)
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported model manifest")
    return manifest, hashlib.sha256(data).hexdigest()


def load_runtime_manifest(path: Path) -> tuple[dict, str]:
    data = path.read_bytes()
    manifest = json.loads(data)
    if set(manifest) != {"schema_version", "python_version", "packages", "pth_files"}:
        raise ValueError("runtime manifest has unexpected fields")
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported runtime manifest")
    python_version = manifest.get("python_version")
    packages = manifest.get("packages")
    pth_files = manifest.get("pth_files")
    if not isinstance(python_version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", python_version):
        raise ValueError("runtime manifest has an invalid Python version")
    if not isinstance(packages, dict) or not packages:
        raise ValueError("runtime package manifest is empty")
    if not isinstance(pth_files, dict):
        raise ValueError("runtime .pth manifest is invalid")
    for name, version in packages.items():
        if canonical_package_name(name) != name or not isinstance(version, str) or not version:
            raise ValueError("runtime package manifest has an invalid entry")
    for name, expected_hash in pth_files.items():
        if Path(name).name != name or not name.endswith(".pth"):
            raise ValueError("runtime .pth manifest has an invalid filename")
        if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            raise ValueError("runtime .pth manifest has an invalid SHA-256")
    return manifest, hashlib.sha256(data).hexdigest()


def write_gui_owl_receipt(directory: Path) -> None:
    config = directory / "config.json"
    weights = sorted(directory.glob("*.safetensors"))
    if not config.is_file() or not weights:
        raise ValueError("incomplete GUI-Owl conversion")
    files = {
        path.name: path.stat().st_size
        for path in sorted(directory.iterdir())
        if path.is_file() and path.name != "conversion-receipt.json"
    }
    atomic_json(
        directory / "conversion-receipt.json",
        {
            "status": "complete",
            "source": GUI_OWL_SOURCE,
            "mlx_vlm": importlib.metadata.version("mlx-vlm"),
            "mlx": importlib.metadata.version("mlx"),
            "files": files,
            "config_sha256": sha256(config),
        },
    )


def validate_models(root: Path, manifest: dict) -> dict:
    expected_models = manifest.get("models")
    if not isinstance(expected_models, dict) or not expected_models:
        raise ValueError("model manifest is empty")
    actual_directories = {path.name for path in root.iterdir() if path.is_dir()}
    if actual_directories != set(expected_models):
        raise ValueError("model directory set differs from the pinned manifest")
    receipt_models = {}
    for name, record in expected_models.items():
        directory = root / name
        expected_files = record.get("files")
        if not isinstance(expected_files, dict) or not expected_files:
            raise ValueError(f"file manifest is empty for {name}")
        actual_files = {path.name for path in directory.iterdir() if path.is_file()}
        if actual_files != set(expected_files):
            raise ValueError(f"file set differs from the pinned manifest for {name}")
        metadata = {}
        for filename, expected_hash in expected_files.items():
            path = directory / filename
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"unsafe model file for {name}: {filename}")
            actual_hash = sha256(path)
            if actual_hash != expected_hash:
                raise ValueError(f"SHA-256 mismatch for {name}/{filename}")
            metadata[filename] = {
                "bytes": path.stat().st_size,
                "sha256": actual_hash,
            }
        receipt_models[name] = {"files": metadata, "source": record.get("source")}
    return receipt_models


def canonical_package_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def installed_packages() -> dict[str, str]:
    packages: dict[str, str] = {}
    for distribution in importlib.metadata.distributions():
        raw_name = distribution.metadata.get("Name")
        if not isinstance(raw_name, str) or not raw_name:
            raise ValueError("installed Python distribution is missing its name")
        name = canonical_package_name(raw_name)
        if name in packages:
            raise ValueError(f"duplicate installed Python distribution: {name}")
        packages[name] = distribution.version
    return dict(sorted(packages.items()))


def installed_pth_files() -> dict[str, str]:
    purelib = Path(sysconfig.get_paths()["purelib"]).resolve(strict=True)
    files = {}
    for path in sorted(purelib.glob("*.pth")):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"unsafe Python .pth file: {path.name}")
        files[path.name] = sha256(path)
    return files


def runtime_state(manifest: dict) -> dict:
    actual = {
        "python_version": platform.python_version(),
        "packages": installed_packages(),
        "pth_files": installed_pth_files(),
    }
    expected = {
        "python_version": manifest["python_version"],
        "packages": manifest["packages"],
        "pth_files": manifest["pth_files"],
    }
    if actual != expected:
        raise ValueError("installed Python runtime differs from the pinned manifest")
    return actual


def finalize(
    model_root: Path,
    receipt_path: Path,
    manifest_path: Path,
    runtime_manifest_path: Path,
    fresh: bool,
) -> None:
    model_root = model_root.resolve(strict=True)
    manifest_path = manifest_path.resolve(strict=True)
    runtime_manifest_path = runtime_manifest_path.resolve(strict=True)
    manifest, manifest_hash = load_model_manifest(manifest_path)
    runtime_manifest, runtime_manifest_hash = load_runtime_manifest(runtime_manifest_path)
    if fresh:
        write_gui_owl_receipt(model_root / "gui-owl-2b")
    models = validate_models(model_root, manifest)
    atomic_json(
        receipt_path,
        {
            "schema_version": 3,
            "model_manifest_sha256": manifest_hash,
            "runtime_manifest_sha256": runtime_manifest_hash,
            "models": models,
            "runtime": runtime_state(runtime_manifest),
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("existing", "fresh"))
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--runtime-manifest", required=True, type=Path)
    args = parser.parse_args()
    finalize(
        args.model_root,
        args.receipt,
        args.manifest,
        args.runtime_manifest,
        fresh=args.mode == "fresh",
    )


if __name__ == "__main__":
    main()
