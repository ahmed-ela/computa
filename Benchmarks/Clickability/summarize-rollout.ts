// Offline, single-turn audit. Never prints arguments, prompts, labels, URLs,
// reasoning, answer bodies, raw errors or opaque application identifiers.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { isAbsolute } from "node:path";
import { receiptText } from "../OpaqueSurfacePerception/receipt-text";

type Json = Record<string, any>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const tools = new Set(["computer_v2_status", "computer_v2_apps", "computer_v2_open", "computer_v2_tabs",
  "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_ax", "computer_v2_set_text",
  "computer_v2_capture", "computer_v2_ground_click", "computer_v2_click", "computer_v2_pointer",
  "computer_v2_keypress", "computer_v2_type", "computer_v2_verify"]);
const hash = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");
function need(value: unknown): asserts value { if (!value) throw new Error("rollout_audit_failed_redacted"); }
function object(value: unknown): value is Json { return !!value && typeof value === "object" && !Array.isArray(value); }
function assistantText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content.filter(item => object(item) && ["output_text", "text"].includes(item.type)
    && typeof item.text === "string").map(item => item.text).join("\n");
}

export function summarizeRollout(raw: string, turnID: string, expectedMarker?: string) {
  need(uuid.test(turnID) && Buffer.byteLength(raw) <= 64 * 1024 * 1024);
  need(expectedMarker === undefined || /^[A-Z][A-Z0-9_]{7,79}$/.test(expectedMarker));
  const lines = raw.trimEnd().split(/\r?\n/); need(lines.length <= 100_000);
  let active: string | null = null, seen = false, complete = false, compacted = 0;
  let startedAt: number | null = null, completedAt: number | null = null;
  let completionText: string | null = null, modelIsQwen4B: boolean | null = null;
  let orphanOutputs = 0, duplicateOutputs = 0, selectedRecords = 0;
  const calls = new Map<string, { number: number; tool: string; requestedAction: string | null;
    requestOffsetMs: number | null; responseOffsetMs: number | null; receiptLatencyMs: number | null;
    outputs: number; outputBytes: number; sources: { browser_clickability: number; focusable_pointer: number };
    markerObserved: boolean; nativeFailure: boolean; dispatch: string | null; verification: boolean;
    latestReceiptStatus: string | null; errorIndicators: string[] }>();
  const messages: { phase: string; text: string }[] = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    const record = JSON.parse(line); need(object(record) && typeof record.type === "string" && object(record.payload));
    const p = record.payload;
    if (record.type === "event_msg" && p.type === "task_started") {
      active = typeof p.turn_id === "string" ? p.turn_id : null;
      if (active === turnID) { seen = true; startedAt ??= Number.isFinite(Date.parse(record.timestamp)) ? Date.parse(record.timestamp) : null; }
    }
    if (record.type === "turn_context") {
      active = typeof p.turn_id === "string" ? p.turn_id : null;
      if (active === turnID) { seen = true; modelIsQwen4B = typeof p.model === "string" && /Qwen3\.5-4B/i.test(p.model); }
    }
    if (active !== turnID) continue;
    selectedRecords++;
    if (record.type === "compacted") { compacted++; continue; } // Never double-count retained history.
    if (record.type === "event_msg" && ["task_complete", "task_aborted"].includes(p.type)) {
      need(p.turn_id === turnID);
      complete = p.type === "task_complete";
      completedAt = Number.isFinite(Date.parse(record.timestamp)) ? Date.parse(record.timestamp) : null;
      completionText = typeof p.last_agent_message === "string" ? p.last_agent_message : null;
      active = null;
      continue;
    }
    if (record.type !== "response_item") continue;
    if (p.type === "message" && p.role === "assistant") {
      messages.push({ phase: ["commentary", "final_answer", "final"].includes(p.phase) ? p.phase : "unspecified",
        text: assistantText(p.content) });
      continue;
    }
    if (p.type === "function_call") {
      need(typeof p.call_id === "string" && p.call_id.length <= 256 && !calls.has(p.call_id) && calls.size < 512);
      let args: Json = {};
      try { const decoded = typeof p.arguments === "string" ? JSON.parse(p.arguments) : p.arguments;
        if (object(decoded)) args = decoded; } catch { /* Redacted malformed arguments remain a request, not a dispatch. */ }
      const action = args.ax_action;
      calls.set(p.call_id, { number: calls.size + 1, tool: tools.has(p.name) ? p.name : "other_tool",
        requestedAction: ["AXPress", "AXRaise", "AXConfirm", "AXShowMenu"].includes(action) ? action : null,
        requestOffsetMs: startedAt !== null && Number.isFinite(Date.parse(record.timestamp)) ? Date.parse(record.timestamp) - startedAt : null,
        responseOffsetMs: null, receiptLatencyMs: null,
        outputs: 0, outputBytes: 0, sources: { browser_clickability: 0, focusable_pointer: 0 },
        markerObserved: false, nativeFailure: false, dispatch: null, verification: false, latestReceiptStatus: null,
        errorIndicators: [] });
      continue;
    }
    if (p.type !== "function_call_output") continue;
    const call = calls.get(p.call_id);
    if (!call) { orphanOutputs++; continue; }
    call.outputs++; if (call.outputs > 1) duplicateOutputs++;
    if (call.outputs === 1 && startedAt !== null && Number.isFinite(Date.parse(record.timestamp))) {
      call.responseOffsetMs = Date.parse(record.timestamp) - startedAt;
      if (call.requestOffsetMs !== null) call.receiptLatencyMs = call.responseOffsetMs - call.requestOffsetMs;
    }
    const output = receiptText(p.output); if (output === null) continue;
    call.outputBytes += Buffer.byteLength(output);
    const firstLine = output.split("\n", 1)[0].replace(/^Error: /, "");
    const knownErrors: Record<string, string> = {
      missing_baseline: "The action has no pre-action observation for comparison.",
      property_mismatch: "The expected property was not observed; the outcome remains unverified.",
      unchanged_property: "That property was already present before the action; it does not verify a changed outcome.",
      invalid_arguments: "Invalid computer V2 argument:",
      unsupported_browser_action: "Unsupported browser action",
      interrupted: "Tool execution was interrupted",
    };
    for (const [code, prefix] of Object.entries(knownErrors)) {
      if (firstLine.startsWith(prefix) && !call.errorIndicators.includes(code)) call.errorIndicators.push(code);
    }
    if (call.tool === "computer_v2_snapshot" || call.tool === "computer_v2_ax" || call.tool === "computer_v2_verify") {
      for (const row of output.split("\n")) {
        if (!/^#\d+ role="/.test(row)) continue;
        const source = / actions=\["AXPress"\] press_source=(browser_clickability|focusable_pointer)$/.exec(row)?.[1];
        if (source) call.sources[source as keyof typeof call.sources]++;
      }
      call.markerObserved = expectedMarker !== undefined && output.includes(expectedMarker);
    }
    // Only a verification-tool receipt can establish this narrow runtime fact.
    if (call.tool === "computer_v2_verify") {
      const verified = /^VERIFIED_PROPERTY operation_id=([^\s]+) snapshot_id=/.exec(output);
      const operation = verified && calls.get(verified[1]);
      if (operation) operation.verification = true;
    }
    const marker = `RUNTIME_ACTION_EVIDENCE turn=${turnID}`;
    const checkpoint = output.lastIndexOf(marker);
    if (checkpoint >= 0 && (checkpoint === 0 || output[checkpoint - 1] === "\n")) {
      for (const row of output.slice(checkpoint + marker.length).split("\n")) {
        const receipt = /^operation=([^\s]+) tool=(computer_v2_[a-z_]+) dispatch=(not_dispatched|dispatched|unknown)(?: foreground_effect=[a-z_]+)? status=(failed|unverified|preflight_corrected_not_performed)(?: preflight_rejection=[a-zA-Z]+)?$/.exec(row);
        if (!receipt) continue;
        const operation = calls.get(receipt[1]); if (!operation || operation.tool !== receipt[2]) continue;
        operation.dispatch = receipt[3]; operation.latestReceiptStatus = receipt[4];
        operation.nativeFailure ||= receipt[4] === "failed";
      }
    }
  }
  need(seen);
  const finals = messages.filter(message => ["final_answer", "final"].includes(message.phase)
    || (completionText !== null && message.text === completionText));
  const toolCalls = [...calls.values()];
  return { schemaVersion: 1, readOnly: true, redacted: true, sourceSHA256: hash(raw),
    selectedTurnSHA256: hash(turnID), selectedRecords, modelIsQwen4B, turnComplete: complete,
    durationMs: startedAt !== null && completedAt !== null ? completedAt - startedAt : null,
    compactions: compacted, requestedTools: toolCalls.map(call => call.tool), toolCalls,
    counts: { calls: calls.size, outputs: toolCalls.reduce((sum, call) => sum + call.outputs, 0),
      nativeFailedOperations: toolCalls.filter(call => call.nativeFailure).length,
      outputsWithRecognizedErrors: toolCalls.filter(call => call.errorIndicators.length > 0).length,
      explicitlyDispatchedOperations: toolCalls.filter(call => call.dispatch === "dispatched").length,
      verifiedProperties: toolCalls.filter(call => call.verification).length, orphanOutputs, duplicateOutputs },
    assistant: { messages: messages.length, finalMessages: finals.length,
      finalBytes: finals.reduce((sum, message) => sum + Buffer.byteLength(message.text), 0),
      completionMatchesFinal: completionText !== null && finals.some(message => message.text === completionText),
      expectedMarkerInFinal: expectedMarker !== undefined && finals.some(message => message.text.includes(expectedMarker)) },
    limitations: ["Tool output alone is not a success or dispatch receipt.",
      "Verified properties are not proof of whole-task completion or absence of search results.",
      "Receipt latency is rollout timestamp difference, not a profiler measurement.",
      "This rollout does not prove foreground, pointer or clipboard preservation."] };
}

if (import.meta.main) {
  try {
    const [path, turnID, expectedMarker, ...extra] = Bun.argv.slice(2);
    need(isAbsolute(path ?? "") && extra.length === 0);
    const stat = lstatSync(path); need(stat.isFile() && !stat.isSymbolicLink() && stat.size <= 64 * 1024 * 1024);
    const raw = readFileSync(path, "utf8");
    console.log(JSON.stringify(summarizeRollout(raw, turnID, expectedMarker), null, 2));
  } catch {
    console.error(JSON.stringify({ auditComplete: false, error: "rollout_audit_failed_redacted" }));
    process.exitCode = 1;
  }
}
