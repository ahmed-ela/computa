import { describe, expect, test } from "bun:test";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, prepareReplay, requestBody, startCapture, summarize } from "./context-replay";

const body = { model: "synthetic", store: false, stream: true, input: [
  { type: "message", role: "user", content: [{ type: "input_text", text: "standing policy" }] },
  { type: "message", role: "user", content: [{ type: "input_text", text: "current request" }] },
  { type: "function_call", name: "status", call_id: "call_test", arguments: "{}" },
  { type: "function_call_output", call_id: "call_test", output: "done" }
], tools: [{ type: "function", name: "status", parameters: { type: "object" } }] };
const raw = JSON.stringify(body, null, 2) + "\n";
const completion = { id: "response_test", status: "completed", error: null, output: [
  { type: "message", role: "assistant", content: [{ type: "output_text", text: "retained ✓" }] },
  { type: "function_call", name: "not_executed", arguments: "{}", call_id: "call_unused" }
], usage: { input_tokens: 50, output_tokens: 3, input_tokens_details: { cached_tokens: 40 } } };
const sse = `event: response.output_text.delta\r\ndata: {"type":"response.output_text.delta","delta":"ignored fragment"}\r\n\r\nevent: response.completed\r\ndata: ${JSON.stringify({ type: "response.completed", response: completion })}\r\n\r\ndata: [DONE]\r\n\r\n`;

describe("inert exact replay", () => {
  test("preserves bytes, all policy/input and tools by default", () => {
    expect(prepareReplay(raw)).toEqual({ raw, changedSampler: false, insertedAssistantHistory: false });
  });
  test("labels explicit sampler changes", () => {
    const prepared = prepareReplay(raw, 0);
    expect(prepared.changedSampler).toBe(true);
    expect(JSON.parse(prepared.raw)).toEqual({ ...body, temperature: 0 });
    expect(() => prepareReplay(raw, 1)).toThrow();
  });
  test("inserts only a provided assistant message before latest user and preserves other order", () => {
    const assistant = { type: "message", role: "assistant", content: [{ type: "output_text", text: "ACTUAL_ACK" }] };
    const prepared = prepareReplay(raw, undefined, JSON.stringify(assistant));
    expect(JSON.parse(prepared.raw).input).toEqual([body.input[0], assistant, ...body.input.slice(1)]);
    expect(JSON.parse(prepared.raw).tools).toEqual(body.tools);
    expect(prepared.insertedAssistantHistory).toBe(true);
    expect(prepared.changedSampler).toBe(false);
  });
  test("rejects role escalation, reasoning, tool calls and oversized history", () => {
    for (const item of [
      { type: "message", role: "system", content: [] },
      { type: "reasoning", role: "assistant", content: [] },
      { type: "message", role: "assistant", content: [{ type: "function_call", name: "delete" }] },
      { type: "message", role: "assistant", content: [{ type: "output_text", text: "x".repeat(2049) }] }
    ]) expect(() => prepareReplay(raw, undefined, JSON.stringify(item))).toThrow();
  });
  test("rejects hosted tools, chained/background requests and unbounded bodies", () => {
    for (const change of [{ tools: [{ type: "mcp" }] }, { previous_response_id: "resp_1" }, { conversation: "conv_1" }, { background: true }, { input: "not explicit" }]) {
      expect(() => requestBody(JSON.stringify({ ...body, ...change }))).toThrow();
    }
    expect(() => requestBody(" ".repeat(1024 * 1024 + 1))).toThrow();
  });
});

describe("completed response accounting", () => {
  test("reads final SSE output once without executing tool calls or using deltas", () => {
    expect(summarize(sse, "text/event-stream", 123, 200)).toEqual({ responseID: "response_test", status: "completed", elapsedMs: 123,
      finalText: "retained ✓", toolCallNames: ["not_executed"], inputTokens: 50, outputTokens: 3, cachedTokens: 40 });
  });
  test("supports nonstreaming JSON", () => expect(summarize(JSON.stringify(completion), "application/json", 1, 200).finalText).toBe("retained ✓"));
  test("fails closed on missing/duplicate terminal, failed events, malformed data and HTTP errors", () => {
    for (const candidate of ["data: [DONE]\n\n", sse + sse, 'data: {"type":"response.failed"}\n\n', "data: not-json\n\n"]) {
      expect(() => summarize(candidate, "text/event-stream", 1, 200)).toThrow();
    }
    expect(() => summarize(JSON.stringify(completion), "application/json", 1, 500)).toThrow();
  });
});

test("CLI bounds and fixed loopback destination", () => {
  expect(parseArgs(["capture", "--out", "/tmp/context-fixture", "--port", "0"]).mode).toBe("capture");
  for (const args of [["replay", "--out", "/tmp/a", "--request", "/tmp/b", "--count", "11"],
    ["capture", "--out", "/tmp/a", "--port", "65536"], ["capture", "--out", "relative", "--port", "0"],
    ["capture", "--out", "/tmp/a", "--port", "0", "--upstream", "https://example.com"]]) expect(() => parseArgs(args)).toThrow();
});

test("mock-only capture preserves request/stream bytes without credential artifacts", async () => {
  const out = await mkdtemp(join(tmpdir(), "heydash-context-replay-test-"));
  let observedBody = "", observedAuth = "";
  const mock = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    observedBody = await request.text(); observedAuth = request.headers.get("authorization") ?? "";
    const encoded = new TextEncoder().encode(sse);
    return new Response(new ReadableStream({ start(controller) {
      for (let i = 0; i < encoded.length; i += 7) controller.enqueue(encoded.slice(i, i + 7));
      controller.close();
    } }), { headers: { "content-type": "text/event-stream", "set-cookie": "should-not-be-recorded" } });
  } });
  const proxy = await startCapture(out, 0, `http://127.0.0.1:${mock.port}`);
  try {
    const result = await fetch(`http://127.0.0.1:${proxy.port}/v1/responses`, { method: "POST", body: raw,
      headers: { "content-type": "application/json", authorization: "Bearer SYNTHETIC_TEST_SECRET" } });
    expect(await result.text()).toBe(sse);
    expect(observedBody).toBe(raw); expect(observedAuth).toBe("Bearer SYNTHETIC_TEST_SECRET");
    const files = await readdir(out);
    expect(files.length).toBe(3);
    expect(await readFile(join(out, files.find(f => f.endsWith("request.json"))!), "utf8")).toBe(raw);
    for (const name of files) {
      const text = await readFile(join(out, name), "utf8");
      expect(text).not.toContain("SYNTHETIC_TEST_SECRET"); expect(text).not.toContain("should-not-be-recorded");
    }
  } finally { proxy.stop(true); mock.stop(true); await rm(out, { recursive: true }); }
});

for (const complete of [true, false]) test(`mock cancellation ${complete ? "after terminal succeeds without spurious error" : "before terminal remains failure"}`, async () => {
  const out = await mkdtemp(join(tmpdir(), "heydash-context-cancel-test-"));
  const sent = complete ? sse : 'data: {"type":"response.output_text.delta","delta":"partial"}\n\n';
  const mock = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() {
    return new Response(new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode(sent));
      // Deliberately keep transport open after terminal; client chooses to stop.
    } }), { headers: { "content-type": "text/event-stream" } });
  } });
  const proxy = await startCapture(out, 0, `http://127.0.0.1:${mock.port}`);
  try {
    const abort = new AbortController();
    const result = await fetch(`http://127.0.0.1:${proxy.port}/v1/responses`, { method: "POST", body: raw, signal: abort.signal });
    const reader = result.body!.getReader();
    expect((await reader.read()).done).toBe(false);
    abort.abort();
    await reader.cancel().catch(() => {});
    let files: string[] = [];
    for (let attempt = 0; attempt < 100; attempt++) {
      files = await readdir(out);
      if (files.some(f => f.endsWith("summary.json"))) break;
      await Bun.sleep(10);
    }
    const summaryFile = files.find(f => f.endsWith("summary.json"));
    expect(summaryFile).toBeDefined();
    const summary = JSON.parse(await readFile(join(out, summaryFile!), "utf8"));
    expect(files.some(f => f.endsWith("error.json"))).toBe(false);
    expect(await readFile(join(out, files.find(f => f.endsWith("response.sse"))!), "utf8")).toBe(sent);
    if (complete) { expect(summary.error).toBeUndefined(); expect(summary.finalText).toBe("retained ✓"); }
    else { expect(summary.error).toContain("exactly one completed"); expect(summary.finalText).toBeUndefined(); }
  } finally { proxy.stop(true); mock.stop(true); await rm(out, { recursive: true }); }
});
