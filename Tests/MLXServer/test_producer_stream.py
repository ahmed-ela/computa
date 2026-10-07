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
            if line.startswith("data: ") and line[6:] != "[DONE]"]


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
            stack.enter_context(patch("mlx_vlm.server.app._request_normalization._build_gen_args", return_value=args))
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


class PinnedOpenResponsesProfileTests(PinnedEndpointHarness):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        from producer_stream import install_producer_adapter
        install_producer_adapter(cls.openai)

    async def test_both_owned_routes_preserve_real_pinned_usage_and_reasoning(self):
        from server import LocalInferenceBoundary, MODEL_IDS
        from producer_stream import _current
        model = MODEL_IDS[0]
        private = "Synthetic reasoning for route qualification"
        request_body = {"model": model, "input": "Synthetic route test", "stream": True,
                        "store": False, "max_output_tokens": 4096, "tools": [TOOL]}
        snapshots = []
        for path in ("/v1/responses", "/v1/codex/responses"):
            forwarded, raw_terminals, effective = [], [], []

            async def upstream(scope, receive, send):
                self.assertEqual(scope["path"], "/v1/responses")
                self.assertEqual(json.loads((await receive())["body"]), request_body)
                await send({"type": "http.response.start", "status": 200,
                            "headers": [(b"content-type", b"text/event-stream")]})

                async def consume(chunk, final):
                    await send({"type": "http.response.body", "body": chunk, "more_body": not final})

                _, events = await self.produce([private, "</think>\n", VALID_CALL],
                                               thinking=True, on_chunk=consume)
                raw_terminals.append(events[-1]["response"])
                effective.append(dict(_current.get().sampling))

            boundary = LocalInferenceBoundary(upstream, [model], "fixture", lambda: {})

            async def receive():
                return {"type": "http.request", "body": json.dumps(request_body).encode()}

            async def send(message):
                forwarded.append(message)

            await boundary({"type": "http", "method": "POST", "path": path, "query_string": b"",
                            "headers": [(b"content-type", b"application/json")]}, receive, send)
            raw = b"".join(message.get("body", b"") for message in forwarded)
            events = decoded_events(raw)
            self.assertEqual(events[-1]["type"], "response.completed")
            result = events[-1]["response"]
            measured = raw_terminals[0]["usage"]
            self.assertEqual(result["model"], model)
            self.assertEqual(result["metadata"]["computa_measured_usage"], measured)
            self.assertNotIn("output_tokens_details", measured)
            self.assertEqual(result["temperature"], effective[0]["temperature"])
            self.assertEqual(result["top_p"], effective[0]["top_p"])
            self.assertEqual(result["usage"], measured if path == "/v1/codex/responses" else None)
            reasoning = [item for item in result["output"] if item["type"] == "reasoning"]
            self.assertEqual(reasoning[0]["summary"], [{"type": "summary_text", "text": private}])
            calls = [item for item in result["output"] if item["type"] == "function_call"]
            self.assertEqual(json.loads(calls[0]["arguments"]), {"text": "synthetic marker"})
            self.assertEqual(result["output_text"], "")
            self.assertIsNone(_current.get())
            snapshots.append({key: measured[key] for key in ("input_tokens", "output_tokens", "total_tokens")})
        self.assertEqual(snapshots[0], snapshots[1])


if __name__ == "__main__":
    unittest.main()
