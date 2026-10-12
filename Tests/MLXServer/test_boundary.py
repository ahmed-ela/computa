"""Offline boundary tests: no MLX import, model load, HTTP listener, or UI."""
import asyncio
import base64
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

path = Path(__file__).parents[2] / "Sources/Computa/Resources/MLXServer/server.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("heydash_mlx", path)
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
MODEL = server.MODEL_IDS[0]


def events(raw):
    return [json.loads(line[6:]) for line in raw.decode().splitlines()
            if line.startswith("data: ") and line[6:] != "[DONE]"]


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
    async def test_app_policy_filters_resumed_tools_but_preserves_exact_history_and_request_ownership(self):
        original = native_tool_request()
        before = copy.deepcopy(original)
        self.boundary.tool_visibility = native_tool_policy()
        observed_names = []
        async def upstream(scope, receive, send):
            from producer_stream import _current
            message = await receive()
            self.calls.append((scope, message))
            observed_names.append(_current.get().allowed_tool_names)
            await send({"type": "http.response.start", "status": 503, "headers": []})
            await send({"type": "http.response.body", "body": b"Unavailable"})
        self.boundary.app = upstream
        output = await self.invoke(raw=json.dumps(original).encode())
        self.assertEqual(output[0]["status"], 503)
        self.assertEqual(len(self.calls), 1)
        scope, message = self.calls[0]
        forwarded = json.loads(message["body"])
        self.assertEqual(forwarded["input"], before["input"])
        self.assertEqual(forwarded["instructions"], before["instructions"])
        self.assertEqual(original, before)
        self.assertEqual(forwarded["model"], MODEL)
        self.assertEqual(dict(scope["headers"])[b"content-length"], str(len(message["body"])).encode())
        self.assertEqual([tool["name"] for tool in forwarded["tools"]], ["computer_v2_open", "functions"])
        self.assertEqual(observed_names, [frozenset(("computer_v2_open", "browser_tabs", "functions.browser_tabs"))])
        opened = forwarded["tools"][0]
        self.assertEqual(opened["description"], "Bind a native app. Use browser_* for webpages.")
        self.assertEqual(opened["parameters"]["properties"]["activation"]["enum"], ["none"])
        self.assertEqual(opened["parameters"]["required"], ["bundle_id", "activation"])
        self.assertNotIn("url", opened["parameters"]["properties"])
        self.assertNotIn("browser_mode", opened["parameters"]["properties"])

    async def test_forced_hidden_tool_never_dispatches_or_pins_a_local_model(self):
        self.boundary.tool_visibility = native_tool_policy()
        for choice in ("required", {"type": "function", "name": "computer_v2_tabs"},
                       {"type": "function", "name": "functions.computer_v2_follow"},
                       {"type": "function", "function": {"name": "computer_v2_bind_tab"}}):
            request = {"model": MODEL, "input": "Synthetic", "store": False, "stream": True,
                       "tools": [{"type": "function", "name": "computer_v2_tabs", "parameters": {}}],
                       "tool_choice": choice}
            output = await self.invoke(raw=json.dumps(request).encode())
            self.assertEqual(output[0]["status"], 400)
            self.assertEqual(self.calls, [])
            self.assertIsNone(self.boundary.selected_model)
            self.assertFalse(self.boundary.busy)

    async def test_child_stream_fault_is_typed_and_scope_clears_before_next_request(self):
        from producer_stream import _current
        from sse_contract import ProtocolError
        captures = []
        async def upstream(scope, receive, send):
            await receive()
            async def child():
                capture = _current.get()
                self.assertIsNotNone(capture)
                captures.append(capture)
                capture.append(capture.raw, "synthetic private source")
                capture.fail("Malformed generated tool call")
            # StreamingResponse may run its iterator in an ASGI child task.
            # Like pinned upstream, catch the producer error into a raw frame.
            try:
                await asyncio.create_task(child())
            except ProtocolError:
                pass
            await send({"type": "http.response.start", "status": 200,
                        "headers": [(b"content-type", b"text/event-stream")]})
            await send({"type": "http.response.body", "body": b'data: {"error":"private"}\n\n'})
        self.boundary.app = upstream
        for _ in range(2):
            out = await self.invoke()
            final = events(out[-1]["body"])[-1]
            self.assertEqual(final["type"], "response.failed")
            self.assertEqual(final["response"]["output"], [])
            self.assertIn("reason=malformed_generated_tool_call", final["response"]["error"]["message"])
            self.assertNotIn("private", json.dumps(final))
            self.assertFalse(self.boundary.busy)
            self.assertIsNone(_current.get())
        self.assertIsNot(captures[0], captures[1])
        self.assertTrue(all(not c.raw and c.fault is None for c in captures))

    async def test_protocol_group_reaches_terminal_diagnostic_and_releases_busy_state(self):
        from sse_contract import ProtocolError
        async def malformed(scope, receive, send):
            await receive()
            raise ExceptionGroup("private upstream context", [ProtocolError("Missing terminal response")])
        # Use the same class imported by the response adapter; no MLX import or listener.
        self.boundary.app = malformed
        output = await self.invoke()
        value = events(output[-1]["body"])[-1]
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

    async def test_request_preserved_and_upstream_error_normalized_without_exception_body(self):
        raw = b'{"store": false, "model": "' + MODEL.encode() + b'", "stream":true,"input":"hello"}'
        result = await self.invoke(raw=raw)
        self.assertEqual(self.calls[0][1]["body"], raw)
        self.assertEqual(result[0]["status"], 503)
        self.assertEqual(json.loads(result[-1]["body"])["error"]["type"], "server_error")
        self.assertNotIn(b"Unavailable", result[-1]["body"])
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


def native_tool_policy():
    return server.NativeToolVisibility({"COMPUTA_EXTERNAL_CHROME_TOOLS_ENABLED": "0",
        "COMPUTA_NATIVE_TOOL_OVERRIDES": json.dumps([{"name": "computer_v2_open",
            "description": "Bind a native app. Use browser_* for webpages.",
            "inputSchema": {"activation": {"enum": ["foreground"]}}}])})


def native_tool_request():
    open_tool = {"type": "function", "name": "computer_v2_open", "description": "Old Chrome instructions",
        "parameters": {"type": "object", "properties": {
            "bundle_id": {"type": "string"}, "activation": {"type": "string", "enum": ["none"]},
            "url": {"type": "string"}, "browser_mode": {"type": "string", "enum": ["chrome"]}},
            "required": ["bundle_id", "activation", "url", "browser_mode"], "additionalProperties": False}}
    return {"model": MODEL, "store": False, "stream": True, "instructions": "Synthetic trusted instructions",
        "input": [{"type": "function_call", "name": "computer_v2_tabs", "call_id": "old-call", "arguments": "{}"},
                  {"type": "function_call_output", "call_id": "old-call", "output": "Synthetic saved tab observation"},
                  {"type": "message", "role": "user", "content": "Use the built-in browser now."}],
        "tools": [open_tool, *[{"type": "function", "name": name, "parameters": {}}
                               for name in sorted(server.CHROME_TOOL_NAMES)],
                  {"type": "namespace", "name": "functions", "tools": [
                      {"type": "function", "name": "computer_v2_follow", "parameters": {}},
                      {"type": "function", "name": "browser_tabs", "parameters": {}}]}]}


class NativeToolVisibilityTests(unittest.TestCase):
    def test_generic_and_explicit_chrome_enabled_profiles_preserve_original_request(self):
        request = native_tool_request()
        for environment in ({}, {"COMPUTA_EXTERNAL_CHROME_TOOLS_ENABLED": "1",
                                  "COMPUTA_NATIVE_TOOL_OVERRIDES": "not-used"}):
            result, allowed = server.NativeToolVisibility(environment).apply(request)
            self.assertIs(result, request)
            self.assertIsNone(allowed)

    def test_empty_hidden_namespace_is_removed_and_unrelated_definitions_are_unchanged(self):
        other = {"type": "function", "name": "synthetic_echo", "description": "Synthetic",
                 "parameters": {"type": "object", "properties": {"text": {"type": "string"}}}}
        request = {"tools": [{"type": "namespace", "name": "functions", "tools": [
            {"type": "function", "name": "computer_v2_tabs", "parameters": {}}]}, other]}
        before = copy.deepcopy(request)
        result, names = native_tool_policy().apply(request)
        self.assertEqual(result["tools"], [other])
        self.assertEqual(names, frozenset(("synthetic_echo",)))
        self.assertEqual(request, before)

    def test_invalid_startup_policy_and_native_open_shape_fail_closed(self):
        for overrides in ("not-json", "{}", '[{"name":"computer_v2_open","description":false}]',
                          '[{"name":"computer_v2_open","description":"a"},{"name":"computer_v2_open","description":"b"}]'):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                server.NativeToolVisibility({"COMPUTA_EXTERNAL_CHROME_TOOLS_ENABLED": "0",
                                             "COMPUTA_NATIVE_TOOL_OVERRIDES": overrides})
        with self.assertRaises(ValueError):
            server.NativeToolVisibility({"COMPUTA_EXTERNAL_CHROME_TOOLS_ENABLED": "unexpected"})
        with self.assertRaises(ValueError):
            native_tool_policy().apply({"tools": [{"type": "function", "name": "computer_v2_open", "parameters": {}}]})

    def test_decoder_rejects_hidden_generated_call_even_with_a_stale_registry_and_clears_scope(self):
        from producer_stream import producer_scope
        from sse_contract import ProtocolError
        parsed = []
        module = SimpleNamespace(__name__="mlx_vlm.tools.parsers.qwen3_coder",
            parse_tool_call=lambda body, tools: parsed.append(body) or {"name": "computer_v2_tabs", "arguments": {}})
        with producer_scope(allowed_tool_names=frozenset(("browser_tabs",))) as capture:
            capture.content = ["<tool_call><function=computer_v2_tabs></function></tool_call>"]
            state = SimpleNamespace(tc_start="<tool_call>", tc_end="</tool_call>", in_tool_call=False, buffer="")
            capture.tools = SimpleNamespace(delegate=state, inputs=[])
            with self.assertRaisesRegex(ProtocolError, "Unadvertised generated tool call"):
                capture.parse_calls(module, [], {"computer_v2_tabs": "function"})
            self.assertEqual(parsed, [])
        self.assertIsNone(capture.allowed_tool_names)
        with producer_scope() as generic:
            generic.content = ["<tool_call><function=computer_v2_tabs></function></tool_call>"]
            generic.tools = SimpleNamespace(delegate=state, inputs=[])
            self.assertEqual(len(generic.parse_calls(module, [], {"computer_v2_tabs": "function"})), 1)
        self.assertEqual(len(parsed), 1)


if __name__ == "__main__":
    unittest.main()
