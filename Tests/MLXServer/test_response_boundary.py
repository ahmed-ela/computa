"""Deterministic ASGI error/stream adaptation; no inference or listener."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[2] / "Sources/Mactopus/Resources/MLXServer"))
from response_boundary import (ResponseBoundary, MAX_ERROR_BODY, context_overflow_budget,
                               is_context_overflow, is_protocol_error)
from sse_contract import ProtocolError


def body(value):
    return json.dumps(value, separators=(",", ":")).encode()


class ErrorShapeTests(unittest.TestCase):
    def test_only_consistent_exact_pinned_context_limit_is_recognized(self):
        message = "Request needs 16400 context tokens (12304 prompt + 4096 max generation), but MAX_KV_SIZE is 16384."
        self.assertTrue(is_context_overflow(body({"detail": message})))
        for other in (message + " ignored", "prefix " + message, message.replace("16400", "16300"),
                      message.replace("16384", "32768"), "Invalid model", None, {"message": message}):
            with self.subTest(other=other):
                self.assertFalse(is_context_overflow(body({"detail": other})))
        self.assertFalse(is_context_overflow(b"not json"))

    def test_only_protocol_exception_groups_are_translated(self):
        self.assertTrue(is_protocol_error(ExceptionGroup("asgi", [ProtocolError("invalid")])) )
        self.assertFalse(is_protocol_error(ExceptionGroup("asgi", [ProtocolError("invalid"), ValueError("other")])))

    def test_budget_metadata_is_numeric_and_matches_the_actual_output_allowance(self):
        raw = body({"detail": "Request needs 16400 context tokens (12304 prompt + 4096 max generation), but MAX_KV_SIZE is 16384."})
        self.assertEqual(context_overflow_budget(raw, max_output_tokens=4096), {
            "input_tokens": 12304, "max_output_tokens": 4096, "context_limit": 16384,
            "required_tokens": 16400, "available_input_tokens": 12288})
        self.assertIsNone(context_overflow_budget(raw, max_output_tokens=2048))
        for prompt, generation in ((16385, 0), (1, 16384), (0, 20000)):
            raw = body({"detail": f"Request needs {prompt + generation} context tokens ({prompt} prompt + {generation} max generation), but MAX_KV_SIZE is 16384."})
            self.assertIsNone(context_overflow_budget(raw))


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_missing_terminal_diagnosis_survives_safe_terminal_error(self):
        await self.start(200, [(b"content-type", b"text/event-stream")])
        created = body({"type": "response.created", "response": {
            "id": "private-response-id", "model": "private-model-path", "status": "in_progress", "output": []}})
        raw = b"data: " + created + b"\n\n"
        with self.assertRaises(ProtocolError) as caught:
            await self.chunk(raw)
        await self.adapter.fail(caught.exception)
        event = json.loads(self.output[-1]["body"].split(b"data: ")[1])
        self.assertEqual(event["type"], "response.failed")
        self.assertEqual(event["response"]["output"], [])
        error = event["response"]["error"]
        self.assertEqual(error["code"], "invalid_prompt")
        self.assertEqual(error["message"], "Local model stream could not be validated. "
            f"[mlx_protocol reason=missing_terminal_response bytes={len(raw)} events=1 items=0 "
            "last=response.created terminal=0 eof=1 causes=1 limited=0]")
        self.assertNotIn("private", error["message"])
        count = len(self.output)
        await self.adapter.fail(caught.exception)
        self.assertEqual(len(self.output), count)
        await self.adapter.finish()

    async def test_unknown_exception_text_never_enters_failure_diagnostic(self):
        secret = "private provider body https://private.example/path"
        await self.adapter.fail(ExceptionGroup(secret, [ProtocolError(secret)]))
        event = json.loads(self.output[-1]["body"].split(b"data: ")[1])
        error = event["response"]["error"]
        self.assertIn("reason=unknown_protocol_error", error["message"])
        self.assertNotIn(secret, error["message"])
        self.assertLess(len(error["message"].encode()), 512)

    async def test_distinct_transport_condition_remains_terminal_and_observable(self):
        with self.assertRaises(ProtocolError) as caught:
            await self.start(200, [(b"content-type", b"application/json")])
        await self.adapter.fail(caught.exception)
        event = json.loads(self.output[-1]["body"].split(b"data: ")[1])
        self.assertEqual(event["response"]["error"]["code"], "invalid_prompt")
        self.assertIn("reason=expected_a_responses_event_stream", event["response"]["error"]["message"])

    async def asyncSetUp(self):
        self.output = []
        async def send(message):
            self.output.append(message)
        self.adapter = ResponseBoundary(send, 4096)

    async def start(self, status=400, headers=None):
        await self.adapter({"type": "http.response.start", "status": status, "headers": headers or []})

    async def chunk(self, data, more=False):
        await self.adapter({"type": "http.response.body", "body": data, "more_body": more})

    async def test_context_overflow_becomes_typed_sse_without_a_completed_event(self):
        raw = body({"detail": "Request needs 20480 context tokens (16384 prompt + 4096 max generation), but MAX_KV_SIZE is 16384."})
        await self.start()
        await self.chunk(raw[:20], True)
        self.assertEqual(self.output, [])
        await self.chunk(raw[20:])
        await self.adapter.finish()
        self.assertEqual(self.output[0]["status"], 200)
        value = json.loads(self.output[1]["body"].split(b"data: ")[1])
        self.assertEqual(value["type"], "response.failed")
        self.assertEqual(value["response"]["error"]["code"], "context_length_exceeded")
        self.assertEqual(value["response"]["output"], [])
        self.assertEqual(value["response"]["context_budget"], {
            "input_tokens": 16384, "max_output_tokens": 4096, "context_limit": 16384,
            "required_tokens": 20480, "available_input_tokens": 12288})

    async def test_wrong_upstream_output_reserve_does_not_trigger_compaction(self):
        raw = body({"detail": "Request needs 17000 context tokens (14952 prompt + 2048 max generation), but MAX_KV_SIZE is 16384."})
        await self.start()
        await self.chunk(raw)
        self.assertEqual(self.output[0]["status"], 400)
        self.assertEqual(self.output[1]["body"], raw)

    async def test_smaller_explicit_output_allowance_is_preserved(self):
        self.adapter = ResponseBoundary(self.adapter.send, 256)
        await self.start()
        await self.chunk(body({"detail": "Request needs 16400 context tokens (16144 prompt + 256 max generation), but MAX_KV_SIZE is 16384."}))
        value = json.loads(self.output[1]["body"].split(b"data: ")[1])
        self.assertEqual(value["response"]["context_budget"]["max_output_tokens"], 256)
        self.assertEqual(value["response"]["context_budget"]["available_input_tokens"], 16128)

    async def test_unrelated_400_is_preserved_byte_for_byte(self):
        raw = b'{ "detail" : "Unknown model" }'
        headers = [(b"content-type", b"application/json"), (b"content-length", str(len(raw)).encode())]
        await self.start(headers=headers)
        await self.chunk(raw[:4], True)
        await self.chunk(raw[4:])
        self.assertEqual(self.output[0]["status"], 400)
        self.assertEqual(self.output[0]["headers"], headers)
        self.assertEqual(self.output[1]["body"], raw)

    async def test_oversized_400_fail_closed_without_forwarding_detail(self):
        await self.start()
        with self.assertRaises(ProtocolError):
            await self.chunk(b"x" * (MAX_ERROR_BODY + 1))
        await self.adapter.fail()
        self.assertEqual(self.output[0]["status"], 200)
        self.assertIn(b'"code":"invalid_prompt"', self.output[1]["body"].replace(b" ", b""))
        self.assertLess(len(self.output[1]["body"]), 1024)

    async def test_success_must_have_sse_content_type_and_complete_body(self):
        with self.assertRaises(ProtocolError):
            await self.start(200, [(b"content-type", b"application/json")])
        await self.adapter.fail()
        self.assertIn(b"response.failed", self.output[-1]["body"])

    async def test_upstream_return_without_eof_is_detected(self):
        with self.assertRaises(ProtocolError):
            await self.adapter.finish()


if __name__ == "__main__":
    unittest.main()
