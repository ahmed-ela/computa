#!/usr/bin/env bun
// JSON-RPC transport only. Tool plans are synthetic test input; this fixture
// contains no model, application launch, browser connection, or input driver.
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { randomUUID } from "node:crypto";

const root = process.env.CODEX_HOME!;
const threadId = "background-policy-thread";
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: Record<string, unknown>) => emit({ method, params: { threadId, ...params } });
const save = (name: string, data: unknown) => writeFileSync(join(root, name), JSON.stringify(data));
type Plan = { tool?: string; arguments?: Record<string, unknown>; repeat?: number; rotateCapture?: boolean; rotateTool?: boolean; marker?: string };
const attempts: Record<string, unknown>[] = [];
const replies: Record<string, unknown>[] = [];
let turnCount = 0, turnId = "", step = 0, finished = true, plan: Plan = {};
let compactRequestID: unknown;

function final(text: string) {
  const item = { id: `answer-${turnCount}`, type: "agentMessage", phase: "final_answer", text };
  notify("item/started", { turnId, item: { ...item, text: "" } });
  notify("item/agentMessage/delta", { turnId, itemId: item.id, delta: text });
  notify("item/completed", { turnId, item });
}

function complete(status = "completed") {
  if (finished) return;
  finished = true;
  notify("turn/completed", { turn: { id: turnId, status, items: [], error: null } });
}

function call() {
  if (finished || !plan.tool) return;
  let tool = plan.tool;
  let args = { ...plan.arguments };
  if (plan.rotateTool) {
    if (step % 3 === 0) args.target = `Rephrased synthetic control ${step}`;
    else if (step % 3 === 1) { tool = "computer_v2_type"; args = { text: `MUST_NOT_TYPE_${step}` }; }
    else { tool = "computer_v2_open"; args = { bundle_id: "com.example.ComputaBackgroundSentinel", activation: "foreground" }; }
  }
  if (plan.rotateCapture && "capture_id" in args) args.capture_id = randomUUID();
  const id = `policy-request-${turnCount}-${step}`;
  const params = { threadId, turnId, callId: `policy-call-${turnCount}-${step}`, tool, arguments: args };
  attempts.push({ id, ...params });
  save("attempts.json", attempts);
  emit({ id, method: "item/tool/call", params });
}

function received(message: any) {
  const text = (message.result?.contentItems ?? []).map((item: any) => item.text ?? "").join("\n");
  if (message.id === "maintenance-action") {
    save("maintenance-result.json", { success: message.result?.success === true, text, error: message.error });
    notify("item/completed", { turnId: "policy-maintenance", item: { id: "policy-compaction", type: "contextCompaction" } });
    notify("turn/completed", { turn: { id: "policy-maintenance", status: "completed", items: [], error: null } });
    result(compactRequestID);
    return;
  }
  if (message.id !== `policy-request-${turnCount}-${step}`) return;
  replies.push({ turnId, tool: attempts.find(x => x.id === message.id)?.tool, success: message.result?.success === true, text, error: message.error });
  save("results.json", replies);
  if (finished) return;
  step++;
  if (step < Math.min(plan.repeat ?? 1, 12)) setTimeout(call, 5);
  else {
    final("UNSUPPORTED_FOREGROUND_SUCCESS_MUST_NOT_APPEAR");
    complete();
  }
}

createInterface({ input: process.stdin }).on("line", line => {
  const message = JSON.parse(line);
  if (!Object.hasOwn(message, "id")) return;
  if (!message.method) return received(message);
  switch (message.method) {
    case "initialize": result(message.id, { userAgent: "background-policy-fixture" }); break;
    case "thread/list": result(message.id, { data: [], nextCursor: null }); break;
    case "thread/start":
      save("specs.json", message.params.dynamicTools);
      result(message.id, { thread: { id: threadId, turns: [] } }); break;
    case "thread/resume":
      result(message.id, { thread: { id: threadId, turns: [], status: { type: "idle" } },
        initialTurnsPage: { data: [], nextCursor: null, hasMore: false }, model: "lmstudio-community/Qwen3.5-4B-MLX-4bit" }); break;
    case "thread/name/set": case "thread/inject_items": result(message.id); break;
    case "turn/start":
      turnCount++;
      turnId = `policy-turn-${turnCount}`;
      step = 0;
      finished = false;
      plan = JSON.parse(message.params.input[0].text);
      result(message.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      setTimeout(() => {
        if (plan.tool) call();
        else { final(plan.marker ?? "NEXT_TURN_OK"); complete(); }
      }, 10);
      break;
    case "turn/interrupt":
      save("interrupted.json", { turnId, attempts: attempts.filter(x => x.turnId === turnId).length });
      result(message.id);
      final("UNSUPPORTED_LATE_FOREGROUND_SUCCESS_MUST_NOT_APPEAR");
      complete("interrupted");
      break;
    case "thread/compact/start":
      compactRequestID = message.id;
      notify("turn/started", { turn: { id: "policy-maintenance", status: "inProgress", items: [] } });
      notify("item/started", { turnId: "policy-maintenance", item: { id: "policy-compaction", type: "contextCompaction" } });
      emit({ id: "maintenance-action", method: "item/tool/call", params: {
        threadId, turnId: "policy-maintenance", callId: "maintenance-action-call", tool: "computer_v2_open",
        arguments: { bundle_id: "com.example.ComputaBackgroundSentinel", activation: "foreground" },
      } });
      break;
    default: emit({ id: message.id, error: { code: -32601, message: `Unexpected background fixture method: ${message.method}` } });
  }
}).on("close", () => process.exit(0));
