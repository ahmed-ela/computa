#!/usr/bin/env python3
"""Pinned, opt-in local MLX provisioning; never reads application conversations."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import tempfile


def load_manifest(path):
    value = json.loads(Path(path).read_text())
    if (value.get("schemaVersion") != 1
            or value.get("repo") != "lmstudio-community/Qwen3.5-4B-MLX-4bit"
            or not re.fullmatch(r"[0-9a-f]{40}", value.get("revision", ""))):
        raise ValueError("Invalid reviewed model pin")
    names = set()
    for entry in value.get("files", []):
        name = entry.get("path", "")
        if (not name or Path(name).name != name or name in (".", "..") or name in names
                or type(entry.get("size")) is not int or entry["size"] < 0):
            raise ValueError("Invalid pinned model file")
        names.add(name)
        if "sha256" in entry:
            valid_hash = re.fullmatch(r"[0-9a-f]{64}", entry["sha256"])
        else:
            valid_hash = re.fullmatch(r"[0-9a-f]{40}", entry.get("gitBlobSHA1", ""))
        if not valid_hash:
            raise ValueError("Missing pinned file digest")
    if not {"config.json", "model.safetensors", "tokenizer.json"}.issubset(names):
        raise ValueError("Incomplete pinned model file set")
    if sum(entry["size"] for entry in value["files"]) != value.get("totalBytes"):
        raise ValueError("Inconsistent pinned model size")
    return value


def verify_model(directory, manifest):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Model destination must be a regular directory")
    expected = {entry["path"] for entry in manifest["files"]}
    if {path.name for path in directory.iterdir()} - expected - {".cache"}:
        raise ValueError("Model directory contains unreviewed files; it was left untouched")
    for entry in manifest["files"]:
        path = directory / entry["path"]
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size != entry["size"]:
            raise ValueError("Pinned model file is missing, nonregular, or has changed size")
        if "sha256" in entry:
            digest = hashlib.sha256()
            expected_hash = entry["sha256"]
        else:
            # Hugging Face's non-LFS blob IDs use Git's blob framing. Large
            # weight/tokenizer files instead use the supplied SHA-256 LFS digest.
            digest = hashlib.sha1(f"blob {info.st_size}\0".encode(), usedforsecurity=False)
            expected_hash = entry["gitBlobSHA1"]
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_hash:
            raise ValueError("Pinned model file digest mismatch; no files were replaced")


def install_model(model_root, manifest, downloader=None):
    model_root = Path(model_root)
    if model_root.is_symlink():
        raise ValueError("Refusing a symlinked model root")
    destination = model_root / manifest["repo"]
    if destination.exists() or destination.is_symlink():
        verify_model(destination, manifest)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.parent.is_symlink():
        raise ValueError("Refusing a symlinked model namespace")
    # Never publish partially downloaded weights. Existing model directories
    # are verified, not overwritten, and the legacy model cache is not changed.
    with tempfile.TemporaryDirectory(prefix=".qwen4b-", dir=destination.parent) as temporary:
        stage = Path(temporary) / "model"
        stage.mkdir(mode=0o700)
        if shutil.disk_usage(destination.parent).free < manifest["totalBytes"] + 512 * 1024 * 1024:
            raise ValueError("Insufficient disk space for pinned model download")
        if downloader is None:
            from huggingface_hub import snapshot_download
            downloader = snapshot_download
        downloader(repo_id=manifest["repo"], revision=manifest["revision"], local_dir=stage,
                   allow_patterns=[entry["path"] for entry in manifest["files"]], token=False)
        verify_model(stage, manifest)
        if destination.exists() or destination.is_symlink():
            raise ValueError("Model destination changed during download; no replacement attempted")
        stage.rename(destination)
    return destination


def verify_runtime(lock, receipt):
    if platform.python_version() != "3.12.13":
        raise ValueError("The pinned Python patch version is required")
    data = Path(lock).read_bytes()
    expected = dict(re.findall(r"^([A-Za-z0-9_.-]+)==([^\s;]+)", data.decode(), re.MULTILINE))
    if expected.get("mlx") != "0.32.2" or expected.get("mlx-vlm") != "0.7.1":
        raise ValueError("The reviewed MLX package pin is missing")
    for name, version in expected.items():
        if importlib.metadata.version(name) != version:
            raise ValueError("Installed MLX package version differs from its lock")
    output = {"schemaVersion": 1, "pythonVersion": platform.python_version(),
              "requirementsSHA256": hashlib.sha256(data).hexdigest(), "packages": expected}
    receipt = Path(receipt)
    if receipt.is_symlink():
        raise ValueError("Refusing a symlinked runtime receipt")
    temporary = receipt.with_name(f".{receipt.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("x") as handle:
            os.chmod(temporary, 0o600)
            json.dump(output, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, receipt)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    runtime = subcommands.add_parser("verify-runtime")
    runtime.add_argument("--lock", required=True, type=Path)
    runtime.add_argument("--receipt", required=True, type=Path)
    model = subcommands.add_parser("install-model")
    model.add_argument("--manifest", required=True, type=Path)
    model.add_argument("--model-root", required=True, type=Path)
    arguments = parser.parse_args()
    if arguments.command == "verify-runtime":
        verify_runtime(arguments.lock, arguments.receipt)
    else:
        manifest = load_manifest(arguments.manifest)
        print(f"Verifying/downloading {manifest['repo']} at {manifest['revision']} ({manifest['totalBytes']} bytes)")
        install_model(arguments.model_root, manifest)
        print("Pinned model is ready; existing model directories were not overwritten.")


if __name__ == "__main__":
    main()
