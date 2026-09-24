"""One locally converted MLX vision model at a time; no implicit downloads."""

from __future__ import annotations

import gc
import hashlib
import importlib.metadata
import io
import json
import math
from pathlib import Path
import re
import struct
import threading
import time
import weakref

from .protocols import ActionParseError, FAMILIES, build_conversation, parse_model_output


ROOT = Path(__file__).resolve().parent.parent


def png_dimensions(data):
    if not isinstance(data, bytes) or not 33 <= len(data) <= 16 * 1024 * 1024:
        raise ValueError("screenshot must be bounded PNG bytes")
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("screenshot must be a PNG with IHDR")
    width, height = struct.unpack(">II", data[16:24])
    if not 1 <= width <= 8192 or not 1 <= height <= 8192 or width * height > 16_777_216:
        raise ValueError("screenshot dimensions exceed the bounded image contract")
    return width, height


class MLXBackend:
    """Narrow implementation seam; tests replace this, never the model protocol."""

    def load(self, path):
        import mlx.core as mx
        from mlx_vlm import load
        self.mx = mx
        self.model, self.processor = load(str(path), lazy=False, trust_remote_code=False,
                                          local_files_only=True)
        mx.eval(self.model.parameters())
        mx.synchronize()

    def generate(self, messages, png_images, tools, settings):
        from PIL import Image
        from mlx_vlm import stream_generate
        # Use the processor's native template directly: mlx_vlm's convenience
        # formatter moves image markers before text, breaking Holo observations.
        template_kwargs = {"tokenize": False, "add_generation_prompt": True,
                           "enable_thinking": settings["enable_thinking"]}
        if tools:
            template_kwargs["tools"] = tools
        prompt = self.processor.apply_chat_template(messages, **template_kwargs)
        images = []
        for data in png_images:
            expected = png_dimensions(data)
            image = Image.open(io.BytesIO(data))
            if image.format != "PNG" or getattr(image, "n_frames", 1) != 1 or image.size != expected:
                raise ValueError("only validated single-frame PNG screenshots are accepted")
            image.load()
            images.append(image.convert("RGB"))
        self.mx.random.seed(settings["seed"])
        self.mx.reset_peak_memory()
        yield from stream_generate(
            self.model, self.processor, prompt, image=images,
            max_tokens=settings["max_tokens"], temperature=settings["temperature"],
            top_p=1.0, enable_thinking=settings["enable_thinking"],
            prefill_step_size=512,
            # No cross-task KV/prefix/vision cache; every proposal is charged.
        )
        self.mx.synchronize()

    def unload(self):
        if hasattr(self, "model"):
            del self.model
        if hasattr(self, "processor"):
            del self.processor
        gc.collect()
        if hasattr(self, "mx"):
            self.mx.clear_cache()
            self.mx.synchronize()


def _setting_number(value, name, low, high, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"invalid {name}")
    if not math.isfinite(value) or not low <= value <= high or (integer and not isinstance(value, int)):
        raise ValueError(f"invalid {name}")
    return value


class LocalVisionPolicy:
    """Construct without loading; call load(), infer(), unload() sequentially.

    model_spec is a models.json entry plus optional local_path, max_tokens,
    temperature, candidate_temperature, seed, enable_thinking, max_step_seconds.
    Runtime never reads credentials, accesses a browser, or downloads files.
    A process-level guard prevents two instances from retaining model weights.
    """

    _owner = None
    _owner_lock = threading.Lock()

    def __init__(self, model_spec, *, backend_factory=MLXBackend, clock=time.perf_counter):
        if not isinstance(model_spec, dict):
            raise ValueError("model_spec must be an object")
        self.spec = dict(model_spec)
        if self.spec.get("family") not in FAMILIES:
            raise ValueError("unknown model family")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", self.spec.get("id", "")):
            raise ValueError("invalid model id")
        if not re.fullmatch(r"[0-9a-f]{40}", self.spec.get("revision", "")):
            raise ValueError("a pinned full source revision is required")
        if not isinstance(self.spec.get("repo"), str) or "/" not in self.spec["repo"]:
            raise ValueError("source repo is required")
        self.path = Path(self.spec.get("local_path", self.spec.get("path", ROOT / "models" / self.spec["id"]))).resolve()
        self.backend_factory, self.clock = backend_factory, clock
        self.backend = None
        self.load_s = None
        self._inference_lock = threading.Lock()
        self.settings = {
            "max_tokens": _setting_number(self.spec.get("max_tokens", 1024), "max_tokens", 16, 8192, True),
            "temperature": _setting_number(self.spec.get("temperature", 0.0), "temperature", 0, 2),
            "candidate_temperature": _setting_number(self.spec.get("candidate_temperature", 0.2), "candidate_temperature", 0, 2),
            "seed": _setting_number(self.spec.get("seed", 0), "seed", 0, 2**32 - 2, True),
            "enable_thinking": self.spec.get("enable_thinking", self.spec["family"] in {"fara", "holo", "qwen"}),
            "max_step_seconds": _setting_number(self.spec.get("max_step_seconds", 120), "max_step_seconds", 1, 600),
        }
        if not isinstance(self.settings["enable_thinking"], bool):
            raise ValueError("enable_thinking must be boolean")

    def _verify_local_files(self):
        receipt_path = self.path / "conversion-receipt.json"
        if not self.path.is_dir() or not receipt_path.is_file():
            raise FileNotFoundError("locally converted model and complete receipt are required; no download attempted")
        receipt = json.loads(receipt_path.read_text())
        source = receipt.get("source", {})
        if receipt.get("status") != "complete" or any(source.get(k) != self.spec.get(k) for k in ["id", "repo", "revision", "family", "precision"]):
            raise ValueError("conversion receipt does not match the pinned model specification")
        config_path = self.path / "config.json"
        if not config_path.is_file() or hashlib.sha256(config_path.read_bytes()).hexdigest() != receipt.get("config_sha256"):
            raise ValueError("model configuration changed after conversion")
        config = json.loads(config_path.read_text())
        expected_type = "qwen3_vl" if self.spec["family"] == "gui_owl" else "qwen3_5"
        if config.get("model_type") != expected_type:
            raise ValueError("model architecture does not match family")
        weights = {name: size for name, size in receipt.get("files", {}).items() if name.endswith(".safetensors")}
        if not weights:
            raise ValueError("conversion receipt contains no weights")
        for name, size in weights.items():
            path = (self.path / name).resolve()
            if not path.is_relative_to(self.path) or not path.is_file() or path.stat().st_size != size:
                raise ValueError("model weight file missing or changed in size")
        return receipt

    def load(self):
        if self.backend is not None:
            return self.metadata
        receipt = self._verify_local_files()
        with self._owner_lock:
            owner = self._owner() if self._owner is not None else None
            if owner is not None:
                raise RuntimeError("another LocalVisionPolicy owns the loaded-model slot; unload it first")
            LocalVisionPolicy._owner = weakref.ref(self)
        start = self.clock()
        backend = None
        try:
            backend = self.backend_factory()
            backend.load(self.path)
            self.backend = backend
            self.load_s = self.clock() - start
        except BaseException:
            if backend is not None:
                backend.unload()
            with self._owner_lock:
                LocalVisionPolicy._owner = None
            raise
        versions = {}
        for package in ["mlx", "mlx-vlm", "transformers", "pillow"]:
            try:
                versions[package] = importlib.metadata.version(package)
            except importlib.metadata.PackageNotFoundError:
                versions[package] = None
        self.metadata = {
            **{key: self.spec.get(key) for key in ["id", "repo", "revision", "family", "precision"]},
            "local_path": str(self.path), "config_sha256": receipt["config_sha256"],
            "receipt_sha256": hashlib.sha256((self.path / "conversion-receipt.json").read_bytes()).hexdigest(),
            "native_prompts_sha256": hashlib.sha256(Path(__file__).with_name("native_prompts.json").read_bytes()).hexdigest(),
            "protocols_sha256": hashlib.sha256(Path(__file__).with_name("protocols.py").read_bytes()).hexdigest(),
            "adapter_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "processor_file_sha256": {name: hashlib.sha256((self.path / name).read_bytes()).hexdigest()
                                      for name in ["chat_template.jinja", "tokenizer_config.json", "processor_config.json", "preprocessor_config.json"]
                                      if (self.path / name).is_file()},
            "settings": self.settings.copy(), "runtime_versions": versions,
            "load_s": self.load_s, "coordinate_space": "normalized-0-1000",
            "cache_policy": "no_cross_proposal_or_cross_task_cache",
            "harness": "bounded-native-protocol-port-not-publisher-benchmark",
            "completion_contract": "native-tool-or-common-clean-final-text-v1",
        }
        return self.metadata

    def _proposal(self, messages, images, tools, index):
        settings = {**self.settings, "seed": self.settings["seed"] + index}
        if index:
            settings["temperature"] = self.settings["candidate_temperature"]
        started, first_token, ended, last = self.clock(), None, None, None
        raw = ""
        error = None
        stream = self.backend.generate(messages, images, tools, settings)
        try:
            for part in stream:
                now = self.clock()
                if first_token is None:
                    first_token = now
                raw += part.text
                last = part
                if now - started > settings["max_step_seconds"]:
                    raise TimeoutError("local inference exceeded per-proposal cooperative deadline")
                if len(raw) > 16000:
                    raise ActionParseError("model output exceeds parsing bound")
            if last is None:
                raise ActionParseError("empty generation")
            action, call, visible_note, output_kind = parse_model_output(
                raw, self.spec["family"], finish_reason=last.finish_reason)
        except (ActionParseError, TimeoutError) as exc:
            error = {"kind": type(exc).__name__, "message": str(exc)}
            action, call, visible_note = None, None, ""
            output_kind = "invalid"
        finally:
            if hasattr(stream, "close"):
                stream.close()
            ended = self.clock()
        def engine_elapsed(tokens, rate):
            # MLX reports tokens / measured elapsed. Invert that exact report;
            # never estimate vision/prefill as TTFT minus an assumed token time.
            return tokens / rate if isinstance(rate, (int, float)) and math.isfinite(rate) and rate > 0 else None
        prompt_tokens = getattr(last, "prompt_tokens", 0)
        generation_tokens = getattr(last, "generation_tokens", 0)
        timing = {
            "total_s": ended - started,
            "first_token_s": first_token - started if first_token is not None else None,
            "prefill_s": engine_elapsed(prompt_tokens, getattr(last, "prompt_tps", None)),
            "generation_s": engine_elapsed(generation_tokens, getattr(last, "generation_tps", None)),
            "prefill_basis": "MLX prompt_tokens / measured prompt_tps; includes first token, excludes host input preparation",
            "generation_basis": "MLX generation_tokens / measured generation_tps",
            "prompt_tokens": prompt_tokens, "generation_tokens": generation_tokens,
            "peak_memory_gb": getattr(last, "peak_memory", None),
            "finish_reason": getattr(last, "finish_reason", None),
        }
        return {"ok": error is None, "action": action, "error": error, "native_call": call,
                "output_kind": output_kind,
                "raw_text": raw, "visible_note": visible_note, "timing": timing,
                "settings": settings, "proposal_index": index, "id": f"c{index}",
                "description": visible_note or (json.dumps(action) if action else "Invalid model output"),
                "observation_summary": visible_note,
                "observation_summary_basis": "native non-reasoning prefix, not a separate perception pass"}

    def infer(self, screenshot, instruction, history, mode="single"):
        start = self.clock()
        if mode not in {"single", "candidates"}:
            raise ValueError("mode must be single or candidates")
        dimensions = png_dimensions(screenshot)
        messages, images, tools = build_conversation(self.spec["family"], instruction, history, screenshot)
        for data in images:
            png_dimensions(data)
        if self.backend is None:
            raise RuntimeError("call load() explicitly before infer(); loading is separately timed")
        if not self._inference_lock.acquire(blocking=False):
            raise RuntimeError("concurrent inference on one policy is forbidden")
        try:
            proposals = [self._proposal(messages, images, tools, i) for i in range(1 if mode == "single" else 2)]
        finally:
            self._inference_lock.release()
        elapsed = self.clock() - start
        common = {"mode": mode, "model": self.metadata, "screenshot_dimensions": list(dimensions),
                  "history_images": len(images) - 1, "load_s": self.load_s}
        if mode == "single":
            return {**common, **proposals[0], "inference_total_s": elapsed,
                    "timing": {**proposals[0]["timing"], "proposal_total_s": proposals[0]["timing"]["total_s"], "total_s": elapsed}}
        return {**common, "candidates": proposals, "native_first_index": 0,
                "observation_summary": "\n".join(p["visible_note"] for p in proposals if p["visible_note"]),
                "observation_summary_basis": "native non-reasoning prefixes, not a separate perception pass",
                "timing": {"total_s": elapsed,
                           "prefill_s": sum(p["timing"]["prefill_s"] for p in proposals) if all(p["timing"]["prefill_s"] is not None for p in proposals) else None,
                           "generation_s": sum(p["timing"]["generation_s"] for p in proposals) if all(p["timing"]["generation_s"] is not None for p in proposals) else None},
                "generation_policy": "two-independent-native-proposals; no deduplication, regeneration or hidden retries"}

    def unload(self):
        if not self._inference_lock.acquire(blocking=False):
            raise RuntimeError("cannot unload during inference")
        try:
            if self.backend is not None:
                self.backend.unload()
                self.backend = None
            with self._owner_lock:
                if self._owner is not None and self._owner() is self:
                    LocalVisionPolicy._owner = None
        finally:
            self._inference_lock.release()

    def __enter__(self):
        self.load()
        return self

    def __exit__(self, *_):
        self.unload()

    close = unload
