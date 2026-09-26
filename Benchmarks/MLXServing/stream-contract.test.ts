import { expect, test } from "bun:test";
import { SSEDecoder, consistentText, functionCall } from "./stream-contract";

test("text consistency preserves leading whitespace and rejects silent final trimming", () => {
  const events = [{ type: "response.output_text.delta", delta: '\n\n{"left":"Queued","right":"Complete"}' }];
  const response = (text: string) => ({ output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text }] }] });
  expect(consistentText(events, response(events[0].delta))).toBe(events[0].delta);
  expect(() => consistentText(events, response(events[0].delta.trim()))).toThrow();
});

test("SSE supports split frames, comments, multiline data and done sentinel", () => {
  const parser = new SSEDecoder();
  expect(parser.push(": ping\n\ndata: {\"type\":")).toEqual([]);
  expect(parser.push("\"test\"}\n\ndata: [DONE]\n\n")).toEqual([{ type: "test" }]);
  parser.finish();
});
test("truncated frame and malformed JSON reject", () => {
  const parser = new SSEDecoder(); parser.push("data: {}");
  expect(() => parser.finish()).toThrow();
  expect(() => new SSEDecoder().push("data: nope\n\n")).toThrow();
});
test("CRLF pairs split across transport chunks retain frame boundaries", () => {
  const parser = new SSEDecoder();
  expect(parser.push('data: {"type":"test"}\r')).toEqual([]);
  expect(parser.push("\n\r")).toEqual([]);
  expect(parser.push("\n")).toEqual([{ type: "test" }]);
  parser.finish();
});
test("strict function lifecycle accepts done-only arguments but not omitted item.done", () => {
  const call = { type: "function_call", id: "fc1", call_id: "call1", name: "read_fixture", arguments: '{"fixture_id":"token"}' };
  const events = [{ type: "response.output_item.added", item: call },
    { type: "response.function_call_arguments.done", item_id: "fc1", arguments: call.arguments },
    { type: "response.output_item.done", item: call }];
  expect(functionCall(events, { output: [call] }, "read_fixture", call.arguments)).toEqual(call);
  expect(() => functionCall(events.slice(0, 2), { output: [call] }, "read_fixture", call.arguments)).toThrow();
  expect(() => functionCall([events[2], events[0], events[1]], { output: [call] }, "read_fixture", call.arguments)).toThrow();
});
