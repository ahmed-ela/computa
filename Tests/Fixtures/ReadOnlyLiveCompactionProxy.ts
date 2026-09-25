#!/Users/ahmedelamin/.bun/bin/bun
// Test-only transport wrapper. Real Codex + real local model; no desktop tool
// executor. All server requests are intercepted, never forwarded to HeyDash.
import { appendFileSync, lstatSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const root = process.env.CODEX_HOME;
if (!root) throw new Error("An isolated CODEX_HOME is required.");
const config = JSON.parse(readFileSync(join(root, "read-only-proxy.json"), "utf8"));
if (typeof config.executable !== "string" || !isAbsolute(config.executable)
    || !config.executable.endsWith("/AgentRuntime/codex-app-server")
    || !["small", "bounded-observation", "bounded-image"].includes(config.payload)
    || !["before", "after", "within"].includes(config.auditName)) {
  throw new Error("Unsupported read-only live fixture configuration.");
}
// The Swift fixture already resolved the signed bundle artifact; independently
// check its pinned source and bytes before the wrapper starts the real child.
const manifest = JSON.parse(readFileSync(join(dirname(config.executable), "manifest.json"), "utf8"));
const executableStat = lstatSync(config.executable);
if (!executableStat.isFile() || executableStat.isSymbolicLink()
    || executableStat.size !== manifest.binarySize || executableStat.size > 512 * 1024 * 1024
    || manifest.sourceCommit !== "4607249e430dac1c961df4dc615beae88e33cec8"
    || createHash("sha256").update(readFileSync(config.executable)).digest("hex") !== manifest.binarySHA256) {
  throw new Error("The bundled runtime artifact failed read-only fixture validation.");
}
const auditPath = join(root, `${config.auditName}-tool-audit.jsonl`);
writeFileSync(auditPath, "", { flag: "wx", mode: 0o600 });
let auditSequence = 0;
const record = (entry: object) => appendFileSync(auditPath,
  JSON.stringify({ sequence: ++auditSequence, ...entry }) + "\n");

// A bounded synthetic observation, not retained user padding or an instruction.
// Its sole purpose is to cross the shipping native threshold after a tool call.
// The actual tokenizer/threshold behavior must be proved by the live gate.
const payload = JSON.stringify({
  fixture: "synthetic read-only status; no desktop was inspected or changed",
  accessibility: "fixture-not-queried",
  screenRecording: "fixture-not-queried",
  ...(config.payload === "bounded-observation" || config.payload === "bounded-image" ? {
    disposableObservation: "alpha beta gamma delta. ".repeat(700),
  } : {}),
});
if (Buffer.byteLength(payload, "utf8") > 20_000) throw new Error("Fixture payload exceeds its bound.");
let image: { imageUrl: string; imageSHA256: string; imageBytes: number } | undefined;
if (config.payload === "bounded-image") {
  // Only the test-created fixed file inside this isolated home may be returned.
  // The answer is never stored in config, tool text, or transport audit.
  const path = join(root, "status-image.png");
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 8 || stat.size > 512 * 1024) {
    throw new Error("Synthetic image must be a regular bounded PNG fixture.");
  }
  const bytes = readFileSync(path);
  if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error("Synthetic fixture is not a PNG.");
  }
  image = { imageUrl: `data:image/png;base64,${bytes.toString("base64")}`,
    imageSHA256: createHash("sha256").update(bytes).digest("hex"), imageBytes: bytes.length };
}
record({ kind: "fixture", payload: config.payload, payloadBytes: Buffer.byteLength(payload, "utf8"),
  ...(image ? { imageSHA256: image.imageSHA256, imageBytes: image.imageBytes } : {}) });

// Inherit the owned process group; shutdown of the wrapper retires its child.
const child = spawn(config.executable, process.argv.slice(2), {
  env: process.env, stdio: ["pipe", "pipe", "pipe"], detached: false,
});
child.stderr.pipe(process.stderr);
let statusCalls = 0;
let closing = false;
const send = (value: object) => child.stdin.write(JSON.stringify(value) + "\n");
const requests = createInterface({ input: process.stdin });
requests.on("line", line => child.stdin.write(line + "\n"));
requests.on("close", () => { closing = true; child.stdin.end(); });
const responses = createInterface({ input: child.stdout });
responses.on("line", line => {
  const value = JSON.parse(line);
  if (!value.method || !Object.hasOwn(value, "id")) {
    process.stdout.write(line + "\n");
    return;
  }
  const params = value.params ?? {};
  let args = params.arguments;
  try { if (typeof args === "string") args = JSON.parse(args); } catch { args = null; }
  const validStatus = value.method === "item/tool/call"
    && params.tool === "computer_v2_status"
    && args && typeof args === "object" && !Array.isArray(args) && Object.keys(args).length === 0
    && typeof params.callId === "string" && params.callId.length > 0
    && typeof params.turnId === "string" && params.turnId.length > 0;
  if (validStatus && statusCalls++ === 0) {
    record({ kind: "status", id: value.id, threadId: params.threadId, turnId: params.turnId,
      callId: params.callId, tool: params.tool, arguments: args, payloadBytes: Buffer.byteLength(payload, "utf8"),
      ...(image ? { imageSHA256: image.imageSHA256, imageBytes: image.imageBytes } : {}) });
    send({ id: value.id, result: { success: true, contentItems: [
      { type: "inputText", text: payload }, ...(image ? [{ type: "inputImage", imageUrl: image.imageUrl }] : []),
    ] } });
  } else {
    record({ kind: "blocked", method: value.method, tool: params.tool ?? null,
      threadId: params.threadId ?? null, turnId: params.turnId ?? null, callId: params.callId ?? null });
    if (value.method === "item/tool/call") {
      send({ id: value.id, result: { success: false,
        contentItems: [{ type: "inputText", text: "Read-only fixture rejected an unexpected or duplicate tool call." }] } });
    } else if (value.method.endsWith("/requestApproval")) {
      send({ id: value.id, result: { decision: "decline" } });
    } else {
      send({ id: value.id, error: { code: -32601, message: "This read-only fixture does not permit interactive requests." } });
    }
  }
});
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => { closing = true; child.kill(signal); });
}
child.on("error", error => { record({ kind: "proxy-error", message: error.message }); process.exit(1); });
// 'exit' can precede stdout EOF; keep the wrapper alive until the final NDJSON
// frames have drained through readline and the wrapper's own output stream.
child.on("close", (code, signal) => {
  record({ kind: "exit", code, signal, closing });
  process.stdout.write("", () => process.exit(code ?? (closing ? 0 : 1)));
});
