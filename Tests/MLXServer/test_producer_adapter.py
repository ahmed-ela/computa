"""Actual pinned producer + app adapter + unchanged strict SSE consumer.

Only synthetic token strings are provided; no model weights, local history,
private captures, network listeners or computer-use surfaces are accessed.
"""
import asyncio
import json

from test_producer_stream import (MALFORMED_CALL, PinnedEndpointHarness,
                                  VALID_CALL, decoded_events)
from producer_stream import _current, install_producer_adapter, producer_scope
from response_boundary import ResponseBoundary
from sse_contract import ProtocolError
from producer_stream import ProducerCapture
from unittest.mock import patch


class ProducerAdapterTests(PinnedEndpointHarness):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        install_producer_adapter(cls.openai)

    async def adapted(self, chunks, **kwargs):
        forwarded, errors = [], []

        async def send(message):
            forwarded.append(message)

        with producer_scope() as capture:
            boundary = ResponseBoundary(send, 4096, capture)
            await boundary({"type": "http.response.start", "status": 200,
                            "headers": [(b"content-type", b"text/event-stream")]})

            async def consume(chunk, final):
                if boundary.closed:
                    return
                try:
                    await boundary({"type": "http.response.body", "body": chunk,
                                    "more_body": not final})
                except ProtocolError as error:
                    errors.append(error)
                    await boundary.fail(error)

            raw, upstream = await self.produce(chunks, require_completed=False,
                                               on_chunk=consume, **kwargs)
            await boundary.finish()
            self.assertIs(_current.get(), capture)
        self.assertIsNone(_current.get())
        self.assertEqual(capture.raw, [])
        self.assertEqual(capture.content, [])
        self.assertEqual(capture.public, [])
        self.assertEqual(capture.reasoning, [])
        self.assertIsNone(capture.thinking)
        self.assertIsNone(capture.tools)
        wire = b"".join(item.get("body", b"") for item in forwarded)
        return decoded_events(wire), upstream, errors

    async def test_actual_plain_html_unicode_and_whitespace_are_byte_exact(self):
        public = "\n<b>synthetic</b> 東京 🌍\t\n"
        events, _, errors = await self.adapted([public[:7], public[7:]], tools=False)
        self.assertEqual(errors, [])
        self.assertEqual(events[-1]["type"], "response.completed")
        self.assertEqual(events[-1]["response"]["output_text"], public)
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), public)

    async def test_actual_html_and_tool_use_same_streamed_public_text(self):
        before, after = "<b>synthetic</b>\n", "\n<i>still public</i>"
        events, upstream, errors = await self.adapted([before, VALID_CALL, after])
        self.assertEqual(errors, [])
        self.assertEqual(events[-1]["type"], "response.completed")
        public = before + after
        self.assertEqual(events[-1]["response"]["output_text"], public)
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), public)
        calls = [i for i in events[-1]["response"]["output"] if i["type"] == "function_call"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads(calls[0]["arguments"]), {"text": "synthetic marker"})
        original = [i for i in upstream[-1]["response"]["output"] if i["type"] == "function_call"]
        self.assertEqual(calls, original)

    async def test_prompt_open_thinking_only_below_cap_fails_without_public_output(self):
        private = "Synthetic unfinished private thought"
        events, upstream, errors = await self.adapted([private], thinking=True)
        self.assertLess(upstream[-1]["response"]["usage"]["output_tokens"], 4096)
        self.assertEqual(len(errors), 1)
        self.assertEqual(str(errors[0]), "Missing generated public output")
        self.assertEqual(events[-1]["type"], "response.failed")
        self.assertEqual(events[-1]["response"].get("output_text", ""), "")
        self.assertEqual(events[-1]["response"]["output"], [])
        self.assertEqual(events[-1]["response"]["error"]["code"], "invalid_prompt")
        self.assertIn("reason=missing_generated_public_output", events[-1]["response"]["error"]["message"])
        self.assertNotIn(private, json.dumps(events[-1]))
        self.assertFalse(any(e["type"] in ("response.completed", "response.incomplete",
                                           "response.output_item.done") for e in events))
        self.assertFalse(any(e["type"] == "response.output_text.delta" for e in events))

    async def test_tool_examples_in_thinking_never_become_executable(self):
        events, _, errors = await self.adapted([
            "Example only: " + VALID_CALL, "</think>\n", "Synthetic answer"], thinking=True)
        self.assertEqual(errors, [])
        self.assertEqual(events[-1]["response"]["output_text"], "Synthetic answer")
        self.assertFalse(any(i["type"] == "function_call" for i in events[-1]["response"]["output"]))

    async def test_malformed_incomplete_nested_and_duplicate_parameters_fail_typed(self):
        values = [
            (MALFORMED_CALL, "malformed_generated_tool_call"),
            (VALID_CALL.removesuffix("</tool_call>"), "incomplete_generated_tool_call"),
            ("<tool_call>" + VALID_CALL + "</tool_call>", "malformed_generated_tool_call"),
            (VALID_CALL.replace("</parameter>", "</parameter><parameter=text>duplicate</parameter>"),
             "malformed_generated_tool_call"),
            (VALID_CALL.replace("synthetic_echo", "unadvertised_function"),
             "unadvertised_generated_tool_call"),
        ]
        for text, reason in values:
            with self.subTest(reason=reason):
                events, _, errors = await self.adapted([text])
                self.assertEqual(len(errors), 1)
                final = events[-1]
                self.assertEqual(final["type"], "response.failed")
                self.assertEqual(final["response"]["output"], [])
                self.assertIn("reason=" + reason, final["response"]["error"]["message"])
                self.assertNotIn(text, json.dumps(final))
                self.assertFalse(any(e["type"] == "response.output_item.done" for e in events))

    async def test_same_function_may_be_called_twice_with_distinct_exact_ids(self):
        second = VALID_CALL.replace("synthetic marker", "different synthetic marker")
        events, _, errors = await self.adapted([VALID_CALL, second])
        self.assertEqual(errors, [])
        calls = [i for i in events[-1]["response"]["output"] if i["type"] == "function_call"]
        self.assertEqual(len(calls), 2)
        self.assertNotEqual(calls[0]["id"], calls[1]["id"])
        self.assertNotEqual(calls[0]["call_id"], calls[1]["call_id"])
        self.assertEqual([json.loads(i["arguments"])["text"] for i in calls],
                         ["synthetic marker", "different synthetic marker"])

    async def test_valid_tool_delimiters_are_chunk_independent(self):
        for split in range(1, len(VALID_CALL)):
            with self.subTest(split=split):
                events, _, errors = await self.adapted([VALID_CALL[:split], VALID_CALL[split:]])
                self.assertEqual(errors, [])
                self.assertEqual(events[-1]["type"], "response.completed")
                self.assertEqual(events[-1]["response"]["output_text"], "")
                calls = [i for i in events[-1]["response"]["output"] if i["type"] == "function_call"]
                self.assertEqual(len(calls), 1)
                self.assertEqual(json.loads(calls[0]["arguments"]), {"text": "synthetic marker"})

    async def test_iterator_eof_held_prefix_fails_without_terminal_promotion(self):
        events, _, errors = await self.adapted(["Visible prefix <thi"],
                                               tools=False, finish_reason=None)
        self.assertEqual(len(errors), 1)
        self.assertEqual(events[-1]["type"], "response.failed")
        self.assertIn("reason=producer_ended_with_buffered_text",
                      events[-1]["response"]["error"]["message"])
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), "Visible prefix ")
        self.assertNotIn("<thi", json.dumps(events))

    async def test_adapter_is_idempotent_and_sequential_failure_does_not_leak(self):
        original = self.openai.make_response_stream_state
        install_producer_adapter(self.openai)
        self.assertIs(self.openai.make_response_stream_state, original)
        failed, _, _ = await self.adapted([MALFORMED_CALL])
        passed, _, errors = await self.adapted(["Independent public answer"], tools=False)
        self.assertEqual(failed[-1]["type"], "response.failed")
        self.assertEqual(errors, [])
        self.assertEqual(passed[-1]["response"]["output_text"], "Independent public answer")

    async def test_concurrent_and_cancelled_scopes_are_isolated_and_cleared(self):
        # Do not concurrently patch the endpoint's global fake worker. Instead
        # interleave its actual adapted parser factories in independent tasks.
        from mlx_vlm.tools.parsers import qwen3_coder
        from test_producer_stream import TOOL
        chat_tools, registry = self.openai._response_tool_registry([TOOL])
        captures = []
        ready = [asyncio.Event(), asyncio.Event()]

        async def one(index, public):
            with producer_scope() as capture:
                captures.append(capture)
                tools = self.openai.ToolCallStreamState("<tool_call>", "</tool_call>")
                thinking = self.openai.make_response_stream_state(None, False)
                ready[index].set()
                await ready[1 - index].wait()
                delta = thinking.feed(public, last=True)
                self.assertEqual(tools.feed(delta.content, last=True), public)
                await asyncio.sleep(0)
                self.assertIs(_current.get(), capture)
                items, text, _, _ = self.openai._response_output_items_from_text(
                    public, "message_" + str(index), qwen3_coder, chat_tools, registry)
                self.assertEqual(text, public)
                self.assertEqual(items[0]["content"][0]["text"], public)
            return text

        self.assertEqual(await asyncio.gather(one(0, "First synthetic"), one(1, "Second synthetic")),
                         ["First synthetic", "Second synthetic"])
        self.assertIsNone(_current.get())
        entered = asyncio.Event()

        async def cancelled():
            with producer_scope() as capture:
                captures.append(capture)
                thinking = self.openai.make_response_stream_state(None, False)
                thinking.feed("Cancelled synthetic")
                entered.set()
                await asyncio.Future()

        task = asyncio.create_task(cancelled())
        await entered.wait()
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertIsNone(_current.get())
        for capture in captures:
            self.assertEqual(capture.raw, [])
            self.assertEqual(capture.content, [])
            self.assertEqual(capture.public, [])
            self.assertEqual(capture.reasoning, [])
            self.assertIsNone(capture.thinking)
            self.assertIsNone(capture.tools)

    async def test_outside_scope_still_delegates_to_pinned_behavior(self):
        raw, events = await self.produce([MALFORMED_CALL])
        self.assertEqual(events[-1]["response"]["output_text"], MALFORMED_CALL)
        self.require_contract_rejection(raw, "Unstreamed final text")

    async def test_capture_bounds_and_unicode_fail_with_fixed_payload_free_errors(self):
        capture = ProducerCapture()
        with self.assertRaisesRegex(ProtocolError, "Invalid producer text"):
            capture.append(capture.raw, "\ud800")
        from sse_contract import SSEContract
        with patch.object(SSEContract, "MAX_STREAM_BYTES", 4):
            with self.assertRaisesRegex(ProtocolError, "Producer capture exceeds bound"):
                capture.append(capture.raw, "12345")
        self.assertEqual(capture.raw, [])

    async def test_scope_cleans_retained_wrappers_and_error_tracebacks(self):
        retained = []
        with self.assertRaisesRegex(ProtocolError, "Producer state mismatch"):
            with producer_scope() as capture:
                tools = self.openai.ToolCallStreamState("<tool_call>", "</tool_call>")
                thinking = self.openai.make_response_stream_state(None, False)
                retained.extend([tools, thinking])
                delta = thinking.feed("Synthetic private prefix <thi")
                tools.feed(delta.content)
                capture.fail("Producer state mismatch")
        self.assertEqual(retained[0].inputs, [])
        self.assertTrue(all(item.delegate.buffer == "" for item in retained))
        self.assertIsNone(capture.fault)
        self.assertIsNone(_current.get())


if __name__ == "__main__":
    import unittest
    unittest.main()
