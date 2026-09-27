#!/usr/bin/env bun
// Scripted model transport for production Core. No model, app, OS input,
// browser, or account is accessed. Swift injects an inert native AX backend.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const root = process.env.CODEX_HOME!;
const mode = readFileSync(join(root, "mode"), "utf8");
const threadId = "native-verification-task";
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: Record<string, unknown>) => emit({ method, params: { threadId, ...params } });
let turnCount = 0, turnId = "", step = 0, finished = false, snapshot = "", lastTool = "";
let waiting: ReturnType<typeof setInterval> | undefined;
const rows: { tool: string; success: boolean; text: string }[] = [];
const persist = () => writeFileSync(join(root, "results.json"), JSON.stringify(rows));

function call(tool: string, args: Record<string, unknown> = {}) {
  lastTool = tool;
  emit({ id: `native-request-${step}`, method: "item/tool/call", params: {
    threadId, turnId, callId: `native-call-${step}`, tool, arguments: args,
  } });
}
function answer(text: string, id = "native-answer") {
  notify("item/completed", { turnId, item: { id, type: "agentMessage", phase: "final_answer", text } });
}
function finish() {
  if (finished) return;
  finished = true;
  if (waiting) clearInterval(waiting);
  persist();
  notify("turn/completed", { turn: { id: turnId, status: "completed", error: null } });
}
function press() {
  call("computer_v2_ax", { snapshot_id: snapshot, element_index: 1, ax_action: "AXPress",
    ...(mode === "detail" ? { postcondition: {
      kind: "detail_view", detail_element_index: 3, expected: "Fixture conversation",
    } } : {}),
  });
}
function received(message: any) {
  if (finished || message.id !== `native-request-${step}`) return;
  const success = message.result?.success === true;
  const text = (message.result?.contentItems ?? []).map((item: any) => item.text ?? "").join("\n");
  rows.push({ tool: lastTool, success, text });
  persist();
  const previousStep = step++;
  if (previousStep === 0) {
    snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
    if (!success || !snapshot) {
      writeFileSync(join(root, "fixture-error"), "Initial native snapshot missing");
      return finish();
    }
    if (mode === "latest-incoming" || mode === "general-read") {
      answer(mode === "latest-incoming" ? "UNSUPPORTED_LATEST_INCOMING_MUST_NOT_APPEAR" : "NATIVE_READ_COMPLETE");
      return finish();
    }
    if (mode === "value") {
      return call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 2, text: "verified fixture value" });
    }
    return press();
  }
  if (["duplicate", "pending-duplicate"].includes(mode) && previousStep === 1) return call("computer_v2_snapshot");
  if (["duplicate", "pending-duplicate"].includes(mode) && previousStep === 2) {
    snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
    return press();
  }
  if (mode === "pending-duplicate" && previousStep === 3) return call("computer_v2_snapshot");
  // Deliberately claim success even after a failed/unverified input. Core, not
  // this scripted model, must prevent that claim from reaching the transcript.
  answer(["wrong-result", "no-plan", "pending-duplicate"].includes(mode)
    ? "NATIVE_FALSE_SUCCESS_MUST_NOT_APPEAR" : "NATIVE_VERIFICATION_COMPLETE");
  finish();
}

const input = createInterface({ input: process.stdin });
input.on("line", line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, "id")) return;
  if (!message.method) return received(message);
  switch (message.method) {
    case "initialize": result(message.id, { userAgent: "native-verification-fixture" }); break;
    case "thread/list": result(message.id, { data: [{ id: threadId, model, status: { type: "idle" } }] }); break;
    case "thread/resume": result(message.id, {
      thread: { id: threadId, turns: [], status: { type: "idle" } },
      initialTurnsPage: { data: [], nextCursor: null, hasMore: false }, model,
    }); break;
    case "thread/name/set": result(message.id); break;
    case "turn/start": {
      turnCount++;
      turnId = `native-verification-turn-${turnCount}`;
      finished = false;
      result(message.id, { turn: { id: turnId, status: "inProgress" } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress" } });
      if (turnCount > 1) {
        answer("NEXT_TURN_OK", "next-answer");
        finish();
        break;
      }
      persist();
      writeFileSync(join(root, "ready"), "yes");
      waiting = setInterval(() => {
        if (!existsSync(join(root, "continue"))) return;
        clearInterval(waiting);
        waiting = undefined;
        call("computer_v2_snapshot");
      }, 5);
      break;
    }
    case "turn/interrupt": {
      if (waiting) clearInterval(waiting);
      finished = true;
      writeFileSync(join(root, "interrupted"), "yes");
      notify("item/agentMessage/delta", { turnId, itemId: "late-answer", delta: "CANCELLED_NATIVE_FALSE_SUCCESS_MUST_NOT_STREAM" });
      answer("CANCELLED_NATIVE_FALSE_SUCCESS_MUST_NOT_APPEAR", "late-answer");
      result(message.id);
      notify("turn/completed", { turn: { id: turnId, status: "interrupted", error: null } });
      break;
    }
    default: emit({ id: message.id, error: { code: -32601, message: `Unexpected native fixture method: ${message.method}` } });
  }
});
input.on("close", () => process.exit(0));
