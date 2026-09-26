"""Deterministic ASGI error/stream adaptation; no inference or listener."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parents[2] / "Sources/Macrouse/Resources/MLXServer"))
from response_boundary import ResponseBoundary, MAX_ERROR_BODY, is_context_overflow, is_protocol_error
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


class AdapterTests(unittest.IsolatedAsyncioTestCase):
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
