// Opt-in actual parent-crash probe. No UI, tools, downloads, or foreign-process adoption.
import { createHash, randomUUID } from "node:crypto";
import { lstatSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { completed, exactText, SSEDecoder, type Event } from "./stream-contract";

const repo = resolve(import.meta.dir, "../..");
const server = join(repo, "Sources/HeyDash/Resources/MLXServer/server.py");
const python = join(homedir(), "Library/Application Support/LocalCodex/VisualGrounding/venv/bin/python");
const modelRoot = join(homedir(), ".lmstudio/models");
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const endpoint = "http://127.0.0.1:1237";
const marker = "HEYDASH_PARENT_DEATH_MEMORY_OK";
const hash = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");
const delay = (ms: number) => Bun.sleep(ms);
const safeEnv = () => ({ HOME: homedir(), PATH: "/usr/bin:/bin:/usr/sbin:/sbin", PYTHONNOUSERSITE: "1",
  PYTHONDONTWRITEBYTECODE: "1", HF_HUB_OFFLINE: "1", TRANSFORMERS_OFFLINE: "1", HF_HUB_DISABLE_TELEMETRY: "1" });

type Identity = { pid: number; parent: number; started: string; command: string };
class LifecycleFailure extends Error {}
export function parseIdentity(value: string): Identity | null {
  const match = value.trim().match(/^(\d+)\s+(\d+)\s+([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+)$/);
  if (!match) return null;
  return { pid: Number(match[1]), parent: Number(match[2]), started: match[3].replace(/\s+/g, " "), command: match[4] };
}
export function sameProcess(a: Identity | null, b: Identity | null) {
  return a !== null && b !== null && a.pid === b.pid && a.started === b.started && a.command === b.command;
}
export function inspectHealth(value: any, nonce: string) {
  if (value?.status !== "healthy" || value?.backend !== "mlx-vlm" || value?.version !== "0.7.1"
      || value?.heydash_instance !== nonce || value?.context_limit !== 16384 || typeof value?.busy !== "boolean"
      || !["active_bytes", "cache_bytes", "peak_bytes"].every(k => Number.isFinite(value?.memory?.[k]) && value.memory[k] >= 0)) {
    throw new LifecycleFailure("Owned server identity/schema mismatch; do not adopt this listener");
  }
  return { busy: value.busy, memory: { active_bytes: value.memory.active_bytes,
    cache_bytes: value.memory.cache_bytes, peak_bytes: value.memory.peak_bytes } };
}

async function command(args: string[], timeoutMS = 5000) {
  const child = Bun.spawn(args, { stdin: "ignore", stdout: "pipe", stderr: "ignore", env: safeEnv() });
  const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMS);
  try {
    const output = await new Response(child.stdout).text();
    const code = await child.exited;
    return { code, output };
  } finally { clearTimeout(timer); }
}
async function identity(pid: number) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return null;
  const result = await command(["/bin/ps", "-p", String(pid), "-o", "pid=,ppid=,lstart=,command="]);
  return result.code === 0 ? parseIdentity(result.output) : null;
}
async function portFree() {
  return new Promise<boolean>(resolveResult => {
    const probe = createServer();
    probe.once("error", () => resolveResult(false));
    probe.listen({ host: "127.0.0.1", port: 1237, exclusive: true }, () => probe.close(() => resolveResult(true)));
  });
}
async function health(nonce: string, signal?: AbortSignal) {
  const response = await fetch(endpoint + "/health", { redirect: "error",
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(1000)]) : AbortSignal.timeout(1000) });
  if (!response.ok) throw new LifecycleFailure("Health HTTP failure");
  const bytes = await response.text();
  if (bytes.length > 32000) throw new LifecycleFailure("Health response exceeds bound");
  return inspectHealth(JSON.parse(bytes), nonce);
}
async function physicalFootprint(pid: number) {
  const result = await command(["/usr/bin/vmmap", "-summary", String(pid)], 8000);
  // Retain only memory totals, never the map, command arguments, or stack data.
  const total = result.output.match(/^Physical footprint:\s*(.+)$/m)?.[1]?.trim() ?? null;
  const peak = result.output.match(/^Physical footprint \(peak\):\s*(.+)$/m)?.[1]?.trim() ?? null;
  return { commandExit: result.code, physicalFootprint: total, peakPhysicalFootprint: peak };
}

async function supervise(nonce: string) {
  if (!/^[a-f0-9-]{36}$/.test(nonce)) throw new LifecycleFailure("Invalid supervisor nonce");
  const child = Bun.spawn([python, "-u", server, "--model-root", modelRoot, "--port", "1237",
    "--parent-pid", String(process.pid)], { stdin: "ignore", stdout: "ignore", stderr: "ignore",
    cwd: modelRoot, env: { ...safeEnv(), HEYDASH_MLX_INSTANCE: nonce } });
  // The runner owns this direct supervisor handle and validates this child's OS
  // identity independently before sending any signal. No model payloads here.
  console.log(JSON.stringify({ supervisorPID: process.pid, childPID: child.pid, nonce }));
  let closing = false;
  const stop = async () => {
    if (closing) return;
    closing = true;
    if (child.exitCode === null) child.kill("SIGTERM");
    const timer = setTimeout(() => { if (child.exitCode === null) child.kill("SIGKILL"); }, 5000);
    await child.exited;
    clearTimeout(timer);
  };
  process.on("SIGINT", stop); process.on("SIGTERM", stop);
  await child.exited;
  process.off("SIGINT", stop); process.off("SIGTERM", stop);
}

async function loadedMarker(nonce: string, signal: AbortSignal) {
  const before = await health(nonce, signal);
  if (before.busy) throw new LifecycleFailure("Owned server is unexpectedly busy; no inference was sent");
  const policy = readFileSync(join(homedir(), "AGENTS.md"), "utf8");
  const request = { model, instructions: "You are HeyDash. This is a read-only local memory-lifecycle test. No tools are available.",
    input: [{ type: "message", role: "user", content: [{ type: "input_text", text: policy }] },
      { type: "message", role: "user", content: [{ type: "input_text", text: `Reply only ${marker}. Do not use tools.` }] }],
    tools: [], stream: true, store: false, reasoning: { effort: "none" }, temperature: 0.1, max_output_tokens: 1024 };
  const started = performance.now();
  const response = await fetch(endpoint + "/v1/responses", { method: "POST", redirect: "error",
    signal: AbortSignal.any([signal, AbortSignal.timeout(120000)]), headers: { "content-type": "application/json" },
    body: JSON.stringify(request) });
  if (!response.ok || !response.headers.get("content-type")?.includes("text/event-stream") || !response.body) {
    throw new LifecycleFailure("Synthetic marker transport failed");
  }
  const reader = response.body.getReader(), decoder = new TextDecoder(), parser = new SSEDecoder();
  const events: Event[] = [];
  let bytes = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) { events.push(...parser.push(decoder.decode())); parser.finish(); break; }
      bytes += chunk.value.length;
      if (bytes > 4 * 1024 * 1024) throw new LifecycleFailure("Synthetic marker stream exceeds bound");
      events.push(...parser.push(decoder.decode(chunk.value, { stream: true })));
    }
    const final = completed(events, model);
    exactText(events, final, marker);
    const after = await health(nonce, signal);
    if (after.busy || after.memory.active_bytes <= 0) throw new LifecycleFailure("Loaded model idle/memory evidence missing");
    return { exactMarker: true, noTools: true, elapsedMS: performance.now() - started,
      requestSHA256: hash(JSON.stringify(request)), inheritedPolicySHA256: hash(policy),
      eventsSHA256: hash(JSON.stringify(events)), eventCount: events.length, bytes,
      usage: { input_tokens: final.usage.input_tokens, output_tokens: final.usage.output_tokens, total_tokens: final.usage.total_tokens }, after };
  } finally { await reader.cancel().catch(() => {}); }
}

async function run(out: string, load: boolean) {
  if (!isAbsolute(out)) throw new LifecycleFailure("Absolute private output directory required");
  const info = lstatSync(out);
  if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o777) !== 0o700 || readdirSync(out).length
      || resolve(out).startsWith(repo + "/") || resolve(out) === repo) {
    throw new LifecycleFailure("Fresh external mode-0700 output directory required");
  }
  const nonce = randomUUID(), controller = new AbortController();
  const summary: any = { state: "preflight", load4BExplicitlyRequested: load, model, endpoint, nonce,
    inferenceLaneRequirement: "Run only when HeyDash and all other inference producers are idle/stopped.",
    limitations: "Process disappearance releases its allocations; this is not a matched RAM A/B or whole-system free-memory measurement.",
    sourceHashes: Object.fromEntries([import.meta.path, server, join(resolve(server, ".."), "response_boundary.py"),
      join(resolve(server, ".."), "sse_contract.py"), join(import.meta.dir, "stream-contract.ts")]
      .map(path => [path, hash(readFileSync(path))])) };
  const save = () => writeFileSync(join(out, "summary.json"), JSON.stringify(summary, null, 2), { mode: 0o600 });
  const stop = () => controller.abort("Operator interrupted lifecycle probe");
  process.on("SIGINT", stop); process.on("SIGTERM", stop);
  let supervisor: ReturnType<typeof Bun.spawn> | null = null;
  let childIdentity: Identity | null = null;
  let expectedChildPID: number | null = null;
  try {
    save();
    if (!(await portFree())) throw new LifecycleFailure("Port1237 already occupied; nothing launched or stopped");
    if (!lstatSync(server).isFile() || !lstatSync(join(modelRoot, model, "config.json")).isFile()) throw new LifecycleFailure("Local source/4B weights unavailable");
    summary.state = "starting_owned_supervisor"; save();
    supervisor = Bun.spawn([process.execPath, import.meta.path, "--supervisor", nonce], {
      stdin: "ignore", stdout: "pipe", stderr: "ignore", env: safeEnv(), cwd: repo });
    const reader = (supervisor.stdout as ReadableStream<Uint8Array>).getReader();
    let handshakeTimer: ReturnType<typeof setTimeout> | undefined;
    let handshake = "";
    try {
      await Promise.race([(async () => {
        while (!handshake.includes("\n")) {
          const next = await reader.read();
          if (next.done) throw new LifecycleFailure("Supervisor exited before handshake");
          handshake += new TextDecoder().decode(next.value);
          if (handshake.length > 1024) throw new LifecycleFailure("Invalid supervisor handshake");
        }
      })(), new Promise((_, reject) => {
        handshakeTimer = setTimeout(() => reject(new LifecycleFailure("Supervisor handshake deadline")), 10000);
      })]);
    } finally { clearTimeout(handshakeTimer); await reader.cancel().catch(() => {}); reader.releaseLock(); }
    const report = JSON.parse(handshake.trim());
    if (report.supervisorPID !== supervisor.pid || report.nonce !== nonce || !Number.isSafeInteger(report.childPID) || report.childPID <= 1) {
      throw new LifecycleFailure("Supervisor ownership mismatch");
    }
    expectedChildPID = report.childPID;
    childIdentity = await identity(expectedChildPID);
    if (!childIdentity || childIdentity.parent !== supervisor.pid || !childIdentity.command.includes(server)
        || !childIdentity.command.includes(`--parent-pid ${supervisor.pid}`)) {
      childIdentity = null; throw new LifecycleFailure("Server OS parent/command identity mismatch");
    }
    summary.supervisorPID = supervisor.pid;
    summary.child = childIdentity;
    const readyDeadline = performance.now() + 60000;
    while (true) {
      controller.signal.throwIfAborted();
      if (supervisor.exitCode !== null) throw new LifecycleFailure("Supervisor/server exited during startup");
      try { summary.ready = await health(nonce, controller.signal); break; }
      catch (error) {
        if (error instanceof Error && error.message.includes("identity/schema")) throw error;
        if (performance.now() >= readyDeadline) throw new LifecycleFailure("Owned server readiness deadline");
        await delay(200);
      }
    }
    if (summary.ready.busy) throw new LifecycleFailure("Server unexpectedly busy at readiness");
    summary.preLoadFootprint = await physicalFootprint(expectedChildPID);
    if (load) {
      summary.state = "running_opt_in_marker"; save();
      summary.loadedMarker = await loadedMarker(nonce, controller.signal);
      summary.loadedFootprint = await physicalFootprint(expectedChildPID);
    }
    controller.signal.throwIfAborted();
    const current = await identity(expectedChildPID);
    if (!sameProcess(childIdentity, current) || current?.parent !== supervisor.pid || supervisor.exitCode !== null) {
      throw new LifecycleFailure("Ownership changed before crash test; no crash signal sent");
    }
    await health(nonce, controller.signal); // Reverify the exact instance before the crash.
    summary.state = "crashing_owned_supervisor"; save();
    const killedAt = performance.now();
    // Intentional hard crash of this runner's own direct child only. No process group kill.
    supervisor.kill("SIGKILL");
    await supervisor.exited;
    summary.supervisorExit = { exitCode: supervisor.exitCode, signal: supervisor.signalCode };
    const deadline = performance.now() + 10000;
    while (await identity(expectedChildPID)) {
      if (performance.now() >= deadline) throw new LifecycleFailure("Owned server outlived parent-watch deadline");
      await delay(100);
    }
    summary.childExitAfterParentDeathMS = performance.now() - killedAt;
    summary.portFreeAfterParentDeath = await portFree();
    if (!summary.portFreeAfterParentDeath) throw new LifecycleFailure("Port was not free after owned child exit; no foreign listener will be stopped");
    summary.parentWatchPass = true;
    summary.state = load ? "passed_loaded_model_parent_death" : "passed_unloaded_parent_death_only";
  } catch (error) {
    summary.failurePhase = summary.state;
    summary.state = "failed";
    // Parser/network exceptions can contain upstream bytes. Only our fixed local
    // diagnostics are retained; responses and reasoning are never written out.
    summary.failure = error instanceof LifecycleFailure ? error.message : "Lifecycle probe failed or interrupted; provider detail withheld";
    process.exitCode = 1;
  } finally {
    controller.abort("Lifecycle probe cleanup");
    if (supervisor && supervisor.exitCode === null) {
      supervisor.kill("SIGTERM");
      await Promise.race([supervisor.exited, delay(6000)]);
      if (supervisor.exitCode === null) { supervisor.kill("SIGKILL"); await supervisor.exited; }
    }
    if (childIdentity) {
      let current = await identity(childIdentity.pid);
      if (sameProcess(childIdentity, current)) {
        summary.fallbackOwnedChildCleanupRequired = true;
        // PID start-time and full command must still match the original owned child.
        try { process.kill(childIdentity.pid, "SIGTERM"); }
        catch (error: any) { if (error?.code !== "ESRCH") summary.cleanupSignalFailed = true; }
        const deadline = performance.now() + 5000;
        do { await delay(100); current = await identity(childIdentity.pid); }
        while (sameProcess(childIdentity, current) && performance.now() < deadline);
        if (sameProcess(childIdentity, current)) {
          try { process.kill(childIdentity.pid, "SIGKILL"); }
          catch (error: any) { if (error?.code !== "ESRCH") summary.cleanupSignalFailed = true; }
          const killDeadline = performance.now() + 3000;
          do { await delay(100); current = await identity(childIdentity.pid); }
          while (sameProcess(childIdentity, current) && performance.now() < killDeadline);
        }
      }
      summary.childAbsentAtCleanup = (await identity(childIdentity.pid)) === null;
    }
    save(); process.off("SIGINT", stop); process.off("SIGTERM", stop);
    console.log(JSON.stringify({ state: summary.state, load4BExplicitlyRequested: load,
      parentWatchPass: summary.parentWatchPass ?? false, childExitAfterParentDeathMS: summary.childExitAfterParentDeathMS ?? null,
      portFreeAfterParentDeath: summary.portFreeAfterParentDeath ?? null, failure: summary.failure ?? null, summaryPath: join(out, "summary.json") }));
  }
}

if (import.meta.main) {
  const args = Bun.argv.slice(2);
  if (args[0] === "--supervisor" && args.length === 2) await supervise(args[1]);
  else if ((args.length === 1 || args.length === 2) && (args.length === 1 || args[1] === "--load-4b")) await run(args[0], args[1] === "--load-4b");
  else throw new LifecycleFailure("Usage: bun parent-death-live.ts /ABS/FRESH/PRIVATE/OUTPUT [--load-4b]");
}
