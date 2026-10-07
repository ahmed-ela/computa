"""Offline fixtures only: no MLX import, models, network, or private captures."""
import copy
import ast
import importlib.util
import json
from pathlib import Path
import unittest
import sys

path = Path(__file__).parents[2] / "Sources/Computa/Resources/MLXServer/sse_contract.py"
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location("heydash_sse", path)
sse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sse)
SSEContract, ProtocolError = sse.SSEContract, sse.ProtocolError


def event(kind, **fields):
    return {"type": kind, **fields}


def wire(events, crlf=False):
    result = b"".join(("event: " + item["type"] + "\ndata: "
                       + json.dumps(item, ensure_ascii=False) + "\n\n").encode() for item in events)
    return result.replace(b"\n", b"\r\n") if crlf else result


def parse(data):
    return [json.loads(line[6:]) for line in data.decode().split("\n") if line.startswith("data: ") and line[6:] != "[DONE]"]


def fixture(public="\n\nHello 🌍\u2028there ", reasoning="", call=None, tokens=25):
    response = {"id": "resp_fixture", "model": "qwen-fixture", "status": "in_progress", "output": [], "created_at": 20}
    message = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "in_progress", "content": []}
    common = {"item_id": message["id"], "output_index": 0, "content_index": 0}
    result = [event("response.created", response=copy.deepcopy(response)),
              event("response.in_progress", response=copy.deepcopy(response)),
              event("response.output_item.added", output_index=0, item=copy.deepcopy(message)),
              event("response.content_part.added", **common, part={"type": "output_text", "text": "", "annotations": []})]
    if reasoning:
        rcommon = {"item_id": "rs_fixture", "output_index": 0, "content_index": 0, "response_id": response["id"]}
        result.append(event("response.reasoning_text.delta", **rcommon, delta=reasoning))
    if public:
        result += [event("response.output_text.delta", **common, delta=chunk) for chunk in [public[:2], public[2:]]]
    if reasoning:
        result.append(event("response.reasoning_text.done", **rcommon, text=reasoning))
    # Mirrors the pinned bug: unfinished thinking leaks into final parsed text;
    # otherwise final parser strips public whitespace.
    reparsed = public.strip() or (reasoning if not call else "")
    part = {"type": "output_text", "text": reparsed, "annotations": []}
    result += [event("response.output_text.done", **common, text=reparsed),
               event("response.content_part.done", **common, part=part)]
    message = {**message, "status": "completed", "content": [part] if reparsed else []}
    if reasoning and public:
        message["reasoning"] = reasoning
    result.append(event("response.output_item.done", output_index=0, item=message))
    output = []
    if reasoning and public:
        output.append({"id": "rs_fixture", "type": "reasoning", "summary": [{"type": "summary_text", "text": reasoning.strip()}]})
    if public or not call:
        output.append(message)
    if call:
        index = len(output)
        result += [event("response.output_item.added", output_index=index, item=copy.deepcopy(call)),
                   event("response.function_call_arguments.done", item_id=call["id"], output_index=index,
                         name=call["name"], call_id=call["call_id"], arguments=call["arguments"], item=copy.deepcopy(call)),
                   event("response.output_item.done", output_index=index, item=copy.deepcopy(call))]
        output.append(copy.deepcopy(call))
    result.append(event("response.completed", response={**response, "status": "completed", "output": output,
                  "output_text": reparsed, "error": None, "incomplete_details": None,
                  "usage": {"input_tokens": 100, "output_tokens": tokens, "total_tokens": 100 + tokens}}))
    return result


CALL = {"id": "fc_original", "type": "function_call", "call_id": "call_exact",
        "name": "computer_v2_status", "arguments": '{ "read_only": true }', "status": "completed"}


class ContractTests(unittest.TestCase):
    def test_every_host_protocol_condition_has_an_allowlisted_diagnostic(self):
        for name in ("sse_contract.py", "response_boundary.py"):
            tree = ast.parse(path.with_name(name).read_text())
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
                    continue
                if node.func.id not in ("_require", "ProtocolError"):
                    continue
                index = 1 if node.func.id == "_require" else 0
                if node.func.id == "ProtocolError" and isinstance(node.args[index], ast.Name):
                    self.assertEqual(node.args[index].id, "message")  # _require forwards its fixed call-site condition.
                    continue
                self.assertIsInstance(node.args[index], ast.Constant)
                self.assertIn(node.args[index].value, sse._PROTOCOL_MESSAGES)

    def test_diagnostic_never_formats_exception_group_or_unknown_payload(self):
        private = "private prompt, tool arguments, or provider exception"
        failure = ExceptionGroup(private, [ProtocolError("Missing terminal response"),
                                          ExceptionGroup(private, [ProtocolError(private)])])
        self.assertEqual(sse.protocol_error_diagnostic(failure), ("missing_terminal_response", 2, False))
        self.assertEqual(sse.protocol_error_diagnostic(ProtocolError(private)),
                         ("unknown_protocol_error", 1, False))
        failure = ExceptionGroup(private, [ProtocolError("Missing terminal response")] * 1000)
        self.assertEqual(sse.protocol_error_diagnostic(failure), ("missing_terminal_response", 31, True))
        for _ in range(40):
            failure = ExceptionGroup(private, [failure])
        self.assertEqual(sse.protocol_error_diagnostic(failure), ("unknown_protocol_error", 0, True))

    def test_json_diagnostics_preserve_duplicate_and_nonfinite_conditions(self):
        for text, reason in [("{\"x\":1,\"x\":2}", "duplicate_json_field"),
                             ("{\"x\":NaN}", "nonfinite_json"),
                             ("{not JSON}", "malformed_stream_json")]:
            with self.subTest(reason=reason), self.assertRaises(ProtocolError) as failure:
                sse._json(text)
            self.assertEqual(sse.protocol_error_diagnostic(failure.exception), (reason, 1, False))

    def test_diagnostic_counters_are_bounded_and_event_names_are_allowlisted(self):
        contract = SSEContract(100)
        events = fixture()[:1] + [event("provider-private-event-name", private="private content")]
        with self.assertRaises(ProtocolError):
            contract.feed(wire(events))
        self.assertEqual(contract.diagnostic_counters(), {
            "bytes": len(wire(events)), "events": 2, "items": 0, "last": "unsupported", "terminal": 0})
        contract = SSEContract(100)
        with self.assertRaises(ProtocolError):
            contract.feed(b"x" * (contract.MAX_STREAM_BYTES + 4096))
        self.assertEqual(contract.diagnostic_counters()["bytes"], contract.MAX_STREAM_BYTES + 1)

    def process(self, events, cap=100, chunk_size=None, crlf=False):
        contract = SSEContract(cap)
        raw = wire(events, crlf)
        chunk_size = chunk_size or len(raw)
        result = b"".join(contract.feed(raw[i:i + chunk_size]) for i in range(0, len(raw), chunk_size))
        result += contract.finish()
        return parse(result)

    def test_public_whitespace_unicode_and_final_text_agree(self):
        public = "\n\nHello 🌍\u2028there "
        output = self.process(fixture(public=public, reasoning="private synthetic reasoning"))
        final = output[-1]["response"]
        self.assertEqual(final["status"], "completed")
        self.assertEqual(final["output_text"], public)
        messages = [i for i in final["output"] if i["type"] == "message"]
        self.assertEqual(messages[0]["content"][0]["text"], public)
        self.assertNotIn("reasoning", messages[0])
        self.assertEqual("".join(e["delta"] for e in output if e["type"] == "response.output_text.delta"), public)
        self.assertEqual([e["text"] for e in output if e["type"] == "response.output_text.done"], [public])
        self.assertEqual([e["sequence_number"] for e in output], list(range(len(output))))
        for index, item in enumerate(final["output"]):
            self.assertTrue(any(e["type"] == "response.output_item.done" and e["item"] == item
                                and e["output_index"] == index for e in output))

    def test_every_single_byte_split_and_crlf_is_safe(self):
        expected = self.process(fixture())
        for crlf in (False, True):
            for chunk in (1, 2, 3, 7, 23, 1024):
                with self.subTest(crlf=crlf, chunk=chunk):
                    self.assertEqual(self.process(fixture(), chunk_size=chunk, crlf=crlf), expected)

    def test_text_deltas_are_realtime_but_final_items_wait_for_eof(self):
        contract = SSEContract(100)
        events = fixture()
        progressive = parse(contract.feed(wire(events)))
        self.assertTrue(any(e["type"] == "response.output_text.delta" for e in progressive))
        self.assertFalse(any(e["type"].endswith(".done") or e["type"] == "response.completed" for e in progressive))
        final = parse(contract.finish())
        self.assertEqual(final[-1]["type"], "response.completed")
        with self.assertRaises(ProtocolError):
            contract.finish()

    def test_empty_message_headers_wait_until_public_text_after_reasoning(self):
        contract = SSEContract(100)
        events = fixture(public="Hello 🌍", reasoning="synthetic private reasoning")
        prefix = parse(contract.feed(wire(events[:4])))
        self.assertEqual([e["type"] for e in prefix], ["response.created", "response.in_progress"])
        thinking = parse(contract.feed(wire(events[4:5])))
        self.assertEqual([e["type"] for e in thinking], [
            "response.output_item.added", "response.reasoning_summary_part.added", "response.reasoning_summary_text.delta",
        ])
        self.assertEqual(thinking[0]["item"]["id"], "rs_fixture")
        self.assertEqual(thinking[0]["output_index"], 0)

        public = parse(contract.feed(wire(events[5:6])))
        self.assertEqual([e["type"] for e in public], [
            "response.output_item.added", "response.content_part.added", "response.output_text.delta",
        ])
        self.assertEqual(public[0]["item"]["id"], "msg_fixture")
        self.assertEqual([e["output_index"] for e in public], [1, 1, 1])
        self.assertEqual(public[2]["item_id"], public[0]["item"]["id"])
        self.assertEqual(public[2]["delta"], "He")
        remaining = parse(contract.feed(wire(events[6:])))
        self.assertFalse(any(e["type"].endswith(".done") for e in prefix + thinking + public + remaining))
        final = parse(contract.finish())
        self.assertEqual(final[-1]["response"]["output_text"], "Hello 🌍")
        self.assertEqual([e["item"]["id"] for e in prefix + thinking + public + remaining + final
                          if e["type"] == "response.output_item.added"], ["rs_fixture", "msg_fixture"])

    def test_every_public_delta_uses_latest_announced_item_and_preserves_utf8_chunks(self):
        # The pinned Rust consumer routes output_text.delta by its most recent
        # output_item.added, not by the item_id carried by the SSE text event.
        public = "\n\nHello 🌍\u2028there\t東京 "
        source = fixture(public=public, reasoning="private 🧭 reasoning")
        expected_chunks = [e["delta"].encode("utf-8") for e in source if e["type"] == "response.output_text.delta"]
        for crlf in (False, True):
            for chunk_size in (1, 3, 7, 257):
                with self.subTest(crlf=crlf, chunk_size=chunk_size):
                    output = self.process(source, chunk_size=chunk_size, crlf=crlf)
                    active = None
                    chunks = []
                    for emitted in output:
                        if emitted["type"] == "response.output_item.added":
                            active = emitted["item"]["id"]
                        if emitted["type"] == "response.output_text.delta":
                            self.assertEqual(emitted["item_id"], active)
                            self.assertEqual(active, "msg_fixture")
                            chunks.append(emitted["delta"].encode("utf-8"))
                    self.assertEqual(chunks, expected_chunks)
                    self.assertEqual(b"".join(chunks), public.encode("utf-8"))
                    self.assertEqual(output[-1]["response"]["output_text"].encode("utf-8"), b"".join(chunks))

    def test_deferred_message_indices_stay_stable_when_terminal_omits_capped_tool(self):
        cases = [
            ("tool-only", fixture(public="", call=CALL), "completed", ["fc_original", "msg_fixture"]),
            ("reasoning-tool", fixture(public="", reasoning="private", call=CALL), "completed",
             ["rs_fixture", "fc_original", "msg_fixture"]),
            ("reasoning-only", fixture(public="", reasoning="private"), "incomplete", ["rs_fixture", "msg_fixture"]),
            ("capped-tool", fixture(public="", call=CALL, tokens=100), "incomplete", ["msg_fixture"]),
            ("capped-reasoning-tool", fixture(public="", reasoning="private", call=CALL, tokens=100),
             "incomplete", ["rs_fixture", "msg_fixture"]),
        ]
        for name, source, status, final_ids in cases:
            with self.subTest(name=name):
                output = self.process(source)
                announced = {}
                completed = {}
                for emitted in output:
                    if emitted["type"] == "response.output_item.added":
                        identity = emitted["item"]["id"]
                        self.assertNotIn(identity, announced)
                        self.assertNotIn(emitted["output_index"], announced.values())
                        announced[identity] = emitted["output_index"]
                    elif "output_index" in emitted:
                        identity = emitted["item"]["id"] if "item" in emitted else emitted["item_id"]
                        self.assertIn(identity, announced)
                        self.assertEqual(emitted["output_index"], announced[identity])
                        if emitted["type"] == "response.output_item.done":
                            completed[identity] = emitted["output_index"]
                final = output[-1]["response"]
                self.assertEqual(final["status"], status)
                self.assertEqual([item["id"] for item in final["output"]], final_ids)
                self.assertEqual(set(completed), set(final_ids))
                self.assertEqual([e["sequence_number"] for e in output], list(range(len(output))))
                if name.startswith("capped"):
                    self.assertIn("fc_original", announced)
                    self.assertNotIn("fc_original", completed)
                    self.assertGreater(announced["msg_fixture"], announced["fc_original"],
                                       "An omitted function must not renumber an already emitted item.")

    def test_deferred_headers_do_not_release_invalid_final_text(self):
        events = fixture(public="Visible incremental text", reasoning="private")
        contract = SSEContract(100)
        before = parse(contract.feed(wire(events[:-1])))
        self.assertTrue(any(e["type"] == "response.output_text.delta" for e in before))
        self.assertFalse(any(e["type"].endswith(".done") for e in before))
        events[-1]["response"]["output_text"] = "Unrelated final text"
        with self.assertRaises(ProtocolError):
            contract.feed(wire(events[-1:]))
        with self.assertRaises(ProtocolError):
            contract.finish()
        failure = parse(contract.failure())
        self.assertEqual(failure[-1]["type"], "response.failed")
        self.assertEqual(failure[-1]["response"]["output"], [])
        self.assertNotIn("Unrelated final text", json.dumps(failure))

    def test_unsupported_interleaving_never_misattributes_resumed_public_text(self):
        source = fixture(public="Hello again", reasoning="private")
        first_public = next(i for i, e in enumerate(source) if e["type"] == "response.output_text.delta")
        common = {"item_id": "rs_fixture", "output_index": 0, "content_index": 0}
        cases = [
            ("resume-existing-reasoning", [event("response.reasoning_text.delta", **common, delta="late private")]),
            ("new-reasoning-then-public", [
                event("response.reasoning_text.delta", item_id="rs_new", output_index=2,
                      content_index=0, delta="late private"), source[first_public + 1],
            ]),
            ("function-then-public", [
                event("response.output_item.added", output_index=2, item=copy.deepcopy(CALL)),
                source[first_public + 1],
            ]),
        ]
        for name, interleaved in cases:
            with self.subTest(name=name):
                contract = SSEContract(100)
                before = parse(contract.feed(wire(source[:first_public + 1])))
                self.assertEqual([e["item_id"] for e in before if e["type"] == "response.output_text.delta"],
                                 ["msg_fixture"])
                with self.assertRaises(ProtocolError):
                    contract.feed(wire(interleaved))
                failure = parse(contract.failure())
                self.assertEqual(failure[-1]["type"], "response.failed")
                self.assertFalse(any(e["type"] == "response.output_item.done" for e in before + failure))

    def test_function_call_is_byte_exact_and_not_dispatched_until_eof(self):
        contract = SSEContract(100)
        before = parse(contract.feed(wire(fixture(public="", reasoning="synthetic", call=CALL))))
        self.assertFalse(any(e["type"] == "response.output_item.done" for e in before))
        after = parse(contract.finish())
        calls = [e["item"] for e in after if e["type"] == "response.output_item.done" and e["item"]["type"] == "function_call"]
        self.assertEqual(calls, [CALL])
        self.assertEqual([i for i in after[-1]["response"]["output"] if i["type"] == "function_call"], [CALL])

    def test_reasoning_only_is_incomplete_and_never_an_answer(self):
        for tokens in (50, 100):
            output = self.process(fixture(public="", reasoning="PRIVATE_SYNTHETIC_NOT_AN_ANSWER", tokens=tokens))
            self.assertEqual(output[-1]["type"], "response.incomplete")
            self.assertEqual(output[-1]["response"]["output_text"], "")
            messages = [i for i in output[-1]["response"]["output"] if i["type"] == "message"]
            self.assertEqual(messages[0]["content"], [])
            self.assertFalse(any(e["type"] == "response.completed" for e in output))

    def test_exhaustion_cannot_release_an_executable_function(self):
        output = self.process(fixture(public="", call=CALL, tokens=100))
        self.assertEqual(output[-1]["type"], "response.incomplete")
        self.assertFalse(any(e["type"] == "response.output_item.done" and e["item"]["type"] == "function_call" for e in output))
        self.assertFalse(any(i["type"] == "function_call" for i in output[-1]["response"]["output"]))

    def test_partial_public_answer_at_token_cap_is_incomplete(self):
        output = self.process(fixture(public="partial", tokens=100))
        self.assertEqual(output[-1]["response"]["output_text"], "partial")
        self.assertEqual(output[-1]["response"]["incomplete_details"], {"reason": "max_output_tokens"})
        self.assertEqual(output[-1]["response"]["output"][0]["status"], "incomplete")

    def test_corrupt_terminal_never_releases_tool(self):
        mutations = [lambda r: r.update(id="wrong"), lambda r: r.update(model="wrong"),
                     lambda r: r.update(status="incomplete"), lambda r: r.update(error={"message": "secret"}),
                     lambda r: r["output"][-1].update(call_id="wrong"), lambda r: r.update(output=[]),
                     lambda r: r["output"].append(copy.deepcopy(r["output"][-1])),
                     lambda r: r["usage"].update(total_tokens=999), lambda r: r["usage"].update(output_tokens=True)]
        for mutate in mutations:
            contract, events = SSEContract(100), fixture(public="", call=CALL)
            before = parse(contract.feed(wire(events[:-1])))
            mutate(events[-1]["response"])
            with self.subTest(mutation=mutate), self.assertRaises(ProtocolError):
                contract.feed(wire(events[-1:]))
            self.assertFalse(any(e["type"] == "response.output_item.done" for e in before))
            failure = parse(contract.failure())
            self.assertEqual(failure[-1]["type"], "response.failed")
            self.assertNotIn("secret", json.dumps(failure))
            self.assertEqual(contract.failure(), b"")

    def test_missing_terminal_truncated_frame_and_late_data_fail_closed(self):
        for raw, after_feed in ((wire(fixture()[:-1]), True), (wire(fixture())[:-1], True),
                               (wire(fixture()) + wire(fixture()[:1]), False),
                               (wire(fixture()) + b"data: [DONE]\n\ndata: {}\n\n", False)):
            contract = SSEContract(100)
            with self.subTest(after_feed=after_feed), self.assertRaises(ProtocolError):
                contract.feed(raw)
                if after_feed:
                    contract.finish()
            self.assertEqual(parse(contract.failure())[-1]["type"], "response.failed")

    def test_clean_done_marker_comments_and_multiline_json(self):
        contract = SSEContract(100)
        raw = b": keepalive\r\n\r\n" + wire(fixture()).replace(b'data: {"type":', b'data: {\ndata: "type":')
        out = contract.feed(raw + b"data: [DONE]\n\n") + contract.finish()
        self.assertEqual(parse(out)[-1]["type"], "response.completed")

    def test_malformed_structures_are_payload_free_protocol_errors(self):
        raws = [b"data: {not-json secret}\n\n", b'data: {"type":"a","type":"b"}\n\n',
                b'data: {"type":"a","value":NaN}\n\n', b"data: \xff\n\n",
                b"event: wrong\ndata: {\"type\":\"response.created\"}\n\n",
                wire(fixture()[:1]) + wire([event("response.in_progress", response=[])]),
                wire(fixture()[:3]) + wire([event("response.content_part.added", item_id=[], part=[])]),
                b'data: {"type":"response.created","response":[]}\n\n']
        for raw in raws:
            with self.subTest(length=len(raw)):
                contract = SSEContract(100)
                with self.assertRaises(ProtocolError) as caught:
                    contract.feed(raw)
                self.assertNotIn("secret", str(caught.exception))

    def test_unrelated_final_text_mismatch_is_not_silently_repaired(self):
        for target in ("response.output_text.done", "response.content_part.done", "response.output_item.done", "response.completed"):
            events = fixture()
            changed = next(e for e in events if e["type"] == target)
            if target == "response.output_text.done":
                changed["text"] = "unstreamed unrelated text"
            elif target == "response.content_part.done":
                changed["part"] = {**changed["part"], "text": "unstreamed unrelated text"}
            elif target == "response.output_item.done":
                changed["item"] = {**changed["item"], "content": [{"type": "output_text", "text": "unstreamed unrelated text"}]}
            else:
                changed["response"]["output_text"] = "unstreamed unrelated text"
            with self.subTest(target=target), self.assertRaises(ProtocolError):
                self.process(events)

    def test_surrogate_string_rejects_without_unicode_exception(self):
        contract = SSEContract(100)
        contract.feed(wire(fixture()[:4]))
        with self.assertRaises(ProtocolError):
            contract.feed(b'data: {"type":"response.output_text.delta","item_id":"msg_fixture","content_index":0,"delta":"\\ud800"}\n\n')

    def test_unencodable_terminal_metadata_still_emits_safe_failure(self):
        contract = SSEContract(100)
        events = fixture(public="", call=CALL)
        contract.feed(wire(events[:-1]))
        events[-1]["response"]["unknown_metadata"] = "\ud800"
        contract.feed(("data: " + json.dumps(events[-1]) + "\n\n").encode())
        with self.assertRaises(ProtocolError):
            contract.finish()
        failure = parse(contract.failure())
        self.assertEqual(failure[-1]["type"], "response.failed")
        self.assertEqual(failure[-1]["response"]["error"]["code"], "invalid_prompt")

    def test_duplicate_lifecycle_unknown_item_and_bad_argument_json_reject(self):
        cases = []
        base = fixture(public="", call=CALL)
        cases.append(base[:1] + base)
        cases.append(base[:3] + [base[2]] + base[3:])
        bad = copy.deepcopy(base)
        next(e for e in bad if e["type"] == "response.function_call_arguments.done")["arguments"] = "{}"
        cases.append(bad)
        bad = copy.deepcopy(base)
        next(e for e in bad if e["type"] == "response.output_item.added" and e["item"]["type"] == "function_call")["item"]["arguments"] = "not json"
        cases.append(bad)
        bad = fixture()
        next(e for e in bad if e["type"] == "response.output_text.delta")["item_id"] = "unknown"
        cases.append(bad)
        for events in cases:
            with self.subTest(events=len(events)), self.assertRaises(ProtocolError):
                self.process(events)

    def test_byte_event_frame_and_text_bounds(self):
        contract = SSEContract(100)
        contract.MAX_STREAM_BYTES = 10
        with self.assertRaises(ProtocolError):
            contract.feed(b" " * 11)
        contract = SSEContract(100)
        contract.MAX_FRAME_BYTES = 10
        with self.assertRaises(ProtocolError):
            contract.feed(b"data: " + b" " * 11)
        contract = SSEContract(100)
        contract.MAX_EVENTS = 1
        with self.assertRaises(ProtocolError):
            contract.feed(wire(fixture()[:2]))
        for reasoning in (False, True):
            contract = SSEContract(100)
            contract.MAX_TEXT_BYTES = 3
            with self.assertRaises(ProtocolError):
                contract.feed(wire(fixture(public="" if reasoning else "long text", reasoning="long thought" if reasoning else "")))


if __name__ == "__main__":
    unittest.main()
