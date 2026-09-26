// Isolated host-identification benchmark; no tool menu or action dispatch.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { makeCapabilityRoutingFixtures } from "./fixtures";
import { TARGET_RESOLVER_INSTRUCTIONS, validateTargetResolution } from "./target-resolver";

type ResolverCase = { id: string; prompt: string; inventory: string; expectedBundleID: string | null };
const [out, rolloutPath, extraCasesPath, tokenLimit = "128"] = Bun.argv.slice(2);
if (Bun.argv.length > 6 || ![out, rolloutPath].every(p => p && isAbsolute(p)) || (extraCasesPath && !isAbsolute(extraCasesPath))
    || !["128", "1024"].includes(tokenLimit)) {
  throw new Error("Usage: resolver-run.ts FRESH_PRIVATE_OUTPUT BASELINE_ROLLOUT [EXTRA_CASES_JSON] [128|1024]");
}
const maxOutputTokens = Number(tokenLimit);
const directory = lstatSync(out);
if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o777) !== 0o700 || readdirSync(out).length
    || resolve(out).startsWith(resolve(import.meta.dir, "../..") + "/")) throw new Error("Fresh external mode-0700 output directory required");
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const read = (path: string, max = 16 * 1024 * 1024) => {
  const stat = lstatSync(path); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > max) throw new Error("Unsafe input file");
  return readFileSync(path, "utf8");
};
const raw = read(rolloutPath), events = raw.trim().split("\n").map(line => JSON.parse(line));
const context = events.find(e => e.type === "turn_context")?.payload;
const items = events.filter(e => e.type === "response_item").map(e => e.payload);
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const policy = read("/Users/ahmedelamin/AGENTS.md", 64 * 1024).trim();
const policies = items.filter(i => i.type === "message" && i.role === "user"
  && i.content?.some((c: any) => c.type === "input_text" && c.text.includes(policy)));
if (context?.model !== model || policies.length !== 1 || items.find(i => i.type === "message" && i.role === "user") !== policies[0]) throw new Error("Baseline/policy mismatch");
const policyContent = policies[0].content;
const corpus = makeCapabilityRoutingFixtures();
const retrospective: ResolverCase[] = corpus.filter(f => f.receipts.some(r => r.name === "computer_v2_apps")).map(f => ({
  id: f.id, prompt: f.prompt, inventory: f.receipts.find(r => r.name === "computer_v2_apps")!.output, expectedBundleID: f.observedHost.bundleID,
}));
if (retrospective.length !== 5) throw new Error("Frozen inventory case count changed");
const baselineUsers = items.filter(i => i.type === "message" && i.role === "user");
const appCalls = items.filter(i => i.type === "function_call" && i.name === "computer_v2_apps");
const appOutputs = items.filter(i => i.type === "function_call_output" && i.call_id === appCalls[0]?.call_id);
if (baselineUsers.length !== 2 || baselineUsers[1].content?.length !== 1 || baselineUsers[1].content[0].type !== "input_text"
    || appCalls.length !== 1 || appOutputs.length !== 1 || typeof appOutputs[0].output !== "string") throw new Error("Recorded baseline changed");
const recorded: ResolverCase = { id: "recorded-original-screen-sharing", prompt: baselineUsers[1].content[0].text,
  inventory: appOutputs[0].output, expectedBundleID: "com.apple.ScreenSharing" };
const extraRaw = extraCasesPath ? read(extraCasesPath, 1024 * 1024) : null;
const extraInput = extraRaw ? JSON.parse(extraRaw) : [];
if (!Array.isArray(extraInput) || extraInput.length > 24) throw new Error("Extra case bound");
const extras: ResolverCase[] = extraInput.map(c => {
  if (!c || Object.keys(c).sort().join(",") !== "apps,expectedBundleID,id,prompt" || !Array.isArray(c.apps) || c.apps.length > 128
      || c.apps.some((a: any) => !a || Object.keys(a).sort().join(",") !== "bundle_id,name" || typeof a.name !== "string" || !a.name || a.name.length > 256
        || typeof a.bundle_id !== "string" || !a.bundle_id || a.bundle_id.length > 256)) throw new Error("Invalid extra-case app records");
  return { id: c.id, prompt: c.prompt, expectedBundleID: c.expectedBundleID,
    inventory: `APPS scope=user_facing matched=${c.apps.length} returned=${c.apps.length} omitted=0. Synthetic local application inventory.\n`
      + c.apps.map((a: any) => JSON.stringify(a)).join("\n") };
});
const cases = [...retrospective, recorded, ...extras], ids = new Set<string>();
function inventoryIDs(text: string): string[] {
  if (typeof text !== "string" || text.length > 64 * 1024 || !text.startsWith("APPS ")) throw new Error("Expected original bounded APPS inventory");
  const rows = text.split("\n").slice(1).filter(line => line.trim()).map(line => JSON.parse(line));
  if (rows.length > 128 || rows.some(row => typeof row.bundle_id !== "string" || !row.bundle_id || typeof row.name !== "string")) throw new Error("Invalid inventory rows");
  return [...new Set(rows.map(row => row.bundle_id))];
}
for (const c of cases) {
  if (!c || Object.keys(c).sort().join(",") !== "expectedBundleID,id,inventory,prompt" || typeof c.id !== "string"
      || !/^[a-z0-9][a-z0-9_-]{0,95}$/.test(c.id) || ids.has(c.id) || typeof c.prompt !== "string" || !c.prompt || c.prompt.length > 8192
      || (c.expectedBundleID !== null && typeof c.expectedBundleID !== "string")) throw new Error("Invalid resolver case");
  ids.add(c.id); const listed = inventoryIDs(c.inventory);
  if (c.expectedBundleID !== null && !listed.includes(c.expectedBundleID)) throw new Error("Unlisted expected host");
}
const sourceSHA256 = hash(read(join(import.meta.dir, "target-resolver.ts"))), rows: any[] = [];
let state = "running", failure: string | null = null;
const save = () => writeFileSync(join(out, "summary.json"), JSON.stringify({
  scope: "host identification only, not permission, task success, or action execution; first five cases are retrospective, sixth reuses recorded task/inventory, neither is new held-out evidence",
  model, state, failure, maxOutputTokens, sourceSHA256, instructionsSHA256: hash(TARGET_RESOLVER_INSTRUCTIONS), baselineSHA256: hash(raw),
  inheritedPolicyContentSHA256: hash(JSON.stringify(policyContent)), corpusSHA256: hash(JSON.stringify(corpus)),
  casesSHA256: hash(JSON.stringify(cases)), extraCasesSHA256: extraRaw ? hash(extraRaw) : null,
  additionalCaseTransform: "apps array serialized verbatim one JSON record per line after generated APPS count header; no added app fields. Original five inventory receipts unchanged.",
  expectedMeaning: "local host identity only; permission-negative inventory still has an identifiable host; no authorization inferred",
  outputBoundCaveat: "A 128-token truncation is an output-bound failure, not evidence that the resolver cannot identify the host.",
  noActionExecution: true, differencesFromProduction: ["separate resolver instructions", "tools=[]", "no status or prior assistant text", `${maxOutputTokens} output tokens`, "temperature 0.1", "direct Responses, not owned App Server"], rows,
}, null, 2), { mode: 0o600 });
async function requireIdle() {
  const child = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"], { stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill("SIGKILL"), 8000);
  try {
    const [raw, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    const loaded = JSON.parse(raw);
    if (code !== 0 || stderr.length > 65536 || loaded.length !== 1 || loaded[0].identifier !== model || loaded[0].status !== "idle"
        || loaded[0].queued !== 0 || loaded[0].parallel !== 1) throw new Error("Sole 4B model must be idle, queued=0, parallel=1");
  } finally { clearTimeout(timer); }
}
try {
  save();
  for (const [index, fixture] of cases.entries()) {
    await requireIdle();
    const request = { model, instructions: TARGET_RESOLVER_INSTRUCTIONS, tools: [], temperature: 0.1, max_output_tokens: maxOutputTokens, stream: false,
      input: [{ type: "message", role: "user", content: policyContent },
        { type: "message", role: "user", content: [{ type: "input_text", text: fixture.prompt }] },
        { type: "message", role: "user", content: [{ type: "input_text", text: fixture.inventory }] }] };
    writeFileSync(join(out, `${fixture.id}-request.json`), JSON.stringify(request), { mode: 0o600 });
    const started = performance.now();
    const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
      headers: { "content-type": "application/json" }, body: JSON.stringify(request), signal: AbortSignal.timeout(45_000) });
    if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
    const body = await response.text(); if (body.length > 1024 * 1024) throw new Error("Response size bound");
    const result = JSON.parse(body), elapsedMS = performance.now() - started;
    if (result.error || result.model !== model || !Array.isArray(result.output)) throw new Error("Invalid provider response");
    const messages = result.output.filter((i: any) => i.type === "message" && i.role === "assistant");
    const text = messages.flatMap((m: any) => m.content ?? []).filter((c: any) => c.type === "output_text").map((c: any) => c.text).join("");
    const shapeValid = messages.length === 1 && messages[0].content?.every((c: any) => c.type === "output_text")
      && result.output.every((i: any) => i.type === "reasoning" || (i.type === "message" && i.role === "assistant"));
    const validation = result.status === "completed" && !result.incomplete_details && shapeValid
      ? validateTargetResolution(text, inventoryIDs(fixture.inventory)) : { valid: false as const, reason: "incomplete_or_unexpected_output" };
    const passed = validation.valid && validation.bundleID === fixture.expectedBundleID;
    writeFileSync(join(out, `${fixture.id}.json`), JSON.stringify({ request, response: result, validation, expectedBundleID: fixture.expectedBundleID, passed }, null, 2), { mode: 0o600 });
    rows.push({ id: fixture.id, group: index < 5 ? "retrospective" : index === 5 ? "recorded" : "additional_frozen_cases", elapsedMS, status: result.status,
      incomplete: result.incomplete_details ?? null,
      valid: validation.valid, passed, reason: validation.valid ? null : validation.reason, textCharacters: text.length,
      requestSHA256: hash(JSON.stringify(request)), responseSHA256: hash(body), usage: result.usage });
    save(); console.log(JSON.stringify({ id: fixture.id, elapsedMS: Math.round(elapsedMS), valid: validation.valid, passed }));
  }
  state = "completed";
} catch (error) { state = "failed"; failure = error instanceof Error ? error.message : "Resolver diagnostic failed"; process.exitCode = 1; }
finally { save(); }
