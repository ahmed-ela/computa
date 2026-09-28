// Offline, selected-turn measurement only. No prompts, page text, identifiers,
// URLs, argument values, errors or assistant answers leave this analyzer.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { isAbsolute } from "node:path";
import { receiptText } from "../OpaqueSurfacePerception/receipt-text";

type Json = Record<string, any>;
type ReadKind = "inventory" | "browser" | "native";
type Header = Record<string, string>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const toolNames = new Set(["computer_v2_status", "computer_v2_apps", "computer_v2_open", "computer_v2_tabs",
  "computer_v2_bind_tab", "computer_v2_snapshot", "computer_v2_continue", "computer_v2_ax", "computer_v2_set_text", "computer_v2_follow_link",
  "computer_v2_capture", "computer_v2_ground_click", "computer_v2_click", "computer_v2_pointer",
  "computer_v2_keypress", "computer_v2_type", "computer_v2_verify",
  "computer_v2_read_page", "computer_v2_read_region", "computer_v2_press", "computer_v2_fill", "computer_v2_follow"]);
const readTools = new Set(["computer_v2_tabs", "computer_v2_continue", "computer_v2_snapshot",
  "computer_v2_bind_tab", "computer_v2_open", "computer_v2_ax", "computer_v2_set_text", "computer_v2_follow_link",
  "computer_v2_read_page", "computer_v2_read_region", "computer_v2_press", "computer_v2_fill", "computer_v2_follow"]);
const inputTools = new Set(["computer_v2_ax", "computer_v2_set_text", "computer_v2_follow_link", "computer_v2_ground_click",
  "computer_v2_click", "computer_v2_pointer", "computer_v2_keypress", "computer_v2_type",
  "computer_v2_press", "computer_v2_fill", "computer_v2_follow"]);
const postActionTools = new Set(["computer_v2_ax", "computer_v2_set_text", "computer_v2_follow_link",
  "computer_v2_press", "computer_v2_fill", "computer_v2_follow"]);
const followTools = new Set(["computer_v2_follow_link", "computer_v2_follow"]);
const maximumHeaderBytes = 32 * 1024;
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const object = (value: unknown): value is Json => !!value && typeof value === "object" && !Array.isArray(value);
function need(value: unknown): asserts value { if (!value) throw new Error("lookup_audit_failed_redacted"); }
const count = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;
const timestamp = (value: unknown) => typeof value === "string" && Number.isFinite(Date.parse(value)) ? Date.parse(value) : null;
const difference = (end: number | null, start: number | null) => end !== null && start !== null && end >= start ? end - start : null;

// Tokenize one bounded host header. Quoted titles/subtree IDs cannot introduce
// fields, and duplicate fields or malformed quotes invalidate the whole header.
function fields(line: string, prefix: string): Header | null {
  // Browser URL/title limits use Unicode characters, not UTF-8 bytes. Leave
  // room for 2,048-character URLs, 512-character titles and escaped metadata.
  if (!line.startsWith(prefix + " ") || Buffer.byteLength(line) > maximumHeaderBytes) return null;
  const tokens: string[] = []; let token = "", quoted = false, escaped = false;
  for (const character of line) {
    if (escaped) { token += character; escaped = false; continue; }
    if (character === "\\" && quoted) { token += character; escaped = true; continue; }
    if (character === '"') { quoted = !quoted; token += character; continue; }
    if (/\s/.test(character) && !quoted) { if (token) tokens.push(token); token = ""; }
    else token += character;
  }
  if (quoted || escaped) return null;
  if (token) tokens.push(token);
  const result: Header = Object.create(null);
  for (const entry of tokens.slice(1)) {
    const match = /^([a-z_]+)=(.+)$/.exec(entry);
    if (!match || Object.hasOwn(result, match[1])) return null;
    result[match[1]] = match[2];
  }
  return result;
}
const number = (header: Header, key: string): number | null => /^\d+$/.test(header[key] ?? "") && count(Number(header[key])) ? Number(header[key]) : null;
const bit = (header: Header, key: string): boolean | null => header[key] === "1" ? true : header[key] === "0" ? false : null;
function cursor(value: unknown, terminal: string[]): string | null | undefined {
  if (typeof value !== "string") return undefined;
  if (uuid.test(value)) return value.toLowerCase();
  return terminal.includes(value) ? null : undefined;
}
type Read = { kind: ReadKind; next: string | null; snapshotID?: string; metrics: Json };

function inventory(text: string): Read | null {
  let value: any; try { value = JSON.parse(text); } catch { return null; }
  if (!object(value) || value.continuation_tool !== "computer_v2_continue" || typeof value.metadata_notice !== "string"
    || !Array.isArray(value.items) || !count(value.returned) || value.returned !== value.items.length
    || value.returned > 100 || !count(value.total_count) || value.total_count > 2048 || value.total_count < value.returned
    || !(value.next_cursor === null || typeof value.next_cursor === "string" && uuid.test(value.next_cursor))) return null;
  if (!value.returned && (value.total_count !== 0 || value.next_cursor !== null)) return null;
  const tokens = new Set<string>(); let truncatedTitles = 0, omittedURLs = 0;
  for (const item of value.items) {
    if (!object(item) || typeof item.candidate_token !== "string" || !uuid.test(item.candidate_token)
      || tokens.has(item.candidate_token.toLowerCase()) || typeof item.title !== "string"
      || typeof item.title_truncated !== "boolean" || typeof item.availability !== "string"
      || !(typeof item.url === "string" || item.url_omitted === true)) return null;
    tokens.add(item.candidate_token.toLowerCase());
    truncatedTitles += Number(item.title_truncated); omittedURLs += Number(item.url_omitted === true);
  }
  return { kind: "inventory", next: value.next_cursor?.toLowerCase() ?? null,
    metrics: { returned: value.returned, reportedTotal: value.total_count, truncatedTitles, omittedURLs } };
}

function semantic(text: string): Read | null {
  const lines = text.split("\n", 4);
  let offset = 0;
  // Admit only the exact current native wrapper lines, never arbitrary prose.
  const nativeWrappers = [
    "NATIVE_AX scope=bound_window activation=none. Semantic AX/set_value only; global key/pointer tools are unavailable in this background binding. Read-only images grant no input authority. Dispatch is not outcome verification.",
    "NATIVE_AX scope=bound_window activation=none verification_read=true. Fresh references only; hidden elements are not action targets. This read never dispatches input.",
  ];
  if (nativeWrappers.includes(lines[0])) offset = 1;
  const native = fields(lines[offset] ?? "", "SEMANTIC_READ");
  const snapshot = fields(lines[offset + (native ? 1 : 0)] ?? "", "AXSNAPSHOT");
  if (!snapshot || !uuid.test(snapshot.id ?? "")) return null;
  if (native) {
    const next = cursor(native.next_cursor, ["-"]);
    if (next === undefined || !["all", "content", "headings", "links"].includes(native.view)
      || native.consistency !== "live_validated_page"
      || !["matched", "no_matches_in_visited_source", "not_requested"].includes(native.query_status)) return null;
    const metrics = { view: native.view, visited: number(native, "visited"), matched: number(native, "matched"),
      offset: number(native, "offset"), shown: number(native, "shown"), sourceTruncated: bit(native, "source_truncated"),
      outputTruncated: bit(native, "output_truncated"), sourceLimitReached: bit(native, "source_limit_reached"),
      queryStatus: native.query_status, observation: "live_validated_page",
      fieldTruncated: Object.hasOwn(native, "field_truncated") ? bit(native, "field_truncated") : null };
    if (Object.entries(metrics).some(([key, value]) => value === null
      && (key !== "fieldTruncated" || Object.hasOwn(native, "field_truncated")))) return null;
    return { kind: "native", next, snapshotID: snapshot.id, metrics };
  }
  if (snapshot.source === "chrome_devtools" && offset === 0) {
    const read = fields(lines[1] ?? "", "READ"), evidence = fields(lines[2] ?? "", "CONTENT_EVIDENCE");
    if (!read || !["overview", "all", "content", "headings", "links"].includes(read.view)
      || !["live", "retained"].includes(read.observation) || read.visibility !== "unknown") return null;
    const next = cursor(read.next_cursor, ["none"]);
    const metrics: Json = { view: read.view, sourceNodes: number(read, "source_nodes"), matches: number(read, "matches"),
      shown: number(read, "shown"), offset: number(read, "offset"), sourceTruncated: bit(read, "source_truncated"),
      outputTruncated: bit(read, "output_truncated"), fieldTruncated: bit(read, "field_truncated"),
      noMatches: bit(read, "no_matches"), observation: read.observation };
    if (next === undefined || Object.values(metrics).includes(null)) return null;
    const metadataTruncated = Object.hasOwn(read, "metadata_truncated") ? bit(read, "metadata_truncated") : null;
    if (Object.hasOwn(read, "metadata_truncated") && metadataTruncated === null) return null;
    const consistency = Object.hasOwn(read, "consistency") ? read.consistency : null;
    if (consistency !== null && (consistency !== "immutable_capture" || !uuid.test(read.source_observation ?? ""))) return null;
    // Structural region counts are copied as claims of this receipt, never as
    // readable-content counts: a toolbar can be inside the main region.
    let structuralCounts: Json | null = null, contentKindCounts: Json | null = null;
    if (evidence?.scope_basis === "observed_ancestry" && evidence.subject_relevance === "not_verified") {
      const kinds = ["readable_shown", "controls_shown", "metadata_shown"];
      const kindValues = kinds.map(name => number(evidence, name));
      const kindsPresent = kinds.some(name => Object.hasOwn(evidence, name));
      if (!kindValues.includes(null) && kindValues.reduce<number>((sum, value) => sum + value!, 0) <= metrics.shown)
        contentKindCounts = Object.fromEntries(kinds.map((name, index) => [name, kindValues[index]]));
      const names = ["document_content_shown", "navigation_shown", "complementary_shown", "banner_shown", "contentinfo_shown", "unknown_shown"];
      const values = names.map(name => number(evidence, name));
      const total = values.reduce<number>((sum, value) => sum + (value ?? 0), 0);
      // New host headers exclude controls/metadata inside main from the
      // document-content count. Provenance and kind are separate groupings.
      if (!values.includes(null) && (kindsPresent ? contentKindCounts !== null && total <= metrics.shown : total === metrics.shown))
        structuralCounts = Object.fromEntries(names.map((name, index) => [name, values[index]]));
    }
    return { kind: "browser", next, snapshotID: snapshot.id, metrics: { ...metrics, metadataTruncated,
      consistency, reportedStructuralCounts: structuralCounts, reportedContentKindCounts: contentKindCounts } };
  }
  // Legacy/plain native snapshots have no continuation guarantee.
  const metrics = { shown: number(snapshot, "shown"), capturedNodes: number(snapshot, "total"),
    sourceTruncated: bit(snapshot, "source_truncated"), outputTruncated: bit(snapshot, "output_truncated") };
  if (snapshot.source !== undefined || Object.values(metrics).includes(null)) return null;
  return { kind: "native", next: null, snapshotID: snapshot.id, metrics: { ...metrics, continuationMeasured: false, fieldTruncated: null } };
}

// Host post-action observations follow these literal wrappers. Never search a
// diagnostic/body for a later header: VERIFICATION_PENDING appends lastIssue,
// which can contain arbitrary newlines. Only preserved typed-block boundaries
// can locate its observation safely after the diagnostic.
function postActionWrapper(line: string, callID: string): { kind: string; snapshotID?: string } | null {
  const verified = /^VERIFIED_PROPERTY operation_id=(\S+) snapshot_id=([0-9a-f-]{36})\. (.+)$/i.exec(line);
  const verifiedMessages = [
    "The predeclared postcondition matched a fresh observation. No input was repeated. This verifies only that property, not an entire task or absent search results.",
    "Only the predeclared result region's displayed text changed. Read the returned content to establish what changed; this does not prove pagination or task success. No input was repeated. This verifies only that property, not an entire task or absent search results.",
    "The predeclared native property matched a fresh read of the exact bound window. No input was repeated. Selection or a detail heading does not prove message sender, incoming direction, or latest ordering.",
  ];
  if (verified && verified[1] === callID && uuid.test(verified[2]) && verifiedMessages.includes(verified[3]))
    return { kind: "verified", snapshotID: verified[2] };
  const already = /^ALREADY_SATISFIED operation_id=(\S+)\. (.+)$/.exec(line);
  if (already?.[1] === callID && already[2] === "The requested native property was already present and remained present in a fresh read. No approval or input was dispatched. Read the current content; this is not proof of message sender or ordering.")
    return { kind: "already_satisfied" };
  const pending = /^VERIFICATION_PENDING operation_id=(\S+)\. (.*)$/.exec(line);
  const pendingMessages = [
    "The bounded read-only verification did not establish the declared result. No input was repeated. Do not change the postcondition or repeat the action. ",
    "Bounded read-only observation could not establish the original native result. No input was replayed. Do not repeat input or change the postcondition. ",
  ];
  if (pending?.[1] === callID && pendingMessages.some(message => pending[2].startsWith(message))) return { kind: "pending" };
  return null;
}

function oversizedSemanticHeader(text: string): boolean {
  const lines = text.split("\n", 4);
  const offset = lines[0].startsWith("NATIVE_AX scope=bound_window ") ? 1 : 0;
  const first = lines[offset] ?? "";
  if (!/^(?:AXSNAPSHOT id=|SEMANTIC_READ )/.test(first)) return false;
  return Buffer.byteLength(first) > maximumHeaderBytes
    || /^(?:READ |AXSNAPSHOT id=)/.test(lines[offset + 1] ?? "")
      && Buffer.byteLength(lines[offset + 1]) > maximumHeaderBytes;
}

// A bounded first host block may summarize historical exposure. It is never
// itself a read receipt or a coverage oracle. Text-only serialization can fold
// the block into the first line; admit only that exact fixed-position wrapper.
function unwrapCoverageSummary(output: unknown): { output: unknown; observed: boolean } {
  const summary = (text: unknown): boolean => typeof text === "string" && Buffer.byteLength(text) <= 128
    && /^READ_COVERAGE scopes=\d+ captured=\d+ partial=\d+ unknown=\d+ source_cut=\d+ output_cut=\d+ field_cut=\d+ dropped=[01]$/.test(text);
  if (Array.isArray(output) && output[0]?.type === "input_text" && summary(output[0].text))
    return { output: output.slice(1), observed: true };
  if (typeof output === "string") {
    const newline = output.indexOf("\n");
    if (summary(newline < 0 ? output : output.slice(0, newline)))
      return { output: newline < 0 ? "" : output.slice(newline + 1), observed: true };
  }
  return { output, observed: false };
}

function semanticReceipt(output: unknown, tool: string, callID: string) {
  // Dispatch descriptions contain page-derived labels. Skip exactly one whole
  // typed host block, never lines within it or a flattened representation.
  // The following wrapper still must match this call and its next snapshot.
  if (postActionTools.has(tool) && Array.isArray(output) && output[0]?.type === "input_text"
    && typeof output[0].text === "string" && Buffer.byteLength(output[0].text) <= maximumHeaderBytes
    && /^Requested [^\r\n]+ on the exact bound (?:browser tab|native window)\. Input was dispatched once\.$/.test(output[0].text)
    && output[1]?.type === "input_text" && typeof output[1].text === "string"
    && postActionWrapper(output[1].text.split("\n", 1)[0], callID)) output = output.slice(1);
  // receiptText has already validated the whole typed array. Do not flatten
  // block boundaries or skip leading image/prose blocks when locating headers.
  const first = typeof output === "string" ? output
    : Array.isArray(output) && output[0]?.type === "input_text" ? output[0].text as string : "";
  const standalone = semantic(first);
  if (standalone && (!followTools.has(tool) || standalone.kind === "browser"))
    return { read: standalone, framing: "standalone", postActionUnmeasured: false, headerBudgetRejected: false };
  const newline = first.indexOf("\n");
  const firstLine = newline < 0 ? first : first.slice(0, newline);
  const wrapper = postActionTools.has(tool) ? postActionWrapper(firstLine, callID) : null;
  if (!wrapper) return { read: null, framing: null, postActionUnmeasured: false, headerBudgetRejected: oversizedSemanticHeader(first) };
  let observation: string | null = null;
  if (wrapper.kind !== "pending" && newline >= 0) observation = first.slice(newline + 1);
  else if (Array.isArray(output) && output[1]?.type === "input_text") observation = output[1].text;
  const read = observation === null ? null : semantic(observation);
  const matching = read && (!followTools.has(tool) || read.kind === "browser")
    && (!wrapper.snapshotID || read.snapshotID?.toLowerCase() === wrapper.snapshotID.toLowerCase());
  return { read: matching ? read : null, framing: "post_action", postActionUnmeasured: !matching,
    headerBudgetRejected: observation !== null && oversizedSemanticHeader(observation) };
}

export function summarizeLookupRollout(raw: string, turnID: string) {
  need(uuid.test(turnID) && Buffer.byteLength(raw) <= 64 * 1024 * 1024);
  const lines = raw.trimEnd().split(/\r?\n/); need(lines.length <= 100_000);
  let active: string | null = null, seen = false, terminal = false;
  let start: number | null = null, end: number | null = null;
  let status: "unknown" | "completed" | "failed" | "aborted" = "unknown";
  let qwen4B: boolean | null = null, selectedRecords = 0, checkpoints = 0, notifications = 0;
  let orphanOutputs = 0, duplicateOutputs = 0, orphanResults = 0, duplicateResults = 0, invalidResults = 0;
  let finalMessages = 0, finalBytes = 0;
  let lastAssistant: { digest: string | null; bytes: number; unphased: boolean } | null = null;
  let terminalMessageDigest: string | null = null, terminalMessageBytes: number | null = null;
  const issued = new Map<string, ReadKind>(); // Historical observation only, never cursor validity/authority.
  const calls = new Map<string, Json>();
  for (const line of lines) {
    if (!line.trim()) continue;
    let record: any; try { record = JSON.parse(line); } catch { throw new Error("lookup_audit_failed_redacted"); }
    need(object(record) && typeof record.type === "string" && object(record.payload));
    const p = record.payload;
    if (record.type === "event_msg" && ["task_started", "turn_started"].includes(p.type)) {
      active = typeof p.turn_id === "string" ? p.turn_id : null;
      if (active === turnID && !terminal) { seen = true; start ??= timestamp(record.timestamp); }
    }
    if (record.type === "turn_context") {
      active = typeof p.turn_id === "string" ? p.turn_id : null;
      if (active === turnID && !terminal) {
        seen = true;
        if (typeof p.model === "string") {
          const selected = p.model === "lmstudio-community/Qwen3.5-4B-MLX-4bit";
          qwen4B = qwen4B === null ? selected : qwen4B && selected;
        }
      }
    }
    if (active !== turnID || terminal) continue;
    // Explicit ownership always overrides ambient context, including late events.
    if (typeof p.turn_id === "string" && p.turn_id !== turnID) continue;
    selectedRecords++;
    if (record.type === "compacted") { checkpoints++; continue; }
    if (record.type === "event_msg" && p.type === "context_compacted") { notifications++; continue; }
    if (record.type === "event_msg" && ["task_complete", "turn_complete", "turn_aborted"].includes(p.type)) {
      if (p.turn_id !== turnID) continue;
      status = p.type === "turn_aborted" ? "aborted" : p.error != null ? "failed" : "completed";
      if (p.type !== "turn_aborted" && typeof p.last_agent_message === "string") {
        terminalMessageDigest = hash(p.last_agent_message);
        terminalMessageBytes = Buffer.byteLength(p.last_agent_message);
      }
      terminal = true; end = timestamp(record.timestamp); active = null; continue;
    }
    if (record.type === "event_msg" && p.type === "dynamic_tool_call_response") {
      const call = calls.get(p.call_id);
      if (!call) { orphanResults++; continue; }
      if (p.turn_id !== turnID || p.tool !== call.originalTool || typeof p.success !== "boolean") { invalidResults++; continue; }
      if (call.resultEvents++) duplicateResults++;
      const result = p.success ? "success" : "failure";
      call.toolResult = call.toolResult === "unknown" ? result : call.toolResult === result ? result : "conflicting";
      continue;
    }
    if (record.type !== "response_item") continue;
    if (p.type === "message" && p.role === "assistant") {
      const textItems = Array.isArray(p.content) ? p.content.filter(item => object(item)
        && ["text", "output_text"].includes(item.type) && typeof item.text === "string") : [];
      // The pinned terminal event concatenates assistant text blocks directly.
      // Keep exact bytes; do not insert separators or normalize hidden markup.
      const text = textItems.map(item => item.text).join("");
      const textOnly = Array.isArray(p.content) && p.content.length > 0 && textItems.length === p.content.length;
      lastAssistant = { digest: textOnly && text.length > 0 ? hash(text) : null,
        bytes: Buffer.byteLength(text), unphased: p.phase === undefined || p.phase === null };
      if (["final_answer", "final"].includes(p.phase)) { finalMessages++; finalBytes += lastAssistant.bytes; }
      continue;
    }
    if (p.type === "function_call") {
      need(typeof p.call_id === "string" && p.call_id.length > 0 && p.call_id.length <= 256
        && !calls.has(p.call_id) && calls.size < 512 && typeof p.name === "string");
      let args: Json | null = null;
      try { const decoded = typeof p.arguments === "string" ? JSON.parse(p.arguments) : null; if (object(decoded)) args = decoded; } catch { /* No text returned. */ }
      const requestedCursor = typeof args?.cursor === "string" && uuid.test(args.cursor) ? args.cursor.toLowerCase() : null;
      calls.set(p.call_id, { number: calls.size + 1, originalTool: p.name, tool: toolNames.has(p.name) ? p.name : "other_tool",
        requestKind: inputTools.has(p.name) ? "input" : ["computer_v2_tabs", "computer_v2_snapshot", "computer_v2_continue", "computer_v2_read_page", "computer_v2_read_region"].includes(p.name) ? "read" : "other",
        argumentsParsed: args !== null, requestedView: ["overview", "all", "content", "headings", "links"].includes(args?.view) ? args!.view : null,
        continuationRequested: p.name === "computer_v2_continue" || requestedCursor !== null,
        previouslyObservedCursorSource: requestedCursor ? issued.get(requestedCursor) ?? null : null,
        requestOffsetMs: difference(timestamp(record.timestamp), start), responseOffsetMs: null, receiptLatencyMs: null,
        outputs: 0, resultEvents: 0, toolResult: "unknown", readObservation: null, outputShapeRecognized: null,
        postActionObservationUnmeasured: false, semanticHeaderBudgetRejected: false, coverageSummaryObserved: false });
      continue;
    }
    if (p.type !== "function_call_output") continue;
    const call = calls.get(p.call_id);
    if (!call) { orphanOutputs++; continue; }
    if (call.outputs++) { duplicateOutputs++; continue; }
    call.responseOffsetMs = difference(timestamp(record.timestamp), start);
    call.receiptLatencyMs = difference(call.responseOffsetMs, call.requestOffsetMs);
    const text = receiptText(p.output); call.outputShapeRecognized = text !== null;
    if (text === null || !readTools.has(call.tool)) continue;
    const unwrapped = unwrapCoverageSummary(p.output);
    call.coverageSummaryObserved = unwrapped.observed;
    const metadata = ["computer_v2_tabs", "computer_v2_continue"].includes(call.tool)
      ? inventory(receiptText(unwrapped.output) ?? "") : null;
    const parsed = metadata ? { read: metadata, framing: "standalone", postActionUnmeasured: false, headerBudgetRejected: false }
      : semanticReceipt(unwrapped.output, call.tool, p.call_id);
    const read = parsed.read;
    call.postActionObservationUnmeasured = parsed.postActionUnmeasured;
    call.semanticHeaderBudgetRejected = parsed.headerBudgetRejected;
    if (!read || call.tool === "computer_v2_tabs" && read.kind !== "inventory") continue;
    call.readObservation = { kind: read.kind, framing: parsed.framing, continuationOffered: read.next !== null, ...read.metrics };
    if (read.next) issued.set(read.next, read.kind);
  }
  need(seen);
  // Some production providers omit Message.phase. The selected turn's terminal
  // event can identify its last unphased response, without guessing from prose.
  // Never search older messages, compacted history, or another turn for a match.
  const completionMatchesLastAssistantMessage = terminalMessageDigest !== null && lastAssistant?.digest != null
    ? terminalMessageDigest === lastAssistant.digest : null;
  let finalMessageBasis = finalMessages > 0 ? "explicit_phase" : "unmeasured";
  if (finalMessages === 0 && status === "completed" && lastAssistant?.unphased
    && completionMatchesLastAssistantMessage === true) {
    finalMessages = 1; finalBytes = lastAssistant.bytes; finalMessageBasis = "matching_terminal_message";
  }
  const toolCalls = [...calls.values()].map(({ originalTool, ...safe }) => safe);
  const outcomes = (kind?: string) => {
    const selected = toolCalls.filter(call => kind === undefined || call.requestKind === kind);
    return { calls: selected.length, success: selected.filter(call => call.toolResult === "success").length,
      failure: selected.filter(call => call.toolResult === "failure").length,
      unknown: selected.filter(call => call.toolResult === "unknown").length,
      conflicting: selected.filter(call => call.toolResult === "conflicting").length };
  };
  const observations = toolCalls.filter(call => call.readObservation !== null);
  return { schemaVersion: 1, readOnly: true, redacted: true, sourceSHA256: hash(raw), selectedTurnSHA256: hash(turnID),
    selectedRecords, modelIsQwen4B: qwen4B, turn: { status, terminalObserved: terminal, elapsedMs: difference(end, start) },
    compactions: { checkpointRecords: checkpoints, notificationEvents: notifications },
    toolCalls, outcomes: { all: outcomes(), readRequests: outcomes("read"), inputRequests: outcomes("input") },
    integrity: { orphanOutputs, duplicateOutputs, orphanResults, duplicateResults, invalidResults },
    reading: { inventoryReceiptOccurrences: observations.filter(call => call.readObservation.kind === "inventory").length,
      browserSemanticReceiptOccurrences: observations.filter(call => call.readObservation.kind === "browser").length,
      nativeSemanticReceiptOccurrences: observations.filter(call => call.readObservation.kind === "native").length,
      postActionSemanticReceiptOccurrences: observations.filter(call => call.readObservation.framing === "post_action").length,
      postActionObservationsUnmeasured: toolCalls.filter(call => call.postActionObservationUnmeasured).length,
      semanticHeaderBudgetRejectedOutputs: toolCalls.filter(call => call.semanticHeaderBudgetRejected).length,
      coverageSummaryOccurrences: toolCalls.filter(call => call.coverageSummaryObserved).length,
      continuationRequests: toolCalls.filter(call => call.continuationRequested).length,
      genericContinuationRequests: toolCalls.filter(call => call.tool === "computer_v2_continue").length,
      continuationRequestsWithPreviouslyObservedCursor: toolCalls.filter(call => call.continuationRequested && call.previouslyObservedCursorSource !== null).length,
      continuationRequestsReturningReadReceipt: observations.filter(call => call.continuationRequested).length,
      uniqueDocumentsRead: null, exhaustiveInventoryCoverage: null, exhaustiveDocumentCoverage: null },
    answer: { finalMessages, finalBytes, finalMessageBasis,
      terminalMessagePresent: terminalMessageDigest !== null, terminalMessageBytes, completionMatchesLastAssistantMessage,
      semanticSupport: "unmeasured", correctness: "unmeasured", unsupportedClaims: null, refusal: "unmeasured" },
    limitations: ["Tool success/failure requires a correlated dynamic_tool_call_response event; output strings and arrays omit that flag.",
      "A host-shaped read receipt is an observation, not proof of tool success, readable content, relevance or task completion.",
      "Counts are receipt occurrences. Captures, filters, subtrees and repeated pages are never combined into exhaustive coverage.",
      "Observed cursor linkage is historical, not proof that the cursor remains authorized, current or accepted.",
      "Post-action reads require an exact host wrapper and a safe observation boundary; flattened pending diagnostics are unmeasured.",
      "Semantic headers are bounded to 32 KiB each; oversized or unrecognized framing leaves the read observation null.",
      "READ_COVERAGE is recognized only as an exact bounded first block/line; its historical counts never create read observations or completeness claims.",
      "Checkpoint records and compaction notifications are reported separately and must not be added together.",
      "An unphased final response is counted only when the completed turn's terminal message exactly matches its last assistant response; terminal-only text is reported separately.",
      "Timing is rollout timestamp difference; terminal completion is not answer correctness. Unmeasured values require separate review."] };
}

if (import.meta.main) {
  try {
    const [path, turnID, ...extra] = Bun.argv.slice(2);
    need(isAbsolute(path ?? "") && extra.length === 0);
    const stat = lstatSync(path); need(stat.isFile() && !stat.isSymbolicLink() && stat.size <= 64 * 1024 * 1024);
    console.log(JSON.stringify(summarizeLookupRollout(readFileSync(path, "utf8"), turnID), null, 2));
  } catch {
    console.error(JSON.stringify({ auditComplete: false, error: "lookup_audit_failed_redacted" }));
    process.exitCode = 1;
  }
}
