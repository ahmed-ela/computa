"""Bounded compatibility boundary for the pinned MLX-VLM 0.7.1 Responses stream.

Only streamed public deltas can become an assistant answer. Upstream reparses and
strips final text, and can mislabel unfinished thinking as completed public text.
Final items (especially executable calls) stay private until EOF and a validated
terminal envelope. This module neither runs tools nor interprets their arguments.
"""
import json
import re
import uuid


class ProtocolError(ValueError):
    """A fixed, payload-free diagnosis safe for logs (not an upstream exception)."""


def _require(condition, message):
    if not condition:
        raise ProtocolError(message)


def _object_pairs(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "Duplicate JSON field")
        result[key] = value
    return result


def _json(text):
    try:
        return json.loads(text, object_pairs_hook=_object_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ProtocolError("Nonfinite JSON")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ProtocolError("Malformed stream JSON") from None


class SSEContract:
    MAX_STREAM_BYTES = 4 * 1024 * 1024
    MAX_FRAME_BYTES = 512 * 1024
    MAX_EVENTS = 20000
    MAX_ITEMS = 64
    MAX_TEXT_BYTES = 256 * 1024

    def __init__(self, max_output_tokens):
        _require(type(max_output_tokens) is int and max_output_tokens > 0, "Invalid output budget")
        self.max_output_tokens = max_output_tokens
        self.response_id = None
        self.model = None
        self.sequence_number = 0
        self._buffer = b""
        self._bytes = self._events = 0
        self._items = {}  # In insertion order; indices never depend on the final parser.
        self._message_id = None
        self._active_item_id = None
        self._terminal = None
        self._finished = self._failed = self._done_marker = False
        self._progress = False

    def _emit(self, event):
        event = {**event, "sequence_number": self.sequence_number}
        self.sequence_number += 1
        try:
            payload = json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        except (ValueError, UnicodeError):
            raise ProtocolError("Invalid stream string") from None
        return b"event: " + event["type"].encode("ascii") + b"\ndata: " + payload + b"\n\n"

    def feed(self, data):
        """Forward validated progress/deltas; hold completion until finish()."""
        try:
            _require(not self._finished and not self._failed, "Stream is already closed")
            _require(isinstance(data, bytes), "Expected stream bytes")
            self._bytes += len(data)
            _require(self._bytes <= self.MAX_STREAM_BYTES, "Stream exceeds byte bound")
            self._buffer += data
            output = []
            while True:
                end = re.search(br"\r?\n\r?\n", self._buffer)
                if end is None:
                    break
                frame, self._buffer = self._buffer[:end.start()], self._buffer[end.end():]
                _require(len(frame) <= self.MAX_FRAME_BYTES, "Stream frame exceeds bound")
                output.append(self._frame(frame))
            _require(len(self._buffer) <= self.MAX_FRAME_BYTES, "Stream frame exceeds bound")
            return b"".join(output)
        except ProtocolError:
            self._failed = True
            raise
        except (TypeError, AttributeError, KeyError, UnicodeError, RecursionError):
            self._failed = True
            raise ProtocolError("Malformed stream structure") from None

    def _frame(self, frame):
        try:
            lines = frame.decode("utf-8", errors="strict").split("\n")
        except UnicodeError:
            raise ProtocolError("Invalid stream UTF-8") from None
        data, names = [], []
        for line in lines:
            line = line.removesuffix("\r")
            if line.startswith(":"):
                continue
            field, sep, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
            if field == "data":
                data.append(value)
            elif field == "event":
                names.append(value)
            elif field not in ("", "id", "retry"):
                raise ProtocolError("Unexpected SSE field")
        if not data:
            _require(not names, "Event has no data")
            return b""
        _require(not self._done_marker, "Data after stream end")
        body = "\n".join(data)
        if body == "[DONE]":
            _require(self._terminal is not None, "End marker before terminal")
            self._done_marker = True
            return b""
        _require(self._terminal is None, "Data after terminal response")
        event = _json(body)
        _require(isinstance(event, dict) and isinstance(event.get("type"), str), "Missing event type")
        _require(not names or names == [event["type"]], "SSE event type mismatch")
        self._events += 1
        _require(self._events <= self.MAX_EVENTS, "Stream exceeds event bound")
        return self._event(event)

    @staticmethod
    def _identity(value):
        _require(isinstance(value, str) and 0 < len(value) <= 512, "Invalid stream identity")
        return value

    def _new_item(self, item):
        identity = self._identity(item.get("id"))
        _require(identity not in self._items and len(self._items) < self.MAX_ITEMS, "Duplicate or excessive items")
        state = {"index": len(self._items), "added": item, "done": None,
                 "text": [], "text_bytes": 0, "text_done": False, "part_added": False,
                 "part_done": False, "args": [], "args_done": False, "announced": False,
                 "part_event": None}
        self._items[identity] = state
        # MLX declares an empty message before it starts reasoning. The agent
        # engine routes text deltas to the most recently added item, so keep
        # that empty message private until public text actually starts. Only
        # unannounced items can move; emitted indices remain stable.
        message = self._items.get(self._message_id)
        if identity != self._message_id and message is not None and not message["announced"]:
            self._items.pop(self._message_id)
            state["index"] -= 1
            message["index"] = len(self._items)
            self._items[self._message_id] = message
        return state

    def _announce(self, state):
        if state["announced"]:
            return b""
        state["announced"] = True
        self._active_item_id = state["added"]["id"]
        output = self._emit({"type": "response.output_item.added",
                             "output_index": state["index"], "item": state["added"]})
        if state["part_event"] is not None:
            output += self._emit({**state["part_event"], "output_index": state["index"]})
        return output

    def _state(self, event, kind=None):
        state = self._items.get(event.get("item_id"))
        _require(state is not None, "Event references unknown item")
        if kind:
            _require(state["added"]["type"] == kind, "Item type mismatch")
        _require(state["done"] is None, "Event after item completion")
        if "content_index" in event:
            _require(type(event["content_index"]) is int and event["content_index"] == 0, "Unsupported content index")
        return state

    def _text(self, state, delta):
        _require(isinstance(delta, str) and not state["text_done"], "Invalid or late text delta")
        try:
            state["text_bytes"] += len(delta.encode("utf-8"))
        except UnicodeError:
            raise ProtocolError("Invalid stream string") from None
        _require(state["text_bytes"] <= self.MAX_TEXT_BYTES, "Item text exceeds bound")
        state["text"].append(delta)

    @staticmethod
    def _part(state):
        return {"type": "output_text", "text": "".join(state["text"]), "annotations": []}

    def _check_final_text(self, state, candidate):
        _require(isinstance(candidate, str), "Invalid final text")
        public = "".join(state["text"])
        if public.strip():
            # Correct only the pinned final parser's known whitespace stripping,
            # not arbitrary discrepancies that may signal a different bug.
            _require(candidate in (public, public.strip()), "Final text differs from public deltas")
        else:
            reasoning = "".join("".join(s["text"]) for s in self._items.values()
                                if s["added"]["type"] == "reasoning")
            _require(not candidate.strip() or (reasoning and candidate.strip() == reasoning.strip()),
                     "Unstreamed final text")

    def _check_message(self, state, item):
        content = item.get("content")
        _require(isinstance(content, list) and len(content) <= 1, "Invalid message content")
        _require(all(isinstance(p, dict) and p.get("type") == "output_text"
                     and isinstance(p.get("text"), str) for p in content), "Invalid message part")
        self._check_final_text(state, "".join(p["text"] for p in content))

    @staticmethod
    def _call(item):
        for key in ("id", "call_id", "name"):
            SSEContract._identity(item.get(key))
        _require(isinstance(item.get("arguments"), str), "Invalid function arguments")
        _require(isinstance(_json(item["arguments"]), dict), "Function arguments must be an object")

    def _event(self, event):
        kind = event["type"]
        if kind == "response.created":
            response = event.get("response")
            _require(self.response_id is None and isinstance(response, dict), "Duplicate or invalid response")
            self.response_id = self._identity(response.get("id"))
            self.model = self._identity(response.get("model"))
            _require(response.get("status") == "in_progress" and not response.get("output"), "Invalid initial response")
            return self._emit(event)
        _require(self.response_id is not None, "Missing response.created")
        if "response_id" in event:
            _require(event["response_id"] == self.response_id, "Response identity mismatch")
        if kind == "response.in_progress":
            response = event.get("response", {})
            _require(not self._progress and response.get("id") == self.response_id
                     and response.get("model") == self.model and response.get("status") == "in_progress",
                     "Invalid progress response")
            self._progress = True
            return self._emit(event)
        if kind == "response.output_item.added":
            item = event.get("item")
            _require(isinstance(item, dict) and item.get("type") in ("message", "function_call", "reasoning"),
                     "Unsupported output item")
            if item["type"] == "message":
                _require(self._message_id is None and item.get("role") == "assistant" and not item.get("content"),
                         "Invalid initial message")
                self._message_id = item.get("id")
            elif item["type"] == "function_call":
                self._call(item)
                _require(not any(s["added"].get("call_id") == item["call_id"] for s in self._items.values()),
                         "Duplicate function call ID")
            state = self._new_item(item)
            return b"" if item["type"] == "message" else self._announce(state)
        if kind.startswith("response.reasoning_text."):
            if kind.endswith(".delta"):
                message = self._items.get(self._message_id)
                _require(message is None or not message["announced"], "Reasoning after public text is unsupported")
            identity = self._identity(event.get("item_id"))
            prefix = b""
            if identity not in self._items:
                _require(kind.endswith(".delta"), "Reasoning completion without deltas")
                item = {"id": identity, "type": "reasoning", "summary": [], "status": "in_progress"}
                state = self._new_item(item)
                prefix = self._announce(state)
            state = self._state(event, "reasoning")
            if kind.endswith(".delta"):
                _require(self._active_item_id == identity, "Interleaved reasoning is unsupported")
                self._text(state, event.get("delta"))
                return prefix + self._emit({**event, "output_index": state["index"]})
            _require(kind.endswith(".done") and not state["text_done"]
                     and event.get("text") == "".join(state["text"]), "Invalid reasoning completion")
            state["text_done"] = True
            return b""
        if kind == "response.content_part.added":
            state = self._state(event, "message")
            part = event.get("part", {})
            _require(not state["part_added"] and part.get("type") == "output_text" and part.get("text") == "",
                     "Invalid initial content part")
            state["part_added"] = True
            state["part_event"] = event
            return b""
        if kind == "response.output_text.delta":
            state = self._state(event, "message")
            _require(state["part_added"], "Text before content part")
            self._text(state, event.get("delta"))
            prefix = self._announce(state)
            _require(self._active_item_id == state["added"]["id"], "Interleaved public text is unsupported")
            return prefix + self._emit({**event, "output_index": state["index"]})
        if kind == "response.output_text.done":
            state = self._state(event, "message")
            _require(state["part_added"] and not state["text_done"] and isinstance(event.get("text"), str),
                     "Invalid text completion")
            self._check_final_text(state, event["text"])
            state["text_done"] = True
            return b""
        if kind == "response.content_part.done":
            state = self._state(event, "message")
            _require(state["text_done"] and not state["part_done"]
                     and event.get("part", {}).get("type") == "output_text", "Invalid content completion")
            self._check_final_text(state, event["part"].get("text"))
            state["part_done"] = True
            return b""
        if kind in ("response.function_call_arguments.delta", "response.function_call_arguments.done"):
            state = self._state(event, "function_call")
            _require(not state["args_done"], "Arguments after completion")
            call = state["added"]
            for field in ("call_id", "name"):
                _require(field not in event or event[field] == call[field], "Function identity mismatch")
            if kind.endswith(".delta"):
                delta = event.get("delta")
                _require(isinstance(delta, str), "Invalid arguments delta")
                state["args"].append(delta)
            else:
                _require(event.get("arguments") == call["arguments"]
                         and (not state["args"] or "".join(state["args"]) == call["arguments"]),
                         "Function arguments mismatch")
                _require("item" not in event or event["item"] == call, "Function item mismatch")
                state["args_done"] = True
            return self._emit({**event, "output_index": state["index"]})
        if kind == "response.output_item.done":
            item = event.get("item")
            _require(isinstance(item, dict), "Invalid completed item")
            state = self._state({"item_id": item.get("id")})
            _require(item.get("type") == state["added"]["type"], "Completed item type mismatch")
            if item["type"] == "message":
                _require(state["part_done"] and item.get("role") == "assistant" and item.get("status") == "completed",
                         "Invalid message completion")
                self._check_message(state, item)
            elif item["type"] == "function_call":
                _require(state["args_done"] and item == state["added"] and item.get("status") == "completed",
                         "Invalid function completion")
            else:
                _require(state["text_done"], "Incomplete reasoning item")
            state["done"] = item
            return b""
        if kind in ("response.completed", "response.incomplete", "response.failed"):
            self._terminal = self._validate_terminal(event)
            return b""
        raise ProtocolError("Unsupported stream event")

    def _validate_terminal(self, event):
        response = event.get("response")
        _require(isinstance(response, dict) and response.get("id") == self.response_id
                 and response.get("model") == self.model, "Terminal identity mismatch")
        expected_status = event["type"].removeprefix("response.")
        _require(response.get("status") == expected_status, "Terminal status mismatch")
        if expected_status != "completed":
            # Upstream errors are deliberately not echoed; they can contain prompt bodies.
            if expected_status == "failed":
                raise ProtocolError("Upstream model generation failed")
            _require(isinstance(response.get("incomplete_details"), dict), "Missing incomplete reason")
            return {**event, "response": {**response, "output": [], "output_text": ""}}
        _require(not response.get("error") and not response.get("incomplete_details"), "Contradictory completed response")
        usage = response.get("usage")
        _require(isinstance(usage, dict) and all(type(usage.get(k)) is int and usage[k] >= 0
                 for k in ("input_tokens", "output_tokens", "total_tokens")), "Invalid usage")
        _require(usage["total_tokens"] == usage["input_tokens"] + usage["output_tokens"], "Inconsistent usage")
        raw_output = response.get("output")
        _require(isinstance(raw_output, list), "Missing terminal output")
        seen = set()
        for item in raw_output:
            _require(isinstance(item, dict), "Malformed terminal item")
            identity = self._identity(item.get("id"))
            _require(identity not in seen and identity in self._items, "Unknown or duplicate terminal item")
            seen.add(identity)
            state = self._items[identity]
            _require(item.get("type") == state["added"]["type"], "Terminal item type mismatch")
            if item["type"] == "function_call":
                _require(item == state["done"], "Terminal function mismatch")
            elif item["type"] == "message":
                _require(item.get("role") == "assistant" and item.get("status") == "completed", "Invalid terminal message")
                self._check_message(state, item)
            else:
                summary = item.get("summary", [])
                _require(isinstance(summary, list) and all(isinstance(p, dict) and p.get("type") == "summary_text"
                         and isinstance(p.get("text"), str) for p in summary), "Invalid terminal reasoning")
                _require("".join(p["text"] for p in summary).strip() == "".join(state["text"]).strip(),
                         "Terminal reasoning differs from deltas")
        _require(self._message_id is not None, "Missing message lifecycle")
        for identity, state in self._items.items():
            if state["added"]["type"] == "reasoning":
                _require(state["text_done"], "Missing reasoning completion")
            else:
                _require(state["done"] is not None, "Missing item completion")
                if state["added"]["type"] == "function_call":
                    _require(identity in seen, "Terminal omitted function")
        public = "".join(self._items[self._message_id]["text"])
        self._check_final_text(self._items[self._message_id], response.get("output_text"))
        _require(not public.strip() or self._message_id in seen, "Terminal omitted public message")
        has_call = any(s["added"]["type"] == "function_call" for s in self._items.values())
        incomplete = usage["output_tokens"] >= self.max_output_tokens or (not public.strip() and not has_call)
        status = "incomplete" if incomplete else "completed"
        output = []
        for identity, state in self._items.items():
            kind = state["added"]["type"]
            if kind == "function_call":
                if not incomplete:
                    output.append(state["done"])
            elif kind == "message":
                output.append({"id": identity, "type": "message", "role": "assistant", "status": status,
                               "content": [self._part(state)] if public else []})
            else:
                output.append({"id": identity, "type": "reasoning", "status": status,
                               "summary": [{"type": "summary_text", "text": "".join(state["text"])}]})
        return {"type": "response." + status, "response": {**response, "status": status,
                "output": output, "output_text": public, "error": None,
                "incomplete_details": {"reason": "max_output_tokens"} if incomplete else None}}

    def finish(self):
        """Called only at a clean ASGI EOF; releases a validated terminal once."""
        try:
            _require(not self._finished and not self._failed, "Stream is already closed")
            _require(not self._buffer.strip(), "Truncated SSE frame")
            _require(self._terminal is not None, "Missing terminal response")
            output = []
            response = self._terminal["response"]
            for item in response["output"]:
                state = self._items[item["id"]]
                output.append(self._announce(state))
                common = {"item_id": item["id"], "output_index": state["index"], "content_index": 0}
                if item["type"] == "message":
                    output.append(self._emit({"type": "response.output_text.done", **common, "text": self._part(state)["text"]}))
                    output.append(self._emit({"type": "response.content_part.done", **common, "part": self._part(state)}))
                elif item["type"] == "reasoning":
                    output.append(self._emit({"type": "response.reasoning_text.done", **common, "text": "".join(state["text"])}))
                output.append(self._emit({"type": "response.output_item.done", "output_index": state["index"], "item": item}))
            output.append(self._emit(self._terminal))
            self._finished = True
            return b"".join(output)
        except ProtocolError:
            self._failed = True
            raise

    def failure(self, code="invalid_prompt", message="Local model stream could not be validated."):
        """Terminate safely after ProtocolError; callers must not pass provider text."""
        if self._finished:
            return b""
        self._failed = self._finished = True
        return self._emit({"type": "response.failed", "response": {
            "id": self.response_id or "resp_" + uuid.uuid4().hex, "object": "response",
            "model": self.model or "local", "status": "failed", "output": [],
            "error": {"code": code, "message": message}, "incomplete_details": None}})
