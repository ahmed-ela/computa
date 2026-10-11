import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { readRuntimePin } from "./runtime-source";

// Real pinned App Server, scripted local model responses. This tests request
// construction and persistence, never ChatGPT behavior or the Swift AX executor.
// Run: bun test Scripts/persistent-instructions.integration.test.ts
// Optional: COMPUTA_INSTRUCTION_TEST_RESOURCES=/absolute/Contents/Resources
const root = resolve(import.meta.dir, "..");
type Json = Record<string, any>;
const model = "browser/chatgpt";
const toolMarker = "COMPUTA_PROTOCOL_TOOL_RESULT";
const dynamicMarker = "COMPUTA_PROTOCOL_DYNAMIC_RESULT";

async function runtimeResources() {
  const explicit = process.env.COMPUTA_INSTRUCTION_TEST_RESOURCES;
  if (explicit !== undefined) {
    if (!explicit.startsWith("/")) throw new Error("Resources must be absolute.");
    return explicit;
  }
  for (const resources of [join(homedir(), "Applications/Computa.app/Contents/Resources"),
    join(root, "Sources/Computa/Resources")]) {
    try {
      await lstat(join(resources, "AgentRuntime/manifest.json"));
      return resources;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  return undefined;
}

const resources = await runtimeResources();
if (resources === undefined) console.log("SKIP persistent-instructions protocol qualification: pinned App Server resources absent; set COMPUTA_INSTRUCTION_TEST_RESOURCES to an absolute Resources directory.");

async function trustedRuntime() {
  if (resources === undefined) throw new Error("Pinned App Server resources absent.");
  const directory = join(resources, "AgentRuntime");
  const manifest = JSON.parse(await readFile(join(directory, "manifest.json"), "utf8"));
  const pin = await readRuntimePin(root);
  expect(manifest.sourceCommit).toBe(pin.sourceCommit);
  expect(manifest.patchSHA256).toBe(pin.patchSHA256);
  expect(manifest.runtimeVersion).toBe(pin.runtimeVersion);
  expect(manifest.executable).toBe("codex-app-server");
  const binary = join(directory, manifest.executable);
  const stat = await lstat(binary);
  expect(stat.isFile() && !stat.isSymbolicLink()).toBe(true);
  expect(stat.size).toBe(manifest.binarySize);
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(binary)) digest.update(chunk);
  expect(digest.digest("hex")).toBe(manifest.binarySHA256);
  return { binary, pin, binarySHA256: manifest.binarySHA256 };
}

function literal(source: string, name: string) {
  const match = source.match(new RegExp(`static let ${name} = """\\n([\\s\\S]*?)\\n    """`));
  if (!match || match[1].includes("\\(")) throw new Error(`Not an un-interpolated app literal: ${name}`);
  return match[1].split("\n").map(line => line.startsWith("    ") ? line.slice(4) : line).join("\n");
}

async function appInstructions() {
  const app = await readFile(join(root, "Sources/Computa/Runtime/ComputaAgentInstructions.swift"), "utf8");
  const runtime = await readFile(join(root, "Sources/Computa/Runtime/CodexAppServerRuntime.swift"), "utf8");
  const base = runtime.match(/baseInstructions: """\n([\s\S]*?)\n                """/)?.[1];
  if (!base || base.includes("\\(")) throw new Error("App base literal unavailable.");
  return {
    base: base.split("\n").map(line => line.startsWith("                ") ? line.slice(16) : line).join("\n"),
    // Match the app's reference-tool developer bundle. Legacy scope and the
    // model-specific Swift base additions are intentionally separate coverage.
    developer: ["scope", "ordinaryRequests", "capabilityEvidence", "finalResponse", "taskCompletion", "codeEditing", "commandLine"]
      .map(name => literal(app, name)).join("\n\n"),
  };
}

function message(text: string) {
  return { type: "message", id: "msg_fixture", role: "assistant", status: "completed",
    content: [{ type: "output_text", text, annotations: [] }] };
}

function sse(output: Json[]) {
  const response = { id: crypto.randomUUID(), object: "response", created_at: 1, model,
    status: "completed", output, usage: { input_tokens: 200, output_tokens: 20, total_tokens: 220 } };
  const events = [{ type: "response.created", response: { ...response, status: "in_progress", output: [] } },
    ...output.map((item, output_index) => ({ type: "response.output_item.done", item, output_index })),
    { type: "response.completed", response }];
  return new Response(events.map((value, sequence_number) => {
    const event = { ...value, sequence_number };
    return `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
  }).join(""), { headers: { "Content-Type": "text/event-stream" } });
}

function offered(body: Json) {
  return (body.tools ?? []).flatMap((tool: Json) => tool.type === "namespace"
    ? tool.tools.map((child: Json) => ({ ...child, namespace: tool.name })) : [tool]);
}

function functionCall(body: Json, name: string, args: Json) {
  const spec = offered(body).find((tool: Json) => tool.name === name);
  if (!spec) throw new Error(`Current request does not offer ${name}`);
  return { type: "function_call", id: "fc_" + crypto.randomUUID(), call_id: "call_" + crypto.randomUUID(),
    name, ...(spec.namespace ? { namespace: spec.namespace } : {}), arguments: JSON.stringify(args), status: "completed" };
}

class Rpc {
  readonly frames: Json[] = [];
  readonly pending = new Map<number, { resolve: (value: Json) => void; reject: (error: Error) => void }>();
  private nextID = 0;
  readonly process: ReturnType<typeof Bun.spawn>;
  private readonly reader: Promise<void>;
  private readonly stderr: Promise<string>;
  failure: Error | undefined;

  constructor(binary: string, home: string, workspace: string) {
    // The entire owned process tree may contact this fixture's loopback model;
    // attempted external network is denied, including unexpected startup calls.
    const policy = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))';
    this.process = Bun.spawn(["/usr/bin/sandbox-exec", "-p", policy, binary, "--listen", "stdio://",
      "-c", "project_root_markers=[]", "-c", "allow_login_shell=false",
      "-c", 'cli_auth_credentials_store="file"', "-c", 'mcp_oauth_credentials_store="file"'], {
      cwd: workspace, env: { HOME: join(home, "ProcessHome"), CODEX_HOME: home,
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", LANG: "en_US.UTF-8" },
      stdin: "pipe", stdout: "pipe", stderr: "pipe",
    });
    this.stderr = new Response(this.process.stderr).text();
    this.reader = this.read();
  }

  private async read() {
    const reader = (this.process.stdout as ReadableStream<Uint8Array>).getReader();
    const decoder = new TextDecoder();
    let pending = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        pending += decoder.decode(value, { stream: true });
        if (pending.length > 2_000_000) throw new Error("Oversized private fixture RPC frame.");
        for (;;) {
          const newline = pending.indexOf("\n");
          if (newline < 0) break;
          const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
          if (!line.trim()) continue;
          const frame = JSON.parse(line);
          if (this.frames.length >= 2000) throw new Error("Private fixture exceeded frame budget.");
          this.frames.push(frame);
          if (frame.method && frame.id !== undefined) {
            if (frame.method !== "item/tool/call" || frame.params.tool !== "computer_v2_status") {
              this.failure = new Error(`Unexpected native request: ${frame.method}`);
              this.send({ id: frame.id, result: { decision: "decline" } });
            } else {
              this.send({ id: frame.id, result: { success: true,
                contentItems: [{ type: "inputText", text: dynamicMarker }] } });
            }
          } else if (typeof frame.id === "number") {
            const request = this.pending.get(frame.id);
            this.pending.delete(frame.id);
            if (frame.error) request?.reject(new Error(JSON.stringify(frame.error)));
            else request?.resolve(frame.result);
          }
        }
      }
    } catch (error) {
      this.failure = error as Error;
    } finally {
      const detail = (await this.stderr).slice(0, 2000);
      for (const request of this.pending.values()) request.reject(this.failure ?? new Error(`App Server ended: ${detail}`));
      this.pending.clear();
    }
  }

  private send(value: Json) { (this.process.stdin as any).write(JSON.stringify(value) + "\n"); }
  request(method: string, params: Json = {}) {
    const id = ++this.nextID;
    const result = new Promise<Json>((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.send({ id, method, params });
    return bounded(result, method);
  }
  notify(method: string) { this.send({ method }); }
  async initialize() {
    await this.request("initialize", { clientInfo: { name: "computa_instruction_fixture", version: "1" },
      capabilities: { experimentalApi: true } });
    this.notify("initialized");
  }
  async completed(threadID: string, start: number) {
    return bounded((async () => {
      for (;;) {
        if (this.failure) throw this.failure;
        if (this.process.exitCode !== null) throw new Error("App Server exited before turn completion.");
        const event = this.frames.slice(start).find(frame => frame.method === "turn/completed" && frame.params.threadId === threadID);
        if (event) { expect(event.params.turn.status).toBe("completed"); return event; }
        await Bun.sleep(10);
      }
    })(), "turn completion");
  }
  async turn(threadID: string, text: string) {
    const start = this.frames.length;
    await this.request("turn/start", { threadId: threadID, input: [{ type: "text", text }] });
    await this.completed(threadID, start);
  }
  async close() {
    (this.process.stdin as any).end();
    try { await bounded(this.process.exited, "owned App Server exit", 5000); }
    catch { this.process.kill("SIGTERM"); await bounded(this.process.exited, "owned App Server termination", 5000); }
    await this.reader;
    await this.stderr;
  }
}

async function bounded<T>(promise: Promise<T>, label: string, milliseconds = 30_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Deadline: ${label}`)), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

function contains(body: Json, text: string): boolean {
  function walk(value: any): boolean {
    if (typeof value === "string") return value.includes(text);
    if (Array.isArray(value)) return value.some(walk);
    if (value && typeof value === "object") return Object.values(value).some(walk);
    return false;
  }
  return walk(body.input);
}
function developerContains(body: Json, text: string): boolean {
  return Array.isArray(body.input) && body.input.some((item: Json) => {
    if (item.type !== "message" || item.role !== "developer" || !Array.isArray(item.content)) return false;
    const actualText = item.content.filter((part: Json) => part.type === "input_text" && typeof part.text === "string")
      .map((part: Json) => part.text).join("");
    return actualText.includes(text);
  });
}
function assertRules(body: Json, rules: { base: string; developer: string }) {
  expect(body.instructions).toBe(rules.base);
  expect(developerContains(body, rules.developer)).toBe(true);
}

test("instruction oracle rejects identical quoted text outside the developer role", () => {
  const rules = { base: "PRIVATE_BASE", developer: "PRIVATE_DEVELOPER_SCOPE\n\nPRIVATE_DEVELOPER_COMMANDS" };
  const developer = { type: "message", role: "developer", content: [{ type: "input_text", text: rules.developer }] };
  expect(() => assertRules({ instructions: rules.base, input: [developer] }, rules)).not.toThrow();
  const quotes = [
    { type: "message", role: "user", content: [{ type: "input_text", text: rules.developer }] },
    { type: "message", role: "assistant", content: [{ type: "output_text", text: rules.developer }] },
    { type: "function_call_output", call_id: "call_quoted", output: rules.developer },
  ];
  for (const quoted of quotes) {
    const body = { instructions: rules.base, input: [quoted] };
    expect(contains(body, rules.developer)).toBe(true);
    expect(developerContains(body, rules.developer)).toBe(false);
    expect(() => assertRules(body, rules)).toThrow();
  }
  const splitAuthority = { instructions: rules.base, input: [
    { ...developer, content: [{ type: "input_text", text: "PRIVATE_DEVELOPER_SCOPE" }] },
    ...quotes,
  ] };
  expect(() => assertRules(splitAuthority, rules)).toThrow();
  expect(() => assertRules({ instructions: "WRONG_BASE", input: [developer] }, rules)).toThrow();
});

function assertToolContinuation(body: Json, call: Json, expectedOutput: string) {
  const retainedCall = body.input.find((item: Json) => item.type === "function_call" && item.call_id === call.call_id);
  expect(retainedCall?.name).toBe(call.name);
  expect(retainedCall?.arguments).toBe(call.arguments);
  const results = body.input.filter((item: Json) => item.type === "function_call_output" && item.call_id === call.call_id);
  expect(results).toHaveLength(1);
  const output = results[0].output;
  const containsOutput = typeof output === "string" ? output.includes(expectedOutput)
    : Array.isArray(output) && output.some((part: Json) => part.text?.includes(expectedOutput));
  if (!containsOutput) throw new Error(`Private fixture tool output does not contain its marker: ${JSON.stringify(output)}`);
  expect(containsOutput).toBe(true);
}

function assertTerminalSchemas(body: Json, baseline?: Json[]): Json[] {
  const specs = offered(body);
  const cli = ["exec_command", "write_stdin"].map(name => {
    const matches = specs.filter((tool: Json) => tool.name === name);
    expect(matches).toHaveLength(1);
    const tool = matches[0];
    expect(tool.type).toBe("function");
    expect(tool.parameters?.type).toBe("object");
    return tool;
  });
  if (baseline) expect(cli).toEqual(baseline);
  return cli;
}

test("terminal schema oracle rejects missing tools and changed full schemas", () => {
  const tools = [
    { type: "function", name: "exec_command", parameters: { type: "object", properties: { cmd: { type: "string" } } } },
    { type: "function", name: "write_stdin", parameters: { type: "object", properties: { session_id: { type: "integer" }, chars: { type: "string" } } } },
  ];
  const baseline = assertTerminalSchemas({ tools });
  expect(() => assertTerminalSchemas({ tools: structuredClone(tools) }, baseline)).not.toThrow();
  expect(() => assertTerminalSchemas({ tools: tools.slice(0, 1) }, baseline)).toThrow();
  const changed = structuredClone(tools);
  changed[1].parameters.properties.chars = { type: "number" };
  expect(() => assertTerminalSchemas({ tools: changed }, baseline)).toThrow();
  expect(() => assertTerminalSchemas({ tools: [...tools, tools[0]] }, baseline)).toThrow();
});

test.skipIf(resources === undefined)("pinned App Server retains app instructions across tools, cold resume, compaction and 80-message replay", async () => {
  const runtime = await trustedRuntime();
  const rules = await appInstructions();
  const directory = await mkdtemp(join(tmpdir(), "computa-instruction-protocol-"));
  const home = join(directory, "EngineHome");
  const workspace = join(home, "Workspace");
  await mkdir(join(home, "ProcessHome"), { recursive: true });
  await mkdir(workspace, { recursive: true });
  const requests: Json[] = [];
  const plans: Array<(body: Json) => Json[]> = [];
  let modelFailure: Error | undefined;
  let compacting = false;
  let baselineCliSchemas: Json[] | undefined;
  let regularSchemaAssertions = 0;
  let compactSchemaAssertions = 0;
  const endpoint = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/v1/responses") return new Response("fixture", { status: 404 });
    try {
      const body = await request.json() as Json;
      requests.push(body);
      const plan = plans.shift();
      if (!plan) throw new Error("Unexpected model inference.");
      if (compacting) {
        expect(offered(body)).toHaveLength(0);
        compactSchemaAssertions++;
      } else {
        baselineCliSchemas = assertTerminalSchemas(body, baselineCliSchemas);
        regularSchemaAssertions++;
      }
      return sse(plan(body));
    } catch (error) { modelFailure = error as Error; return new Response("Fixture assertion failed", { status: 400 }); }
  } });
  const config = { "project_root_markers": [], "allow_login_shell": false,
    "features.shell_snapshot": false, "features.shell_snapshot_v2": false,
    "memories.use_memories": false, "skills.include_instructions": false,
    "include_permissions_instructions": true, "include_apps_instructions": false, "include_environment_context": false,
    "features.plugins": false, "features.apps": false, "features.browser_use": false, "features.computer_use": false,
    "features.goals": false, "features.image_generation": false, "features.in_app_browser": false,
    "features.multi_agent": false, "features.multi_agent_v2": false,
    "features.shell_tool": true, "features.unified_exec": true, "features.view_image": false,
    "features.sleep_tool": false, "features.workspace_dependencies": false,
    "web_search": "disabled", "model_context_window": 32768, "model_auto_compact_token_limit": 28000,
    "model_providers.computa_fixture": { name: "Private instruction fixture", base_url: `http://127.0.0.1:${endpoint.port}/v1`,
      wire_api: "responses", requires_openai_auth: false, supports_websockets: false, request_max_retries: 0, stream_max_retries: 0 } };
  // macOS refuses nested sandbox-exec profiles. The outer owned-process
  // sandbox denies external network; only the scripted /usr/bin/printf runs.
  // This instruction fixture uses the app's permissions boilerplate, but its
  // outer sandbox and inner approval policy differ from both app access modes.
  const common = { model, modelProvider: "computa_fixture", cwd: workspace, sandbox: "danger-full-access",
    approvalPolicy: "on-request", baseInstructions: rules.base, developerInstructions: rules.developer, config };
  let rpc: Rpc | undefined;
  try {
    rpc = new Rpc(runtime.binary, home, workspace);
    await rpc.initialize();
    const started = await rpc.request("thread/start", { ...common, ephemeral: false, threadSource: "local_codex",
      dynamicTools: [{ name: "computer_v2_status", description: "Read this private fixture's status.",
        inputSchema: { type: "object", properties: {}, additionalProperties: false } }] });
    const threadID = started.thread.id;

    let terminalCall: Json | undefined;
    let dynamicCall: Json | undefined;
    plans.push(body => {
      assertRules(body, rules);
      expect(offered(body).map((tool: Json) => tool.name)).toContain("write_stdin");
      terminalCall = functionCall(body, "exec_command", { cmd: `/usr/bin/printf '${toolMarker}\\n'`, workdir: workspace, max_output_tokens: 1000 });
      return [terminalCall];
    }, body => { assertRules(body, rules); assertToolContinuation(body, terminalCall!, toolMarker); return [message("CLI fixture complete")]; });
    await rpc.turn(threadID, "Read the private protocol fixture's terminal status.");
    const command = rpc.frames.find(frame => frame.method === "item/completed" && frame.params.item.type === "commandExecution");
    expect(command?.params.item.exitCode).toBe(0);
    expect(command?.params.item.aggregatedOutput).toContain(toolMarker);
    plans.push(body => { assertRules(body, rules); dynamicCall = functionCall(body, "computer_v2_status", {}); return [dynamicCall]; }, body => {
      assertRules(body, rules); assertToolContinuation(body, dynamicCall!, dynamicMarker); return [message("Native fixture complete")];
    });
    await rpc.turn(threadID, "Read the private fixture's native status.");
    expect(rpc.frames.filter(frame => frame.method === "item/tool/call")).toHaveLength(1);

    await rpc.close(); rpc = new Rpc(runtime.binary, home, workspace); await rpc.initialize();
    await rpc.request("thread/resume", { ...common, threadId: threadID, excludeTurns: true });
    plans.push(body => {
      assertRules(body, rules);
      expect(offered(body).map((tool: Json) => tool.name)).toContain("computer_v2_status");
      assertToolContinuation(body, terminalCall!, toolMarker);
      assertToolContinuation(body, dynamicCall!, dynamicMarker);
      return [message("Cold resume complete")];
    });
    await rpc.turn(threadID, "Continue after reopening the private fixture.");

    plans.push(body => {
      assertRules(body, rules); expect(offered(body)).toHaveLength(0);
      return [message("Private fixture summary: terminal and native status completed. No action remains pending.")];
    });
    const compactStart = rpc.frames.length;
    compacting = true;
    try {
      await rpc.request("thread/compact/start", { threadId: threadID });
      await rpc.completed(threadID, compactStart);
    } finally { compacting = false; }
    plans.push(body => { assertRules(body, rules); expect(offered(body).length).toBeGreaterThan(0); return [message("Post-compaction complete")]; });
    await rpc.turn(threadID, "Continue after context maintenance.");

    const history = Array.from({ length: 80 }, (_, i) => ({ type: "message", role: i % 2 ? "assistant" : "user",
      content: [{ type: i % 2 ? "output_text" : "input_text", text: `SYNTHETIC_HISTORY_${i.toString().padStart(2, "0")}` }] }));
    const replay = await rpc.request("thread/resume", { ...common, threadId: crypto.randomUUID(), history, excludeTurns: true });
    expect(replay.thread.id).not.toBe(threadID);
    plans.push(body => {
      assertRules(body, rules);
      for (let i = 0; i < 80; i++) expect(contains(body, `SYNTHETIC_HISTORY_${i.toString().padStart(2, "0")}`)).toBe(true);
      return [message("Long-history fixture complete")];
    });
    await rpc.turn(replay.thread.id, "Inspect the final retained context.");

    // Measure whether cold resume refreshes developer overrides in an existing
    // history, separately from the retained-instructions assertions above.
    const developerOverrideObserved: boolean[] = [];
    for (let revision = 1; revision <= 2; revision++) {
      await rpc.close(); rpc = new Rpc(runtime.binary, home, workspace); await rpc.initialize();
      const marker = `COMPUTA_PRIVATE_DEVELOPER_REVISION_${revision}`;
      const updated = { base: rules.base + `\n\nCOMPUTA_PRIVATE_BASE_REVISION_${revision}`,
        developer: rules.developer + `\n\n${marker}` };
      await rpc.request("thread/resume", { ...common, threadId: threadID, excludeTurns: true,
        baseInstructions: updated.base, developerInstructions: updated.developer });
      plans.push(body => {
        expect(body.instructions).toBe(updated.base);
        developerOverrideObserved.push(developerContains(body, marker));
        expect(offered(body).map((tool: Json) => tool.name)).toContain("computer_v2_status");
        return [message("Developer-override observation complete")];
      });
      await rpc.turn(threadID, "Observe only this private fixture's retained context.");
    }
    if (modelFailure) throw modelFailure;
    expect(plans).toHaveLength(0);
    expect(requests).toHaveLength(10);
    expect(developerOverrideObserved).toHaveLength(2);
    expect(regularSchemaAssertions).toBe(9);
    expect(compactSchemaAssertions).toBe(1);
    console.log(JSON.stringify({ verified: true, sourceCommit: runtime.pin.sourceCommit, binarySHA256: runtime.binarySHA256,
      actualModelRequests: requests.length, builtinTerminalContinuation: true, dynamicToolContinuation: true,
      exactTerminalSchemasRetained: regularSchemaAssertions, noToolsCompactionRequests: compactSchemaAssertions,
      coldResume: true, noToolsCompaction: true, postCompaction: true, syntheticHistoryMessages: 80,
      coldResumeDeveloperOverrideObserved: developerOverrideObserved, coldResumeBaseOverrideObserved: true,
      fixtureThreadSandbox: "danger-full-access inside outbound-denying OS sandbox",
      appLiteralSections: ["scope", "ordinaryRequests", "capabilityEvidence", "finalResponse", "taskCompletion", "codeEditing", "commandLine"],
      modelSpecificSwiftBaseAdditionsNotInstantiated: true, realChatGPTBehavior: false, externalNetworkDenied: true }));
  } catch (error) {
    throw modelFailure ?? error;
  } finally {
    try { if (rpc) await rpc.close(); }
    finally {
      endpoint.stop(true);
      await rm(directory, { recursive: true });
    }
  }
}, 180_000);
