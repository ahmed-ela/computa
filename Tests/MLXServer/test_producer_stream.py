"""Synthetic-only reproduction of the pinned MLX Responses producer boundary.

Uses the real endpoint and parser classes with a hardcoded token iterator. No
model, processor assets, private capture, listener, live app, or browser is used.
These are producer characterization tests, not proof of a historical live cause.
Run in the already-installed pinned mlx-vlm 0.7.1 Python environment.
"""
from contextlib import ExitStack
import importlib.metadata
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).parents[2] / "Sources/Computa/Resources/MLXServer"))
from sse_contract import ProtocolError, SSEContract


TOOL = {"type": "function", "name": "synthetic_echo", "parameters": {
    "type": "object", "properties": {"text": {"type": "string"}},
    "required": ["text"], "additionalProperties": False}}
VALID_CALL = ("<tool_call>\n<function=synthetic_echo>\n"
              "<parameter=text>synthetic marker</parameter>\n"
              "</function>\n</tool_call>")
MALFORMED_CALL = "<tool_call>synthetic non-function payload</tool_call>"


def decoded_events(raw):
    return [json.loads(line[6:]) for line in raw.decode().splitlines()
            if line.startswith("data: ")]


class PinnedEndpointHarness(unittest.IsolatedAsyncioTestCase):
    """Shared fake generation setup; contains no test methods or live inputs."""
    @classmethod
    def setUpClass(cls):
        try:
            pinned = importlib.metadata.version("mlx-vlm") == "0.7.1"
        except importlib.metadata.PackageNotFoundError:
            pinned = False
        if not pinned:
            raise unittest.SkipTest("Requires already-installed pinned mlx-vlm 0.7.1")
        # Importing the endpoint does not load weights or start its generator.
        # Every subsequent model/generation entry point is replaced below.
        from mlx_vlm.server import generation, openai
        from starlette.requests import Request
        cls.generation, cls.openai, cls.Request = generation, openai, Request

    async def produce(self, chunks, *, thinking=False, tools=True, finish_reason="stop",
                      adapter_context=None, require_completed=True, on_chunk=None):
        self.assertTrue(chunks)
        processor = SimpleNamespace(tokenizer=SimpleNamespace(response_template=None))
        args = self.generation.GenerationArguments(max_tokens=4096, enable_thinking=thinking)
        tokens = [self.generation.StreamingToken(
            text=text, token=0, logprobs=0.0,
            finish_reason=finish_reason if index == len(chunks) - 1 else None,
        ) for index, text in enumerate(chunks)]

        def synthetic_tokens():
            yield from tokens

        generator = SimpleNamespace(generate=Mock(return_value=(
            SimpleNamespace(prompt_tokens=7), synthetic_tokens())))
        body = json.dumps({"model": "synthetic-only", "input": "Synthetic parser test",
            "stream": True, "store": False, "max_output_tokens": 4096,
            "tools": [TOOL] if tools else []}).encode()

        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}

        request = self.Request({"type": "http", "method": "POST", "path": "/v1/responses",
                                "headers": []}, receive)
        with ExitStack() as stack:
            stack.enter_context(patch.object(self.openai, "get_cached_model",
                return_value=(None, processor, {})))
            stack.enter_context(patch.object(self.openai, "_build_gen_args", return_value=args))
            stack.enter_context(patch.object(self.openai, "apply_chat_template",
                return_value="<|im_start|>assistant\n<think>\n" if thinking else "synthetic prompt"))
            stack.enter_context(patch.object(self.openai, "_infer_tool_parser_from_processor",
                return_value="qwen3_coder"))
            preflight = stack.enter_context(patch.object(self.openai,
                "_preflight_stream_context_budget", new=AsyncMock()))
            stack.enter_context(patch.object(self.openai.runtime, "response_generator", generator))
            stack.enter_context(patch.object(self.openai.runtime, "metrics", Mock()))
            forbidden = stack.enter_context(patch.object(self.openai, "stream_generate",
                side_effect=AssertionError("No inference is allowed in this test")))
            stack.enter_context(patch.object(self.openai, "generate",
                side_effect=AssertionError("No inference is allowed in this test")))
            # The actual parser can warn with the rejected source. All source is
            # synthetic, but keep test output bounded and payload-free anyway.
            stack.enter_context(patch("mlx_vlm.tools.extractor.logger.warning"))
            stack.enter_context(patch.object(self.openai.logger, "exception"))
            if adapter_context is not None:
                stack.enter_context(adapter_context)
            response = await self.openai.responses_endpoint(request)
            collected = []
            async for chunk in response.body_iterator:
                chunk = chunk.encode() if isinstance(chunk, str) else chunk
                collected.append(chunk)
                if on_chunk is not None:
                    await on_chunk(chunk, False)
            if on_chunk is not None:
                await on_chunk(b"", True)
            raw = b"".join(collected)
            preflight.assert_awaited_once()
            generator.generate.assert_called_once()
            forbidden.assert_not_called()
        events = decoded_events(raw)
        if require_completed:
            self.assertEqual(events[-1]["type"], "response.completed",
                             "The pinned producer must reach its actual terminal envelope")
        return raw, events

    def require_contract_rejection(self, raw, expected):
        contract = SSEContract(4096)
        with self.assertRaisesRegex(ProtocolError, expected):
            contract.feed(raw)
            contract.finish()
        failed = decoded_events(contract.failure())
        self.assertEqual(failed[-1]["type"], "response.failed")
        self.assertEqual(failed[-1]["response"]["output"], [])
        return contract


class PinnedProducerStreamTests(PinnedEndpointHarness):
    async def test_actual_plain_producer_stream_and_final_agree(self):
        raw, events = await self.produce(["Hello ", "🌍", "\n"], tools=False)
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), "Hello 🌍\n")
        contract = SSEContract(4096)
        out = decoded_events(contract.feed(raw) + contract.finish())
        self.assertEqual(out[-1]["response"]["output_text"], "Hello 🌍\n")

    async def test_actual_valid_tool_call_is_exact_and_waits_for_eof(self):
        raw, events = await self.produce([VALID_CALL])
        self.assertFalse(any(e["type"] == "response.output_text.delta" for e in events))
        contract = SSEContract(4096)
        before = decoded_events(contract.feed(raw))
        self.assertFalse(any(e["type"] == "response.output_item.done" for e in before))
        after = decoded_events(contract.finish())
        calls = [i for i in after[-1]["response"]["output"] if i["type"] == "function_call"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["name"], "synthetic_echo")
        self.assertEqual(json.loads(calls[0]["arguments"]), {"text": "synthetic marker"})

    async def test_actual_malformed_tool_span_is_unstreamed_terminal_text(self):
        raw, events = await self.produce(["\n", MALFORMED_CALL])
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), "\n")
        self.assertEqual(events[-1]["response"]["output_text"], MALFORMED_CALL)
        contract = self.require_contract_rejection(raw, "Unstreamed final text")
        self.assertEqual(contract.diagnostic_counters()["events"], 6)
        self.assertEqual(contract.diagnostic_counters()["items"], 1)
        self.assertEqual(contract.diagnostic_counters()["last"], "response.output_text.done")

    async def test_actual_unterminated_tool_span_is_unstreamed_terminal_text(self):
        incomplete = VALID_CALL.removesuffix("</tool_call>")
        raw, events = await self.produce([incomplete], finish_reason="length")
        self.assertFalse(any(e["type"] == "response.output_text.delta" for e in events))
        self.assertEqual(events[-1]["response"]["output_text"], incomplete.strip())
        self.require_contract_rejection(raw, "Unstreamed final text")

    async def test_actual_thinking_plus_malformed_tool_keeps_channels_distinct(self):
        raw, events = await self.produce([
            "Synthetic private reasoning", "</think>\n", MALFORMED_CALL], thinking=True)
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.reasoning_text.delta"),
                         "Synthetic private reasoning")
        self.assertFalse(any(e["type"] == "response.output_text.delta" for e in events))
        self.assertEqual(events[-1]["response"]["output_text"], MALFORMED_CALL)
        self.require_contract_rejection(raw, "Unstreamed final text")

    async def test_actual_malformed_span_discrepancy_is_chunk_independent(self):
        for split in range(1, len(MALFORMED_CALL)):
            with self.subTest(split=split):
                raw, events = await self.produce([MALFORMED_CALL[:split], MALFORMED_CALL[split:]])
                self.assertFalse(any(e["type"] == "response.output_text.delta" for e in events))
                self.require_contract_rejection(raw, "Unstreamed final text")

    async def test_actual_iterator_eof_does_not_flush_partial_thinking_marker(self):
        raw, events = await self.produce(["Public prefix <thi"], tools=False, finish_reason=None)
        self.assertEqual("".join(e["delta"] for e in events
                         if e["type"] == "response.output_text.delta"), "Public prefix ")
        self.assertEqual(events[-1]["response"]["output_text"], "Public prefix <thi")
        self.require_contract_rejection(raw, "Final text differs from public deltas")


if __name__ == "__main__":
    unittest.main()
