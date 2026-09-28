"""Offline boundary tests: no MLX import, model load, HTTP listener, or UI."""
import asyncio
import base64
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

path = Path(__file__).parents[2] / "Sources/Computa/Resources/MLXServer/server.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("heydash_mlx", path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
MODEL = server.MODEL_IDS[0]


class RequestTests(unittest.TestCase):
    def test_model_discovery_preserves_legacy_9b_beside_owned_4b(self):
        with tempfile.TemporaryDirectory() as temporary:
            owned, legacy = Path(temporary) / "owned", Path(temporary) / "legacy"
            for root, model in [(owned, MODEL), (legacy, MODEL), (legacy, server.MODEL_IDS[1])]:
                directory = root / model
                directory.mkdir(parents=True)
                (directory / "config.json").write_text("{}")
            paths = server.discover_model_paths(owned, legacy)
            self.assertEqual(paths[MODEL], (owned / MODEL).resolve())
            self.assertEqual(paths[server.MODEL_IDS[1]], (legacy / server.MODEL_IDS[1]).resolve())
            self.assertEqual(server.discover_model_paths(owned), {MODEL: (owned / MODEL).resolve()})
            self.assertEqual(server.discover_model_paths(Path(temporary) / "missing", legacy)[MODEL],
                             (legacy / MODEL).resolve())
            self.assertEqual(server.discover_model_paths(Path(temporary) / "missing"), {})

    def test_parent_exit_releases_process_instead_of_leaving_resident_weights(self):
        parents = iter([42, 42, 1])
        waits, exits = [], []
        server.watch_parent(42, parent_id=lambda: next(parents), wait=waits.append, terminate=exits.append)
        self.assertEqual(waits, [1, 1])
        self.assertEqual(exits, [0])

    def request(self, **overrides):
        return {"model": MODEL, "store": False, "stream": True, "input": "Hello", **overrides}

    def test_full_history_and_reasoning_pass_without_mutation(self):
        request = self.request(input=[{"type": "function_call_output", "call_id": "a", "output": "done"}],
                               reasoning={"effort": "medium"})
        before = json.dumps(request)
        server.validate_request(request, (MODEL,))
        self.assertEqual(json.dumps(request), before)

    def test_rejects_model_download_stateful_and_nonstreaming_work(self):
        for values in ({"model": "unknown/model"}, {"store": True}, {"store": None},
                       {"previous_response_id": "old"}, {"stream": False},
                       {"thinking_budget": 513}, {"thinking_budget": None}, {"thinking_budget": True},
                       {"max_output_tokens": 4097}, {"max_output_tokens": True}, {"input": None}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                server.validate_request(self.request(**values), (MODEL,))

    def test_rejects_extra_models_and_remote_code_even_false_or_empty(self):
        for field in ("adapters", "adapter_path", "draft_model", "trust_remote_code", "messages", "audio", "video", "images",
                      "max_tokens", "tool_parser", "thinking_start_token", "thinking_end_token"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                server.validate_request(self.request(**{field: None}), (MODEL,))

    def test_rejects_file_and_network_images_inside_tool_results(self):
        for source in ("https://example.com/image.png", "/private/file.png", "file:///tmp/a", "data:image/png;base64,invalid!!"):
            request = self.request(input=[{"type": "function_call_output", "output": [
                {"type": "input_image", "image_url": source}]}])
            with self.subTest(source=source), self.assertRaises(ValueError):
                server.validate_request(request, (MODEL,))

    def test_valid_inline_tool_result_image_is_preserved_but_count_is_bounded(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGB", (2, 2)).save(data, format="PNG")
        image = {"type": "input_image", "image_url": "data:image/png;base64," + base64.b64encode(data.getvalue()).decode()}
        request = self.request(input=[{"type": "function_call_output", "call_id": "a", "output": [image]}])
        before = json.dumps(request)
        server.validate_request(request, (MODEL,))
        self.assertEqual(json.dumps(request), before)
        request["input"][0]["output"] = [image] * 9
        with self.assertRaises(ValueError):
            server.validate_request(request, (MODEL,))
        image["image_url"] = "data:image/png;base64," + base64.b64encode(data.getvalue()[:45]).decode()
        request["input"][0]["output"] = [image]
        with self.assertRaises(ValueError):
            server.validate_request(request, (MODEL,))

    def test_rejects_unsupported_media_and_excessive_nesting(self):
        for kind in ("input_audio", "input_video", "input_file", "video_url"):
            with self.assertRaises(ValueError):
                server.validate_request(self.request(input=[{"type": kind}]), (MODEL,))
        tree = []
        for _ in range(66):
            tree = [tree]
        with self.assertRaises(ValueError):
            server.validate_request(self.request(input=tree), (MODEL,))


class BoundaryTests(unittest.IsolatedAsyncioTestCase):
    async def test_protocol_group_reaches_terminal_diagnostic_and_releases_busy_state(self):
        from sse_contract import ProtocolError
        async def malformed(scope, receive, send):
            await receive()
            raise ExceptionGroup("private upstream context", [ProtocolError("Missing terminal response")])
        # Use the same class imported by the response adapter; no MLX import or listener.
        self.boundary.app = malformed
        output = await self.invoke()
        value = json.loads(output[-1]["body"].split(b"data: ")[1])
        self.assertEqual(value["type"], "response.failed")
        self.assertEqual(value["response"]["error"]["code"], "invalid_prompt")
        self.assertIn("reason=missing_terminal_response", value["response"]["error"]["message"])
        self.assertNotIn("private", value["response"]["error"]["message"])
        self.assertFalse(self.boundary.busy)

    async def test_mixed_exception_group_does_not_masquerade_as_protocol_diagnostic(self):
        from sse_contract import ProtocolError
        async def mixed(scope, receive, send):
            raise ExceptionGroup("private context", [ProtocolError("Missing terminal response"), ValueError("other")])
        self.boundary.app = mixed
        with self.assertRaises(ExceptionGroup):
            await self.invoke()
        self.assertFalse(self.boundary.busy)

    async def test_only_public_model_ids_are_accepted_and_resolved_internally(self):
        self.boundary.model_paths = {MODEL: Path("/fixture/owned/models") / MODEL}
        await self.invoke()
        self.assertEqual(len(self.calls), 1)
        scope, message = self.calls[0]
        value = json.loads(message["body"])
        self.assertEqual(value["model"], str(self.boundary.model_paths[MODEL]))
        self.assertEqual(self.boundary.selected_model, MODEL)
        self.assertEqual(dict(scope["headers"])[b"content-length"], str(len(message["body"])).encode())
        self.calls.clear()
        output = await self.invoke(raw=json.dumps({"model": str(self.boundary.model_paths[MODEL]),
            "store": False, "stream": True, "input": "Hello"}).encode())
        self.assertEqual(output[0]["status"], 400)
        self.assertEqual(self.calls, [])

    async def asyncSetUp(self):
        self.calls = []
        async def upstream(scope, receive, send):
            self.calls.append((scope, await receive()))
            await send({"type": "http.response.start", "status": 503, "headers": []})
            await send({"type": "http.response.body", "body": b"Unavailable"})
        self.boundary = server.LocalInferenceBoundary(upstream, (MODEL,), "owned-instance", lambda: {})

    async def invoke(self, method="POST", path="/v1/responses", headers=None, raw=None, query=b""):
        body = raw if raw is not None else json.dumps({"model": MODEL, "input": "Hello", "store": False, "stream": True}).encode()
        messages = [{"type": "http.request", "body": body}]
        async def receive():
            return messages.pop(0) if messages else {"type": "http.disconnect"}
        output = []
        async def send(value):
            output.append(value)
        await self.boundary({"type": "http", "method": method, "path": path,
                             "headers": headers or [(b"content-type", b"application/json")],
                             "query_string": query}, receive, send)
        return output

    async def test_request_and_unrelated_upstream_error_are_not_reencoded(self):
        raw = b'{"store": false, "model": "' + MODEL.encode() + b'", "stream":true,"input":"hello"}'
        result = await self.invoke(raw=raw)
        self.assertEqual(self.calls[0][1]["body"], raw)
        self.assertEqual(result[0]["status"], 503)
        self.assertEqual(result[-1]["body"], b"Unavailable")
        self.assertFalse(self.boundary.busy)

    async def test_health_proves_owned_nonce_and_models_do_not_load(self):
        health = await self.invoke("GET", "/health")
        self.assertEqual(json.loads(health[-1]["body"])["heydash_instance"], "owned-instance")
        self.assertIsNone(json.loads(health[-1]["body"])["selected_model"])
        models = await self.invoke("GET", "/v1/models")
        self.assertEqual(json.loads(models[-1]["body"])["data"][0]["id"], MODEL)
        self.assertEqual(self.calls, [])
        self.assertIsNone(self.boundary.selected_model)

    async def test_first_valid_request_pins_model_and_same_model_preserves_bytes(self):
        self.boundary.models = server.MODEL_IDS
        raw = b'{"store": false, "model": "' + MODEL.encode() + b'", "stream":true,"input":"hello"}'
        await self.invoke(raw=raw)
        await self.invoke(raw=raw)
        self.assertEqual(self.boundary.selected_model, MODEL)
        self.assertEqual([call[1]["body"] for call in self.calls], [raw, raw])
        health = json.loads((await self.invoke("GET", "/health"))[-1]["body"])
        self.assertEqual(health["selected_model"], MODEL)
        self.assertFalse(health["busy"])

    async def test_other_model_requires_owned_restart_before_any_dispatch(self):
        self.boundary.models = server.MODEL_IDS
        await self.invoke()
        other = json.dumps({"model": server.MODEL_IDS[1], "input": "Hello", "store": False, "stream": True}).encode()
        result = await self.invoke(raw=other)
        self.assertEqual(result[0]["status"], 409)
        self.assertEqual(json.loads(result[-1]["body"])["error"]["code"], "owned_restart_required")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.boundary.selected_model, MODEL)
        self.assertFalse(self.boundary.busy)
        await self.invoke()
        self.assertEqual(len(self.calls), 2)

    async def test_invalid_requests_do_not_pin_before_another_model_is_selected(self):
        self.boundary.models = server.MODEL_IDS
        for raw in (b"{", json.dumps({"model": MODEL, "input": "Hello", "store": True, "stream": True}).encode(),
                    json.dumps({"model": MODEL, "input": "Hello", "store": False, "stream": True, "max_tokens": 8}).encode()):
            self.assertEqual((await self.invoke(raw=raw))[0]["status"], 400)
            self.assertIsNone(self.boundary.selected_model)
        self.assertEqual(self.calls, [])
        other = json.dumps({"model": server.MODEL_IDS[1], "input": "Hello", "store": False, "stream": True}).encode()
        await self.invoke(raw=other)
        self.assertEqual(self.boundary.selected_model, server.MODEL_IDS[1])
        self.assertEqual(self.calls[0][1]["body"], other)

    async def test_new_process_boundary_can_select_a_different_model(self):
        self.boundary.models = server.MODEL_IDS
        await self.invoke()
        old_boundary = self.boundary
        self.boundary = server.LocalInferenceBoundary(old_boundary.app, server.MODEL_IDS, "new-owned-instance", lambda: {})
        other = json.dumps({"model": server.MODEL_IDS[1], "input": "Hello", "store": False, "stream": True}).encode()
        await self.invoke(raw=other)
        self.assertEqual(old_boundary.selected_model, MODEL)
        self.assertEqual(self.boundary.selected_model, server.MODEL_IDS[1])
        self.assertEqual(len(self.calls), 2)

    async def test_web_origins_queries_and_unneeded_endpoints_reject(self):
        for options, expected in (({"headers": [(b"origin", b"https://evil.test")]}, 403),
                                  ({"query": b"model_dir=/"}, 403), ({"path": "/v1/settings"}, 404),
                                  ({"headers": [(b"content-type", b"text/plain")]}, 415),
                                  ({"method": "OPTIONS"}, 404)):
            result = await self.invoke(**options)
            self.assertEqual(result[0]["status"], expected)
        self.assertEqual(self.calls, [])

    async def test_bounded_body_and_malformed_json_never_reach_upstream(self):
        previous = server.MAX_BODY
        try:
            server.MAX_BODY = 100
            self.assertEqual((await self.invoke(raw=b"x" * 101))[0]["status"], 413)
        finally:
            server.MAX_BODY = previous
        self.assertEqual((await self.invoke(raw=b"{"))[0]["status"], 400)
        raw = json.dumps({"model": MODEL, "input": "hello", "store": False, "stream": True, "temperature": float("nan")}).encode()
        self.assertEqual((await self.invoke(raw=raw))[0]["status"], 400)
        self.assertFalse(self.boundary.busy)
        self.assertEqual(self.calls, [])

    async def test_concurrent_request_is_rejected_without_queue(self):
        self.boundary.busy = True
        self.assertEqual((await self.invoke())[0]["status"], 429)
        self.assertTrue(self.boundary.busy)
        self.assertEqual(self.calls, [])
        self.assertIsNone(self.boundary.selected_model)

    async def test_cancelled_upstream_releases_slot_without_retry(self):
        async def cancel(scope, receive, send):
            self.calls.append(await receive())
            raise asyncio.CancelledError()
        self.boundary.app = cancel
        self.boundary.models = server.MODEL_IDS
        with self.assertRaises(asyncio.CancelledError):
            await self.invoke()
        self.assertFalse(self.boundary.busy)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.boundary.selected_model, MODEL)
        other = json.dumps({"model": server.MODEL_IDS[1], "input": "Hello", "store": False, "stream": True}).encode()
        self.assertEqual((await self.invoke(raw=other))[0]["status"], 409)
        self.assertEqual(len(self.calls), 1)


if __name__ == "__main__":
    unittest.main()
