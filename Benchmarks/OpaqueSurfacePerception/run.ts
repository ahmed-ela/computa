// Serial, read-only perception comparison. No computer driver or tool dispatch.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { formatOCR, type Source } from "./format";
import { assessResponse, parseOptions } from "./runner-support";

const [out, manifestPath, actualDir, rolloutPath, model, ...optionArgs] = Bun.argv.slice(2);
const { maxOutputTokens, caseID } = parseOptions(optionArgs);
if (Bun.argv.length < 7 || ![out, manifestPath, actualDir, rolloutPath].every(p => p && isAbsolute(p))
    || !["lmstudio-community/Qwen3.5-9B-MLX-4bit", "lmstudio-community/Qwen3.5-4B-MLX-4bit"].includes(model)) {
  throw new Error("Usage: run.ts FRESH_PRIVATE_OUTPUT MANIFEST ACTUAL_CAPTURE_DIR ROLLOUT MODEL_ID [--max-output-tokens=4096] [--case=CASE_ID]");
}
const directory = lstatSync(out);
if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o777) !== 0o700
    || readdirSync(out).length || resolve(out).startsWith(resolve(import.meta.dir, "../..") + "/")) {
  throw new Error("Use a fresh external mode-0700 output directory");
}
const hash = (v: string | Uint8Array) => createHash("sha256").update(v).digest("hex");
const read = (p: string, maximum = 16 * 1024 * 1024): Buffer => {
  const s = lstatSync(p);
  if (!s.isFile() || s.isSymbolicLink() || s.size < 1 || s.size > maximum) throw new Error("Unsafe input artifact");
  return readFileSync(p);
};
const save = (name: string, value: unknown) => writeFileSync(join(out, name), JSON.stringify(value, null, 2), { mode: 0o600 });
const manifestRaw = read(manifestPath), manifest = JSON.parse(manifestRaw.toString());
if (manifest.version !== 1 || manifest.total_case_count !== 7 || manifest.cases?.length !== 6
    || manifest.source_sha256 !== hash(read(join(import.meta.dir, "fixtures.ts")))) throw new Error("Frozen corpus changed");
const actualRaw = read(join(actualDir, "observation.json")), actual = JSON.parse(actualRaw.toString());
if (actual.ax_relationship !== "preceding_snapshot_not_synchronized" || !actual.native_ax?.text
    || actual.source?.image_sha256 !== hash(read(join(actualDir, "capture.png")))) throw new Error("Original capture/preceding AX required");
const cases = [...manifest.cases, { id: "recorded-remote-browser", imagePath: join(actualDir, "capture.png"),
  hostAX: `Preceding native AX; not synchronized with this screenshot. Age at capture: ${actual.ax_age_ms} ms.\n${actual.native_ax.text}`,
  group: "recorded", expected: { visible: "browser", left: null, right: null }, question: manifest.question }];
const ids = new Set<string>();
for (const c of cases) {
  if (!/^[a-z0-9-]+$/.test(c.id) || ids.has(c.id) || !isAbsolute(c.imagePath) || typeof c.hostAX !== "string"
      || c.hostAX.length > 20000 || c.question !== manifest.question || !c.expected) throw new Error("Invalid frozen case");
  ids.add(c.id);
}
if (caseID && !ids.has(caseID)) throw new Error("Case filter is not in the frozen corpus");
const rolloutRaw = read(rolloutPath, 64 * 1024 * 1024);
const events = rolloutRaw.toString().trim().split("\n").map(s => JSON.parse(s));
const meta = events.find(e => e.type === "session_meta")?.payload;
const policy = read("/Users/ahmedelamin/AGENTS.md", 64 * 1024).toString().trim();
const inherited = events.find(e => e.type === "response_item" && e.payload.type === "message" && e.payload.role === "user"
  && e.payload.content?.some((c: any) => c.type === "input_text" && c.text.includes(policy)))?.payload;
if (!inherited || typeof meta?.base_instructions?.text !== "string" || !meta.base_instructions.text.startsWith("You are HeyDash.")) {
  throw new Error("Original production instructions and inherited policy required");
}
async function command(argv: string[], timeout = 12000) {
  const child = Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill("SIGTERM"), timeout);
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (code !== 0 || stdout.length + stderr.length > 1024 * 1024) throw new Error(`Benchmark child failed: ${argv[0]} (${code})`);
    return stdout;
  } finally { clearTimeout(timer); }
}
async function idle() {
  const loaded = JSON.parse(await command(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"]));
  if (loaded.length !== 1 || loaded[0].identifier !== model || loaded[0].status !== "idle"
      || loaded[0].queued !== 0 || loaded[0].parallel !== 1) throw new Error("Expected sole requested model idle with no queue");
}
const rows: any[] = [], perceptions: any[] = [];
let state = "preparing", failure: string | null = null;
let stopSignal: string | null = null;
const stop = (signal: string) => { stopSignal ??= signal; summary(); };
const onInterrupt = () => stop("SIGINT"), onTerminate = () => stop("SIGTERM");
process.on("SIGINT", onInterrupt);
process.on("SIGTERM", onTerminate);
const frozenNativeOCR = read(join(import.meta.dir, "native-ocr.swift"));
const provenance = Object.freeze({
  baselineRolloutSHA256: hash(rolloutRaw), manifestSHA256: hash(manifestRaw), actualObservationSHA256: hash(actualRaw),
  instructionsSHA256: hash(meta.base_instructions.text), inheritedPolicySHA256: hash(JSON.stringify(inherited.content)),
  formatterSHA256: hash(read(join(import.meta.dir, "format.ts"))), nativeOCRSHA256: hash(frozenNativeOCR),
  runnerSHA256: hash(read(import.meta.path)), supportSHA256: hash(read(join(import.meta.dir, "runner-support.ts"))),
  casesSHA256: hash(JSON.stringify(cases)),
});
const summary = () => save("summary.json", { state, failure, model, noActionExecution: true,
  scope: "Static perception only, not task completion, input capability, or original failure replay",
  differencesFromProduction: ["explicit classification question", "no prior reasoning or compacted summary", "tools=[]", "direct Responses", `${maxOutputTokens} output-token cap`, "temperature 0.1"],
  armOrder: "alternating AB/BA by frozen case index; one sample per arm/case; cache/order effects remain",
  maxOutputTokens, caseFilter: caseID, stopSignal, reasoningEffort: "medium", ...provenance,
  assessment: { totalAttempts: rows.length, validAnswers: rows.filter(r => r.valid).length,
    correctAnswers: rows.filter(r => r.passed).length, budgetCensored: rows.filter(r => r.outcome === "budget_censored").length,
    note: "Censored and missing answers count against task yield, not as measured visual classification errors" }, perceptions, rows });
try {
  summary();
  await idle();
  const executable = join(out, "native-ocr");
  const nativeSource = join(out, "native-ocr.swift");
  writeFileSync(nativeSource, frozenNativeOCR, { mode: 0o600, flag: "wx" });
  await command(["/usr/bin/swiftc", "-O", nativeSource, "-o", executable], 60000);
  caseLoop: for (const [index, c] of cases.entries()) {
    if (caseID && c.id !== caseID) continue;
    if (stopSignal) break;
    const image = read(c.imagePath, 32 * 1024 * 1024);
    if (!image.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) throw new Error("Expected PNG");
    const source: Source = { capture_id: index === 6 ? actual.source.capture_id : `00000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
      image_sha256: hash(image), width: image.readUInt32BE(16), height: image.readUInt32BE(20) };
    const ocrPath = join(out, `${c.id}-ocr.json`);
    const started = performance.now();
    await command([executable, c.imagePath, ocrPath], 65000);
    const processMS = performance.now() - started;
    const raw = JSON.parse(read(ocrPath, 128 * 1024).toString());
    const ocrText = formatOCR(raw, source);
    perceptions.push({ id: c.id, imageSHA256: source.image_sha256, detected: raw.detected_count,
      ocrNativeMS: raw.elapsed_ms, ocrProcessMS: processMS, formattedBytes: Buffer.byteLength(ocrText) });
    const arms = index % 2 ? ["ocr", "baseline"] : ["baseline", "ocr"];
    for (const arm of arms) {
      if (stopSignal) break caseLoop;
      await idle(); state = "running"; summary();
      if (stopSignal) break caseLoop;
      const content: any[] = [{ type: "input_text", text: c.hostAX }];
      if (arm === "ocr") content.push({ type: "input_text", text: ocrText });
      content.push({ type: "input_image", image_url: `data:image/png;base64,${image.toString("base64")}` });
      const request = { model, instructions: meta.base_instructions.text, tools: [], temperature: 0.1,
        reasoning: { effort: "medium" }, max_output_tokens: maxOutputTokens, stream: false,
        input: [{ type: "message", role: "user", content: inherited.content },
          { type: "message", role: "user", content: [{ type: "input_text", text: c.question }] },
          { type: "message", role: "user", content }] };
      save(`${c.id}-${arm}-request.json`, request);
      const begin = performance.now();
      const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
        headers: { "content-type": "application/json" }, body: JSON.stringify(request), signal: AbortSignal.timeout(180000) });
      if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
      const responseRaw = await response.text(), elapsedMS = performance.now() - begin;
      if (responseRaw.length > 2 * 1024 * 1024) throw new Error("Provider output bound exceeded");
      const result = JSON.parse(responseRaw);
      if (result.error || result.model !== model || !Array.isArray(result.output)) throw new Error("Invalid provider response");
      const assessment = assessResponse(result, c.expected, maxOutputTokens);
      save(`${c.id}-${arm}-response.json`, { result, ...assessment, expected: c.expected });
      const { answer, ...audit } = assessment;
      rows.push({ id: c.id, group: c.group, arm, elapsedMS, ...audit, status: result.status,
        requestSHA256: hash(JSON.stringify(request)), responseSHA256: hash(responseRaw), usage: result.usage });
      summary(); console.log(JSON.stringify({ id: c.id, arm, elapsedMS: Math.round(elapsedMS), outcome: assessment.outcome }));
    }
  }
  state = stopSignal ? "interrupted_after_request_boundary" : "completed";
} catch (error) { state = "failed"; failure = error instanceof Error ? error.message : "Perception comparison failed"; process.exitCode = 1; }
finally {
  // Do not report a safe stop while the provider may still own an outstanding
  // request. Signals above never abort a request; even timeout/error exits must
  // wait for the model's idle boundary before ending this benchmark process.
  let verifiedIdle = false;
  for (let attempt = 0; attempt < 180; attempt++) {
    try { await idle(); verifiedIdle = true; break; } catch { await Bun.sleep(1000); }
  }
  if (!verifiedIdle) {
    state = "provider_state_unconfirmed";
    failure = `${failure ?? "No completed idle verification"}; do not launch another inference until provider status is checked`;
    process.exitCode = 1;
  }
  summary();
  process.off("SIGINT", onInterrupt);
  process.off("SIGTERM", onTerminate);
}
