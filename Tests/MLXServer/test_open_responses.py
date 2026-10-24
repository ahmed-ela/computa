"""Owned local profile normalization; no model loads, UI, or network."""
import copy
import asyncio
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / "Sources/Computa/Resources/MLXServer"))
from open_responses import DONE, ResponseProfile, sampling_parameters
from producer_stream import install_producer_adapter, producer_scope
from sse_contract import ProtocolError, SSEContract
from server import LocalInferenceBoundary
from test_sse_contract import CALL, fixture, parse, wire


MODEL = "lmstudio-community/Qwen3.5-4B-MLX-4bit"
REQUEST = {"model": MODEL, "store": False, "stream": True, "input": "Synthetic fixture",
           "instructions": "Synthetic instructions", "max_output_tokens": 100,
           "tools": [{"type": "function", "name": CALL["name"], "parameters": {"type": "object"}}],
           "tool_choice": "auto", "parallel_tool_calls": False, "metadata": {"fixture": "local"}}
SAMPLER = {"temperature": 0.23, "top_p": 0.81, "presence_penalty": 0.12,
           "frequency_penalty": 0.34, "top_logprobs": 0}


def profile(request=None, sampling=None):
    return ResponseProfile(request or REQUEST, SimpleNamespace(sampling=sampling or dict(SAMPLER)), 100)


class OpenResponsesTests(unittest.TestCase):
    artifacts = {}

    @classmethod
    def tearDownClass(cls):
        destination = os.environ.get("COMPUTA_OPEN_RESPONSES_ARTIFACTS")
        if not destination:
            return
        directory = Path(destination)
        directory.mkdir(parents=True, exist_ok=True)
        cases = []
        for name, (data, kind, status) in cls.artifacts.items():
            filename = name + (".sse" if kind == "sse" else ".json")
            (directory / filename).write_bytes(data)
            item = {"name": name, "file": filename, "kind": kind}
            if name == "mlx-codex-local-usage":
                item["profile"] = "codex-local-usage"
            if status is not None:
                item["expectStatus"] = status
            cases.append(item)
        (directory / "manifest.json").write_text(json.dumps({"version": 1, "cases": cases}, indent=2))

    def test_effective_sampler_wins_over_request_and_private_model_path(self):
        request = {**REQUEST, "temperature": 1.9, "top_p": 0.1}
        source = fixture()[0]["response"]
        source["model"] = "/synthetic/private/model/path"
        resource = profile(request).resource(source)
        self.assertEqual(resource["model"], MODEL)
        self.assertEqual(resource["temperature"], SAMPLER["temperature"])
        self.assertEqual(resource["top_p"], SAMPLER["top_p"])
        self.assertTrue(resource["metadata"]["computa_sampling"]["verified"])
        self.assertIsNone(resource["completed_at"])
        self.assertEqual(resource["tools"][0]["strict"], None)
        self.assertEqual(resource["tools"][0]["description"], None)
        self.assertNotIn("input", profile(request).request)
        self.assertEqual(request["temperature"], 1.9)

    def test_partial_measured_usage_never_invents_reasoning_zero(self):
        source = fixture(reasoning="Synthetic reasoning")[-1]["response"]
        source["usage"]["input_tokens_details"] = {"cached_tokens": 0}
        original = copy.deepcopy(source["usage"])
        result = profile().resource(source)
        self.assertIsNone(result["usage"])
        self.assertEqual(result["metadata"]["computa_measured_usage"], original)
        self.assertFalse(result["metadata"]["computa_usage_details_complete"])
        self.assertNotIn("output_tokens_details", result["metadata"]["computa_measured_usage"])
        self.assertEqual(source["usage"], original)

    def test_genuinely_complete_usage_breakdown_is_preserved(self):
        source = fixture()[-1]["response"]
        source["usage"].update(input_tokens_details={"cached_tokens": 7},
                               output_tokens_details={"reasoning_tokens": 3})
        result = profile().resource(source)
        self.assertEqual(result["usage"], source["usage"])
        self.assertNotIn("computa_measured_usage", result["metadata"])
        self.artifacts["mlx-complete-usage"] = (json.dumps(result).encode(), "response", "completed")

    def test_codex_usage_profile_preserves_partial_counts_without_inventing_details(self):
        source = fixture(public="", reasoning="Synthetic reasoning", call=CALL)
        source[-1]["response"]["usage"]["input_tokens_details"] = {"cached_tokens": 7}
        measured = copy.deepcopy(source[-1]["response"]["usage"])
        codex_profile = ResponseProfile(REQUEST, SimpleNamespace(sampling=dict(SAMPLER)), 100,
                                       codex_usage=True)
        contract = SSEContract(100, codex_profile)
        result = contract.feed(wire(source)) + contract.finish()
        response = parse(result)[-1]["response"]
        self.assertEqual(response["usage"], measured)
        self.assertEqual(response["metadata"]["computa_measured_usage"], measured)
        self.assertFalse(response["metadata"]["computa_usage_details_complete"])
        self.assertEqual(response["metadata"]["computa_responses_profile"], "codex-local-usage")
        self.assertNotIn("output_tokens_details", response["usage"])
        self.assertEqual(source[-1]["response"]["usage"], measured)
        self.artifacts["mlx-codex-local-usage"] = (result, "sse", "completed")

    def test_only_defined_codex_routes_are_enabled_and_keep_strict_request_constraints(self):
        async def check():
            calls = []
            async def upstream(scope, receive, send):
                calls.append(scope["path"])
                await send({"type": "http.response.start", "status": 503, "headers": []})
                await send({"type": "http.response.body", "body": b"synthetic"})
            boundary = LocalInferenceBoundary(upstream, [MODEL], "fixture", lambda: {})
            async def invoke(path, method="POST", body=REQUEST):
                output = []
                async def receive():
                    return {"type": "http.request", "body": json.dumps(body).encode()}
                async def send(message):
                    output.append(message)
                await boundary({"type": "http", "method": method, "path": path, "query_string": b"",
                    "headers": [(b"content-type", b"application/json")]}, receive, send)
                return output
            for path in ("/v1/models", "/v1/codex/models"):
                result = await invoke(path, "GET")
                self.assertEqual(result[0]["status"], 200)
                self.assertEqual(json.loads(result[-1]["body"])["data"][0]["id"], MODEL)
            for path in ("/v1/codex", "/v1/codex/other", "/v1/codex/codex/responses"):
                self.assertEqual((await invoke(path))[0]["status"], 404)
            self.assertEqual((await invoke("/v1/codex/responses", body={**REQUEST, "stream": False}))[0]["status"], 400)
            self.assertEqual((await invoke("/v1/codex/responses"))[0]["status"], 503)
            self.assertEqual(calls, ["/v1/responses"])
        asyncio.run(check())

    def test_invalid_usage_breakdown_never_releases_executable_item(self):
        for details in ({"cached_tokens": True}, {"cached_tokens": -1}, {"cached_tokens": 101}):
            contract = SSEContract(100, profile())
            source = fixture(public="", call=CALL)
            source[-1]["response"]["usage"]["input_tokens_details"] = details
            before = contract.feed(wire(source[:-1]))
            with self.subTest(details=details), self.assertRaisesRegex(ProtocolError, "Invalid usage details"):
                contract.feed(wire(source[-1:]))
            self.assertFalse(any(e["type"] == "response.output_item.done" for e in parse(before + contract.failure())))

    def test_finite_http_errors_use_standard_payload_and_never_replay_work(self):
        async def check():
            calls = []
            async def upstream(scope, receive, send):
                calls.append(await receive())
                await send({"type": "http.response.start", "status": 503, "headers": []})
                await send({"type": "http.response.body", "body": b"private exception body"})
            boundary = LocalInferenceBoundary(upstream, [MODEL], "fixture", lambda: {})
            async def invoke(request, path="/v1/responses", headers=None):
                output = []
                async def receive():
                    return {"type": "http.request", "body": json.dumps(request).encode()}
                async def send(message):
                    output.append(message)
                await boundary({"type": "http", "method": "POST", "path": path,
                    "query_string": b"", "headers": headers or [(b"content-type", b"application/json")]}, receive, send)
                return output
            for name, request, path, status, kind in (
                ("mlx-invalid-request", {**REQUEST, "stream": False}, "/v1/responses", 400, "invalid_request"),
                ("mlx-not-found", REQUEST, "/other", 404, "not_found"),
                ("mlx-server-error", REQUEST, "/v1/responses", 503, "server_error"),
            ):
                output = await invoke(request, path)
                self.assertEqual(output[0]["status"], status)
                raw = output[-1]["body"]
                value = json.loads(raw)
                self.assertEqual(value["error"]["type"], kind)
                self.assertFalse(value["error"]["retryable"])
                self.assertIn("param", value["error"])
                self.assertIn("code", value["error"])
                self.assertNotIn(b"private", raw)
                self.artifacts[name] = (raw, "error", None)
            self.assertEqual(len(calls), 1)
            boundary.busy = True
            output = await invoke(REQUEST)
            self.assertEqual(output[0]["status"], 429)
            value = json.loads(output[-1]["body"])
            self.assertEqual(value["error"]["type"], "too_many_requests")
            self.assertFalse(value["error"]["retryable"])
            self.assertEqual(len(calls), 1)
        asyncio.run(check())

    def test_pinned_argument_seam_captures_actual_values_and_clears_between_requests(self):
        arguments = SimpleNamespace(**{key: value for key, value in SAMPLER.items() if key != "top_logprobs"})
        upstream = SimpleNamespace(make_response_stream_state=lambda: None, ToolCallStreamState=lambda: None,
            _response_output_items_from_text=lambda: None, _build_gen_args=lambda *a, **kw: arguments)
        with patch("producer_stream.importlib.metadata.version", return_value="0.7.1"):
            install_producer_adapter(upstream)
        with producer_scope() as first:
            self.assertIs(upstream._build_gen_args(object()), arguments)
            self.assertEqual(first.sampling, SAMPLER)
            self.assertEqual(profile(sampling=first.sampling).resource(fixture()[0]["response"])["temperature"], 0.23)
        self.assertIsNone(first.sampling)
        with producer_scope() as second:
            self.assertIsNone(second.sampling)
            self.assertIsNot(first, second)

    def test_missing_or_nonfinite_effective_sampler_fails_closed(self):
        for values in ({"temperature": float("nan"), "top_p": 1}, {"temperature": False, "top_p": 1}, {}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                sampling_parameters(SimpleNamespace(**values))
        contract = SSEContract(100, ResponseProfile(REQUEST, SimpleNamespace(sampling=None), 100))
        with self.assertRaisesRegex(ProtocolError, "Missing effective sampling configuration"):
            contract.feed(wire(fixture()[:1]))
        output = contract.failure()
        events = parse(output)
        self.assertEqual([e["type"] for e in events], ["response.created", "error", "response.failed"])
        self.assertFalse(events[-1]["response"]["metadata"]["computa_sampling"]["verified"])
        self.assertTrue(output.endswith(DONE))

    def test_completed_incomplete_and_failure_streams_end_once_after_terminal(self):
        for name, source, status in (
            ("mlx-completed", fixture(public="Synthetic answer", reasoning="Synthetic reasoning"), "completed"),
            ("mlx-incomplete", fixture(public="Partial answer", tokens=100), "incomplete"),
        ):
            with self.subTest(status=status):
                contract = SSEContract(100, profile())
                before = contract.feed(wire(source))
                self.assertNotIn(DONE, before)
                self.assertFalse(any(e["type"] == "response.output_item.done" for e in parse(before)))
                result = before + contract.finish()
                events = parse(result)
                self.assertEqual(events[-1]["type"], "response." + status)
                self.assertEqual(result.count(DONE), 1)
                self.assertTrue(result.endswith(DONE))
                self.assertEqual([e["sequence_number"] for e in events], list(range(len(events))))
                self.assertEqual(events[-1]["response"]["metadata"]["computa_measured_usage"], source[-1]["response"]["usage"])
                self.assertIsNone(events[-1]["response"]["usage"])
                self.artifacts[name] = (result, "sse", status)
        contract = SSEContract(100, profile())
        result = contract.failure()
        events = parse(result)
        self.assertEqual([e["type"] for e in events], ["response.created", "error", "response.failed"])
        self.assertEqual(events[1]["error"], events[2]["response"]["error"])
        self.assertEqual(events[1]["error"]["type"], "model_error")
        self.assertFalse(events[1]["error"]["retryable"])
        self.assertEqual(result.count(DONE), 1)
        self.assertEqual(contract.failure(), b"")
        self.artifacts["mlx-failed"] = (result, "sse", "failed")

    def test_public_catalog_model_does_not_weaken_internal_identity_or_tool_guard(self):
        source = fixture(public="", call=CALL)
        for item in source:
            if "response" in item:
                item["response"]["model"] = "/synthetic/private/path"
        contract = SSEContract(100, profile())
        before = contract.feed(wire(source[:-1]))
        self.assertFalse(any(e["type"] == "response.output_item.done" for e in parse(before)))
        source[-1]["response"]["model"] = "/synthetic/different/path"
        with self.assertRaisesRegex(ProtocolError, "Terminal identity mismatch"):
            contract.feed(wire(source[-1:]))
        self.assertFalse(any(e["type"] == "response.output_item.done" for e in parse(contract.failure())))

    def test_function_lifecycle_has_exact_arguments_and_preserves_eof_admission(self):
        contract = SSEContract(100, profile())
        before = contract.feed(wire(fixture(public="", call=CALL)))
        events = parse(before)
        added = next(e["item"] for e in events if e["type"] == "response.output_item.added")
        self.assertEqual(added["status"], "in_progress")
        self.assertEqual(added["arguments"], "")
        self.assertEqual("".join(e["delta"] for e in events if e["type"] == "response.function_call_arguments.delta"), CALL["arguments"])
        self.assertFalse(any(e["type"] == "response.output_item.done" for e in events))
        result = before + contract.finish()
        events = parse(result)
        self.assertEqual(events[-1]["response"]["output"][0], CALL)
        self.assertTrue(result.endswith(DONE))
        self.artifacts["mlx-function-call"] = (result, "sse", "completed")

    def test_empty_message_never_exposes_a_content_part_absent_from_final_item(self):
        for source in (fixture(public="", call=CALL),
                       fixture(public="", reasoning="Synthetic reasoning", tokens=100)):
            # The producer may publish a zero-length token before tool/reasoning
            # output. It must not expose an empty content lifecycle prematurely.
            source.insert(4, {"type": "response.output_text.delta", "item_id": "msg_fixture",
                              "output_index": 0, "content_index": 0, "delta": ""})
            contract = SSEContract(100, profile())
            result = contract.feed(wire(source)) + contract.finish()
            events = parse(result)
            self.assertFalse(any(e["type"].startswith("response.content_part.") for e in events))
            self.assertFalse(any(e["type"].startswith("response.output_text.") for e in events))
            message = next(item for item in events[-1]["response"]["output"] if item["type"] == "message")
            self.assertEqual(message["content"], [])


if __name__ == "__main__":
    unittest.main()
