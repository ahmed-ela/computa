#!/usr/bin/env python3
"""Persistent, offline MLX visual-grounding sidecar for Macrouse.

The process accepts bounded newline-delimited JSON on stdin and emits exactly
one response per request on stdout. Model prose never crosses this boundary.
"""

from __future__ import annotations

import argparse
import ast
import gc
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import re
import struct
import sys
import sysconfig
import time
import unicodedata
import uuid

from grounding_runtime.cascade import (
    AGREEMENT_THRESHOLD,
    GroundingRefusal,
    requires_showui,
    select_point,
)
from grounding_runtime.local_policy import LocalVisionPolicy


PROTOCOL_VERSION = 1
METHOD_VERSION = "goclick-guiowl-showui-agreement-v2"
MAX_REQUEST_BYTES = 64 * 1024
MAX_IMAGE_BYTES = 16 * 1024 * 1024
MAX_TARGET_CHARACTERS = 512
SHOWUI_SYSTEM = (
    "Based on the screenshot of the page, I give a text description and you give "
    "its corresponding location. The coordinate represents a clickable location "
    "[x, y] for an element, which is a relative coordinate on the screenshot, "
    "scaled from 0 to 1."
)
GUI_OWL_SPEC = {
    "id": "gui-owl-2b",
    "repo": "mPLUG/GUI-Owl-1.5-2B-Instruct",
    "revision": "528ceaec795bbfbe6103bd79e03db849feadfb24",
    "family": "gui_owl",
    "precision": "mlx-affine-4bit-group64-bfloat16",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_package_name(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def _runtime_expectation(manifest: dict) -> dict:
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
        if _canonical_package_name(name) != name or not isinstance(version, str) or not version:
            raise ValueError("runtime package manifest has an invalid entry")
    for name, expected_hash in pth_files.items():
        if Path(name).name != name or not name.endswith(".pth"):
            raise ValueError("runtime .pth manifest has an invalid filename")
        if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            raise ValueError("runtime .pth manifest has an invalid SHA-256")
    return {
        "python_version": python_version,
        "packages": packages,
        "pth_files": pth_files,
    }


def _installed_packages() -> dict[str, str]:
    packages: dict[str, str] = {}
    for distribution in importlib.metadata.distributions():
        raw_name = distribution.metadata.get("Name")
        if not isinstance(raw_name, str) or not raw_name:
            raise ValueError("installed Python distribution is missing its name")
        name = _canonical_package_name(raw_name)
        if name in packages:
            raise ValueError(f"duplicate installed Python distribution: {name}")
        packages[name] = distribution.version
    return dict(sorted(packages.items()))


def _installed_pth_files() -> dict[str, str]:
    purelib = Path(sysconfig.get_paths()["purelib"]).resolve(strict=True)
    files = {}
    for path in sorted(purelib.glob("*.pth")):
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"unsafe Python .pth file: {path.name}")
        files[path.name] = _sha256(path)
    return files


def _actual_runtime() -> dict:
    return {
        "python_version": platform.python_version(),
        "packages": _installed_packages(),
        "pth_files": _installed_pth_files(),
    }


def _verify_installation(model_root: Path) -> None:
    receipt_path = model_root.parent / "installation.json"
    manifest_path = Path(__file__).with_name("model-manifest.json")
    runtime_manifest_path = Path(__file__).with_name("runtime-manifest.json")
    if not receipt_path.is_file():
        raise FileNotFoundError("installation.json is missing; rerun the installer")
    if not manifest_path.is_file():
        raise FileNotFoundError("the bundled model manifest is missing")
    if not runtime_manifest_path.is_file():
        raise FileNotFoundError("the bundled runtime manifest is missing")
    receipt = json.loads(receipt_path.read_text())
    manifest_data = manifest_path.read_bytes()
    manifest = json.loads(manifest_data)
    runtime_manifest_data = runtime_manifest_path.read_bytes()
    runtime_manifest = json.loads(runtime_manifest_data)
    if set(receipt) != {
        "schema_version",
        "model_manifest_sha256",
        "runtime_manifest_sha256",
        "models",
        "runtime",
    }:
        raise ValueError("installation receipt has unexpected fields")
    if receipt.get("schema_version") != 3 or manifest.get("schema_version") != 1:
        raise ValueError("unsupported installation receipt")
    if receipt.get("model_manifest_sha256") != hashlib.sha256(manifest_data).hexdigest():
        raise ValueError("installation receipt does not match the bundled model manifest")
    if receipt.get("runtime_manifest_sha256") != hashlib.sha256(runtime_manifest_data).hexdigest():
        raise ValueError("installation receipt does not match the bundled runtime manifest")
    expected_runtime = _runtime_expectation(runtime_manifest)
    if receipt.get("runtime") != expected_runtime:
        raise ValueError("installation receipt has unexpected runtime metadata")
    if _actual_runtime() != expected_runtime:
        raise ValueError("installed Python runtime differs from the pinned manifest")
    models = manifest.get("models") or {}
    receipt_models = receipt.get("models") or {}
    actual_directories = {path.name for path in model_root.iterdir() if path.is_dir()}
    if actual_directories != set(models) or set(receipt_models) != set(models):
        raise ValueError("model directory set changed after installation")
    for name, model in models.items():
        directory = model_root / name
        expected_files = model.get("files") or {}
        recorded_model = receipt_models.get(name) or {}
        if set(recorded_model) != {"files", "source"} or recorded_model.get("source") != model.get("source"):
            raise ValueError(f"model receipt metadata changed for {name}")
        recorded_files = recorded_model.get("files") or {}
        actual_files = {path.name for path in directory.iterdir() if path.is_file()}
        if actual_files != set(expected_files) or set(recorded_files) != set(expected_files):
            raise ValueError(f"model file set changed for {name}")
        for filename, expected_hash in expected_files.items():
            path = directory / filename
            recorded = recorded_files.get(filename) or {}
            if set(recorded) != {"bytes", "sha256"}:
                raise ValueError(f"model receipt file metadata changed for {name}/{filename}")
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"unsafe model file for {name}: {filename}")
            if path.stat().st_size != recorded.get("bytes"):
                raise ValueError(f"model file size changed for {name}/{filename}")
            actual_hash = _sha256(path)
            if actual_hash != expected_hash or actual_hash != recorded.get("sha256"):
                raise ValueError(f"model file hash changed for {name}/{filename}")


def _png_dimensions(data: bytes) -> tuple[int, int]:
    if not 33 <= len(data) <= MAX_IMAGE_BYTES:
        raise ValueError("image must be a bounded PNG")
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("image must be a PNG with an IHDR")
    width, height = struct.unpack(">II", data[16:24])
    if not 1 <= width <= 8192 or not 1 <= height <= 8192:
        raise ValueError("image dimensions are outside the supported range")
    if width * height > 16_777_216:
        raise ValueError("image exceeds the pixel-count limit")
    return width, height


def _read_image(path_value: object, request_root: Path) -> tuple[Path, bytes, int, int]:
    if not isinstance(path_value, str) or not path_value:
        raise ValueError("image_path must be a non-empty string")
    path = Path(path_value)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("image_path must be an absolute regular file")
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(request_root):
        raise ValueError("image_path is outside the request directory")
    if not resolved.is_file():
        raise ValueError("image_path is not a regular file")
    data = resolved.read_bytes()
    width, height = _png_dimensions(data)
    return resolved, data, width, height


def _target(value: object) -> str:
    if not isinstance(value, str) or len(value) > MAX_TARGET_CHARACTERS:
        raise ValueError("target must be a string of at most 512 characters")
    if value != value.strip() or not value:
        raise ValueError("target must be non-empty with no surrounding whitespace")
    if any(unicodedata.category(character) in {"Cc", "Cf", "Zl", "Zp"} for character in value):
        raise ValueError("target contains disallowed formatting characters")
    return value


def _descriptor(instruction: str) -> str:
    value = instruction.strip().rstrip(".")
    return value[6:] if value.lower().startswith("click ") else value


def _go_prompt(instruction: str) -> str:
    return (
        f"Where is the {_descriptor(instruction)} element? "
        "(Output the center coordinates of the target)"
    )


def _show_prompt(processor, image_path: Path, instruction: str) -> str:
    return processor.apply_chat_template(
        [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": SHOWUI_SYSTEM},
                    {"type": "image", "image": str(image_path)},
                    {"type": "text", "text": instruction},
                ],
            }
        ],
        tokenize=False,
        add_generation_prompt=True,
    )


def _bounded_point(x: object, y: object, width: int, height: int):
    if isinstance(x, bool) or isinstance(y, bool):
        return None
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return None
    x, y = float(x), float(y)
    if not math.isfinite(x) or not math.isfinite(y):
        return None
    if not 0 <= x < width or not 0 <= y < height:
        return None
    return [x, y]


def _go_point(text: str, width: int, height: int):
    match = re.fullmatch(
        r"\s*(?:<s>)?\(\s*<loc_(\d+)>\s*,\s*<loc_(\d+)>\s*\)\s*(?:</s>)?\s*",
        text,
    )
    if not match:
        return None
    x, y = map(int, match.groups())
    if not 0 <= x <= 999 or not 0 <= y <= 999:
        return None
    return _bounded_point(x * width / 1000.0, y * height / 1000.0, width, height)


def _show_point(text: str, width: int, height: int):
    try:
        value = ast.literal_eval(text.strip())
    except (SyntaxError, ValueError):
        return None
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    if any(isinstance(item, bool) or not isinstance(item, (int, float)) for item in value):
        return None
    if any(not math.isfinite(float(item)) or not 0 <= float(item) <= 1 for item in value):
        return None
    return _bounded_point(float(value[0]) * width, float(value[1]) * height, width, height)


def _owl_point(result: dict, width: int, height: int):
    action = result.get("action") or {}
    if action.get("action") != "click":
        return None
    return _bounded_point(
        action.get("x", -1) * (width - 1) / 1000.0,
        action.get("y", -1) * (height - 1) / 1000.0,
        width,
        height,
    )


def _wire_point(point):
    return None if point is None else {"x": point[0], "y": point[1]}


class Cascade:
    def __init__(self, model_root: Path):
        self.model_root = model_root.resolve(strict=True)
        _verify_installation(self.model_root)
        import mlx.core as mx
        from mlx_vlm import generate, load

        self.mx = mx
        self.generate = generate
        started = time.perf_counter()
        self.go_model, self.go_processor = load(
            self.model_root / "goclick-base-4bit",
            lazy=False,
            local_files_only=True,
        )
        self.show_model, self.show_processor = load(
            self.model_root / "showui-2b-4bit",
            lazy=False,
            local_files_only=True,
        )
        self.owl = LocalVisionPolicy(
            {
                **GUI_OWL_SPEC,
                "local_path": str(self.model_root / "gui-owl-2b"),
                "max_tokens": 256,
                "max_step_seconds": 45,
                "temperature": 0.0,
                "enable_thinking": False,
            }
        )
        self.owl.load()
        self.mx.eval(self.go_model.parameters(), self.show_model.parameters())
        self.mx.synchronize()
        self.load_seconds = time.perf_counter() - started

    def warm(self, image_path: Path):
        data = image_path.read_bytes()
        width, height = _png_dimensions(data)
        self._go(image_path, "Click the Search projects field.", width, height)
        self._owl(data, "Click the Search projects field.", width, height)
        self._show(image_path, "Click the Search projects field.", width, height)
        self.mx.synchronize()

    def _go(self, image_path: Path, target: str, width: int, height: int):
        started = time.perf_counter()
        result = self.generate(
            self.go_model,
            self.go_processor,
            _go_prompt(target),
            image=[str(image_path)],
            max_tokens=32,
            temperature=0.0,
            verbose=False,
        )
        self.mx.synchronize()
        return _go_point(result.text, width, height), time.perf_counter() - started

    def _owl(self, data: bytes, target: str, width: int, height: int):
        started = time.perf_counter()
        result = self.owl.infer(data, target, [], "single")
        self.mx.synchronize()
        return _owl_point(result, width, height), time.perf_counter() - started

    def _show(self, image_path: Path, target: str, width: int, height: int):
        started = time.perf_counter()
        result = self.generate(
            self.show_model,
            self.show_processor,
            _show_prompt(self.show_processor, image_path, target),
            image=[str(image_path)],
            max_tokens=32,
            temperature=0.0,
            verbose=False,
        )
        self.mx.synchronize()
        return _show_point(result.text, width, height), time.perf_counter() - started

    def ground(self, image_path: Path, data: bytes, target: str, width: int, height: int):
        started = time.perf_counter()
        go_point, go_seconds = self._go(image_path, target, width, height)
        owl_point, owl_seconds = self._owl(data, target, width, height)
        used_showui, initial_distance = requires_showui(
            go_point, owl_point, width, height
        )
        show_point, show_seconds = None, None
        if used_showui:
            show_point, show_seconds = self._show(image_path, target, width, height)
        try:
            selection = select_point(go_point, owl_point, show_point, width, height)
        except GroundingRefusal as error:
            error.details = {
                "used_showui": used_showui,
                "agreement_threshold_normalized_diagonal": AGREEMENT_THRESHOLD,
                "initial_distance_normalized_diagonal": (
                    initial_distance / math.hypot(width, height)
                    if initial_distance is not None
                    else None
                ),
                "model_points": {
                    "goclick": _wire_point(go_point),
                    "gui_owl_2b": _wire_point(owl_point),
                    "showui": _wire_point(show_point),
                },
                "model_latency_ms": {
                    "goclick": go_seconds * 1000,
                    "gui_owl_2b": owl_seconds * 1000,
                    "showui": show_seconds * 1000 if show_seconds is not None else None,
                },
                "latency_ms": (time.perf_counter() - started) * 1000,
            }
            raise
        return {
            "point": {
                "x": selection["point"][0],
                "y": selection["point"][1],
            },
            "method_version": METHOD_VERSION,
            "used_showui": selection["used_showui"],
            "selected_pair": selection["selected_pair"],
            "agreement_threshold_normalized_diagonal": AGREEMENT_THRESHOLD,
            "initial_distance_normalized_diagonal": selection[
                "initial_distance_normalized_diagonal"
            ],
            "selected_distance_normalized_diagonal": selection[
                "selected_distance_normalized_diagonal"
            ],
            "model_points": {
                "goclick": _wire_point(go_point),
                "gui_owl_2b": _wire_point(owl_point),
                "showui": _wire_point(show_point),
            },
            "model_latency_ms": {
                "goclick": go_seconds * 1000,
                "gui_owl_2b": owl_seconds * 1000,
                "showui": show_seconds * 1000 if show_seconds is not None else None,
            },
            "latency_ms": (time.perf_counter() - started) * 1000,
        }

    def close(self):
        self.owl.unload()
        del self.go_model, self.go_processor, self.show_model, self.show_processor
        gc.collect()
        self.mx.clear_cache()
        self.mx.synchronize()


def _write(value: dict):
    sys.stdout.write(json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n")
    sys.stdout.flush()


def _request_id(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("id must be a UUID string")
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise ValueError("id must be a UUID string") from error
    if str(parsed).lower() != value.lower():
        raise ValueError("id must use canonical UUID syntax")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--request-root", required=True, type=Path)
    parser.add_argument("--warmup-image", type=Path)
    args = parser.parse_args()
    request_root = args.request_root.resolve(strict=True)
    cascade = Cascade(args.model_root)
    try:
        warmup_seconds = None
        if args.warmup_image is not None:
            warm_started = time.perf_counter()
            cascade.warm(args.warmup_image.resolve(strict=True))
            warmup_seconds = time.perf_counter() - warm_started
        _write(
            {
                "type": "ready",
                "protocol_version": PROTOCOL_VERSION,
                "method_version": METHOD_VERSION,
                "load_seconds": cascade.load_seconds,
                "warmup_seconds": warmup_seconds,
            }
        )
        while True:
            raw = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
            if not raw:
                return 0
            if len(raw) > MAX_REQUEST_BYTES or not raw.endswith(b"\n"):
                raise ValueError("request line exceeded the protocol bound")
            request_id = None
            try:
                request = json.loads(raw)
                if not isinstance(request, dict):
                    raise ValueError("request must be a JSON object")
                if set(request) - {"id", "method", "image_path", "target"}:
                    raise ValueError("request contains unexpected fields")
                request_id = _request_id(request.get("id"))
                method = request.get("method")
                if method == "shutdown":
                    _write({"id": request_id, "ok": True})
                    return 0
                if method != "ground":
                    raise ValueError("unsupported method")
                image_path, data, width, height = _read_image(
                    request.get("image_path"), request_root
                )
                target = _target(request.get("target"))
                decision = cascade.ground(image_path, data, target, width, height)
                _write(
                    {
                        "id": request_id,
                        "ok": True,
                        "image_width": width,
                        "image_height": height,
                        **decision,
                    }
                )
            except GroundingRefusal as error:
                _write(
                    {
                        "id": request_id,
                        "ok": False,
                        "error_code": error.code,
                        "error": f"{type(error).__name__}: {error}",
                        "image_width": width,
                        "image_height": height,
                        **error.details,
                    }
                )
            except Exception as error:
                _write(
                    {
                        "id": request_id,
                        "ok": False,
                        "error_code": "worker_error",
                        "error": f"{type(error).__name__}: {error}",
                    }
                )
                return 1
    finally:
        cascade.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        sys.stderr.write(f"Visual grounding worker failed: {type(error).__name__}: {error}\n")
        sys.stderr.flush()
        raise
