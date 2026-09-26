// Serial synthetic checks for typed overflow and exhausted-output behavior.
// Reuses a frozen production request; never invokes a real tool or the desktop.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { SSEDecoder, completed, exactText } from "./stream-contract";
import { inspectObservation, observationMode } from "./provider-observation";

const [directory, source, nonce] = Bun.argv.slice(2);
if (!directory || !source || !nonce || !isAbsolute(directory) || !isAbsolute(source)) throw new Error("Expected PRIVATE_OUTPUT BASE_REQUEST LAUNCH_UUID");
const info = lstatSync(directory);
if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o777) !== 0o700 || readdirSync(directory).length
    || resolve(directory).startsWith(resolve(import.meta.dir, "../..") + "/")) throw new Error("Fresh external private directory required");
const original = JSON.parse(readFileSync(source, "utf8"));
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
if (original.model !== model || !original.instructions?.startsWith("You are HeyDash.")
    || original.input?.length !== 2 || !JSON.stringify(original.input[0]).includes("StudyLock Permanent Non-Bypass Policy")) throw new Error("Frozen production request required");
const observer = observationMode("guarded:" + nonce);
const save = (name: string, value: unknown) => writeFileSync(join(directory, name), JSON.stringify(value, null, 2), { mode: 0o600 });
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const results: any[] = [];
async function ready() {
  const response = await fetch("http://127.0.0.1:1237/health", { signal: AbortSignal.timeout(3000), redirect: "error" });
  if (!response.ok || !inspectObservation(observer, await response.json(), model).idle) throw new Error("Owned boundary not idle");
}
async function run(label: string, prompt: string, options: any = {}) {
  await ready();
  const request = { ...original, input: [original.input[0], { role: "user", content: [{ type: "input_text", text: prompt }] }], tools: [], ...options };
  save(label + "-request.json", request);
  const started = performance.now();
  const response = await fetch("http://127.0.0.1:1237/v1/responses", { method: "POST", redirect: "error", signal: AbortSignal.timeout(90000),
    headers: { "content-type": "application/json" }, body: JSON.stringify(request) });
  if (response.status !== 200 || !response.headers.get("content-type")?.includes("text/event-stream")) throw new Error("Expected typed SSE response");
  const raw = await response.text();
  if (raw.length > 4 * 1024 * 1024) throw new Error("Stream bound exceeded");
  const parser = new SSEDecoder(), events = parser.push(raw); parser.finish();
  save(label + "-events.json", events);
  results.push({ label, elapsedMS: performance.now() - started, requestSHA256: hash(request), eventsSHA256: hash(events),
    types: events.map(event => event.type), usage: events.find(event => event.type === "response.completed" || event.type === "response.incomplete")?.response?.usage ?? null });
  return events;
}
let passed = false;
try {
  const overflow = await run("overflow", "Read this disposable synthetic input and reply READ. Do not use tools.\n" + "filler ".repeat(17000));
  if (overflow.length !== 1 || overflow[0].type !== "response.failed"
      || overflow[0].response?.error?.code !== "context_length_exceeded") throw new Error("Overflow was not mapped to the native compaction error");
  const exhausted = await run("exhausted", "Explain how rain forms, in one paragraph. Do not use tools.", { max_output_tokens: 1 });
  const terminal = exhausted.filter(event => ["response.completed", "response.failed", "response.incomplete"].includes(event.type));
  if (terminal.length !== 1 || terminal[0].type !== "response.incomplete"
      || terminal[0].response?.incomplete_details?.reason !== "max_output_tokens"
      || exhausted.some(event => event.type === "response.output_item.done" && event.item?.type === "function_call")) throw new Error("Exhausted output was not safely incomplete");
  const followup = await run("following", "Reply only HEYDASH_BOUNDARY_RECOVERED. Do not use tools.", { enable_thinking: false, max_output_tokens: 128 });
  exactText(followup, completed(followup, model), "HEYDASH_BOUNDARY_RECOVERED");
  await ready();
  passed = true;
} finally {
  save("summary.json", { passed, results, noToolsExecuted: true, appServerRecoveryProven: false,
    limitation: "Typed provider errors and following inference only; real App Server compaction requires a separate gate." });
  console.log(JSON.stringify({ passed, results: results.map(({ label, elapsedMS, usage }) => ({ label, elapsedMS, usage })) }));
}
