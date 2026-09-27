// Opt-in, inert-tool diagnostic. This file never imports or dispatches a native
// computer driver. Raw protocol/model evidence belongs in a fresh private dir.
// Official protocol: https://developers.openai.com/codex/app-server/
import { createHash } from "node:crypto";
import { appendFileSync, lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { makeInspectionRoutes } from "./inspection-routes";
import { withHostContract } from "./host-contract";
import { annotateExplicitAppMention } from "./explicit-app-mention";

const [out, baselinePath, arm = "baseline"] = Bun.argv.slice(2);
if (Bun.argv.length > 5 || !out || !baselinePath || ![out, baselinePath].every(isAbsolute)
    || !["baseline", "capability_header", "host_contract", "explicit_mention"].includes(arm)) {
  throw new Error("Usage: owned-runtime.ts FRESH_PRIVATE_OUTPUT BASELINE_ROLLOUT [baseline|capability_header|host_contract|explicit_mention]");
}
const repo = resolve(import.meta.dir, "../..");
const dir = lstatSync(out);
if (!dir.isDirectory() || dir.isSymbolicLink() || (dir.mode & 0o777) !== 0o700 || readdirSync(out).length
    || resolve(out).startsWith(repo + "/")) throw new Error("Fresh external mode-0700 output directory required");
if (process.platform !== "darwin" || process.arch !== "arm64") throw new Error("macOS arm64 required");
const hash = (data: string | Uint8Array) => createHash("sha256").update(data).digest("hex");
function readBounded(path: string, maximum = 16 * 1024 * 1024): Buffer {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size < 1 || stat.size > maximum) throw new Error("Unsafe input artifact");
  return readFileSync(path);
}
const save = (name: string, value: unknown) => writeFileSync(join(out, name), JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
const canonical = (value: any): string => JSON.stringify(value, (_key, item) => item && typeof item === "object" && !Array.isArray(item)
  ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
const baseline = readBounded(baselinePath);
const events = baseline.toString("utf8").trim().split("\n").map(line => JSON.parse(line));
const metas = events.filter(e => e.type === "session_meta"), contexts = events.filter(e => e.type === "turn_context");
const items = events.filter(e => e.type === "response_item").map(e => e.payload);
const users = items.filter(i => i.type === "message" && i.role === "user");
const calls = items.filter(i => i.type === "function_call");
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const meta = metas[0]?.payload, context = contexts[0]?.payload;
if (metas.length !== 1 || contexts.length !== 1 || users.length !== 2 || calls.length !== 2
    || calls.map(c => c.name).join(",") !== "computer_v2_status,computer_v2_apps"
    || meta?.model_provider !== "lmstudio" || context?.model !== model || context?.effort !== "medium"
    || context?.approval_policy !== "on-request" || context?.sandbox_policy?.type !== "workspace-write"
    || context?.sandbox_policy?.network_access !== false || meta.cwd !== context.cwd || !isAbsolute(meta.cwd)
    || typeof meta.base_instructions?.text !== "string" || !/^You are (?:HeyDash|Macndash)\./.test(meta.base_instructions.text)
    || meta.dynamic_tools?.length !== 12 || users[1].content?.length !== 1
    || users[1].content[0].type !== "input_text" || typeof users[1].content[0].text !== "string") {
  throw new Error("Unexpected baseline contract; nothing launched");
}
const prompt = users[1].content[0].text, instructions = meta.base_instructions.text;
const policy = readBounded(join(process.env.HOME!, "AGENTS.md"), 64 * 1024).toString().trim();
if (!users[0].content?.some((c: any) => c.type === "input_text" && c.text.includes(policy))) throw new Error("Baseline policy mismatch");
const receipts = new Map<string, string>();
for (const call of calls) {
  const outputs = items.filter(i => i.type === "function_call_output" && i.call_id === call.call_id);
  if (canonical(JSON.parse(call.arguments)) !== "{}" || outputs.length !== 1 || typeof outputs[0].output !== "string") throw new Error("Unexpected receipt");
  receipts.set(call.name, outputs[0].output);
}
const header = arm === "capability_header" ? makeInspectionRoutes(JSON.parse(receipts.get("computer_v2_status")!)) + "\n" : "";
const appsReceipt = arm === "explicit_mention" ? annotateExplicitAppMention(prompt, receipts.get("computer_v2_apps")!)
  : header + receipts.get("computer_v2_apps")!;
const dynamicTools = arm === "host_contract" ? withHostContract(meta.dynamic_tools) : meta.dynamic_tools;
const expectedNames = [...dynamicTools.map((t: any) => t.name), "request_user_input"].sort();
if (new Set(expectedNames).size !== 13 || meta.dynamic_tools.some((t: any) => !t.name.startsWith("computer_v2_"))) throw new Error("Unexpected tool set");
// Pinned tools/src/json_schema/types.rs lacks these range/length keywords.
// Compare the runtime's observed projection, without changing the submitted
// dynamic schemas or forwarding body. No unknown field is broadly ignored.
function expectedWireSchema(tool: any) {
  const schema = structuredClone(tool.inputSchema);
  if (tool.name === "computer_v2_snapshot") {
    delete schema.properties.query.minLength; delete schema.properties.query.maxLength;
  } else if (tool.name === "computer_v2_capture") {
    delete schema.properties.display_id.minimum; delete schema.properties.display_id.maximum;
  } else if (tool.name === "computer_v2_pointer") {
    delete schema.properties.x.minimum; delete schema.properties.y.minimum;
  }
  return schema;
}

// Extract the literal production config, fail closed on a new expression. No
// copied prompt prefix, extra instructions, output cap, or sampling override.
const swift = readBounded(join(repo, "Sources/Mactopus/Runtime/CodexAppServerRuntime.swift")).toString();
const configBody = swift.split("static func localThreadConfig(")[1]?.split("struct Configuration:")[0];
const entries = [...(configBody ?? "").matchAll(/"([a-z0-9_.]+)": ([^,\n]+),/g)];
if (entries.length !== 22 || !swift.includes("case .smallModelComputerUse: 16384") || !swift.includes("case .smallModelComputerUse: 12288")) throw new Error("Review changed production config");
const config: Record<string, unknown> = Object.fromEntries(entries.map(([, key, value]) => [key,
  value === "context.contextWindow" ? 16384 : value === "compactLimit" ? 12288 : JSON.parse(value)]));
if (config["features.shell_tool"] !== false || config["features.unified_exec"] !== false || config.web_search !== "disabled") throw new Error("Unsafe production config");
const artifactDir = join(repo, "Sources/Mactopus/Resources/AgentRuntime");
const manifestRaw = readBounded(join(artifactDir, "manifest.json"), 16384), manifest = JSON.parse(manifestRaw.toString());
const pin = JSON.parse(readBounded(join(repo, "Runtime/codex-source.lock.json"), 16384).toString());
const executable = join(artifactDir, "codex-app-server"), binary = readBounded(executable, 512 * 1024 * 1024);
if (manifest.schemaVersion !== 1 || manifest.platform !== "macos" || manifest.architecture !== "arm64"
    || manifest.executable !== "codex-app-server" || manifest.sourceCommit !== pin.sourceCommit || manifest.patchSHA256 !== pin.patchSHA256
    || manifest.runtimeVersion !== pin.runtimeVersion || manifest.binarySize !== binary.length || manifest.binarySHA256 !== hash(binary)
    || hash(readBounded(join(repo, "Runtime/patches/compaction-retention.patch"))) !== pin.patchSHA256
    || binary.readUInt32LE(0) !== 0xfeedfacf || binary.readUInt32LE(4) !== 0x0100000c || binary.readUInt32LE(12) !== 2
    || !(lstatSync(executable).mode & 0o111)) throw new Error("Packaged runtime verification failed");

async function command(argv: string[], timeout = 8_000): Promise<string> {
  const child = Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill("SIGKILL"), timeout);
  try {
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    if (code !== 0 || stdout.length + stderr.length > 1024 * 1024) throw new Error("Preflight command failed");
    return stdout;
  } finally { clearTimeout(timer); }
}
async function idle() {
  const loaded = JSON.parse(await command([join(process.env.HOME!, ".lmstudio/bin/lms"), "ps", "--json"]));
  if (loaded.length !== 1 || loaded[0].identifier !== model || loaded[0].status !== "idle"
      || loaded[0].queued !== 0 || loaded[0].parallel !== 1) throw new Error("Sole 4B model must be idle, queued=0, parallel=1");
}
await command(["/usr/bin/codesign", "--verify", "--strict", executable]);
await idle();
const ownedHome = join(out, "codex-home");
mkdirSync(ownedHome, { mode: 0o700 });
const operationalConfig = { ...config, model, model_provider: "lmstudio", analytics: { enabled: false }, feedback: { enabled: false },
  otel: { exporter: "none", trace_exporter: "none", metrics_exporter: "none", log_user_prompt: false }, mcp_servers: {} };
// Startup-level CLI overrides prevent startup plugins/telemetry. Thread config
// below remains exactly production. No existing CODEX_HOME/config is modified.
const launchArgs = [executable, "--listen", "stdio://", ...Object.entries(operationalConfig).flatMap(([key, value]) =>
  ["-c", `${key}=${typeof value === "object" ? "{" + Object.entries(value as object).map(([k, v]) => `${k} = ${JSON.stringify(v)}`).join(", ") + "}" : JSON.stringify(value)}`])];
let threadID: string | undefined, turnID: string | undefined, terminal: any = null;
let stopReason: string | null = null, failure: string | null = null, callCount = 0, providerRequests = 0;
let stopping: Promise<void> | undefined, began = 0, child: ReturnType<typeof Bun.spawn> | undefined;
let shutdownSignal: string | null = null, wireBytes = 0, logBytes = 0;
const lifecycle: any[] = [], outgoing: any[] = [], pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void; timer: Timer }>();
const starts = new Map<string, any>(), seenCalls = new Set<string>();
const providerControllers = new Set<AbortController>();
const requestsAudit: any[] = [];
let nextID = 1, resolveTerminal: () => void = () => {};
const terminalPromise = new Promise<void>(resolve => { resolveTerminal = resolve; });
function record(direction: string, value: any) {
  const line = JSON.stringify({ at: new Date().toISOString(), direction, value }) + "\n";
  logBytes += Buffer.byteLength(line);
  if (logBytes > 16 * 1024 * 1024) throw new Error("Protocol evidence limit");
  appendFileSync(join(out, "protocol.ndjson"), line, { mode: 0o600 });
}
function send(value: any) { record("client", value); (child!.stdin as any).write(JSON.stringify(value) + "\n"); (child!.stdin as any).flush(); }
function rpc(method: string, params: any, milliseconds = 8_000): Promise<any> {
  const id = nextID++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`RPC timeout: ${method}`)); }, milliseconds);
    pending.set(id, { resolve, reject, timer }); send({ id, method, params });
  });
}
async function stop(reason: string) {
  stopReason ??= reason;
  if (!stopping) stopping = (async () => {
    if (threadID && turnID && !terminal) await rpc("turn/interrupt", { threadId: threadID, turnId: turnID }, 5_000);
  })();
  await stopping;
}
function crash(error: unknown) {
  failure ??= error instanceof Error ? error.message : "Diagnostic failure";
  void stop("diagnostic_failure").catch(() => {});
  resolveTerminal();
}
// The forwarder never alters a provider request or streaming response. Its
// first-request parity/tool gate runs BEFORE any inference can be sent.
const proxy = Bun.serve({ hostname: "127.0.0.1", port: 0, idleTimeout: 100, async fetch(request) {
  const url = new URL(request.url);
  try {
    if (request.method === "GET" && url.pathname === "/v1/models") {
      return await fetch("http://127.0.0.1:1234/v1/models", { redirect: "error", signal: AbortSignal.timeout(5_000) });
    }
    if (request.method !== "POST" || url.pathname !== "/v1/responses" || url.search || stopReason || ++providerRequests > 6) throw new Error("Unexpected provider request");
    const body = await request.text();
    if (Buffer.byteLength(body) > 2 * 1024 * 1024) throw new Error("Provider request bound");
    // Retain rejected requests privately too: serialization mismatches must be
    // inspected, not bypassed. This is before forwarding to the model.
    writeFileSync(join(out, `provider-${providerRequests}-request.json`), body, { mode: 0o600 });
    const payload = JSON.parse(body);
    const names = (payload.tools ?? []).map((t: any) => t.name).sort();
    if (payload.model !== model || payload.instructions !== instructions || canonical(names) !== canonical(expectedNames)) throw new Error("Wire model/instructions/tools mismatch");
    for (const tool of dynamicTools) {
      const wire = payload.tools.find((t: any) => t.name === tool.name);
      if (wire?.type !== "function" || wire.description !== tool.description || canonical(wire.parameters) !== canonical(expectedWireSchema(tool))) throw new Error("Wire dynamic schema mismatch");
    }
    const wireUsers = (payload.input ?? []).filter((i: any) => i.type === "message" && i.role === "user");
    if (wireUsers.length !== 2 || wireUsers.some((u: any, i: number) => canonical(u.content) !== canonical(users[i].content))) throw new Error("Wire inherited policy/task mismatch");
    const number = providerRequests;
    writeFileSync(join(out, `provider-${number}-request.json`), body, { mode: 0o600 });
    requestsAudit.push({ number, requestSHA256: hash(body), toolNames: names, instructionSHA256: hash(payload.instructions), policyAndTaskExact: true });
    const controller = new AbortController(); providerControllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 90_000);
    request.signal.addEventListener("abort", () => controller.abort(), { once: true });
    let response: Response;
    try { response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
      headers: { "content-type": "application/json", accept: "text/event-stream" }, body, signal: controller.signal }); }
    catch (e) { clearTimeout(timeout); providerControllers.delete(controller); throw e; }
    if (!response.ok || !response.body) { clearTimeout(timeout); providerControllers.delete(controller); throw new Error("Local provider failed"); }
    const digest = createHash("sha256");
    const stream = response.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, sink) {
        wireBytes += chunk.byteLength;
        if (wireBytes > 8 * 1024 * 1024) { controller.abort(); throw new Error("Provider response bound"); }
        digest.update(chunk); appendFileSync(join(out, `provider-${number}-response.bin`), chunk, { mode: 0o600 }); sink.enqueue(chunk);
      }, flush() { requestsAudit[number - 1].responseSHA256 = digest.digest("hex"); },
    }));
    const reader = stream.getReader();
    return new Response(new ReadableStream({ async pull(sink) {
      try { const chunk = await reader.read(); if (chunk.done) { clearTimeout(timeout); providerControllers.delete(controller); sink.close(); } else sink.enqueue(chunk.value); }
      catch (e) { clearTimeout(timeout); providerControllers.delete(controller); sink.error(e); }
    }, cancel() { clearTimeout(timeout); providerControllers.delete(controller); controller.abort(); return reader.cancel(); } }),
    { status: response.status, headers: { "content-type": response.headers.get("content-type") ?? "text/event-stream" } });
  } catch (error) { crash(error); return new Response("Diagnostic provider gate rejected request", { status: 502 }); }
} });

async function serverRequest(message: any) {
  const p = message.params ?? {};
  if (message.method === "item/tool/call") {
    callCount++;
    if (p.threadId !== threadID || p.turnId !== turnID || seenCalls.has(p.callId) || p.namespace != null) throw new Error("Tool identity mismatch");
    seenCalls.add(p.callId);
    const started = starts.get(p.callId);
    if (!started || started.tool !== p.tool || canonical(started.arguments) !== canonical(p.arguments)) throw new Error("Missing matching item/started");
    lifecycle.push({ event: "tool/request", callID: p.callId, name: p.tool, argsSHA256: hash(canonical(p.arguments)) });
    const replay = receipts.get(p.tool);
    if (!stopReason && callCount < 6 && replay !== undefined && canonical(p.arguments) === "{}") {
      const text = p.tool === "computer_v2_apps" ? appsReceipt : replay;
      send({ id: message.id, result: { success: true, contentItems: [{ type: "inputText", text }] } });
      lifecycle.push({ event: "tool/replayed", callID: p.callId, name: p.tool, outputSHA256: hash(text), source: "recorded_baseline_not_live" });
      return;
    }
    outgoing.push({ callID: p.callId, tool: p.tool, arguments: p.arguments });
    await stop(callCount >= 6 ? "call_limit" : "next_action_observed");
    send({ id: message.id, result: { success: false, contentItems: [{ type: "inputText", text: "Diagnostic only: this action was NOT executed. The owning turn was interrupted; no computer input was sent." }] } });
    lifecycle.push({ event: "tool/declined_after_interrupt", callID: p.callId, name: p.tool });
    return;
  }
  await stop("unexpected_server_request");
  const result = message.method === "item/commandExecution/requestApproval" || message.method === "item/fileChange/requestApproval" ? { decision: "cancel" }
    : message.method === "item/permissions/requestApproval" ? { permissions: {}, scope: "turn" }
    : message.method === "item/tool/requestUserInput" ? { answers: {} }
    : message.method === "mcpServer/elicitation/request" ? { action: "cancel", content: null } : undefined;
  send(result ? { id: message.id, result } : { id: message.id, error: { code: -32601, message: "Diagnostic denies this server request" } });
}
function receive(message: any) {
  record("server", message);
  if (message.method && message.id !== undefined) { void serverRequest(message).catch(crash); return; }
  if (!message.method && message.id !== undefined) {
    const waiter = pending.get(message.id); if (!waiter) return;
    clearTimeout(waiter.timer); pending.delete(message.id);
    message.error ? waiter.reject(new Error("App Server RPC rejected request")) : waiter.resolve(message.result); return;
  }
  const p = message.params ?? {};
  if (message.method === "turn/started" && p.threadId === threadID) turnID = p.turn.id;
  if (["item/started", "item/completed"].includes(message.method) && p.threadId === threadID) {
    const item = p.item;
    if (item?.type === "dynamicToolCall") {
      if (message.method === "item/started") starts.set(item.id, item);
      lifecycle.push({ event: message.method, callID: item.id, name: item.tool, status: item.status, success: item.success ?? null });
    } else if (["commandExecution", "fileChange", "mcpToolCall", "collabAgentToolCall", "webSearch"].includes(item?.type)) crash(new Error("Unexpected built-in execution item"));
  }
  if (message.method === "turn/completed" && p.threadId === threadID && p.turn?.id === turnID) {
    terminal = p.turn; lifecycle.push({ event: "turn/completed", status: terminal.status }); resolveTerminal();
  }
}
const env: Record<string, string> = {};
for (const key of ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "TZ"]) if (process.env[key]) env[key] = process.env[key]!;
env.CODEX_HOME = ownedHome; env.CODEX_OSS_BASE_URL = `http://127.0.0.1:${proxy.port}/v1`;
env.CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED = "1";
save("setup.json", { arm, baselineSHA256: hash(baseline), manifest, manifestSHA256: hash(manifestRaw), swiftSHA256: hash(swift),
  config, instructionSHA256: hash(instructions), dynamicToolsSHA256: hash(canonical(dynamicTools)), promptSHA256: hash(prompt),
  statusSource: "recorded_baseline_not_live", header: header || null, candidateSourceSHA256: hash(readBounded(join(import.meta.dir, "inspection-routes.ts"))),
  hostContractSourceSHA256: arm === "host_contract" ? hash(readBounded(join(import.meta.dir, "host-contract.ts"))) : null,
  mentionSourceSHA256: arm === "explicit_mention" ? hash(readBounded(join(import.meta.dir, "explicit-app-mention.ts"))) : null,
  appReceiptChanged: appsReceipt !== receipts.get("computer_v2_apps"), appReceiptBytes: Buffer.byteLength(appsReceipt),
  cwd: meta.cwd, noComputerDispatch: true, transport: "owned App Server with identity-gated loopback forwarder", maxCalls: 6, maxTurnMS: 90_000 });
let deadline: Timer | undefined;
const onSignal = () => { void stop("operator_signal").finally(resolveTerminal).catch(() => {}); };
process.on("SIGINT", onSignal); process.on("SIGTERM", onSignal);
try {
  await idle();
  // Recheck the exact artifact immediately before spawn (no PATH resolution).
  if (hash(readBounded(executable, 512 * 1024 * 1024)) !== manifest.binarySHA256) throw new Error("Runtime changed before launch");
  child = Bun.spawn(launchArgs, { cwd: meta.cwd, env, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  void (async () => {
    let buffer = ""; const decoder = new TextDecoder();
    for await (const chunk of child!.stdout as ReadableStream<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });
      if (buffer.length > 2 * 1024 * 1024) throw new Error("NDJSON line bound");
      let end: number; while ((end = buffer.indexOf("\n")) >= 0) { const line = buffer.slice(0, end); buffer = buffer.slice(end + 1); if (line.trim()) receive(JSON.parse(line)); }
    }
    if (!terminal && !stopReason) throw new Error("Owned runtime ended before terminal event");
  })().catch(crash);
  void (async () => { let bytes = 0; for await (const chunk of child!.stderr as ReadableStream<Uint8Array>) {
    bytes += chunk.length; if (bytes > 2 * 1024 * 1024) throw new Error("Runtime stderr bound");
    appendFileSync(join(out, "runtime.stderr"), chunk, { mode: 0o600 });
  } })().catch(crash);
  await rpc("initialize", { clientInfo: { name: "local_codex", title: "Macndash", version: "0.1.0" }, capabilities: { experimentalApi: true } });
  send({ method: "initialized", params: {} });
  const effective = await rpc("config/read", { cwd: meta.cwd, includeLayers: true }); save("effective-config.json", effective);
  for (const [key, value] of Object.entries(config)) {
    const found = key.split(".").reduce((v: any, segment) => v?.[segment], effective.config);
    if (canonical(found) !== canonical(value)) throw new Error("Effective config differs from production override");
  }
  if (Object.keys(effective.config.mcp_servers ?? {}).length || effective.config.developer_instructions || effective.config.instructions
      || effective.config.analytics?.enabled !== false) throw new Error("Unexpected external tools/instructions/analytics");
  const start = await rpc("thread/start", { modelProvider: "lmstudio", model, cwd: meta.cwd, sandbox: "workspace-write", approvalPolicy: "on-request",
    ephemeral: false, threadSource: "local_codex", baseInstructions: instructions, config, dynamicTools });
  if (start.model !== model || start.modelProvider !== "lmstudio" || typeof start.thread?.id !== "string") throw new Error("Thread identity/provider mismatch");
  threadID = start.thread.id;
  if (failure || stopReason) throw new Error("Diagnostic stopped during setup");
  began = performance.now();
  deadline = setTimeout(() => { void stop("turn_time_limit").finally(resolveTerminal).catch(() => {}); }, 90_000);
  const turn = await rpc("turn/start", { threadId: threadID, input: [{ type: "text", text: prompt }], effort: context.effort, model });
  if (turnID && turn.turn?.id !== turnID) throw new Error("Turn identity mismatch");
  turnID = turn.turn?.id; if (!turnID) throw new Error("Missing turn identity");
  await terminalPromise;
  if (stopping) await stopping.catch(() => {});
  // A cancelled tool need not reach successful item/completed; report exactly
  // what happened instead of treating an intended next action as execution.
  save("first-next-action.json", outgoing);
} catch (error) { crash(error); }
finally {
  if (deadline) clearTimeout(deadline);
  if (child) {
    if (!terminal && threadID && turnID) await stop("shutdown").catch(() => {});
    if (!terminal && turnID) {
      // Give the actual interrupted terminal notification a bounded drain;
      // interrupt acknowledgement alone is not a completed-turn receipt.
      await new Promise<void>(resolve => { const timer = setTimeout(resolve, 2_000); void terminalPromise.then(() => { if (terminal) { clearTimeout(timer); resolve(); } }); });
    }
    for (const controller of providerControllers) controller.abort();
    try { (child.stdin as any).end(); } catch {}
    const exited = async (ms: number) => { let timer: Timer; const result = await Promise.race([child!.exited.then(() => true), new Promise<boolean>(r => { timer = setTimeout(() => r(false), ms); })]); clearTimeout(timer!); return result; };
    if (!await exited(3_000)) { shutdownSignal = "SIGTERM"; child.kill("SIGTERM"); }
    if (!await exited(2_000)) { shutdownSignal = "SIGKILL"; child.kill("SIGKILL"); }
    if (!await exited(2_000)) failure ??= "Owned child did not exit within shutdown bound";
  }
  for (const waiter of pending.values()) { clearTimeout(waiter.timer); waiter.reject(new Error("Owned runtime shutdown")); }
  pending.clear(); proxy.stop(true); process.off("SIGINT", onSignal); process.off("SIGTERM", onSignal);
  const expectedTerminal = terminal?.status === "completed" && !stopReason
    || terminal?.status === "interrupted" && stopReason === "next_action_observed" && outgoing.length === 1 && callCount < 6;
  if (terminal && (terminal.error || !expectedTerminal)) failure ??= "Unexpected terminal status/error";
  const summary = { arm, state: failure ? "failed" : terminal ? "terminal_observed" : "no_terminal", failure,
    baselineSHA256: hash(baseline), runtimeSHA256: manifest.binarySHA256, model, statusSource: "recorded_baseline_not_live",
    turnMS: began ? Math.round(performance.now() - began) : null, threadID, turnID, ownedPID: child?.pid,
    stopReason, terminalStatus: terminal?.status ?? null, terminalError: terminal?.error ? true : false,
    callCount, nextCallNames: outgoing.map(c => c.tool), lifecycle, providerRequests, requestsAudit,
    shutdownSignal, childExitCode: child?.exitCode ?? null, noComputerDispatch: true,
    scope: "next-action routing only; recorded status/apps; no task execution or live capability proof" };
  save("summary.json", summary);
  console.log(JSON.stringify({ arm, state: summary.state, failure, stopReason, terminalStatus: summary.terminalStatus,
    callCount, nextCallNames: summary.nextCallNames, providerRequests, noComputerDispatch: true }));
  if (failure || !terminal) process.exitCode = 1;
}
