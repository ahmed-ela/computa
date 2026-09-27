"""Pinned MLX preflight integration, with real Qwen tokenizer/image processing.

No model weights, GPU inference worker, listener, live chat or browser are used.
Run in the owned MLX venv; outside it these integration checks explicitly skip.
MACTOPUS_BUDGET_MODEL_DIR may point to local Qwen3.5-4B processor assets.
"""
import base64
import importlib.metadata
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parents[2] / "Sources/Mactopus/Resources/MLXServer"))
from response_boundary import ResponseBoundary


class PinnedContextBudgetTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        try:
            pinned = importlib.metadata.version("mlx-vlm") == "0.7.1"
        except importlib.metadata.PackageNotFoundError:
            pinned = False
        if not pinned:
            raise unittest.SkipTest("Requires owned pinned mlx-vlm 0.7.1 environment")
        model_dir = Path(os.environ.get("MACTOPUS_BUDGET_MODEL_DIR",
            str(Path.home() / ".lmstudio/models/lmstudio-community/Qwen3.5-4B-MLX-4bit")))
        if not (model_dir / "tokenizer.json").is_file():
            raise unittest.SkipTest("Requires already-local Qwen processor assets; never downloads")
        # Model-module import installs the same processor registration as load(),
        # but neither constructs a model nor opens any safetensors file.
        import mlx_vlm.models.qwen3_5  # noqa: F401
        from mlx_vlm.utils import load_processor
        from mlx_vlm.server import generation, openai
        from mlx_vlm.server.runtime import runtime
        cls.generation, cls.openai, cls.runtime = generation, openai, runtime
        cls.processor = load_processor(model_dir, local_files_only=True, trust_remote_code=False)
        cls.config = json.loads((model_dir / "config.json").read_text())

    def setUp(self):
        # Real preprocessing and budget implementation, without __init__ starting
        # its GPU worker or loading weights. Any attempted generation fails.
        self.generator = object.__new__(self.generation.ResponseGenerator)
        self.generator.processor = self.processor
        self.generator.model = SimpleNamespace(config=SimpleNamespace(**self.config))
        self.generator.wait_until_ready = Mock()
        self.generator.generate = Mock(side_effect=AssertionError("No generation allowed in preflight test"))

    def request(self, **overrides):
        return {"model": "lmstudio-community/Qwen3.5-4B-MLX-4bit", "store": False,
            "stream": True, "max_output_tokens": 4096,
            "instructions": "Preserve verified actions. INSTRUCTION_MARKER",
            "tools": [{"type": "function", "name": "computer_v2_snapshot",
                "description": "TOOL_SCHEMA_MARKER", "parameters": {"type": "object",
                    "properties": {"cursor": {"type": "string"}}, "additionalProperties": False}}],
            "input": [{"role": "user", "content": "Inspect the fixture"},
                {"type": "function_call", "call_id": "fixture_call", "name": "computer_v2_snapshot",
                    "arguments": "{}"},
                {"type": "function_call_output", "call_id": "fixture_call", "output": "RECEIPT_MARKER observed"},
                {"role": "user", "content": "yes"}], **overrides}

    def prepared_prompt(self, request):
        # These are the pinned Responses endpoint's own normalization/template
        # functions, not a character-based approximation or parallel template.
        value = self.openai.OpenAIRequest(**request)
        items = self.openai._normalize_response_input(value.input)
        messages, images = self.openai._response_items_to_chat(items)
        self.openai._normalize_response_instruction_messages(messages, value.instructions)
        tools, _ = self.openai._response_tool_registry(value.tools)
        args = self.openai._build_gen_args(value, self.processor)
        prompt = self.openai.apply_chat_template(self.processor, self.config, messages,
            num_images=len(images), tools=tools or None, **args.to_template_kwargs())
        return prompt, images or None, args

    def test_complete_request_counts_template_tools_instructions_and_receipts(self):
        prompt, images, args = self.prepared_prompt(self.request())
        for marker in ("INSTRUCTION_MARKER", "TOOL_SCHEMA_MARKER", "RECEIPT_MARKER", "computer_v2_snapshot"):
            self.assertIn(marker, prompt)
        raw = self.generator._preprocess_request(prompt, images)
        actual = self.generation._count_prompt_tokens(raw)
        expected = len(self.processor.tokenizer.encode(prompt, add_special_tokens=True))
        self.assertEqual(actual, expected)
        self.assertGreater(actual, len(self.processor.tokenizer.encode("yes")))
        self.assertEqual(args.max_tokens, 4096)

    def test_exact_fit_passes_one_token_overflow_rejects_before_generation(self):
        prompt, images, args = self.prepared_prompt(self.request(max_output_tokens=256))
        count = self.generation._count_prompt_tokens(self.generator._preprocess_request(prompt, images))
        with patch.object(self.generation, "get_configured_context_limit", return_value=count + 256):
            self.generator.validate_context_budget(prompt, images=images, args=args)
        with patch.object(self.generation, "get_configured_context_limit", return_value=count + 255):
            with self.assertRaises(self.generation.PromptTooLongError):
                self.generator.validate_context_budget(prompt, images=images, args=args)
        self.generator.generate.assert_not_called()

    def test_image_budget_uses_expanded_processor_input_ids_not_placeholder_count(self):
        from PIL import Image
        data = io.BytesIO()
        Image.new("RGB", (256, 256), color="white").save(data, format="PNG")
        request = self.request(input=[{"role": "user", "content": [
            {"type": "input_text", "text": "Inspect this synthetic screenshot"},
            {"type": "input_image", "image_url": "data:image/png;base64," + base64.b64encode(data.getvalue()).decode()}]}])
        prompt, images, args = self.prepared_prompt(request)
        raw = self.generator._preprocess_request(prompt, images)
        exact = self.generation._count_prompt_tokens(raw)
        placeholder_only = len(self.processor.tokenizer.encode(prompt, add_special_tokens=True))
        self.assertGreater(exact, placeholder_only)
        with patch.object(self.generation, "get_configured_context_limit", return_value=placeholder_only + args.max_tokens):
            with self.assertRaises(self.generation.PromptTooLongError):
                self.generator.validate_context_budget(prompt, images=images, args=args)
        self.generator.generate.assert_not_called()

    async def test_real_responses_endpoint_rejects_before_sse_and_boundary_preserves_exact_budget(self):
        from fastapi import HTTPException
        from starlette.requests import Request
        request = self.request()
        request["input"][2]["output"] = "观测页面坐标和航班时间。" * 1800
        prompt, images, args = self.prepared_prompt(request)
        exact = self.generation._count_prompt_tokens(self.generator._preprocess_request(prompt, images))
        self.assertGreater(exact + args.max_tokens, 16384)
        raw = json.dumps(request).encode()
        async def receive():
            return {"type": "http.request", "body": raw, "more_body": False}
        http_request = Request({"type": "http", "method": "POST", "path": "/v1/responses",
            "headers": [(b"content-type", b"application/json")]}, receive)
        output = []
        async def send(message):
            output.append(message)
        adapter = ResponseBoundary(send, args.max_tokens)
        with patch.object(self.runtime, "response_generator", self.generator), \
             patch.object(self.openai, "get_cached_model", return_value=(self.generator.model, self.processor, self.config)), \
             patch.object(self.generation, "get_configured_context_limit", return_value=16384), \
             patch.object(self.generator, "_preprocess_request", wraps=self.generator._preprocess_request) as preprocess:
            with self.assertRaises(HTTPException) as raised:
                await self.openai.responses_endpoint(http_request)
            self.assertEqual(raised.exception.status_code, 400)
            # One preprocessing pass rejects before the endpoint creates SSE.
            self.assertEqual(preprocess.call_count, 1)
        self.generator.generate.assert_not_called()
        await adapter({"type": "http.response.start", "status": 400, "headers": []})
        await adapter({"type": "http.response.body", "body": json.dumps({"detail": raised.exception.detail}).encode()})
        await adapter.finish()
        event = json.loads(output[1]["body"].split(b"data: ")[1])
        self.assertEqual(event["type"], "response.failed")
        self.assertEqual(event["response"]["error"]["code"], "context_length_exceeded")
        self.assertEqual(event["response"]["context_budget"]["input_tokens"], exact)
        self.assertEqual(event["response"]["context_budget"]["max_output_tokens"], args.max_tokens)
        self.assertNotIn("RECEIPT_MARKER", output[1]["body"].decode())
        self.assertEqual(event["response"]["output"], [])


if __name__ == "__main__":
    unittest.main()
