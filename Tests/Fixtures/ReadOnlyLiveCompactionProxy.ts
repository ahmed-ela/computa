#!/usr/bin/env bun
// Test-only transport wrapper. Real Codex + real local model; no desktop tool
// executor. All server requests are intercepted, never forwarded to Computa.
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
    || !["small", "bounded-observation", "bounded-image", "activation-failure", "bounded-activation-failure", "native-stop", "ax-query-recovery"].includes(config.payload)
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
// Its sole purpose is to cross the explicitly configured native test threshold
// after a tool call; forced fixtures are not shipping-threshold capacity proof.
// The actual tokenizer/threshold behavior must be proved by the live gate.
const activationFailure = ["activation-failure", "bounded-activation-failure"].includes(config.payload);
// A model may reasonably check permissions before attempting the requested app
// open. This optional preflight is synthetic, bounded, and never queries macOS.
const activationPreflight = JSON.stringify({
  fixture: "synthetic permission status; no desktop was inspected or changed",
  accessibility: "granted",
  screenRecording: "granted",
});
let failure: Record<string, unknown> | undefined;
if (activationFailure) {
  if (typeof config.failureText !== "string" || Buffer.byteLength(config.failureText, "utf8") > 4_096) {
    throw new Error("A bounded native activation diagnostic is required.");
  }
  failure = JSON.parse(config.failureText);
  if (!failure || Array.isArray(failure) || typeof failure !== "object"
      || (failure.error as Record<string, unknown>)?.code !== "application_activation_failed"
      || failure.cause !== "undetermined" || failure.website_status !== "not_observed"
      || failure.action_outcome !== "not_confirmed") {
    throw new Error("The fixture only accepts an unconfirmed native activation failure.");
  }
}
const payload = JSON.stringify(activationFailure ? {
  ...failure,
  fixture: "synthetic activation failure; no desktop was inspected or changed",
  ...(config.payload === "bounded-activation-failure" ? {
    disposableObservation: "alpha beta gamma delta. ".repeat(700),
  } : {}),
} : {
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

// Generated by Swift's real formatter, never acquired from the desktop. This
// single decision diagnostic accepts only the fixture's short literal target.
let queryRecovery: { queryLiteral: string; shortQuery?: string; open: string; initial: string; targeted: string; unbound: string; apps: string; "apps-default": string } | undefined;
if (config.payload === "ax-query-recovery") {
  const path = join(root, "ax-query-recovery.json");
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 16_384) {
    throw new Error("Expected a bounded regular synthetic AX query fixture.");
  }
  const fixture = JSON.parse(readFileSync(path, "utf8"));
  if (!fixture || typeof fixture.queryLiteral !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$/.test(fixture.queryLiteral)
      || fixture.queryLiteral !== fixture.queryLiteral.trim()
      || (fixture.shortQuery !== undefined && (typeof fixture.shortQuery !== "string"
        || !/^[A-Za-z0-9_-]{3,80}$/.test(fixture.shortQuery)
        || !fixture.queryLiteral.endsWith(` ${fixture.shortQuery}`)))
      || typeof fixture.open !== "string" || Buffer.byteLength(fixture.open, "utf8") > 2_048
      || !fixture.open.includes("profile=existing ordinary_profile_access=true")
      || typeof fixture.unbound !== "string" || !fixture.unbound
      || Buffer.byteLength(fixture.unbound, "utf8") > 1_024
      || !["apps", "apps-default"].every(key => typeof fixture[key] === "string"
        && fixture[key].startsWith("APPS ") && Buffer.byteLength(fixture[key], "utf8") <= 3_500)
      || !["initial", "targeted"].every(key => typeof fixture[key] === "string"
        && fixture[key].startsWith("AXSNAPSHOT ") && fixture[key].includes(" parents=[")
        && Buffer.byteLength(fixture[key], "utf8") <= 4_096)
      || !fixture.initial.includes("output_truncated=1")) {
    throw new Error("Unsupported synthetic AX query fixture.");
  }
  queryRecovery = fixture;
}

// Inherit the owned process group; shutdown of the wrapper retires its child.
const child = spawn(config.executable, process.argv.slice(2), {
  env: process.env, stdio: ["pipe", "pipe", "pipe"], detached: false,
});
child.stderr.pipe(process.stderr);
let statusCalls = 0;
let appInventoryCalls = 0;
let openCalls = 0;
let closing = false;
let queryRequests = 0;
let initialSnapshots = 0;
let targetedSnapshots = 0;
let unboundSnapshots = 0;
const queryCallIDs = new Set<string>();
let queryTurn: string | undefined;
const queryWatchdog = queryRecovery ? setTimeout(() => {
  record({ kind: "query-limit", reason: "120-second watchdog" });
  closing = true;
  child.kill("SIGTERM");
}, 120_000) : undefined;
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
  if (queryRecovery) {
    // No server request in this mode reaches Computa, including approvals,
    // captures, mouse/keyboard actions, or any unsupported dynamic tool.
    queryRequests += 1;
    if (queryRequests >= 8) {
      record({ kind: "query-limit", reason: "8-request ceiling", method: value.method, tool: params.tool ?? null });
      closing = true;
      child.kill("SIGTERM");
      return;
    }
    const validCall = value.method === "item/tool/call"
      && args && typeof args === "object" && !Array.isArray(args)
      && typeof params.callId === "string" && params.callId.length > 0
      && !queryCallIDs.has(params.callId)
      && typeof params.turnId === "string" && params.turnId.length > 0
      && (queryTurn === undefined || queryTurn === params.turnId);
    let stage: string | undefined;
    let text: string | undefined;
    let success = true;
    if (validCall) {
      queryCallIDs.add(params.callId);
      queryTurn = params.turnId;
      const keys = Object.keys(args);
      const literalQuery = keys.length === 1 && keys[0] === "query"
        && typeof args.query === "string" && args.query.length <= 200
        && [queryRecovery.queryLiteral, queryRecovery.shortQuery].some(literal =>
          literal !== undefined && args.query.trim().toLowerCase() === literal.toLowerCase());
      if (params.tool === "computer_v2_status" && keys.length === 0 && statusCalls === 0 && openCalls === 0) {
        statusCalls += 1; stage = "status"; text = activationPreflight;
      } else if (params.tool === "computer_v2_apps" && appInventoryCalls === 0 && openCalls === 0
          && (keys.length === 0 || (keys.length === 1 && keys[0] === "query"
            && typeof args.query === "string" && args.query.length <= 200 && args.query.trim().length > 0
            && ["google chrome", "com.google.chrome"].some(value => value.includes(args.query.trim().toLowerCase()))))) {
        appInventoryCalls += 1;
        stage = keys.length === 0 ? "apps-default" : "apps";
        text = keys.length === 0 ? queryRecovery["apps-default"] : queryRecovery.apps;
      } else if (params.tool === "computer_v2_snapshot" && openCalls === 0 && unboundSnapshots === 0
          && (keys.length === 0 || literalQuery)) {
        unboundSnapshots += 1; stage = "unbound"; text = queryRecovery.unbound; success = false;
      } else if (params.tool === "computer_v2_open" && openCalls === 0
          && keys.every(key => ["bundle_id", "browser_mode"].includes(key))
          && args.bundle_id === "com.google.Chrome" && [undefined, "existing"].includes(args.browser_mode)) {
        openCalls += 1; stage = "open"; text = queryRecovery.open;
      } else if (params.tool === "computer_v2_snapshot" && openCalls === 1 && keys.length === 0
          && initialSnapshots === 0 && targetedSnapshots === 0) {
        initialSnapshots += 1; stage = "initial"; text = queryRecovery.initial;
      } else if (params.tool === "computer_v2_snapshot" && openCalls === 1 && targetedSnapshots === 0 && literalQuery) {
        targetedSnapshots += 1;
        stage = initialSnapshots === 1 ? "query" : "direct-query";
        text = queryRecovery.targeted;
      }
    }
    if (stage && text !== undefined) {
      record({ kind: "query-recovery", stage, id: value.id, threadId: params.threadId,
        turnId: params.turnId, callId: params.callId, tool: params.tool, arguments: args, success,
        payloadBytes: Buffer.byteLength(text, "utf8"), payloadSHA256: createHash("sha256").update(text).digest("hex") });
      send({ id: value.id, result: { success, contentItems: [{ type: "inputText", text }] } });
    } else {
      record({ kind: "blocked", method: value.method, tool: params.tool ?? null,
        threadId: params.threadId ?? null, turnId: params.turnId ?? null, callId: params.callId ?? null });
      if (value.method === "item/tool/call") {
        send({ id: value.id, result: { success: false,
          contentItems: [{ type: "inputText", text: "Synthetic read-only fixture rejected an unsupported, duplicate, or out-of-sequence call." }] } });
      } else if (value.method.endsWith("/requestApproval")) {
        send({ id: value.id, result: { decision: "decline" } });
      } else {
        send({ id: value.id, error: { code: -32601, message: "No interactive requests are permitted by this synthetic fixture." } });
      }
    }
    return;
  }
  const validStatus = value.method === "item/tool/call"
    && params.tool === "computer_v2_status"
    && args && typeof args === "object" && !Array.isArray(args) && Object.keys(args).length === 0
    && typeof params.callId === "string" && params.callId.length > 0
    && typeof params.turnId === "string" && params.turnId.length > 0;
  const validOpen = value.method === "item/tool/call" && params.tool === "computer_v2_open"
    && args && typeof args === "object" && !Array.isArray(args) && Object.keys(args).length === 1
    && args.bundle_id === "com.google.Chrome"
    && typeof params.callId === "string" && params.callId.length > 0
    && typeof params.turnId === "string" && params.turnId.length > 0;
  if (config.payload === "native-stop" && validOpen && openCalls++ === 0) {
    // Only this exact open reaches the DEBUG-only typed-failure seam in Core.
    // The Swift configuration must enable that seam; no real desktop execution.
    record({ kind: "native-stop", callId: params.callId, threadId: params.threadId, turnId: params.turnId });
    process.stdout.write(line + "\n");
  } else if (activationFailure && validStatus && openCalls === 0 && statusCalls === 0) {
    statusCalls += 1;
    record({ kind: "activation-preflight", id: value.id, threadId: params.threadId, turnId: params.turnId,
      callId: params.callId, tool: params.tool, arguments: args,
      payloadBytes: Buffer.byteLength(activationPreflight, "utf8") });
    send({ id: value.id, result: { success: true,
      contentItems: [{ type: "inputText", text: activationPreflight }] } });
  } else if (activationFailure && validOpen && openCalls++ === 0) {
    record({ kind: "activation-failure", id: value.id, threadId: params.threadId, turnId: params.turnId,
      callId: params.callId, tool: params.tool, arguments: args, payloadBytes: Buffer.byteLength(payload, "utf8") });
    send({ id: value.id, result: { success: false, contentItems: [{ type: "inputText", text: payload }] } });
  } else if (!activationFailure && validStatus && statusCalls++ === 0) {
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
  if (queryWatchdog !== undefined) clearTimeout(queryWatchdog);
  record({ kind: "exit", code, signal, closing });
  process.stdout.write("", () => process.exit(code ?? (closing ? 0 : 1)));
});
