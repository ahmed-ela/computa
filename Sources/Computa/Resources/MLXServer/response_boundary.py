"""ASGI transport compatibility for the pinned MLX-VLM Responses endpoint."""
import json
import re
import uuid

from sse_contract import ProtocolError, SSEContract, protocol_error_diagnostic

MAX_ERROR_BODY = 64 * 1024
CONTEXT_LIMIT = 16384
MAX_OUTPUT_TOKENS = 4096
CONTEXT_ERROR = re.compile(
    r"Request needs ([0-9]+) context tokens \(([0-9]+) prompt \+ ([0-9]+) max generation\), "
    r"but MAX_KV_SIZE is ([0-9]+)\."
)


def context_overflow_budget(body, *, max_output_tokens=None):
    """Extract only a genuine pre-generation budget from pinned MLX-VLM.

    Its Responses endpoint first applies the actual model's chat template to
    instructions, tools and the full history, then prepares text/image inputs.
    validate_context_budget counts those input_ids and the output allowance
    before SSE starts or generation is queued. Reuse that authoritative gate;
    a second tokenizer/byte estimate would diverge and preprocess images again.
    """
    try:
        value = json.loads(body)
        detail = value.get("detail") if isinstance(value, dict) else None
        match = CONTEXT_ERROR.fullmatch(detail) if isinstance(detail, str) else None
        if not match:
            return None
        requested, prompt, generation, limit = map(int, match.groups())
        if (limit != CONTEXT_LIMIT or prompt < 1 or not 1 <= generation <= MAX_OUTPUT_TOKENS
                or requested != prompt + generation or requested <= limit):
            return None
        if max_output_tokens is not None and generation != max_output_tokens:
            # A different allowance is not evidence about this request. Do not
            # authorize compaction/retry from a mismatched upstream response.
            return None
        return {"input_tokens": prompt, "max_output_tokens": generation,
                "context_limit": limit, "required_tokens": requested,
                "available_input_tokens": limit - generation}
    except (ValueError, TypeError):
        return None


def is_context_overflow(body):
    return context_overflow_budget(body) is not None


def is_protocol_error(error):
    if isinstance(error, ProtocolError):
        return True
    if isinstance(error, BaseExceptionGroup):
        return bool(error.exceptions) and all(is_protocol_error(child) for child in error.exceptions)
    return False


def stream_start():
    return {"type": "http.response.start", "status": 200, "headers": [
        (b"content-type", b"text/event-stream; charset=utf-8"),
        (b"cache-control", b"no-store"), (b"x-accel-buffering", b"no")]}


class ResponseBoundary:
    def __init__(self, send, max_output_tokens, producer=None):
        self.send = send
        self.contract = SSEContract(max_output_tokens=max_output_tokens)
        self.start = None
        self.error_body = bytearray()
        self.sent_start = False
        self.closed = False
        self.upstream_eof = False
        self.producer = producer

    async def __call__(self, message):
        if self.closed:
            raise ProtocolError("Response after EOF.")
        if message["type"] == "http.response.start":
            if self.start is not None:
                raise ProtocolError("Duplicate response start.")
            self.start = message
            status = message["status"]
            if status == 200:
                headers = dict(message.get("headers", []))
                if not headers.get(b"content-type", b"").startswith(b"text/event-stream"):
                    raise ProtocolError("Expected a Responses event stream.")
                await self.send(stream_start())
                self.sent_start = True
            elif status != 400:
                await self.send(message)
                self.sent_start = True
            return
        if message["type"] != "http.response.body" or self.start is None:
            raise ProtocolError("Missing response start.")
        final = not message.get("more_body", False)
        self.upstream_eof = final
        body = message.get("body", b"")
        status = self.start["status"]
        if status == 200:
            # Upstream catches parser exceptions and encodes an untyped error.
            # Preserve only our exact host-authored fault, never that raw body.
            if self.producer is not None and self.producer.fault is not None:
                raise self.producer.fault
            output = self.contract.feed(body)
            if final:
                output += self.contract.finish()
            if output or final:
                await self.send({"type": "http.response.body", "body": output, "more_body": not final})
        elif status == 400:
            if len(self.error_body) + len(body) > MAX_ERROR_BODY:
                raise ProtocolError("Upstream error body limit exceeded.")
            self.error_body.extend(body)
            if final:
                budget = context_overflow_budget(self.error_body,
                                                 max_output_tokens=self.contract.max_output_tokens)
                if budget is not None:
                    await self.send(stream_start())
                    self.sent_start = True
                    event = {"type": "response.failed", "sequence_number": 0, "response": {
                        "id": "resp_" + uuid.uuid4().hex, "object": "response", "status": "failed",
                        "output": [], "error": {"code": "context_length_exceeded",
                            "message": "Local input and output allowance exceed the 16384-token context window."},
                        # Numeric-only evidence; never retain prompt text, tool
                        # results, image payloads or upstream exception bodies.
                        "context_budget": budget}}
                    payload = ("event: response.failed\ndata: " + json.dumps(event, separators=(",", ":")) + "\n\n").encode()
                    await self.send({"type": "http.response.body", "body": payload})
                else:
                    await self.send(self.start)
                    self.sent_start = True
                    await self.send({"type": "http.response.body", "body": bytes(self.error_body)})
        else:
            await self.send(message)
        self.closed = final

    async def fail(self, error=None):
        if self.closed:
            return
        if not self.sent_start:
            await self.send(stream_start())
            self.sent_start = True
        # The owned App Server treats invalid_prompt as terminal, unlike unknown
        # codes which would repeatedly retry a deterministic protocol error.
        reason, causes, limited = protocol_error_diagnostic(error)
        counters = self.contract.diagnostic_counters()
        message = ("Local model stream could not be validated. "
                   f"[mlx_protocol reason={reason} bytes={counters['bytes']} events={counters['events']} "
                   f"items={counters['items']} last={counters['last']} terminal={counters['terminal']} "
                   f"eof={int(self.upstream_eof)} causes={causes} limited={int(limited)}]")
        payload = self.contract.failure(code="invalid_prompt", message=message)
        await self.send({"type": "http.response.body", "body": payload})
        self.closed = True

    async def finish(self):
        if not self.closed:
            raise ProtocolError("Upstream response ended without EOF.")
