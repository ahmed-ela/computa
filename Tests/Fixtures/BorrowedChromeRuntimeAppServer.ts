#!/Users/ahmedelamin/.bun/bin/bun
// Deterministic production-Core JSON-RPC exercise. The injected Swift adapter
// is inert; this fixture has no browser connection, model, settings or input.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const root = process.env.CODEX_HOME!;
const mode = readFileSync(join(root, "mode"), "utf8");
const threadId = "borrowed-runtime-thread", turnId = "borrowed-runtime-turn";
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: Record<string, unknown>) => emit({ method, params: { threadId, ...params } });
let step = 0, finished = false, snapshot = "", firstCandidate = "";
const results: { tool: string; success: boolean; text: string }[] = [];
let lastTool = "";
let waiting: ReturnType<typeof setInterval> | undefined;
function call(tool: string, args: Record<string, unknown> = {}) {
  lastTool = tool;
  emit({ id: `borrowed-request-${step}`, method: "item/tool/call", params: {
    threadId, turnId, callId: `borrowed-call-${step}`, tool, arguments: args,
  } });
}
function finish(success: boolean) {
  if (finished) return;
  finished = true;
  if (waiting) clearInterval(waiting);
  writeFileSync(join(root, "results.json"), JSON.stringify(results));
  notify("turn/completed", { turn: { id: turnId, status: success ? "completed" : "failed", items: [],
    error: success ? null : { message: "Borrowed runtime fixture failed" } } });
}
function received(message: any) {
  if (finished || message.id !== `borrowed-request-${step}`) return;
  const success = message.result?.success === true;
  const text = (message.result?.contentItems ?? []).map((item: any) => item.text ?? "").join("\n");
  results.push({ tool: lastTool, success, text });
  if (mode === "unsupported-actions") return unsupportedActions(success, text);
  if (mode === "no-connection") return finish(!success && text.includes("not connected"));
  if (mode === "inventory-hold") {
    if (!success) return finish(false);
    writeFileSync(join(root, "inventory-ready"), "ready");
    return;
  }
  if (mode === "invalid-owned-hold") {
    if (step === 0) {
      if (!success) return finish(false);
      writeFileSync(join(root, "inventory-ready"), "ready");
      waiting = setInterval(() => {
        if (!existsSync(join(root, "try-invalid-token"))) return;
        clearInterval(waiting);
        step = 1;
        call("computer_v2_bind_tab", { candidate_token: "99999999-9999-4999-8999-999999999999" });
      }, 10);
    } else {
      writeFileSync(join(root, "invalid-token-result.json"), JSON.stringify({ success, text }));
      if (success) return finish(false);
    }
    return;
  }
  if (step >= 10) {
    if (success || !text.includes("borrowed Chrome tab")) return finish(false);
  } else if (step === 4) {
    if (success) return finish(false);
  } else if (!success) return finish(false);
  try {
    switch (step++) {
      case 0: {
        const page = JSON.parse(text);
        if (page.returned !== 1 || page.total_count !== 2 || !page.next_cursor) return finish(false);
        firstCandidate = page.items[0].candidate_token;
        call("computer_v2_tabs", { cursor: page.next_cursor, page_size: 1 }); break;
      }
      case 1: {
        const page = JSON.parse(text);
        if (page.returned !== 1 || page.total_count !== 2 || page.next_cursor
            || page.items[0].candidate_token === firstCandidate) return finish(false);
        call("computer_v2_bind_tab", { candidate_token: page.items[0].candidate_token }); break;
      }
      case 2:
        if (!text.includes("ownership=borrowed")) return finish(false);
        call("computer_v2_snapshot"); break;
      case 3:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        call("computer_v2_bind_tab", { candidate_token: "99999999-9999-4999-8999-999999999999" }); break;
      case 4:
        // Unknown candidate admission must preserve the bound capability AND
        // its already-observed snapshot, not force a new turn or observation.
        call("computer_v2_ax", { snapshot_id: snapshot, element_index: 0, ax_action: "AXPress" }); break;
      case 5: call("computer_v2_snapshot"); break;
      case 6:
        if (!text.includes('value="1"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "HDé7 東京 👋" }); break;
      case 7: call("computer_v2_snapshot"); break;
      case 8:
        if (!text.includes("HDé7 東京 👋")) return finish(false);
        // Rebinding the same exact opaque token remains a read-only identity
        // operation; fetch a fresh page solely to obtain that token again.
        call("computer_v2_tabs", { page_size: 2 }); break;
      case 9:
        call("computer_v2_capture"); break;
      case 10:
        call("computer_v2_keypress", { key: "a", modifiers: [] }); break;
      case 11:
        call("computer_v2_type", { text: "must-not-type" }); break;
      case 12:
        call("computer_v2_click", { capture_id: "11111111-1111-4111-8111-111111111111", x: 1, y: 1 }); break;
      case 13: finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function unsupportedActions(success: boolean, text: string) {
  if (step >= 3 && step <= 8) {
    if (success || !text.includes("No approval or action was requested")) return finish(false);
    if (step === 3 && (!text.includes("settable=true") || !text.includes("computer_v2_set_text directly"))) return finish(false);
    if ([6, 7].includes(step) && !text.includes("enabled=false")) return finish(false);
    if ([5, 8].includes(step) && !text.includes("settable=false")) return finish(false);
  } else if (!success) return finish(false);
  try {
    switch (step++) {
      case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot"); break;
      case 2:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        call("computer_v2_ax", { snapshot_id: snapshot, element_index: 1, ax_action: "AXPress" }); break;
      case 3: call("computer_v2_ax", { snapshot_id: snapshot, element_index: 0, ax_action: "AXRaise" }); break;
      case 4: call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 0, text: "not a field" }); break;
      case 5: call("computer_v2_ax", { snapshot_id: snapshot, element_index: 3, ax_action: "AXPress" }); break;
      case 6: call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 4, text: "disabled" }); break;
      case 7: call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 5, text: "readonly" }); break;
      case 8:
        // All rejected admissions must preserve this same observed capability.
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "Supported direct text" }); break;
      case 9: call("computer_v2_snapshot"); break;
      case 10:
        if (!text.includes('value="Supported direct text"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        call("computer_v2_ax", { snapshot_id: snapshot, element_index: 0, ax_action: "AXPress" }); break;
      case 11: call("computer_v2_snapshot"); break;
      case 12: finish(text.includes('value="1"')); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
createInterface({ input: process.stdin }).on("line", line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, "id")) return;
  if (!message.method) return received(message);
  switch (message.method) {
    case "initialize": result(message.id, { userAgent: "borrowed-runtime-fixture" }); break;
    case "thread/list": result(message.id, { data: [], nextCursor: null }); break;
    case "thread/start":
      writeFileSync(join(root, "specs.json"), JSON.stringify(message.params.dynamicTools));
      result(message.id, { thread: { id: threadId, turns: [] } }); break;
    case "thread/name/set": result(message.id); break;
    case "turn/start":
      result(message.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      setTimeout(() => call("computer_v2_tabs", { page_size: 1 }), 10); break;
    case "turn/interrupt": result(message.id); finish(true); break;
    default: emit({ id: message.id, error: { code: -32601, message: "Unexpected borrowed fixture method" } });
  }
}).on("close", () => process.exit(0));
