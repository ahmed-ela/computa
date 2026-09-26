#!/Users/ahmedelamin/.bun/bin/bun
// Opt-in deterministic transport for real Macrouse V2 desktop execution.
// No LLM or owned Codex App Server is used. Only three fixed calls can be sent.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const root = process.env.CODEX_HOME;
if (!root) throw new Error("An isolated CODEX_HOME is required.");
const { pageURL } = JSON.parse(readFileSync(join(root, "native-focus.json"), "utf8"));
const url = new URL(pageURL);
if (url.protocol !== "https:" || url.hostname !== "example.com" || url.pathname !== "/"
    || !/^\?heydash_focus_id=[0-9A-F-]{36}$/i.test(url.search) || url.hash) {
  throw new Error("Only the exact disposable public nonce URL is permitted.");
}
const threadId = "native-focus-fixture-thread";
const turnId = "native-focus-fixture-turn";
const calls = [
  { tool: "computer_v2_open", arguments: { bundle_id: "com.google.Chrome", url: pageURL } },
  { tool: "computer_v2_snapshot", arguments: { query: "Example Domain" } },
  { tool: "computer_v2_keypress", arguments: { key: "l", modifiers: ["command"] } },
];
let index = 0;
let started = false;
let finished = false;
let waitingTimer: ReturnType<typeof setInterval> | undefined;
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: Record<string, unknown>) => emit({ method, params: { threadId, ...params } });
const mark = (name: string) => writeFileSync(join(root, name), "ready");
function finish(success: boolean) {
  if (finished) return;
  finished = true;
  if (waitingTimer) clearInterval(waitingTimer);
  if (success) notify("item/completed", { turnId, item: {
    id: "native-focus-answer", type: "agentMessage", phase: "final_answer", text: "NATIVE_FOCUS_FIXTURE_COMPLETE",
  } });
  else mark("gate-failed");
  notify("turn/completed", { turn: { id: turnId, status: success ? "completed" : "failed",
    error: success ? null : { message: "The bounded native-focus fixture failed." }, items: [] } });
}
function sendCall() {
  if (finished) return;
  const call = calls[index];
  const id = `native-focus-call-${index}`;
  notify("item/started", { turnId, item: { id, type: "dynamicToolCall", status: "inProgress", ...call } });
  emit({ id: `native-focus-request-${index}`, method: "item/tool/call", params: {
    threadId, turnId, callId: id, ...call,
  } });
}
const lines = createInterface({ input: process.stdin });
lines.on("line", line => {
  const request = JSON.parse(line);
  if (!Object.hasOwn(request, "id")) return;
  if (!request.method) {
    if (finished || request.id !== `native-focus-request-${index}`) return;
    const response = request.result;
    const success = response?.success === true && Array.isArray(response.contentItems);
    notify("item/completed", { turnId, item: { id: `native-focus-call-${index}`,
      type: "dynamicToolCall", status: "completed", ...calls[index], success,
      contentItems: response?.contentItems ?? [],
    } });
    if (!success) return finish(false);
    index += 1;
    if (index === calls.length) return finish(true);
    if (index === 1) {
      mark("opened");
      const deadline = Date.now() + 15_000;
      waitingTimer = setInterval(() => {
        if (Date.now() > deadline) return finish(false);
        if (!existsSync(join(root, "page-ready"))) return;
        clearInterval(waitingTimer);
        waitingTimer = undefined;
        sendCall();
      }, 20);
    } else sendCall();
    return;
  }
  switch (request.method) {
    case "initialize": result(request.id, { userAgent: "deterministic-native-focus-fixture" }); break;
    case "thread/list": result(request.id, { data: [], nextCursor: null }); break;
    case "thread/start": result(request.id, { thread: { id: threadId, turns: [] } }); break;
    case "thread/name/set": result(request.id); break;
    case "turn/start":
      if (started) { emit({ id: request.id, error: { code: -32600, message: "Only one fixture turn is permitted." } }); break; }
      started = true;
      result(request.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      setTimeout(sendCall, 10);
      break;
    case "turn/interrupt": result(request.id); finish(false); break;
    default: emit({ id: request.id, error: { code: -32601, message: "Unexpected native-focus fixture method." } });
  }
});
lines.on("close", () => process.exit(0));
