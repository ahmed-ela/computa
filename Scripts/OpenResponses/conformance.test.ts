import { describe, expect, test } from "bun:test";
import { officialRequestHeaders, parseOfficialFixtureHeaders, parseFrames, responseErrors, schemaErrors, streamErrors, verifyUpstream } from "./conformance";
import { testTemplates, type TestConfig } from "./vendor/src/lib/compliance-tests";

const config: TestConfig = { baseUrl: "http://127.0.0.1/v1", apiKey: "fixture-only", model: "fixture", authHeaderName: "Authorization", useBearerPrefix: true };
const phaseFixture = testTemplates.find(template => template.id === "response-output-phase-schema")!;

function resource(): Record<string, any> {
  const value = phaseFixture.getMockResponse!(config) as Record<string, any>;
  value.output = [value.output[1]];
  return structuredClone(value);
}

function framesForResponse(response: Record<string, any>): Record<string, any>[] {
  const pending = structuredClone(response);
  pending.status = "in_progress"; pending.completed_at = null; pending.output = [];
  const events: Record<string, any>[] = [
    { type: "response.created", response: pending },
    { type: "response.in_progress", response: pending },
  ];
  for (const [index, item] of response.output.entries()) {
    const added = structuredClone(item); added.status = "in_progress";
    if (item.type === "message") added.content = [];
    else if (item.type === "reasoning") added.summary = [];
    else added[item.type === "custom_tool_call" ? "input" : "arguments"] = "";
    events.push({ type: "response.output_item.added", output_index: index, item: added });
    const common = { output_index: index, item_id: item.id };
    if (item.type === "message") {
      for (const [content_index, part] of item.content.entries()) {
        const content = { ...common, content_index };
        events.push({ type: "response.content_part.added", ...content, part: { ...part, text: "" } });
        events.push({ type: "response.output_text.delta", ...content, delta: part.text });
        events.push({ type: "response.output_text.done", ...content, text: part.text });
        events.push({ type: "response.content_part.done", ...content, part });
      }
    } else if (item.type === "reasoning") {
      for (const [summary_index, part] of item.summary.entries()) {
        const content = { ...common, summary_index };
        events.push({ type: "response.reasoning_summary_part.added", ...content, part: { ...part, text: "" } });
        events.push({ type: "response.reasoning_summary_text.delta", ...content, delta: part.text });
        events.push({ type: "response.reasoning_summary_text.done", ...content, text: part.text });
        events.push({ type: "response.reasoning_summary_part.done", ...content, part });
      }
    } else {
      const field = item.type === "custom_tool_call" ? "input" : "arguments";
      const kind = item.type === "custom_tool_call" ? "custom_tool_call_input" : "function_call_arguments";
      events.push({ type: `response.${kind}.delta`, ...common, delta: item[field] });
      events.push({ type: `response.${kind}.done`, ...common, [field]: item[field] });
    }
    events.push({ type: "response.output_item.done", output_index: index, item });
  }
  events.push({ type: "response.completed", response });
  return events.map((event, sequence_number) => ({ ...event, sequence_number }));
}

function encode(events: Record<string, any>[]) {
  return events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join("") + "data: [DONE]\n\n";
}

describe("pinned Open Responses conformance infrastructure", () => {
  test("default official headers preserve authorization and invent no native turn context", () => {
    const original = new Headers({ Authorization: "Bearer fixture-only", "Content-Type": "application/json" });
    const first = officialRequestHeaders(original), second = officialRequestHeaders(original);
    expect(first.get("Authorization")).toBe("Bearer fixture-only");
    expect(first.get("Content-Type")).toBe("application/json");
    expect(first.get("x-computa-task-id")).toMatch(/^[a-f0-9-]{36}$/);
    expect(first.get("x-computa-task-id")).not.toBe(second.get("x-computa-task-id"));
    expect(first.has("x-codex-turn-metadata")).toBe(false);
    expect(original.has("x-computa-task-id")).toBe(false);
  });
  test("explicit fixture headers retain the prepared native context without rewriting other request headers", () => {
    const value = { "x-computa-task-id": "7851b5cc-fc3f-4336-95a0-d02e217da9f2",
      "x-codex-turn-metadata": '{"thread_id":"d4d641ae-3716-4d7d-a4d8-4079885d791e","turn_id":"41a57bdf-24b2-4763-b1c2-ec277b33eb82"}' };
    const parsed = parseOfficialFixtureHeaders(value);
    const headers = officialRequestHeaders({ Authorization: "Bearer fixture-only", "Content-Type": "application/json", "X-Upstream-Case": "unmodified" }, parsed);
    expect(headers.get("x-computa-task-id")).toBe(value["x-computa-task-id"]);
    expect(headers.get("x-codex-turn-metadata")).toBe(value["x-codex-turn-metadata"]);
    expect(headers.get("Authorization")).toBe("Bearer fixture-only");
    expect(headers.get("Content-Type")).toBe("application/json");
    expect(headers.get("X-Upstream-Case")).toBe("unmodified");
    expect(value).toEqual(parsed);
  });
  test("fixture headers reject missing identities, arbitrary header overrides and malformed metadata", () => {
    const value = { "x-computa-task-id": "7851b5cc-fc3f-4336-95a0-d02e217da9f2",
      "x-codex-turn-metadata": '{"thread_id":"d4d641ae-3716-4d7d-a4d8-4079885d791e","turn_id":"41a57bdf-24b2-4763-b1c2-ec277b33eb82"}' };
    for (const invalid of [null, [], {}, { ...value, Authorization: "replacement" }, { ...value, "x-computa-task-id": "not-a-uuid" },
      { ...value, "x-codex-turn-metadata": "invalid" }, { ...value, "x-codex-turn-metadata": "null" },
      { ...value, "x-codex-turn-metadata": "{}" }, { ...value, "x-codex-turn-metadata": JSON.stringify({ thread_id: value["x-computa-task-id"], turn_id: "invalid" }) },
      { ...value, "x-codex-turn-metadata": JSON.stringify({ thread_id: value["x-computa-task-id"], turn_id: value["x-computa-task-id"], extra: "foreign" }) },
      { ...value, "x-codex-turn-metadata": value["x-codex-turn-metadata"] + "\n" },
      { ...value, "x-codex-turn-metadata": "x".repeat(4097) }]) expect(() => parseOfficialFixtureHeaders(invalid)).toThrow();
  });
  test("vendored schemas and official tests match upstream hashes", async () => { await verifyUpstream(); });
  test("official assistant-phase fixture validates without data repair", () => {
    expect(responseErrors(phaseFixture.getMockResponse!(config) as Record<string, any>)).toEqual([]);
  });
  test("raw schema rejects mandatory fields Zod would default", () => {
    const value = resource(); delete value.object;
    expect(schemaErrors(value, "ResponseResource").length).toBeGreaterThan(0);
    expect(Object.hasOwn(value, "object")).toBe(false);
  });
  test("unknown usage remains nullable and required", () => {
    const value = resource(); value.usage = null;
    expect(responseErrors(value)).toEqual([]);
    delete value.usage;
    expect(responseErrors(value).length).toBeGreaterThan(0);
  });
  test("owned Codex local usage profile permits only genuine partial breakdowns", () => {
    const value = resource(); value.usage = { input_tokens: 12, output_tokens: 4, total_tokens: 16 };
    expect(responseErrors(value).length).toBeGreaterThan(0);
    expect(responseErrors(value, "codex-local-usage")).toEqual([]);
    value.usage.input_tokens_details = { cached_tokens: 0 };
    expect(responseErrors(value, "codex-local-usage")).toEqual([]);
    value.usage.total_tokens = 17;
    expect(responseErrors(value, "codex-local-usage").some(error => error.includes("total does not equal"))).toBe(true);
    value.usage.total_tokens = 16; delete value.usage.output_tokens;
    expect(responseErrors(value, "codex-local-usage").length).toBeGreaterThan(0);
    value.usage.output_tokens = -1;
    expect(responseErrors(value, "codex-local-usage").length).toBeGreaterThan(0);
    value.usage.output_tokens = 4; value.usage.output_tokens_details = {};
    expect(responseErrors(value, "codex-local-usage").length).toBeGreaterThan(0);
    value.usage.output_tokens_details = { reasoning_tokens: 2 };
    expect(responseErrors(value, "codex-local-usage")).toEqual([]);
    delete value.completed_at;
    expect(responseErrors(value, "codex-local-usage").length).toBeGreaterThan(0);
  });
  test("full message lifecycle validates", () => { expect(streamErrors(encode(framesForResponse(resource())))).toEqual([]); });
  test("multiple function call lifecycles reconstruct terminal output", () => {
    const value = resource();
    value.output = [0, 1].map(index => ({ id: `fc_${index}`, call_id: `call_${index}`, type: "function_call", status: "completed", name: "fixture_tool", arguments: '{"a":1}' }));
    expect(streamErrors(encode(framesForResponse(value)))).toEqual([]);
  });
  test("reasoning summary lifecycles reconstruct their terminal item", () => {
    const value = resource();
    value.output.unshift({ id: "rs_fixture", type: "reasoning", status: "completed", summary: [{ type: "summary_text", text: "Synthetic summary" }] });
    const events = framesForResponse(value);
    expect(streamErrors(encode(events))).toEqual([]);
    events.find(event => event.type === "response.reasoning_summary_text.delta")!.delta = "different";
    expect(streamErrors(encode(events)).some(error => error.includes("summary done differs"))).toBe(true);
    const noPartDone = framesForResponse(value).filter(event => event.type !== "response.reasoning_summary_part.done");
    expect(streamErrors(encode(noPartDone)).some(error => error.includes("closed before its summary part"))).toBe(true);
    delete value.output[0].status; // The upstream ReasoningBody schema does not require status in JSON.
    expect(responseErrors(value)).toEqual([]);
  });
  test("custom tools require the explicit compatibility profile", () => {
    const value = resource();
    value.tools = [{ type: "custom", name: "apply_patch", format: { type: "text" } }];
    value.output = [{ id: "ctc_fixture", call_id: "call_fixture", type: "custom_tool_call", status: "completed", name: "apply_patch", input: "*** Begin Patch\n*** End Patch" }];
    const stream = encode(framesForResponse(value));
    expect(streamErrors(stream).length).toBeGreaterThan(0);
    expect(streamErrors(stream, "codex-custom-tools")).toEqual([]);
    delete value.completed_at;
    expect(streamErrors(encode(framesForResponse(value)), "codex-custom-tools").length).toBeGreaterThan(0);
  });
  test("namespaced descriptors and custom choices stay in compatibility profile", () => {
    const value = resource();
    value.tools = [{ type: "namespace", name: "functions", tools: [{ type: "custom", name: "apply_patch" },
      { type: "function", name: "exec_command", description: null, parameters: null, strict: null }] }];
    value.tool_choice = { type: "custom", name: "functions.apply_patch" };
    expect(responseErrors(value).length).toBeGreaterThan(0);
    expect(responseErrors(value, "codex-custom-tools")).toEqual([]);
    value.tool_choice = { type: "allowed_tools", mode: "required", tools: [{ type: "custom", name: "functions.apply_patch" }] };
    expect(responseErrors(value, "codex-custom-tools")).toEqual([]);
    const requestTools = structuredClone(value.tools);
    delete requestTools[0].tools[1].strict; // Request strict is optional boolean; output strict is required nullable.
    const request = { model: "fixture", input: [
      { type: "custom_tool_call", call_id: "call_fixture", name: "apply_patch", input: "patch" },
      { type: "custom_tool_call_output", call_id: "call_fixture", output: "applied" },
    ], tools: requestTools, tool_choice: value.tool_choice };
    expect(schemaErrors(request, "CreateResponseBody").length).toBeGreaterThan(0);
    expect(schemaErrors(request, "CreateResponseBody", "codex-custom-tools")).toEqual([]);
    delete value.tools[0].tools[1].strict;
    expect(responseErrors(value, "codex-custom-tools").length).toBeGreaterThan(0);
  });
  test("SSE terminal sentinel is required and final", () => {
    const value = encode(framesForResponse(resource()));
    expect(streamErrors(value.replace("data: [DONE]\n\n", "")).length).toBeGreaterThan(0);
    expect(streamErrors(value + "data: [DONE]\n\n").length).toBeGreaterThan(0);
    expect(streamErrors(value + 'event: x\ndata: {"type":"x"}\n\n').length).toBeGreaterThan(0);
  });
  test("SSE event mismatch, invalid sequence, and postterminal events fail", () => {
    const events = framesForResponse(resource());
    const text = encode(events);
    expect(streamErrors(text.replace("event: response.created", "event: response.in_progress")).length).toBeGreaterThan(0);
    events[2].sequence_number = events[1].sequence_number;
    expect(streamErrors(encode(events)).length).toBeGreaterThan(0);
    const after = framesForResponse(resource());
    after.push({ type: "response.in_progress", response: after[1].response, sequence_number: after.length });
    expect(streamErrors(encode(after)).length).toBeGreaterThan(0);
  });
  test("content completion cannot precede text completion", () => {
    const events = framesForResponse(resource());
    const done = events.findIndex(event => event.type === "response.output_text.done");
    events.splice(done, 1);
    expect(streamErrors(encode(events)).some(error => error.includes("matching output_text.done"))).toBe(true);
  });
  test("delta text and terminal output must agree", () => {
    const events = framesForResponse(resource());
    events.find(event => event.type === "response.output_text.delta")!.delta = "different";
    expect(streamErrors(encode(events)).some(error => error.includes("accumulated deltas"))).toBe(true);
    const terminal = framesForResponse(resource());
    terminal[terminal.length - 1].response = structuredClone(terminal[terminal.length - 1].response);
    terminal[terminal.length - 1].response.output[0].content[0].text = "different";
    expect(streamErrors(encode(terminal)).some(error => error.includes("output_item.done"))).toBe(true);
  });
  test("tool arguments cannot mutate after done", () => {
    const value = resource(); value.output = [{ id: "fc_fixture", call_id: "call_fixture", type: "function_call", status: "completed", name: "fixture_tool", arguments: "{}" }];
    const events = framesForResponse(value);
    const index = events.findIndex(event => event.type === "response.output_item.done");
    events.splice(index, 0, { type: "response.function_call_arguments.delta", item_id: "fc_fixture", output_index: 0, delta: " " });
    events.forEach((event, sequence_number) => { event.sequence_number = sequence_number; });
    expect(streamErrors(encode(events)).some(error => error.includes("updated after done"))).toBe(true);
  });
  test("streaming failure has a structured error and failed terminal", () => {
    const value = resource(); value.status = "failed"; value.completed_at = null; value.output = []; value.error = { code: "fixture_failure", message: "Fixture failed" };
    const pending = { ...value, status: "in_progress", error: null };
    const events = [
      { type: "response.created", response: pending, sequence_number: 0 },
      { type: "response.in_progress", response: pending, sequence_number: 1 },
      { type: "error", error: { type: "model_error", code: "fixture_failure", message: "Fixture failed", param: null }, sequence_number: 2 },
      { type: "response.failed", response: value, sequence_number: 3 },
    ];
    expect(streamErrors(encode(events), "standard", "failed")).toEqual([]);
    events.pop();
    expect(streamErrors(encode(events)).length).toBeGreaterThan(0);
  });
  test("multiline data and CRLF parse as SSE", () => {
    const event = { type: "response.created", sequence_number: 0 };
    const text = `event: response.created\r\ndata: ${JSON.stringify(event)}\r\n\r\ndata: [DONE]\r\n\r\n`;
    expect(parseFrames(text).errors).toEqual([]);
    expect(parseFrames(text).frames[0].data).toEqual(event);
  });
});
