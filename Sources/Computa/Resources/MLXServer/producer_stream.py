"""App-owned, request-local finalization for the pinned MLX-VLM 0.7.1 producer.

Upstream streams through two parsers but reparses raw text differently at EOF.
Capture their actual outputs instead. This does not synthesize deltas, execute
tools, or replace the downstream terminal/EOF validator. No shared venv edits.
"""
from contextlib import contextmanager
from contextvars import ContextVar
import importlib.metadata
import json
import re
import uuid

from sse_contract import ProtocolError, SSEContract, _json


_current = ContextVar("mactopus_response_producer", default=None)


class ProducerCapture:
    def __init__(self):
        self.raw, self.content, self.public, self.reasoning = [], [], [], []
        self.byte_count = 0
        self.thinking = self.tools = None
        self.finalized = False
        self.fault = None

    def fail(self, reason):
        self.fault = ProtocolError(reason)
        raise self.fault

    def append(self, target, text):
        if text is None:
            return
        if not isinstance(text, str):
            self.fail("Invalid producer text")
        # Includes all four retained channels, not merely one copy of the raw
        # generation. This is a bound, not persistent telemetry or a trace.
        try:
            self.byte_count += len(text.encode("utf-8"))
        except UnicodeError:
            self.fail("Invalid producer text")
        if self.byte_count > SSEContract.MAX_STREAM_BYTES:
            self.fail("Producer capture exceeds bound")
        target.append(text)

    def assemble(self, full_text, message_id, tool_module, chat_tools, tool_registry,
                 thinking_start_token=None, thinking_end_token=None,
                 reasoning_item_id=None, processor=None):
        if (self.finalized or self.thinking is None or self.tools is None
                or full_text != "".join(self.raw)
                or "".join(self.content) != "".join(self.tools.inputs)):
            self.fail("Producer state mismatch")
        self.finalized = True
        # Upstream can omit last=True on iterator EOF. Never invent a delta for
        # a held prefix, or quietly drop it, merely to make the terminal pass.
        if self.thinking.delegate.buffer or self.tools.delegate.buffer:
            self.fail("Producer ended with buffered text")
        public, reasoning = "".join(self.public), "".join(self.reasoning)
        calls = self.parse_calls(tool_module, chat_tools, tool_registry)
        items = []
        if reasoning:
            if not reasoning_item_id:
                self.fail("Producer state mismatch")
            items.append({"id": reasoning_item_id, "type": "reasoning",
                          "summary": [{"type": "summary_text", "text": reasoning}]})
        if public or not calls:
            items.append({"id": message_id, "type": "message", "role": "assistant",
                          "status": "completed", "content": [{"type": "output_text",
                          "text": public, "annotations": []}] if public else []})
        items.extend(calls)
        return items, public, reasoning or None, "tool_calls" if calls else "stop"

    def parse_calls(self, module, tools, registry):
        text = "".join(self.content)  # NEVER parse tool examples in reasoning.
        state = self.tools.delegate
        if not state.tc_start:
            return []
        # Both catalog models use this exact parser. New parser dialects need
        # explicit complete-consumption tests rather than permissive fallback.
        if (module is None or module.__name__ != "mlx_vlm.tools.parsers.qwen3_coder"
                or state.tc_start != "<tool_call>" or state.tc_end != "</tool_call>"):
            self.fail("Unsupported producer tool parser")
        if state.in_tool_call:
            self.fail("Incomplete generated tool call")
        calls, offset = [], 0
        while True:
            start = text.find(state.tc_start, offset)
            if start < 0:
                break
            end = text.find(state.tc_end, start + len(state.tc_start))
            if end < 0:
                self.fail("Incomplete generated tool call")
            body = text[start + len(state.tc_start):end].strip()
            # The upstream parser can otherwise ignore stray text, duplicate
            # parameters or additional functions. Require the entire span.
            match = re.fullmatch(r"<function=([^\s<>]+)>(.*?)</function>", body, re.S)
            if not match or "<function=" in match[2] or "</function>" in match[2]:
                self.fail("Malformed generated tool call")
            name, parameters = match.groups()
            if registry.get(name) != "function":
                self.fail("Unadvertised generated tool call")
            seen, cursor = set(), 0
            for parameter in re.finditer(r"<parameter=([^\s<>]+)>(.*?)</parameter>", parameters, re.S):
                if (parameters[cursor:parameter.start()].strip() or parameter[1] in seen
                        or "<parameter=" in parameter[2] or "</parameter>" in parameter[2]
                        or state.tc_start in parameter[2]):
                    self.fail("Malformed generated tool call")
                seen.add(parameter[1])
                cursor = parameter.end()
            if parameters[cursor:].strip():
                self.fail("Malformed generated tool call")
            try:
                parsed = module.parse_tool_call(body, tools)
                arguments = parsed["arguments"]
                if not isinstance(arguments, str):
                    arguments = json.dumps(arguments, ensure_ascii=False, allow_nan=False)
                valid = parsed["name"] == name and isinstance(_json(arguments), dict)
            except Exception:
                # Do not log the rejected call, private arguments or exception.
                self.fail("Malformed generated tool call")
            if not valid:
                self.fail("Malformed generated tool call")
            calls.append({"id": "fc_" + uuid.uuid4().hex, "type": "function_call",
                          "call_id": "call_" + uuid.uuid4().hex, "name": name,
                          "arguments": arguments, "status": "completed"})
            if len(calls) > 32:
                self.fail("Excessive generated tool calls")
            offset = end + len(state.tc_end)
        return calls


@contextmanager
def producer_scope():
    capture = ProducerCapture()
    token = _current.set(capture)
    try:
        yield capture
    finally:
        _current.reset(token)
        # Drop retained content on normal EOF, disconnect, cancellation or error.
        capture.raw.clear()
        capture.content.clear()
        capture.public.clear()
        capture.reasoning.clear()
        if capture.tools is not None:
            capture.tools.inputs.clear()
            capture.tools.delegate.buffer = ""
        if capture.thinking is not None:
            capture.thinking.delegate.buffer = ""
        capture.thinking = capture.tools = None
        if capture.fault is not None:
            capture.fault.__traceback__ = None
            capture.fault = None


def install_producer_adapter(upstream):
    """Install process-local seams after upstream app registration, exactly once."""
    if importlib.metadata.version("mlx-vlm") != "0.7.1":
        raise RuntimeError("Unsupported MLX producer version")
    if getattr(upstream, "_mactopus_stream_adapter", False):
        return
    original_thinking = upstream.make_response_stream_state
    original_tools = upstream.ToolCallStreamState
    original_final = upstream._response_output_items_from_text

    class ObservedThinking:
        def __init__(self, delegate, capture):
            self.delegate, self.capture = delegate, capture

        def feed(self, text, last=False):
            self.capture.append(self.capture.raw, text)
            delta = self.delegate.feed(text, last=last)
            self.capture.append(self.capture.reasoning, delta.reasoning)
            self.capture.append(self.capture.content, delta.content)
            return delta

    class ObservedTools:
        def __init__(self, delegate, capture):
            self.delegate, self.capture, self.inputs = delegate, capture, []

        def feed(self, text, last=False):
            self.capture.append(self.inputs, text)
            delta = self.delegate.feed(text, last=last)
            self.capture.append(self.capture.public, delta)
            return delta

    def thinking_factory(*args, **kwargs):
        delegate = original_thinking(*args, **kwargs)
        capture = _current.get()
        if capture is None:
            return delegate
        if capture.thinking is not None:
            capture.fail("Producer state mismatch")
        # Future response-template parsers can emit dedicated tool events which
        # this upstream adapter discards. Don't silently interpret that as no call.
        from mlx_vlm.server.responses_state import ThinkingStreamState
        if type(delegate) is not ThinkingStreamState:
            capture.fail("Unsupported producer thinking parser")
        capture.thinking = ObservedThinking(delegate, capture)
        return capture.thinking

    def tool_factory(*args, **kwargs):
        delegate = original_tools(*args, **kwargs)
        capture = _current.get()
        if capture is None:
            return delegate
        if capture.tools is not None:
            capture.fail("Producer state mismatch")
        capture.tools = ObservedTools(delegate, capture)
        return capture.tools

    def finalize(*args, **kwargs):
        capture = _current.get()
        if capture is None:
            return original_final(*args, **kwargs)
        return capture.assemble(*args, **kwargs)

    upstream.make_response_stream_state = thinking_factory
    upstream.ToolCallStreamState = tool_factory
    upstream._response_output_items_from_text = finalize
    upstream._mactopus_stream_adapter = True
