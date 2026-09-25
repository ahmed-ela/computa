// Private, single continuation replay. Substitutes only verified receipt bodies
// from the real Rust External projection. No summary sampling or tool dispatch.
import { readFileSync, writeFileSync, renameSync, statSync, readdirSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { createHash } from "node:crypto";

const MODEL = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const FILE_LIMIT = 16 * 1024 * 1024;
const RESPONSE_LIMIT = 8 * 1024 * 1024;
const hash = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");
type Json = Record<string, any>;
class Rejected extends Error {}
function need(condition: unknown, code: string): asserts condition { if (!condition) throw new Rejected(code); }
const object = (value: unknown): value is Json => !!value && typeof value === "object" && !Array.isArray(value);
const canonical = (value: any): string => JSON.stringify(value, (_key, child) => object(child)
  ? Object.fromEntries(Object.keys(child).sort().map(key => [key, child[key]])) : child);

function readJSON(path: string, code: string): { value: Json; bytes: Buffer } {
  let bytes: Buffer;
  try {
    const info = statSync(path);
    need(info.isFile() && info.size > 0 && info.size <= FILE_LIMIT, `${code}_size`);
    bytes = readFileSync(path);
  } catch (error) { if (error instanceof Rejected) throw error; throw new Rejected(`${code}_read`); }
  let value: unknown;
  try { value = JSON.parse(bytes.toString("utf8")); } catch { throw new Rejected(`${code}_json`); }
  need(object(value), `${code}_shape`);
  return { value, bytes };
}

function receiptSequence(items: any[], label: string): Json[] {
  need(Array.isArray(items) && items.length <= 1_000, `${label}_items`);
  const sequence: Json[] = [], pending = new Set<string>(), completed = new Set<string>();
  for (const item of items) {
    need(object(item) && typeof item.type === "string", `${label}_item_shape`);
    if (item.type !== "function_call" && item.type !== "function_call_output") {
      need(["message", "reasoning"].includes(item.type), `${label}_unsupported_item`);
      continue;
    }
    need(typeof item.call_id === "string" && item.call_id.length > 0, `${label}_call_id`);
    // Known optional serializer metadata may be absent in the saved baseline;
    // it is validated but NEVER copied over the baseline request's item fields.
    const keys = item.type === "function_call"
      ? ["type", "call_id", "name", "arguments", "id", "status", "namespace"]
      : ["type", "call_id", "output", "id"];
    need(Object.keys(item).every(key => keys.includes(key)), `${label}_unsupported_receipt_field`);
    need(item.id == null || typeof item.id === "string", `${label}_item_id`);
    if (item.type === "function_call") {
      need(item.namespace == null && (item.status == null || item.status === "completed"), `${label}_call_metadata`);
      need(typeof item.name === "string" && !!item.name && typeof item.arguments === "string", `${label}_function_identity`);
      need(!pending.has(item.call_id) && !completed.has(item.call_id), `${label}_duplicate_call`);
      pending.add(item.call_id);
    } else {
      need(pending.delete(item.call_id) && !completed.has(item.call_id), `${label}_unmatched_output`);
      completed.add(item.call_id);
      need(typeof item.output === "string" || Array.isArray(item.output), `${label}_output_shape`);
      if (Array.isArray(item.output)) {
        need(item.output.length <= 128 && item.output.every((part: any) => object(part)
          && (part.type === "input_text" && typeof part.text === "string"
            || part.type === "input_image" && typeof part.image_url === "string")), `${label}_output_content`);
      }
    }
    sequence.push(item);
  }
  need(pending.size === 0 && completed.size === 13 && sequence.length === 26, `${label}_requires_13_pairs`);
  return sequence;
}

function imageReceipts(items: Json[]): { callID: string | null; image: Json }[] {
  const result: { callID: string | null; image: Json }[] = [];
  for (const item of items) {
    const content = item.type === "function_call_output" ? item.output : item.content;
    if (!Array.isArray(content)) continue;
    for (const part of content) if (part?.type === "input_image") {
      result.push({ callID: item.type === "function_call_output" ? item.call_id : null, image: part });
    }
  }
  return result;
}

async function requireIdle() {
  const process = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"], { stdout: "pipe", stderr: "pipe" });
  const raw = await new Response(process.stdout).text();
  need(await process.exited === 0, "model_preflight_exit");
  let models: any;
  try { models = JSON.parse(raw); } catch { throw new Rejected("model_preflight_json"); }
  need(Array.isArray(models) && models.length === 1 && models[0].identifier === MODEL && models[0].status === "idle"
    && models[0].queued === 0 && models[0].parallel === 1, "model_not_exclusively_idle");
}

async function responseBytes(response: Response): Promise<Uint8Array> {
  need(response.body, "empty_response_body");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.length;
    if (length > RESPONSE_LIMIT) { await reader.cancel(); throw new Rejected("response_size_limit"); }
    chunks.push(value);
  }
  return Buffer.concat(chunks);
}

async function main() {
  const [baselinePath, exporterPath, root, ...extra] = Bun.argv.slice(2);
  need(!extra.length && [baselinePath, exporterPath, root].every(path => path && isAbsolute(path)), "requires_three_absolute_paths");
  let directory;
  try { directory = statSync(root); } catch { throw new Rejected("output_directory_missing"); }
  need(directory.isDirectory() && (directory.mode & 0o077) === 0 && readdirSync(root).length === 0, "requires_fresh_private_directory");
  const baseline = readJSON(baselinePath, "baseline"), exported = readJSON(exporterPath, "exporter");
  const request = baseline.value.request;
  need(object(request) && request.model === MODEL && request.stream === false && Array.isArray(request.tools)
    && request.tools.length === 13 && typeof request.instructions === "string" && !!request.instructions
    && Number.isInteger(request.max_output_tokens) && request.max_output_tokens > 0 && request.max_output_tokens <= 2048
    && !request.previous_response_id && !request.conversation && !request.background, "unsupported_baseline_request");
  const original = receiptSequence(request.input, "baseline");
  const replacement = receiptSequence(exported.value.items, "exporter");
  for (let index = 0; index < original.length; index++) {
    const before = original[index], after = replacement[index];
    need(before.type === after.type && before.call_id === after.call_id, "receipt_order_or_call_identity_changed");
    if (before.type === "function_call") need(before.name === after.name && before.arguments === after.arguments, "function_name_or_arguments_changed");
  }
  const baselineImages = imageReceipts(request.input), candidateImages = imageReceipts(exported.value.items);
  need(baselineImages.length === 1 && candidateImages.length === 1 && baselineImages[0].callID !== null
    && canonical(baselineImages) === canonical(candidateImages), "single_exact_image_receipt_required");

  const outputs = replacement.filter(item => item.type === "function_call_output");
  const outputByID = new Map(outputs.map(item => [item.call_id, item.output]));
  const candidate = structuredClone(request);
  const outputAudit: Json[] = [];
  for (const item of candidate.input) if (item.type === "function_call_output") {
    const output = outputByID.get(item.call_id);
    outputAudit.push({ callIDSHA256: hash(item.call_id), beforeSHA256: hash(JSON.stringify(item.output)),
      afterSHA256: hash(JSON.stringify(output)), beforeBytes: Buffer.byteLength(JSON.stringify(item.output)),
      afterBytes: Buffer.byteLength(JSON.stringify(output)), changed: canonical(item.output) !== canonical(output) });
    item.output = structuredClone(output);
  }
  // Restore the old bodies and demand byte-equal JSON serialization of ALL
  // remaining fields, including the original summary, policy and tool schemas.
  const restored = structuredClone(candidate);
  const baselineOutputs = new Map(original.filter(item => item.type === "function_call_output").map(item => [item.call_id, item.output]));
  for (const item of restored.input) if (item.type === "function_call_output") item.output = baselineOutputs.get(item.call_id);
  need(JSON.stringify(restored) === JSON.stringify(request), "non_output_request_fields_changed");
  const serialized = JSON.stringify(candidate);
  need(Buffer.byteLength(serialized) <= FILE_LIMIT, "candidate_request_size");
  const audit = { scope: "single saved-baseline continuation; Rust-exported receipt-body substitution only; no tool dispatch",
    baselineFileSHA256: hash(baseline.bytes), exporterFileSHA256: hash(exported.bytes),
    baselineRequestSHA256: hash(JSON.stringify(request)), candidateRequestSHA256: hash(serialized),
    instructionSHA256: hash(request.instructions), toolsSHA256: hash(JSON.stringify(request.tools)),
    untouchedMessagesSHA256: hash(JSON.stringify(request.input.filter((item: Json) => item.type === "message"))),
    functionCallsSHA256: hash(JSON.stringify(original.filter(item => item.type === "function_call"))),
    retainedImageSHA256: hash(canonical(baselineImages[0].image)),
    exactCallOutputPairs: 13, exactImageCount: 1, nonOutputFieldsExact: true,
    ignoredExporterNonReceiptItems: exported.value.items.length - replacement.length,
    changedOutputCount: outputAudit.filter(item => item.changed).length, outputAudit };
  if (process.env.HEYDASH_RETENTION_VERIFY_ONLY === "1") { console.log(JSON.stringify({ state: "verified_only", ...audit })); return; }
  need(audit.changedOutputCount > 0, "no_receipt_body_change_to_replay");

  let state = "running", failure: string | null = null, metrics: Json | null = null;
  const save = () => {
    const temporary = join(root, "summary.json.tmp");
    writeFileSync(temporary, JSON.stringify({ ...audit, state, failure, metrics }, null, 2), { mode: 0o600, flag: "wx" });
    renameSync(temporary, join(root, "summary.json"));
  };
  try {
    writeFileSync(join(root, "candidate-request.json"), serialized, { mode: 0o600, flag: "wx" });
    save();
    await requireIdle();
    const started = performance.now();
    const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
      headers: { "content-type": "application/json" }, body: serialized, signal: AbortSignal.timeout(60000) });
    const raw = await responseBytes(response);
    writeFileSync(join(root, "candidate-response.json"), raw, { mode: 0o600, flag: "wx" });
    metrics = { httpStatus: response.status, elapsed_ms: performance.now() - started, responseSHA256: hash(raw) };
    need(response.ok, "provider_http_failure");
    let result: any;
    try { result = JSON.parse(Buffer.from(raw).toString("utf8")); } catch { throw new Rejected("provider_response_json"); }
    need(object(result) && !result.error && result.model === MODEL && Array.isArray(result.output)
      && ["completed", "incomplete"].includes(result.status), "provider_response_shape");
    const text = result.output.filter((item: Json) => item.type === "message" && item.role === "assistant")
      .flatMap((item: Json) => item.content ?? []).filter((part: Json) => part.type === "output_text" && typeof part.text === "string")
      .map((part: Json) => part.text).join("").trim();
    const toolRequestCount = result.output.filter((item: Json) => item.type === "function_call").length;
    metrics = { ...metrics, status: result.status, usage: result.usage ?? null, toolRequestCount,
      finalTextBytes: Buffer.byteLength(text), finalTextSHA256: hash(text) };
    state = result.status !== "completed" ? "incomplete" : toolRequestCount ? "tool_requested_not_executed" : text ? "answered_requires_blinded_audit" : "no_final_answer";
  } catch (error) {
    state = "stopped";
    failure = error instanceof Rejected ? error.message : error instanceof Error && ["AbortError", "TimeoutError"].includes(error.name)
      ? "request_timeout" : "replay_io_or_transport_failure";
    process.exitCode = 1;
  } finally { save(); }
  console.log(JSON.stringify({ state, failure, metrics, changedOutputCount: audit.changedOutputCount,
    candidateRequestSHA256: audit.candidateRequestSHA256 }));
}

main().catch(error => {
  // Even malformed private JSON or filesystem errors must not echo data bodies.
  console.log(JSON.stringify({ state: "stopped", failure: error instanceof Rejected ? error.message : "validation_or_artifact_io_failure" }));
  process.exitCode = 1;
});
