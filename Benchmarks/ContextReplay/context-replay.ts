import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

const UPSTREAM = "http://127.0.0.1:1234";
const BODY_LIMIT = 1024 * 1024, RESPONSE_LIMIT = 8 * 1024 * 1024, TIMEOUT_MS = 120_000;
type Json = Record<string, any>;
const bytes = (text: string) => Buffer.byteLength(text, "utf8");
function requireThat(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); }
export function requestBody(raw: string): Json {
  requireThat(bytes(raw) <= BODY_LIMIT, "Request exceeds 1 MiB");
  const body = JSON.parse(raw);
  requireThat(body && typeof body === "object" && !Array.isArray(body), "Expected request object");
  requireThat(typeof body.model === "string" && body.model.length > 0, "Missing model");
  requireThat(Array.isArray(body.input), "Replay requires explicit input history");
  requireThat(!body.previous_response_id && !body.conversation, "Replay requires unchained history");
  requireThat(!body.background, "Background inference is not supported");
  requireThat(body.tools === undefined || (Array.isArray(body.tools) && body.tools.every((t: Json) =>
    t?.type === "function" && typeof t.name === "string")), "Only inert custom-function tools are allowed");
  return body;
}

export function prepareReplay(raw: string, temperature?: number, assistantRaw?: string) {
  const body = requestBody(raw);
  requireThat(temperature === undefined || temperature === 0, "Only explicit temperature 0 is supported");
  if (assistantRaw !== undefined) {
    requireThat(bytes(assistantRaw) <= 2048, "Assistant history exceeds 2048 bytes");
    const item = JSON.parse(assistantRaw);
    requireThat(item?.type === "message" && item.role === "assistant", "Expected original assistant message");
    requireThat(Object.keys(item).every(k => ["type", "role", "id", "content", "phase"].includes(k)), "Unexpected assistant fields");
    requireThat(Array.isArray(item.content) && item.content.length > 0 && item.content.every((c: Json) =>
      c?.type === "output_text" && typeof c.text === "string" && Object.keys(c).every(k => ["type", "text"].includes(k))),
      "Assistant history must contain output text only");
    const index = body.input.findLastIndex((i: Json) => i?.type === "message" && i.role === "user");
    requireThat(index >= 0, "No latest user request to precede");
    body.input.splice(index, 0, item);
  }
  if (temperature !== undefined) body.temperature = temperature;
  const result = temperature === undefined && assistantRaw === undefined ? raw : JSON.stringify(body);
  requireThat(bytes(result) <= BODY_LIMIT, "Modified request exceeds 1 MiB");
  return { raw: result, changedSampler: temperature !== undefined, insertedAssistantHistory: assistantRaw !== undefined };
}

export function summarize(raw: string, contentType: string, elapsedMs: number, status: number): Json {
  let response: Json;
  if (contentType.includes("text/event-stream")) {
    const events: Json[] = [];
    for (const block of raw.split(/\r?\n\r?\n/)) {
      const data = block.split(/\r?\n/).filter(l => l.startsWith("data:"))
        .map(l => l.slice(5).replace(/^ /, "")).join("\n");
      if (data && data !== "[DONE]") events.push(JSON.parse(data));
    }
    requireThat(!events.some(e => e.type === "error" || e.type === "response.failed" || e.type === "response.incomplete"), "SSE reports failure/incomplete");
    const completed = events.filter(e => e.type === "response.completed");
    requireThat(completed.length === 1, "Expected exactly one completed SSE response");
    response = completed[0].response;
  } else response = JSON.parse(raw);
  requireThat(status >= 200 && status < 300, `HTTP ${status}`);
  requireThat(response && !response.error && response.status === "completed", "Response did not complete successfully");
  const output = response.output ?? [];
  requireThat(Array.isArray(output), "Invalid response output");
  return { responseID: response.id ?? null, status: response.status, elapsedMs,
    finalText: output.filter((i: Json) => i.type === "message" && i.role === "assistant")
      .flatMap((i: Json) => i.content ?? []).filter((c: Json) => c.type === "output_text").map((c: Json) => c.text).join(""),
    toolCallNames: output.filter((i: Json) => i.type === "function_call").map((i: Json) => i.name),
    inputTokens: response.usage?.input_tokens ?? null, outputTokens: response.usage?.output_tokens ?? null,
    cachedTokens: response.usage?.input_tokens_details?.cached_tokens ?? null };
}

async function save(path: string, value: string) { await writeFile(path, value, { flag: "wx", mode: 0o600 }); }
async function boundedFile(path: string, limit: number) {
  requireThat(isAbsolute(path), "File paths must be absolute");
  requireThat((await stat(path)).size <= limit, "Input file too large");
  return readFile(path, "utf8");
}
async function outputDirectory(path: string) {
  requireThat(isAbsolute(path), "Output directory must be absolute");
  await mkdir(path, { recursive: true, mode: 0o700 });
}
async function readBounded(response: Response): Promise<Uint8Array[]> {
  requireThat(response.body, "Missing response stream");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.byteLength;
      requireThat(length <= RESPONSE_LIMIT, "Response exceeds 8 MiB");
      chunks.push(value);
    }
  } catch (error) { await reader.cancel().catch(() => {}); throw error; }
  return chunks;
}
function decoded(chunks: Uint8Array[]) { return Buffer.concat(chunks).toString("utf8"); }
async function recordResponse(out: string, prefix: string, raw: string, type: string, elapsed: number, status: number, variant: Json = {}, transportFailure?: unknown) {
  await save(join(out, `${prefix}.response.${type.includes("event-stream") ? "sse" : "json"}`), raw);
  let result: Json;
  try {
    if (transportFailure) throw transportFailure;
    result = { ...summarize(raw, type, elapsed, status), ...variant };
  }
  catch (error) { result = { error: String(error), status, elapsedMs: elapsed, ...variant }; }
  await save(join(out, `${prefix}.summary.json`), JSON.stringify(result, null, 2));
  return result;
}

// Exported only for isolated tests; the CLI never accepts an arbitrary upstream.
export async function startCapture(out: string, port: number, upstream = UPSTREAM) {
  await outputDirectory(out);
  let count = 0;
  return Bun.serve({ hostname: "127.0.0.1", port, maxRequestBodySize: BODY_LIMIT, idleTimeout: 0,
    async fetch(incoming) {
      const path = new URL(incoming.url).pathname;
      if (incoming.method === "GET" && ["/v1/models", "/api/v1/models"].includes(path)) {
        try { return await fetch(upstream + path, { signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" }); }
        catch { return new Response("Upstream unavailable", { status: 502 }); }
      }
      if (incoming.method !== "POST" || path !== "/v1/responses") return new Response("Unsupported route", { status: 404 });
      if (count >= 30) return new Response("Capture limit reached", { status: 429 });
      const prefix = `${String(++count).padStart(3, "0")}-${crypto.randomUUID()}`;
      const started = performance.now(), abort = new AbortController();
      const timer = setTimeout(() => abort.abort(), TIMEOUT_MS);
      try {
        const raw = await incoming.text();
        requestBody(raw);
        await save(join(out, `${prefix}.request.json`), raw);
        const headers = new Headers({ "content-type": "application/json" });
        // Credentials, if supplied, go only to fixed loopback; no headers are recorded.
        if (incoming.headers.has("authorization")) headers.set("authorization", incoming.headers.get("authorization")!);
        const result = await fetch(upstream + path, { method: "POST", headers, body: raw, signal: abort.signal, redirect: "error" });
        requireThat(result.body, "Missing upstream stream");
        const reader = result.body.getReader(), chunks: Uint8Array[] = [];
        const type = result.headers.get("content-type") ?? "application/json";
        let length = 0, cancelled = false;
        const stream = new ReadableStream<Uint8Array>({
          async start(controller) {
            let failure: unknown;
            try {
              while (true) {
                const { value, done } = await reader.read();
                if (done) break;
                length += value.byteLength;
                requireThat(length <= RESPONSE_LIMIT, "Response exceeds 8 MiB");
                chunks.push(value); controller.enqueue(value);
              }
            } catch (error) { failure = error; abort.abort(); }
            finally { clearTimeout(timer); }
            try {
              // Responses clients may cancel immediately after response.completed.
              // That is successful only if the captured terminal payload validates.
              const summary = await recordResponse(out, prefix, decoded(chunks), type, performance.now() - started,
                result.status, {}, cancelled ? undefined : failure);
              if (!cancelled) {
                if (failure && summary.error) controller.error(failure);
                else controller.close();
              }
            } catch (error) {
              await save(join(out, `${prefix}.error.json`), JSON.stringify({ error: String(error) })).catch(() => {});
              if (!cancelled) controller.error(error);
            }
          }, cancel() { cancelled = true; abort.abort(); return reader.cancel(); }
        });
        return new Response(stream, { status: result.status, headers: { "content-type": type, "cache-control": "no-store" } });
      } catch (error) {
        clearTimeout(timer); abort.abort();
        await save(join(out, `${prefix}.error.json`), JSON.stringify({ error: String(error) })).catch(() => {});
        return new Response("Capture failed; inspect local error artifact", { status: 502 });
      }
    }
  });
}

export function parseArgs(args: string[]) {
  const mode = args.shift();
  requireThat(mode === "capture" || mode === "replay", "Use capture or replay");
  const values: Record<string, string> = {};
  const allowed = mode === "capture" ? ["--out", "--port"] : ["--out", "--request", "--count", "--temperature", "--assistant-history"];
  while (args.length) {
    const key = args.shift()!, value = args.shift();
    requireThat(allowed.includes(key) && !(key in values) && value !== undefined && !value.startsWith("--"), "Invalid/duplicate argument");
    values[key] = value;
  }
  requireThat(values["--out"] && isAbsolute(values["--out"]), "--out requires absolute directory");
  if (mode === "capture") requireThat(/^\d+$/.test(values["--port"] ?? "") && Number(values["--port"]) <= 65535, "--port requires 0–65535");
  else {
    requireThat(values["--request"] && isAbsolute(values["--request"]), "--request requires absolute file");
    requireThat(/^(?:[1-9]|10)$/.test(values["--count"] ?? "1"), "--count requires 1–10");
    requireThat(values["--temperature"] === undefined || values["--temperature"] === "0", "Only --temperature 0 is supported");
  }
  return { mode, values };
}

if (import.meta.main) {
  try {
    const { mode, values: v } = parseArgs(process.argv.slice(2));
    if (mode === "capture") {
      const server = await startCapture(v["--out"], Number(v["--port"]));
      console.log(JSON.stringify({ ready: true, host: "127.0.0.1", port: server.port }));
    } else {
      const raw = await boundedFile(v["--request"], BODY_LIMIT);
      const assistant = v["--assistant-history"] ? await boundedFile(v["--assistant-history"], 2048) : undefined;
      const prepared = prepareReplay(raw, v["--temperature"] === "0" ? 0 : undefined, assistant);
      await outputDirectory(v["--out"]);
      for (let i = 1; i <= Number(v["--count"] ?? 1); i++) {
        const prefix = `${String(i).padStart(3, "0")}-${crypto.randomUUID()}`, started = performance.now();
        await save(join(v["--out"], `${prefix}.request.json`), prepared.raw);
        const result = await fetch(UPSTREAM + "/v1/responses", { method: "POST", headers: { "content-type": "application/json" },
          body: prepared.raw, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" });
        const response = await recordResponse(v["--out"], prefix, decoded(await readBounded(result)), result.headers.get("content-type") ?? "application/json",
          performance.now() - started, result.status, { changedSampler: prepared.changedSampler, insertedAssistantHistory: prepared.insertedAssistantHistory });
        console.log(JSON.stringify(response));
        requireThat(!response.error, "Replay failed; inspect saved artifacts");
      }
    }
  } catch (error) { console.error(JSON.stringify({ error: String(error) })); process.exitCode = 1; }
}
