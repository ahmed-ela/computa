#!/usr/bin/env bun
// Deterministic JSON-RPC fixture only. No model, tool execution, or desktop use.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const root = process.env.CODEX_HOME;
if (!root) throw new Error("The fixture requires its isolated CODEX_HOME.");
const scenario = readFileSync(join(root, "scenario"), "utf8").trim();
const threadId = "fixture-thread";
const resuming = scenario.startsWith("resume-");
const modelId = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const resumedTurnId = "resume-prior-turn";
let userTurns = resuming ? 1 : 0;
let compactRequestId: unknown;
let finishUnsolicitedMaintenance: (() => void) | undefined;
const receivedMaintenanceResponses = new Set<string>();

function emit(value: unknown) {
  process.stdout.write(JSON.stringify(value) + "\n");
}
function result(id: unknown, value: unknown = {}) {
  emit({ id, result: value });
}
function notify(method: string, params: Record<string, unknown>) {
  emit({ method, params: { threadId, ...params } });
}
function mark(name: string) {
  writeFileSync(join(root!, name), "ready");
}
function afterMarker(name: string, action: () => void) {
  const timer = setInterval(() => {
    if (!existsSync(join(root!, name))) return;
    clearInterval(timer);
    action();
  }, 10);
}
function usage(turnId: string, used: number) {
  notify("thread/tokenUsage/updated", {
    turnId,
    tokenUsage: {
      modelContextWindow: 7_782,
      last: { totalTokens: used, inputTokens: used - 100, outputTokens: 100, cachedInputTokens: 0, reasoningOutputTokens: 0 },
      total: { totalTokens: used, inputTokens: used - 100, outputTokens: 100, cachedInputTokens: 0, reasoningOutputTokens: 0 },
    },
  });
}
async function fragmentedUserTurn(turnId: string, closeOutput: boolean) {
  const text = "FRAGMENTED_REPLY_START\n" + "0123456789abcdef".repeat(8_192) + "\nFRAGMENTED_REPLY_END";
  notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
  notify("item/started", { turnId, item: { id: "large-assistant", type: "agentMessage", phase: "final_answer", text: "" } });
  const frame = Buffer.from(JSON.stringify({ method: "item/completed", params: {
    threadId, turnId, item: { id: "large-assistant", type: "agentMessage", phase: "final_answer", text },
  } }) + "\n");
  const widths = [17, 4_093, 2_048, 8_191, 1, 31];
  for (let offset = 0, index = 0; offset < frame.length; index++) {
    const end = Math.min(frame.length, offset + widths[index % widths.length]);
    const chunk = frame.subarray(offset, end);
    await new Promise<void>((resolve, reject) => process.stdout.write(chunk, error => error ? reject(error) : resolve()));
    offset = end;
  }
  usage(turnId, 6_200);
  notify("turn/completed", { turn: { id: turnId, status: "completed", error: null, items: [] } });
  mark("fragmented-output-finished");
  // Flush the final terminal to the pipe, then EOF immediately. No timing-based
  // race injection or process.exit before stdout has drained is involved.
  if (closeOutput) process.stdout.end(() => process.exit(0));
}
function completedUserTurn(turnId: string, index: number) {
  notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
  notify("item/completed", {
    turnId,
    item: { id: `assistant-${index}`, type: "agentMessage", phase: "final_answer", text: index === 1 ? "ACTUAL_PRIOR_REPLY" : "NEW_REPLY" },
  });
  const firstUsage = scenario === "below-threshold" ? 6_143 : scenario === "at-threshold" ? 6_144 : 6_200;
  const used = index === 1 ? firstUsage : 3_100;
  usage(turnId, used);
  notify("turn/completed", { turn: { id: turnId, status: "completed", error: null, items: [] } });
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const request = JSON.parse(line);
  if (!Object.hasOwn(request, "id")) return;
  if (!request.method) {
    if (request.id === "maintenance-status" || request.id === "maintenance-command") {
      receivedMaintenanceResponses.add(request.id);
      if (receivedMaintenanceResponses.size === 2 && finishUnsolicitedMaintenance) {
        const finish = finishUnsolicitedMaintenance;
        finishUnsolicitedMaintenance = undefined;
        mark("maintenance-denials-received");
        finish();
      }
    }
    return;
  }
  switch (request.method) {
    case "initialize": result(request.id, { userAgent: "deterministic-compaction-fixture" }); break;
    case "thread/list": result(request.id, { data: resuming ? [{
      id: threadId, model: scenario === "resume-missing-model" ? null : modelId, name: "Synthetic resumed task", preview: "Existing fixture history", status: { type: "idle" }, updatedAt: 1_790_000_000,
    }] : [], nextCursor: null }); break;
    case "thread/start": result(request.id, { thread: { id: threadId, turns: [] } }); break;
    case "thread/resume": {
      mark("resume-waiting");
      const resume = () => {
        result(request.id, {
          thread: { id: threadId, model: modelId, status: { type: "idle" }, turns: [] },
          initialTurnsPage: { data: [{
            id: resumedTurnId, status: "completed", error: null, itemsView: "full", items: [
              { id: "resumed-user", type: "userMessage", content: [{ type: "text", text: "ORIGINAL_SYNTHETIC_PROMPT" }] },
              { id: "resumed-assistant", type: "agentMessage", phase: "final_answer", text: "ACTUAL_PRIOR_REPLY" },
            ],
          }], nextCursor: null, hasMore: false },
        });
        mark("resume-ack-sent");
        if (scenario === "resume-delayed-high") setTimeout(() => { usage(resumedTurnId, 6_200); mark("resume-usage-sent"); }, 100);
      };
      if (scenario === "resume-early-high" || scenario === "resume-stop") usage(resumedTurnId, 6_200);
      if (scenario === "resume-short" || scenario === "resume-missing-model") usage(resumedTurnId, 3_100);
      if (scenario === "resume-wrong-turn") usage("unrelated-stale-turn", 3_100);
      if (scenario === "resume-invalid") usage(resumedTurnId, -1);
      if (scenario === "resume-stop") afterMarker("release-resume", resume);
      else resume();
      break;
    }
    case "thread/name/set": result(request.id); break;
    case "turn/start": {
      const index = ++userTurns;
      const turnId = `user-turn-${index}`;
      if (index > 1) mark("second-user-turn-started");
      result(request.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      // The runtime may accept the RPC before reading the completion stream.
      setTimeout(() => {
        if (scenario === "fragmented-output" || scenario === "fragmented-output-eof") {
          void fragmentedUserTurn(turnId, scenario === "fragmented-output-eof");
        } else completedUserTurn(turnId, index);
      }, 10);
      break;
    }
    case "thread/compact/start": {
      compactRequestId = request.id;
      const turnId = "maintenance-turn";
      const item = { id: "compact-item", type: "contextCompaction" };
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("item/started", { turnId, item });
      if (scenario === "unsolicited-maintenance-actions") {
        finishUnsolicitedMaintenance = () => {
          notify("item/completed", { turnId, item });
          notify("turn/completed", { turn: { id: turnId, status: "completed", error: null, items: [] } });
          result(request.id);
        };
        emit({ id: "maintenance-status", method: "item/tool/call", params: {
          threadId, turnId, callId: "maintenance-status-call", tool: "computer_v2_status", arguments: {},
        } });
        // This is only an approval request; the fixture has no command executor.
        emit({ id: "maintenance-command", method: "item/commandExecution/requestApproval", params: {
          threadId, turnId, itemId: "maintenance-command-item", command: "fixture-only-no-command-execution", cwd: root,
        } });
        break;
      }
      if (scenario === "malformed-ack") {
        result(request.id, "not-an-ack-object");
        mark("malformed-ack-sent");
        break;
      }
      if (scenario === "disconnect") {
        result(request.id);
        mark("compaction-waiting");
        afterMarker("disconnect-now", () => process.exit(0));
        break;
      }
      if (scenario !== "missing-item") notify("item/completed", { turnId, item });
      // Deliberately publish BOTH lifecycle terminals before the RPC acceptance.
      notify("turn/completed", { turn: { id: turnId, status: "completed", error: null, items: [] } });
      result(request.id);
      break;
    }
    case "thread/inject_items":
      mark("injection-waiting");
      afterMarker("release-injection", () => result(request.id));
      break;
    case "turn/interrupt":
      result(request.id);
      notify("turn/completed", { turn: { id: request.params.turnId, status: "interrupted", error: null, items: [] } });
      break;
    default:
      emit({ id: request.id, error: { code: -32601, message: `Unexpected fixture method: ${request.method}; compact=${String(compactRequestId)}` } });
  }
});
lines.on("close", () => process.exit(0));
