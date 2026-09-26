"""One owned, loopback-only MLX-VLM process. No proxy, UI, or model downloads."""
import argparse
import asyncio
import base64
import binascii
import importlib.metadata
import io
import json
import os
from pathlib import Path
import sys
import threading
import time
import uuid

from response_boundary import ResponseBoundary, is_protocol_error

MODEL_IDS = (
    "lmstudio-community/Qwen3.5-4B-MLX-4bit",
    "lmstudio-community/Qwen3.5-9B-MLX-4bit",
)
MAX_BODY = 32 * 1024 * 1024
MAX_IMAGE = 6 * 1024 * 1024
MAX_IMAGES = 8


def reject_nonfinite(_):
    raise ValueError("Nonfinite JSON is not supported.")


def watch_parent(expected, parent_id=os.getppid, wait=time.sleep, terminate=os._exit):
    # An app crash must release its model/Metal allocations, not leave a daemon.
    while parent_id() == expected:
        wait(1)
    terminate(0)


def validate_request(value, models):
    if not isinstance(value, dict) or value.get("model") not in models:
        raise ValueError("Select an installed supported local model.")
    if value.get("store") is not False or value.get("previous_response_id"):
        raise ValueError("Full-history requests with store=false are required.")
    if value.get("stream") is not True:
        raise ValueError("Streaming is required so cancellation releases generation.")
    # Do not let request fields create extra resident models or enable remote code.
    for key in ("adapter_path", "adapters", "draft_model", "trust_remote_code",
                "messages", "audio", "video", "images", "max_tokens", "tool_parser",
                "thinking_start_token", "thinking_end_token"):
        if key in value:
            raise ValueError("Unsupported inference option.")
    limit = value.get("max_output_tokens", 4096)
    if type(limit) is not int or not 1 <= limit <= 4096:
        raise ValueError("Output allowance must be from 1 to 4096 tokens.")
    if "thinking_budget" in value:
        budget = value["thinking_budget"]
        if type(budget) is not int or not 1 <= budget <= 512:
            raise ValueError("Thinking allowance must be from 1 to 512 tokens.")
    if not isinstance(value.get("input"), (list, str)):
        raise ValueError("A full input history is required.")
    image_count = 0
    image_bytes = 0
    pending = [(value["input"], 0)]
    while pending:
        item, depth = pending.pop()
        if depth > 64:
            raise ValueError("Input nesting limit exceeded.")
        if isinstance(item, list):
            pending.extend((child, depth + 1) for child in item)
        elif isinstance(item, dict):
            kind = item.get("type")
            if kind in ("input_audio", "input_video", "input_file", "file", "audio_url", "video_url"):
                raise ValueError("Only text and inline screenshots are supported.")
            if kind in ("input_image", "image_url"):
                url = item.get("image_url")
                if isinstance(url, dict):
                    url = url.get("url")
                if not isinstance(url, str) or len(url) > MAX_IMAGE * 4 // 3 + 128:
                    raise ValueError("Screenshot size limit exceeded.")
                prefix, sep, payload = url.partition(",")
                if not sep or prefix not in ("data:image/png;base64", "data:image/jpeg;base64"):
                    raise ValueError("Screenshots must be inline PNG or JPEG; no files or network URLs.")
                try:
                    data = base64.b64decode(payload, validate=True)
                except (ValueError, binascii.Error):
                    raise ValueError("Malformed inline screenshot.") from None
                image_count += 1
                image_bytes += len(data)
                if image_count > MAX_IMAGES or len(data) > MAX_IMAGE or image_bytes > 16 * 1024 * 1024:
                    raise ValueError("Screenshot budget exceeded.")
                from PIL import Image
                try:
                    with Image.open(io.BytesIO(data)) as image:
                        width, height = image.size
                        if image.format not in ("PNG", "JPEG") or width * height > 8_000_000:
                            raise ValueError("Screenshot dimensions exceed the pixel budget.")
                        image.verify()
                except Exception:
                    raise ValueError("Unsupported screenshot or pixel budget exceeded.") from None
            pending.extend((child, depth + 1) for child in item.values() if isinstance(child, (dict, list)))


class LocalInferenceBoundary:
    """Bound accepted work and normalize the pinned server's Responses contract."""

    def __init__(self, app, models, instance, memory):
        self.app, self.models, self.instance, self.memory = app, models, instance, memory
        self.busy = False
        self.selected_model = None

    async def json(self, send, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        await send({"type": "http.response.start", "status": status,
                    "headers": [(b"content-type", b"application/json"), (b"cache-control", b"no-store")]})
        await send({"type": "http.response.body", "body": body})

    async def __call__(self, scope, receive, send):
        if scope["type"] == "lifespan":
            return await self.app(scope, receive, send)
        if scope["type"] != "http":
            return await send({"type": "websocket.close", "code": 1008})
        headers = dict(scope.get("headers", []))
        if b"origin" in headers or scope.get("query_string"):
            return await self.json(send, 403, {"error": {"message": "Native local clients only."}})
        method, path = scope["method"], scope["path"]
        if method == "GET" and path == "/health":
            return await self.json(send, 200, {"status": "healthy", "heydash_instance": self.instance,
                "backend": "mlx-vlm", "version": "0.7.1", "busy": self.busy,
                "context_limit": 16384, "memory": self.memory(), "selected_model": self.selected_model})
        if method == "GET" and path == "/v1/models":
            return await self.json(send, 200, {"object": "list", "data": [
                {"id": model, "object": "model", "owned_by": "local"} for model in self.models]})
        if method != "POST" or path != "/v1/responses":
            return await self.json(send, 404, {"error": {"message": "Endpoint is not enabled."}})
        if headers.get(b"content-type", b"").split(b";", 1)[0].strip() != b"application/json":
            return await self.json(send, 415, {"error": {"message": "application/json is required."}})
        if self.busy:
            return await self.json(send, 429, {"error": {"message": "Local model is busy; no request was queued."}})
        self.busy = True
        try:
            body = bytearray()
            try:
                async with asyncio.timeout(10):
                    while True:
                        message = await receive()
                        if message["type"] == "http.disconnect":
                            return
                        body.extend(message.get("body", b""))
                        if len(body) > MAX_BODY:
                            return await self.json(send, 413, {"error": {"message": "Request size limit exceeded."}})
                        if not message.get("more_body", False):
                            break
            except TimeoutError:
                return await self.json(send, 408, {"error": {"message": "Request upload timed out."}})
            try:
                request = json.loads(body, parse_constant=reject_nonfinite)
                validate_request(request, self.models)
            except (ValueError, TypeError, RecursionError):
                return await self.json(send, 400, {"error": {"message": "Invalid local inference request."}})
            # The pinned upstream retains old model references during a switch.
            # One process therefore serves one selected model for its lifetime;
            # the app must reap it before starting another model's process.
            # Pin only after validation, but retain the pin after upstream errors
            # or cancellation: either may already have allocated model weights.
            if self.selected_model is not None and request["model"] != self.selected_model:
                return await self.json(send, 409, {"error": {"code": "owned_restart_required",
                    "message": "Switching models requires restarting the owned local model server."}})
            self.selected_model = request["model"]
            delivered = False

            async def replay_receive():
                nonlocal delivered
                if not delivered:
                    delivered = True
                    return {"type": "http.request", "body": bytes(body), "more_body": False}
                return await receive()

            response = ResponseBoundary(send, request.get("max_output_tokens", 4096))
            try:
                await self.app(scope, replay_receive, response)
                await response.finish()
            except Exception as error:
                if not is_protocol_error(error):
                    raise
                await response.fail()
        finally:
            self.busy = False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--port", type=int, default=1237)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()
    root = args.model_root.resolve(strict=True)
    if not root.is_dir() or not 1024 <= args.port <= 65535 or args.parent_pid <= 1 or os.getppid() != args.parent_pid:
        raise SystemExit("Invalid local server configuration.")
    threading.Thread(target=watch_parent, args=(args.parent_pid,), daemon=True).start()
    instance = str(uuid.UUID(os.environ["HEYDASH_MLX_INSTANCE"]))
    for package, expected in (("mlx", "0.32.2"), ("mlx-vlm", "0.7.1")):
        if importlib.metadata.version(package) != expected:
            raise SystemExit("The pinned MLX environment is unavailable; do not modify the shared environment.")
    models = tuple(model for model in MODEL_IDS if (root / model / "config.json").is_file())
    if not models:
        raise SystemExit("No supported local model weights are available.")
    # Only allow the owned launch settings; never inherit preload/drafter/remote-code options.
    for key in tuple(os.environ):
        if key.startswith(("MLX_VLM_", "APC_", "MLX_TRUST_", "KV_")):
            del os.environ[key]
    os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "APC_ENABLED": "0", "APC_DISK_ENABLED": "0", "MLX_VLM_RESPONSE_STORE_LIMIT": "0",
        "MLX_VLM_VISION_CACHE_SIZE": "1", "MLX_VLM_MAX_NUM_SEQS": "1",
        "MLX_VLM_MAX_TOKENS": "4096", "MLX_VLM_ENABLE_THINKING": "1",
        "MLX_VLM_THINKING_BUDGET": "512",
        "MLX_VLM_LOG_PROGRESS_INTERVAL": "0", "PREFILL_STEP_SIZE": "512", "MAX_KV_SIZE": "16384",
        "TOKENIZERS_PARALLELISM": "false", "HF_HUB_DISABLE_TELEMETRY": "1"})
    os.chdir(root)
    import mlx.core as mx
    mx.set_cache_limit(256 * 1024 * 1024)
    mx.set_memory_limit(10 * 1024 * 1024 * 1024)
    from mlx_vlm.server import app
    import uvicorn

    def memory():
        return {"active_bytes": mx.get_active_memory(), "cache_bytes": mx.get_cache_memory(),
                "peak_bytes": mx.get_peak_memory()}

    guarded = LocalInferenceBoundary(app, models, instance, memory)
    uvicorn.run(guarded, host="127.0.0.1", port=args.port, workers=1, server_header=False,
                access_log=False, log_level="warning")


if __name__ == "__main__":
    main()
