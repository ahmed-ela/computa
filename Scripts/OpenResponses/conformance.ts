import { createHash, randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import { runAllTests, testTemplates, type TestConfig } from "./vendor/src/lib/compliance-tests";

type JSON = Record<string, any>;
export type Profile = "standard" | "codex-custom-tools" | "codex-local-usage";
const root = dirname(import.meta.path);
const upstream = JSON.parse(await readFile(resolve(root, "vendor/public/openapi/openapi.json"), "utf8"));
const streamSchema = upstream.paths["/responses"].post.responses["200"].content["text/event-stream"].schema;
const compiled = new Map<string, ReturnType<Ajv2020["compile"]>>();

// This explicit adapter is for the owned Codex engine, not the Open Responses
// standard. It adds known custom-tool shapes without weakening core schemas.
function schemasFor(profile: Profile) {
  const schemas = structuredClone(upstream.components.schemas);
  if (profile === "codex-local-usage") {
    // The pinned owned Codex parser accepts genuine counts without the full
    // standard usage breakdown. This exception applies only to that route.
    schemas.Usage.required = ["input_tokens", "output_tokens", "total_tokens"];
    for (const key of schemas.Usage.required) schemas.Usage.properties[key].minimum = 0;
  }
  if (profile === "codex-custom-tools") {
    schemas.ComputaCodexCustomCall = {
      type: "object", required: ["type", "id", "call_id", "name", "input", "status"],
      properties: {
        type: { const: "custom_tool_call" }, id: { type: "string" }, call_id: { type: "string" },
        name: { type: "string" }, input: { type: "string" },
        status: { enum: ["in_progress", "completed", "incomplete"] }, namespace: { type: "string" },
      },
    };
    schemas.ComputaCodexCustomTool = {
      type: "object", required: ["type", "name"],
      properties: {
        type: { const: "custom" }, name: { type: "string" },
        description: { type: ["string", "null"] }, format: { type: ["object", "null"] },
      },
    };
    schemas.ComputaCodexCustomChoice = {
      type: "object", required: ["type", "name"],
      properties: { type: { const: "custom" }, name: { type: "string" } },
    };
    schemas.ComputaCodexCustomCallParam = {
      type: "object", required: ["type", "call_id", "name", "input"],
      properties: {
        type: { const: "custom_tool_call" }, id: { type: ["string", "null"] }, call_id: { type: "string" },
        name: { type: "string" }, input: { type: "string" }, namespace: { type: "string" },
        status: { enum: ["in_progress", "completed", "incomplete", null] },
      },
    };
    schemas.ComputaCodexCustomOutputParam = {
      type: "object", required: ["type", "call_id", "output"],
      properties: {
        type: { const: "custom_tool_call_output" }, id: { type: ["string", "null"] },
        call_id: { type: "string" }, output: { type: "string" },
        status: { enum: ["in_progress", "completed", "incomplete", null] },
      },
    };
    schemas.ComputaCodexNamespaceTool = {
      type: "object", required: ["type", "name", "tools"],
      properties: {
        type: { const: "namespace" }, name: { type: "string" }, description: { type: ["string", "null"] },
        tools: { type: "array", items: { $ref: "#/components/schemas/Tool" } },
      },
    };
    schemas.ComputaCodexNamespaceParam = structuredClone(schemas.ComputaCodexNamespaceTool);
    schemas.ComputaCodexNamespaceParam.properties.tools.items = { $ref: "#/components/schemas/ResponsesToolParam" };
    schemas.ItemField.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomCall" });
    schemas.ItemParam.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomCallParam" }, { $ref: "#/components/schemas/ComputaCodexCustomOutputParam" });
    schemas.Tool.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomTool" });
    schemas.Tool.oneOf.push({ $ref: "#/components/schemas/ComputaCodexNamespaceTool" });
    schemas.ResponsesToolParam.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomTool" }, { $ref: "#/components/schemas/ComputaCodexNamespaceParam" });
    schemas.ResponseResource.properties.tool_choice.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomChoice" });
    schemas.SpecificToolChoiceParam.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomChoice" });
    schemas.AllowedToolChoice.properties.tools.items.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomChoice" });
    for (const kind of ["delta", "done"]) {
      const field = kind === "delta" ? "delta" : "input";
      schemas[`ComputaCodexCustomInput${kind}`] = {
        type: "object", required: ["type", "sequence_number", "item_id", "output_index", field],
        properties: {
          type: { const: `response.custom_tool_call_input.${kind}` }, sequence_number: { type: "integer" },
          item_id: { type: "string" }, output_index: { type: "integer" }, [field]: { type: "string" },
        },
      };
    }
  }
  return schemas;
}

export function schemaErrors(value: unknown, name: string, profile: Profile = "standard"): string[] {
  const key = `${profile}:${name}`;
  let validate = compiled.get(key);
  if (!validate) {
    let schema: JSON = name === "StreamingEvent" ? structuredClone(streamSchema) : { $ref: `#/components/schemas/${name}` };
    if (name === "StreamingEvent" && profile === "codex-custom-tools") {
      schema.oneOf.push({ $ref: "#/components/schemas/ComputaCodexCustomInputdelta" }, { $ref: "#/components/schemas/ComputaCodexCustomInputdone" });
    }
    const ajv = new Ajv2020({ strict: false, allErrors: true, validateFormats: false });
    validate = ajv.compile({ ...schema, components: { schemas: schemasFor(profile) } });
    compiled.set(key, validate);
  }
  if (validate(value)) return [];
  return (validate.errors ?? []).map(error => `${name}${error.instancePath || "/"}: ${error.message}`);
}

function equal(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ak = Object.keys(a), bk = Object.keys(b);
  return ak.length === bk.length && ak.every(key => Object.hasOwn(b, key) && equal((a as JSON)[key], (b as JSON)[key]));
}

export function responseErrors(response: JSON, profile: Profile = "standard"): string[] {
  const errors = schemaErrors(response, "ResponseResource", profile);
  if (profile === "codex-local-usage" && response.usage !== null && response.usage !== undefined) {
    const usage = response.usage;
    if (usage.total_tokens !== usage.input_tokens + usage.output_tokens) errors.push("Codex local usage total does not equal input plus output counts");
  }
  if (!["queued", "in_progress", "completed", "failed", "incomplete"].includes(response.status)) errors.push("Unknown response lifecycle status");
  if (response.status === "completed" && (response.error !== null || response.incomplete_details !== null)) errors.push("Completed response contains failure details");
  if (response.status === "failed" && response.error === null) errors.push("Failed response has no error");
  if (response.status === "incomplete" && response.incomplete_details === null) errors.push("Incomplete response has no incomplete_details");
  if (response.status === "completed" && !Number.isInteger(response.completed_at)) errors.push("Completed response has no completion timestamp");
  if (Array.isArray(response.output)) {
    const ids = new Set<string>(), calls = new Set<string>();
    for (const [index, item] of response.output.entries()) {
      if (ids.has(item.id)) errors.push(`Duplicate output item ID at index ${index}`);
      ids.add(item.id);
      if (item.call_id) {
        if (calls.has(item.call_id)) errors.push(`Duplicate tool call ID at index ${index}`);
        calls.add(item.call_id);
      }
      if (response.status === "completed" && (item.status !== undefined || ["message", "function_call", "function_call_output", "custom_tool_call"].includes(item.type)) && item.status !== "completed") errors.push(`Completed response has unclosed item ${index}`);
      if (item.status === "incomplete" && (response.status !== "incomplete" || index !== response.output.length - 1)) errors.push("Incomplete item is not the final item of an incomplete response");
    }
  }
  return errors;
}

type ParsedFrame = { name: string; data: JSON };
export function parseFrames(text: string): { frames: ParsedFrame[]; errors: string[] } {
  const errors: string[] = [], frames: ParsedFrame[] = [];
  const normalized = text.replaceAll("\r\n", "\n");
  if (!normalized.endsWith("\n\n")) errors.push("SSE stream ends with an unterminated frame");
  let done = false, doneCount = 0;
  for (const block of normalized.split("\n\n")) {
    const names: string[] = [], data: string[] = [];
    for (const line of block.split("\n")) {
      if (line.startsWith("event:")) names.push(line.slice(6).trim());
      if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
    }
    if (!data.length) continue;
    if (done) errors.push("SSE data follows the terminal [DONE] sentinel");
    const payload = data.join("\n");
    if (payload === "[DONE]") { done = true; doneCount++; continue; }
    try {
      const value = JSON.parse(payload);
      if (!value || typeof value !== "object" || Array.isArray(value)) { errors.push("SSE payload is not a JSON object"); continue; }
      if (names.length !== 1 || names[0] !== value.type) errors.push("SSE event field does not match body type");
      frames.push({ name: names[0], data: value });
    } catch { errors.push("SSE data is invalid JSON"); }
  }
  if (doneCount !== 1) errors.push("SSE stream must contain exactly one terminal [DONE] sentinel");
  return { frames, errors };
}

type PartState = { initial: JSON; delta: string; textDone?: string; done?: JSON };
type ItemState = { initial: JSON; done?: JSON; argumentDelta: string; argumentDone?: string; parts: Map<number, PartState>; summaries: Map<number, PartState> };
export function streamErrors(text: string, profile: Profile = "standard", expectStatus?: string): string[] {
  const parsed = parseFrames(text), errors = [...parsed.errors];
  const items = new Map<number, ItemState>();
  let sequence = -1, terminal: JSON | undefined, sawError = false, responseID: string | undefined;
  if (parsed.frames[0]?.name !== "response.created") errors.push("First response event must be response.created");
  for (const [eventIndex, frame] of parsed.frames.entries()) {
    const e = frame.data;
    errors.push(...schemaErrors(e, "StreamingEvent", profile).map(error => `Event ${eventIndex}: ${error}`));
    if (!Number.isInteger(e.sequence_number) || e.sequence_number < 0 || e.sequence_number <= sequence) errors.push(`Event ${eventIndex}: sequence_number is not monotonically increasing`);
    sequence = e.sequence_number;
    if (terminal) errors.push(`Event ${eventIndex}: event after terminal response`);
    if (e.response) {
      errors.push(...responseErrors(e.response, profile).map(error => `Event ${eventIndex}: ${error}`));
      if (responseID && responseID !== e.response.id) errors.push("Response ID changes within stream");
      responseID = e.response.id;
      if (e.type === "response.created" && (eventIndex !== 0 || !["queued", "in_progress"].includes(e.response.status))) errors.push("response.created has an invalid lifecycle position/status");
      const state = e.type.slice("response.".length);
      if (["in_progress", "completed", "failed", "incomplete", "queued"].includes(state) && e.response.status !== state) errors.push("Response event type disagrees with response.status");
      if (["response.completed", "response.failed", "response.incomplete"].includes(e.type)) terminal = e.response;
    }
    if (e.type === "error") sawError = true;
    if (e.type === "response.output_item.added") {
      if (items.has(e.output_index)) errors.push("Output item index added twice");
      if (e.item.status !== "in_progress") errors.push("Added output item is not in_progress");
      if ([...items.values()].some(item => item.initial.id === e.item.id)) errors.push("Output item ID added twice");
      items.set(e.output_index, { initial: e.item, argumentDelta: "", parts: new Map(), summaries: new Map() });
      continue;
    }
    if (e.output_index === undefined) continue;
    const item = items.get(e.output_index);
    if (!item) { errors.push(`Event ${eventIndex}: output item used before added`); continue; }
    if (item.done) errors.push(`Event ${eventIndex}: completed output item was updated`);
    if (e.item_id !== undefined && e.item_id !== item.initial.id) errors.push("Item event references a different ID");
    if (e.type === "response.output_item.done") {
      if (e.item.id !== item.initial.id || e.item.type !== item.initial.type) errors.push("Output item identity changes at done");
      for (const key of ["role", "name", "call_id", "namespace", "phase"]) if (!equal(e.item[key], item.initial[key])) errors.push(`Output item ${key} changes within stream`);
      if (!["completed", "incomplete"].includes(e.item.status)) errors.push("Output item done has a nonterminal status");
      if (item.initial.type === "message") {
        for (const [index, part] of item.parts) {
          if (!part.done) errors.push("Output item closed before its content part");
          if (!equal(e.item.content?.[index], part.done)) errors.push("Output item content differs from completed content part");
        }
        if (item.parts.size !== e.item.content?.length) errors.push("Output item contains content with no part lifecycle");
      } else if (item.initial.type === "reasoning") {
        for (const [index, part] of item.summaries) {
          if (!part.done) errors.push("Reasoning item closed before its summary part");
          if (!equal(e.item.summary?.[index], part.done)) errors.push("Reasoning item summary differs from completed summary part");
        }
        if (item.summaries.size !== e.item.summary?.length) errors.push("Reasoning item contains summary with no part lifecycle");
      } else if (["function_call", "custom_tool_call"].includes(item.initial.type)) {
        const field = item.initial.type === "function_call" ? "arguments" : "input";
        if (item.argumentDone === undefined || item.argumentDone !== e.item[field]) errors.push("Tool item closed before matching arguments/input done");
      }
      item.done = e.item;
      continue;
    }
    if (/^response\.(function_call_arguments|custom_tool_call_input)\.(delta|done)$/.test(e.type)) {
      if (!["function_call", "custom_tool_call"].includes(item.initial.type)) errors.push("Tool arguments attached to a non-tool item");
      const expected = item.initial.type === "custom_tool_call" ? "custom_tool_call_input" : "function_call_arguments";
      if (!e.type.startsWith(`response.${expected}.`)) errors.push("Arguments event belongs to a different item type");
      if (item.argumentDone !== undefined) errors.push("Tool arguments/input updated after done");
      if (e.type.endsWith(".delta")) item.argumentDelta += e.delta;
      else {
        const value = e[expected === "function_call_arguments" ? "arguments" : "input"];
        if (value !== item.argumentDelta) errors.push("Tool arguments/input done differs from accumulated deltas");
        item.argumentDone = value;
      }
      continue;
    }
    if (e.type === "response.content_part.added") {
      if (item.initial.type !== "message") errors.push("Content part attached to a non-message item");
      if (item.parts.has(e.content_index)) errors.push("Content part index added twice");
      item.parts.set(e.content_index, { initial: e.part, delta: "" });
      continue;
    }
    if (e.type === "response.reasoning_summary_part.added") {
      if (item.initial.type !== "reasoning") errors.push("Summary part attached to a non-reasoning item");
      if (item.summaries.has(e.summary_index)) errors.push("Summary part index added twice");
      item.summaries.set(e.summary_index, { initial: e.part, delta: "" });
      continue;
    }
    if (e.summary_index !== undefined) {
      const part = item.summaries.get(e.summary_index);
      if (!part) { errors.push("Summary event used before reasoning_summary_part.added"); continue; }
      if (part.done) errors.push("Completed summary part was updated");
      if (e.type === "response.reasoning_summary_text.delta") {
        if (part.textDone !== undefined) errors.push("Summary delta after reasoning_summary_text.done");
        part.delta += e.delta;
      } else if (e.type === "response.reasoning_summary_text.done") {
        if (part.textDone !== undefined) errors.push("Summary text completed twice");
        if (e.text !== part.delta) errors.push("Reasoning summary done differs from accumulated deltas");
        part.textDone = e.text;
      } else if (e.type === "response.reasoning_summary_part.done") {
        if (part.initial.type !== e.part.type) errors.push("Summary part type changes at done");
        if (e.part.type === "summary_text" && (part.textDone === undefined || part.textDone !== e.part.text)) errors.push("Summary part closed before matching reasoning_summary_text.done");
        part.done = e.part;
      }
      continue;
    }
    if (e.content_index === undefined) continue;
    const part = item.parts.get(e.content_index);
    if (!part) { errors.push("Content event used before content_part.added"); continue; }
    if (part.done) errors.push("Completed content part was updated");
    if (e.type === "response.output_text.delta") {
      if (part.textDone !== undefined) errors.push("Text delta after output_text.done");
      part.delta += e.delta;
    } else if (e.type === "response.output_text.done") {
      if (part.textDone !== undefined) errors.push("Text completed twice");
      if (e.text !== part.delta) errors.push("Output text done differs from accumulated deltas");
      part.textDone = e.text;
    } else if (e.type === "response.content_part.done") {
      if (part.initial.type !== e.part.type) errors.push("Content part type changes at done");
      if (e.part.type === "output_text" && (part.textDone === undefined || part.textDone !== e.part.text)) errors.push("Content part closed before matching output_text.done");
      part.done = e.part;
    }
  }
  if (!terminal) errors.push("SSE stream has no terminal response");
  else {
    if (expectStatus && terminal.status !== expectStatus) errors.push("Terminal response has unexpected status");
    if (sawError && terminal.status !== "failed") errors.push("Streaming error is not followed by response.failed");
    if (terminal.status === "completed" || terminal.status === "incomplete") {
      if (items.size !== terminal.output?.length) errors.push("Terminal output count differs from stream items");
      for (const [index, item] of items) {
        if (!item.done) errors.push("Terminal response contains an unclosed output item");
        if (!equal(item.done, terminal.output?.[index])) errors.push("Terminal output differs from output_item.done");
      }
    }
  }
  return [...new Set(errors)];
}

export async function verifyUpstream(): Promise<void> {
  const manifest = JSON.parse(await readFile(resolve(root, "upstream-manifest.json"), "utf8"));
  for (const file of manifest.files) {
    const bytes = await readFile(resolve(root, "vendor", file.path));
    if (createHash("sha256").update(bytes).digest("hex") !== file.sha256) throw new Error(`Pinned upstream file changed: ${file.path}`);
  }
}

async function validateArtifacts(directory: string) {
  const absolute = resolve(directory);
  const manifest = JSON.parse(await readFile(resolve(absolute, "manifest.json"), "utf8"));
  const ajv = new Ajv2020({ strict: false, allErrors: true });
  const validate = ajv.compile(JSON.parse(await readFile(resolve(root, "artifact-manifest.schema.json"), "utf8")));
  if (!validate(manifest)) throw new Error(`Invalid artifact manifest: ${ajv.errorsText(validate.errors)}`);
  const names = new Set<string>(), files = new Set<string>();
  const results = [];
  for (const entry of manifest.cases) {
    const file = resolve(absolute, entry.file), rel = relative(absolute, file);
    if (isAbsolute(entry.file) || rel.startsWith("..")) throw new Error("Artifact path must remain within its directory");
    if (names.has(entry.name) || files.has(file)) throw new Error("Duplicate artifact case or file");
    names.add(entry.name); files.add(file);
    const text = await readFile(file, "utf8"), profile = entry.profile ?? "standard";
    let errors: string[];
    if (entry.kind === "sse") errors = streamErrors(text, profile, entry.expectStatus);
    else {
      const value = JSON.parse(text);
      if (entry.kind === "response") {
        errors = responseErrors(value, profile);
        if (entry.expectStatus && value.status !== entry.expectStatus) errors.push("Response has unexpected status");
      } else if (entry.kind === "error") errors = schemaErrors(value.error, "ErrorPayload", profile);
      else errors = schemaErrors(value, "CreateResponseBody", profile);
    }
    results.push({ name: entry.name, profile, kind: entry.kind, status: errors.length ? "failed" : "passed", errors });
  }
  console.log(JSON.stringify({ upstreamCommit: "21a5dbc23578eaf66040755e1b00a1e3476cabda", specificationVersion: "2026-04-24", results }, null, 2));
  if (results.some(result => result.status === "failed")) process.exitCode = 1;
}

const officialIDs = ["basic-response", "assistant-phase", "response-output-phase-schema", "streaming-response", "system-prompt", "tool-calling", "multi-turn"];
async function runOfficial(baseUrl: string, model: string) {
  const apiKey = process.env.COMPUTA_OPEN_RESPONSES_API_KEY;
  if (!apiKey) throw new Error("Set COMPUTA_OPEN_RESPONSES_API_KEY in the process environment");
  const url = new URL(baseUrl);
  if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) throw new Error("Official deterministic conformance target must be loopback");
  const config: TestConfig = { baseUrl, model, apiKey, authHeaderName: "Authorization", useBearerPrefix: true, runtime: "server" };
  const originalFetch = globalThis.fetch;
  const wireResults: { id: string; errors: string[] }[] = [];
  let activeID = "";
  globalThis.fetch = async (input, init) => {
    const headers = new Headers(init?.headers);
    headers.set("x-computa-task-id", randomUUID());
    const response = await originalFetch(input, { ...init, headers });
    const body = await response.clone().text();
    const contentType = response.headers.get("content-type") ?? "";
    let errors: string[] = [];
    if (!response.ok) errors.push(`HTTP status ${response.status}`);
    else if (contentType.startsWith("text/event-stream")) errors = streamErrors(body, "standard", "completed");
    else if (contentType.startsWith("application/json")) {
      try { errors = responseErrors(JSON.parse(body)); } catch { errors.push("Invalid response JSON"); }
    } else errors.push("Unexpected response Content-Type");
    wireResults.push({ id: activeID, errors });
    return response;
  };
  try {
    const results = [];
    for (const id of officialIDs) {
      activeID = id;
      const template = testTemplates.find(template => template.id === id);
      if (!template) throw new Error(`Pinned upstream template missing: ${id}`);
      const [result] = await runAllTests(config, () => {}, [template]);
      // Do not print request content, API credentials, or provider response text.
      results.push({ id, status: result.status, errors: result.errors ?? [], streamEvents: result.streamEvents });
    }
    console.log(JSON.stringify({ upstreamCommit: "21a5dbc23578eaf66040755e1b00a1e3476cabda", specificationVersion: "2026-04-24", results, rawWireValidation: wireResults,
      excludedOptionalCapabilities: ["image-input", "compaction", "websocket", "previous_response_id"],
      note: "The output-phase schema test is an upstream local schema fixture, not a server request." }, null, 2));
    if (results.some(result => result.status !== "passed") || wireResults.some(result => result.errors.length)) process.exitCode = 1;
  } finally { globalThis.fetch = originalFetch; }
}

export async function main(args: string[]) {
  await verifyUpstream();
  const value = (flag: string) => args.indexOf(flag) >= 0 ? args[args.indexOf(flag) + 1] : undefined;
  if (value("--artifacts")) return validateArtifacts(value("--artifacts")!);
  if (args.includes("--official") && value("--base-url") && value("--model")) return runOfficial(value("--base-url")!, value("--model")!);
  throw new Error("Usage: bun Scripts/open-responses-conformance.ts --artifacts <directory> OR --official --base-url <loopback/v1> --model <model>");
}

if (import.meta.main) await main(process.argv.slice(2));
