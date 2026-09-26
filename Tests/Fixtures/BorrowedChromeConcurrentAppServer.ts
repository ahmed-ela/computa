#!/Users/ahmedelamin/.bun/bin/bun
// Scripted App Server, NOT Qwen. Actual production Swift Core performs every
// tool. The test owns both headless tabs and injects one document navigation.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const root = process.env.CODEX_HOME!;
const fixtureURL = readFileSync(join(root, "agent-url"), "utf8");
const threadId = "concurrent-fixture-thread", turnId = "concurrent-fixture-turn";
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: object) => emit({ method, params: { threadId, ...params } });
let requestID = 0, stage = "inventory", cycle = 1, finished = false;
let snapshot = "", button = -1, field = -1;
let waiting: ReturnType<typeof setInterval> | undefined;
const rows: { tool: string; success: boolean; text: string; stage: string; cycle: number }[] = [];
let lastTool = "";
function call(tool: string, args: object = {}) {
  lastTool = tool;
  emit({ id: ++requestID, method: "item/tool/call", params: {
    threadId, turnId, callId: `concurrent-${requestID}`, tool, arguments: args,
  } });
}
function finish(ok: boolean) {
  if (finished) return;
  finished = true;
  if (waiting) clearInterval(waiting);
  writeFileSync(join(root, "results.json"), JSON.stringify(rows));
  notify("turn/completed", { turn: { id: turnId, status: ok ? "completed" : "failed", items: [],
    error: ok ? null : { message: "Concurrent fixture contract failed" } } });
}
function waitForFile(name: string, body: () => void) {
  const started = Date.now();
  waiting = setInterval(() => {
    if (existsSync(join(root, name))) { clearInterval(waiting); body(); }
    else if (Date.now() - started > 15000) finish(false);
  }, 10);
}
function observe(text: string) {
  snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
  const buttonLine = text.split("\n").find(line => line.includes('label="Increment fixture counter"'));
  const fieldLine = text.split("\n").find(line => line.includes('label="Fixture Unicode value"') && line.includes("settable=true"));
  button = Number(/^#(\d+)/.exec(buttonLine ?? "")?.[1] ?? -1);
  field = Number(/^#(\d+)/.exec(fieldLine ?? "")?.[1] ?? -1);
  if (!snapshot || button < 0 || field < 0) throw new Error("Missing observed fixture controls");
}
function exactLabel(text: string, label: string) {
  return text.split("\n").some(line => line.includes(`label=${JSON.stringify(label)} `));
}
function expectedBefore() { return cycle <= 2 ? cycle - 1 : cycle - 3; }
function received(message: any) {
  if (finished || message.id !== requestID) return;
  const success = message.result?.success === true;
  const text = (message.result?.contentItems ?? []).map((item: any) => item.text ?? "").join("\n");
  rows.push({ tool: lastTool, success, text, stage, cycle });
  if (stage === "stale-press") {
    if (success || !/changed|stale|fresh/i.test(text)) return finish(false);
    writeFileSync(join(root, "stale-refused"), "ready");
    return waitForFile("confirm-no-stale-mutation", () => { stage = "snapshot"; call("computer_v2_snapshot"); });
  }
  if (!success) return finish(false);
  try {
    switch (stage) {
      case "inventory": {
        const page = JSON.parse(text);
        const matches = page.items.filter((item: any) => item.url === fixtureURL);
        if (matches.length !== 1) return finish(false);
        stage = "bind"; call("computer_v2_bind_tab", { candidate_token: matches[0].candidate_token }); break;
      }
      case "bind": stage = "snapshot"; call("computer_v2_snapshot"); break;
      case "snapshot": {
        observe(text);
        if (!exactLabel(text, `Counter ${expectedBefore()}`)) return finish(false);
        stage = "press";
        call("computer_v2_ax", { snapshot_id: snapshot, element_index: button, ax_action: "AXPress" }); break;
      }
      case "press": stage = "after-press"; call("computer_v2_snapshot"); break;
      case "after-press": {
        observe(text);
        if (!exactLabel(text, `Counter ${expectedBefore() + 1}`)) return finish(false);
        stage = "text";
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: field, text: `Agent-${cycle} 東京 👋` }); break;
      }
      case "text": stage = "after-text"; call("computer_v2_snapshot"); break;
      case "after-text": {
        if (!exactLabel(text, `Value Agent-${cycle} 東京 👋`)) return finish(false);
        if (cycle === 5) return finish(true);
        cycle++;
        stage = cycle === 3 ? "before-conflict" : "snapshot";
        call("computer_v2_snapshot"); break;
      }
      case "before-conflict": {
        observe(text);
        if (!exactLabel(text, "Counter 2")) return finish(false);
        writeFileSync(join(root, "navigate-agent-now"), "ready");
        waitForFile("agent-navigation-complete", () => {
          stage = "stale-press";
          call("computer_v2_ax", { snapshot_id: snapshot, element_index: button, ax_action: "AXPress" });
        }); break;
      }
      default: finish(false);
    }
  } catch { finish(false); }
}
createInterface({ input: process.stdin }).on("line", line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, "id")) return;
  if (!message.method) return received(message);
  switch (message.method) {
    case "initialize": result(message.id, { userAgent: "concurrent-headless-fixture" }); break;
    case "thread/list": result(message.id, { data: [], nextCursor: null }); break;
    case "thread/start": result(message.id, { thread: { id: threadId, turns: [] } }); break;
    case "thread/name/set": result(message.id); break;
    case "turn/start":
      result(message.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      setTimeout(() => call("computer_v2_tabs", { page_size: 25 }), 10); break;
    case "turn/interrupt": result(message.id); finish(false); break;
    default: emit({ id: message.id, error: { code: -32601, message: "Unexpected concurrent fixture method" } });
  }
}).on("close", () => process.exit(0));
