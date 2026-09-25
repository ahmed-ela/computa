// Synthetic wire-prefix replay, not a production runtime or desktop acceptance test.
// No emitted tool call is dispatched. Only a literal fixture query can receive
// one synthetic response; all other calls end that lane as unsupported.
import { readFileSync, writeFileSync, renameSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { isAbsolute, join } from "node:path";
import { groupAXSnapshotParents } from "./parent-blocks";

const [captureRoot, fixtureA, fixtureB, outputRoot] = Bun.argv.slice(2);
if (![captureRoot, fixtureA, fixtureB, outputRoot].every(p => p && isAbsolute(p))) {
  throw new Error("Supply absolute capture root, Order A fixture, Cedar fixture, and private output directory");
}
if ((statSync(outputRoot).mode & 0o077) !== 0) throw new Error("Output directory must be private");
const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const stable = (v: any): string => JSON.stringify(v, Object.keys(v ?? {}).sort());
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const policy = readFileSync("/Users/ahmedelamin/AGENTS.md", "utf8");

function readRequest(number: number) {
  const bytes = readFileSync(join(captureRoot, `connection-${String(number).padStart(2, "0")}.client-to-upstream.bin`));
  const end = bytes.indexOf("\r\n\r\n");
  if (end < 0) throw new Error("Missing HTTP header terminator");
  const header = bytes.subarray(0, end).toString("ascii");
  const lengths = [...header.matchAll(/^content-length:\s*(\d+)\s*$/gmi)];
  if (!header.startsWith("POST /v1/responses HTTP/1.1\r\n") || /transfer-encoding:/i.test(header)
      || lengths.length !== 1 || Number(lengths[0][1]) !== bytes.length - end - 4) {
    throw new Error("Expected exactly one complete content-length Responses request");
  }
  return JSON.parse(bytes.subarray(end + 4).toString("utf8"));
}

const cases = [
  { id: "order-a-first", fixture: JSON.parse(readFileSync(fixtureA, "utf8")), expected: "Arrives Tuesday", request: readRequest(3), arms: ["flat", "blocks"] },
  { id: "cedar-second", fixture: JSON.parse(readFileSync(fixtureB, "utf8")), expected: "Expected Thursday", request: readRequest(6), arms: ["blocks", "flat"] },
];
for (const c of cases) {
  const r = c.request, last = r.input?.at(-1), call = r.input?.at(-2);
  if (r.model !== model || r.tools?.length !== 13 || r.instructions !== cases[0].request.instructions
      || JSON.stringify(r.tools) !== JSON.stringify(cases[0].request.tools)
      || !r.input.some((i: any) => i.content?.some?.((t: any) => t.type === "input_text" && t.text.includes(policy)))
      || last?.type !== "function_call_output" || last.output !== c.fixture.initial
      || call?.name !== "computer_v2_snapshot" || call.call_id !== last.call_id
      || stable(JSON.parse(call.arguments)) !== "{}" || c.fixture.initial.includes(c.expected)
      || !c.fixture.targeted.includes(c.expected)) throw new Error("Wire/fixture preconditions failed");
  for (const stage of ["initial", "targeted"]) {
    const grouped = groupAXSnapshotParents(c.fixture[stage], stage === "initial" ? 3000 : 1000);
    if (grouped === c.fixture[stage]) throw new Error("Treatment must produce a validated representation change");
  }
}

async function requireIdle() {
  const child = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"], { stdout: "pipe", stderr: "pipe" });
  const list = JSON.parse(await new Response(child.stdout).text());
  if (await child.exited !== 0 || list.length !== 1 || list[0].identifier !== model
      || list[0].status !== "idle" || list[0].queued !== 0 || list[0].parallel !== 1) {
    throw new Error("Expected the sole idle serial 4B model; stop without changing its state");
  }
}

const rows: any[] = [];
let state = "running", stopReason: string | null = null;
function save() {
  const summary = { scope: "synthetic exact captured prefix; representation-only paired replay; no desktop", model,
    state, stopReason, plannedLanes: 4, attemptedLanes: rows.length,
    instructionSHA256: hash(cases[0].request.instructions), policySHA256: hash(policy),
    differencesFromProduction: ["stream=false", "max_output_tokens=2048", "temperature=0.1", "no App Server after captured prefix"],
    rows };
  const tmp = join(outputRoot, "summary.json.tmp");
  writeFileSync(tmp, JSON.stringify(summary, null, 2), { mode: 0o600 });
  renameSync(tmp, join(outputRoot, "summary.json"));
}

try {
  save();
  for (const c of cases) for (const arm of c.arms) {
    const request = structuredClone(c.request);
    // Same decoding/request bounds for both arms. No instructions or tools changed.
    request.stream = false;
    request.max_output_tokens = 2048;
    request.temperature = 0.1;
    if (arm === "blocks") request.input.at(-1).output = groupAXSnapshotParents(c.fixture.initial, 3000);
    const before = structuredClone(request);
    before.input.at(-1).output = c.fixture.initial;
    const control = { ...structuredClone(c.request), stream: false, max_output_tokens: 2048, temperature: 0.1 };
    if (JSON.stringify(before) !== JSON.stringify(control)) throw new Error("Non-observation treatment change");
    const row: any = { id: `${c.id}-${arm}`, arm, expected: c.expected, queryIssued: false,
      outcome: "pending", calls: [], requests: [], elapsed_ms: 0 };
    rows.push(row);
    save();
    const started = performance.now();
    for (let step = 0; step < 2; step++) {
      await requireIdle();
      const sent = performance.now();
      const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
        headers: { "content-type": "application/json" }, body: JSON.stringify(request), signal: AbortSignal.timeout(45000) });
      if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
      const result: any = await response.json();
      writeFileSync(join(outputRoot, `${row.id}-${step}.json`), JSON.stringify({ request, response: result }), { mode: 0o600 });
      row.requests.push({ elapsed_ms: performance.now() - sent, usage: result.usage, status: result.status });
      if (result.error || !Array.isArray(result.output) || result.model !== model) throw new Error("Invalid provider response");
      const calls = result.output.filter((i: any) => i.type === "function_call");
      const final = result.output.filter((i: any) => i.type === "message" && i.role === "assistant")
        .flatMap((i: any) => i.content ?? []).filter((i: any) => i.type === "output_text")
        .map((i: any) => i.text).join("").trim();
      row.calls.push(...calls.map((i: any) => ({ name: i.name, arguments: i.arguments })));
      if (result.status !== "completed") { row.outcome = "incomplete"; break; }
      if (calls.length === 0) {
        row.answer = final;
        // Nonexact includes correct content with extra wording; do not confuse
        // failure of the exact-output contract with a wrong factual answer.
        row.outcome = !final ? "no_final_answer" : final === c.expected && row.queryIssued ? "correct_after_query" : "nonexact_answer";
        break;
      }
      let args: any;
      try { args = JSON.parse(calls[0].arguments); } catch { args = null; }
      if (step !== 0 || calls.length !== 1 || calls[0].name !== "computer_v2_snapshot" || !args
          || Object.keys(args).length !== 1 || typeof args.query !== "string"
          || ![c.fixture.queryLiteral, c.fixture.shortQuery].filter(Boolean)
            .some((q: string) => args.query.trim().toLowerCase() === q.toLowerCase())) {
        row.outcome = "unsupported_call_no_dispatch";
        break;
      }
      row.queryIssued = true;
      request.input.push(...result.output, { type: "function_call_output", call_id: calls[0].call_id,
        output: arm === "blocks" ? groupAXSnapshotParents(c.fixture.targeted, 1000) : c.fixture.targeted });
    }
    row.elapsed_ms = performance.now() - started;
    if (row.outcome === "pending") row.outcome = "no_final_answer";
    save();
    console.log(JSON.stringify(row));
  }
  state = "completed";
} catch (error) {
  state = "stopped";
  stopReason = error instanceof Error ? error.message : String(error);
  if (rows.at(-1)?.outcome === "pending") rows.at(-1).outcome = "transport_or_provider_failure";
  throw error;
} finally { save(); }
