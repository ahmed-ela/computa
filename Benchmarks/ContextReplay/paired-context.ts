// Offline diagnostic only: no networking, inference, tool executor, or runtime edits.
// This is an explicit text-history counterfactual, NOT a reconstruction of old
// hidden reasoning. Historical reasoning is deliberately omitted and reported.
import { createHash } from "node:crypto";
import { mkdir, open, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

type Json = Record<string, any>;
export const REQUEST_LIMIT = 1024 * 1024;
export const ROLLOUT_LIMIT = 16 * 1024 * 1024;
const PLAN_LIMIT = 64 * 1024;
export interface PairingPlan {
  version: 1;
  // Exact initial replacement_history item count, not an inferred boundary.
  compactedPrefixCount: number;
  currentUserIndex: number;
  // All actual completed user-turn messages in the LAST guardian_history.
  guardianMessageIndices: number[];
  // Policy items between replacement_history and the current user. Any other
  // intervening item must be a proven native-injected assistant-evidence item.
  preservedBeforeCurrentIndices: number[];
}
const bytes = (value: string) => Buffer.byteLength(value, "utf8");
const sha = (value: string) => createHash("sha256").update(value).digest("hex");
function need(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); }
function object(value: unknown): value is Json { return !!value && typeof value === "object" && !Array.isArray(value); }
function canonical(value: any): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (object(value)) return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  return JSON.stringify(value);
}
const same = (a: any, b: any) => canonical(a) === canonical(b);
function parseObject(raw: string, limit: number, label: string): Json {
  need(bytes(raw) <= limit, `${label} exceeds byte limit`);
  const value = JSON.parse(raw);
  need(object(value), `${label} must be an object`);
  return value;
}
function indices(value: unknown, label: string): asserts value is number[] {
  need(Array.isArray(value) && value.every((n, i) => Number.isSafeInteger(n) && n >= 0 && (i === 0 || n > value[i - 1])), `${label} must be strictly increasing nonnegative indices`);
}
export function pairingPlan(raw: string): PairingPlan {
  const p = parseObject(raw, PLAN_LIMIT, "Plan");
  need(same(Object.keys(p).sort(), ["version", "compactedPrefixCount", "currentUserIndex", "guardianMessageIndices", "preservedBeforeCurrentIndices"].sort()), "Unexpected or missing plan fields");
  need(p.version === 1 && Number.isSafeInteger(p.compactedPrefixCount) && p.compactedPrefixCount > 0
    && Number.isSafeInteger(p.currentUserIndex) && p.currentUserIndex > p.compactedPrefixCount, "Invalid plan boundaries");
  indices(p.guardianMessageIndices, "Guardian message indices");
  indices(p.preservedBeforeCurrentIndices, "Preserved policy indices");
  need(p.guardianMessageIndices.length >= 2 && p.preservedBeforeCurrentIndices.length > 0, "Explicit history and policy proof required");
  return p as PairingPlan;
}

// Convert the installed native rollout message to its public Responses shape.
// Only known native provenance metadata is removed; unknown fields fail.
function publicMessage(value: any, compactorTurnID?: string): Json {
  need(object(value) && value.type === "message" && ["user", "assistant"].includes(value.role), "Expected user/assistant text message");
  need(Object.keys(value).every(k => ["type", "id", "role", "content", "phase", "internal_chat_message_metadata_passthrough"].includes(k)), "Unknown message fields");
  const metadata = value.internal_chat_message_metadata_passthrough;
  if (metadata != null) {
    need(object(metadata) && Object.keys(metadata).every(k => ["turn_id", "create_time", "content_item_kinds"].includes(k))
      && typeof metadata.turn_id === "string" && metadata.turn_id.length > 0
      && (metadata.create_time === undefined || (typeof metadata.create_time === "number" && Number.isFinite(metadata.create_time)))
      && Array.isArray(metadata.content_item_kinds) && metadata.content_item_kinds.length === value.content?.length
      && (value.role === "assistant"
        ? metadata.content_item_kinds.every((kind: string) => kind === "unknown")
          || (compactorTurnID !== undefined && metadata.content_item_kinds.every((kind: string) => kind === "compaction.summary"))
        : metadata.content_item_kinds.every((kind: string) => ["user.text", "agents_md.instructions", "compaction.summary"].includes(kind))),
    "Unknown native message metadata is unsupported");
    need(compactorTurnID === undefined || metadata.turn_id === compactorTurnID, "Compactor message provenance mismatches native turn");
  }
  need(typeof value.id === "string" && value.id.length > 0, "Native message ID required for provenance");
  need(value.phase === undefined || value.phase === null || ["commentary", "final_answer"].includes(value.phase), "Unsupported message phase");
  need(Array.isArray(value.content) && value.content.length > 0 && value.content.every((c: any) => object(c)
    && same(Object.keys(c).sort(), ["text", "type"]) && c.type === (value.role === "user" ? "input_text" : "output_text")
    && typeof c.text === "string"), "Only exact text content is supported");
  const result: Json = { type: "message", id: value.id, role: value.role, content: structuredClone(value.content) };
  if (value.phase !== undefined && value.phase !== null) result.phase = value.phase;
  return result;
}
const text = (item: Json) => item.content.map((c: Json) => c.text).join("");
function withoutID(item: Json): Json { const { id, ...rest } = item; return rest; }
function boundedEvidence(original: string): string {
  if (bytes(original) <= 2048) return original;
  const header = "[Historical completed assistant reply; excerpt]\n", omission = "\n[... middle omitted ...]\n";
  const available = 2048 - bytes(header) - bytes(omission), firstLimit = Math.floor(available / 2);
  const scalars = Array.from(original);
  let first = "", last = "";
  for (const scalar of scalars) { if (bytes(first + scalar) > firstLimit) break; first += scalar; }
  for (let i = scalars.length - 1; i >= 0; i--) { if (bytes(scalars[i] + last) > available - firstLimit) break; last = scalars[i] + last; }
  return header + first + omission + last;
}
interface RecordLine { type: string; payload: Json; }
interface Turn { id: string; context: boolean; compacted: boolean; items: Json[]; }
function parseRollout(raw: string): RecordLine[] {
  need(bytes(raw) <= ROLLOUT_LIMIT, "Rollout exceeds 16 MiB");
  const lines = raw.trimEnd().split(/\r?\n/);
  need(lines.length <= 100_000 && lines.length > 0, "Rollout line limit exceeded");
  return lines.map(line => {
    const entry = JSON.parse(line);
    need(object(entry) && typeof entry.type === "string" && object(entry.payload), "Malformed rollout record");
    return entry as RecordLine;
  });
}

export function preparePairedContext(requestRaw: string, rolloutRaw: string, suppliedPlan: PairingPlan) {
  const plan = pairingPlan(JSON.stringify(suppliedPlan));
  const request = parseObject(requestRaw, REQUEST_LIMIT, "Request"), input = request.input;
  need(typeof request.model === "string" && request.model.length > 0 && Array.isArray(input), "Explicit model and input history required");
  need(!request.previous_response_id && !request.conversation && !request.background, "Chained/background requests are unsupported");
  need(request.tools === undefined || (Array.isArray(request.tools) && request.tools.every((t: any) => object(t) && t.type === "function" && typeof t.name === "string")), "Only inert custom-function definitions are supported");
  need(plan.currentUserIndex < input.length && input.findLastIndex((i: any) => i?.type === "message" && i.role === "user") === plan.currentUserIndex, "Current user must be the final user message");
  const currentUser = publicMessage(input[plan.currentUserIndex]);
  const records = parseRollout(rolloutRaw), lastCompacted = records.findLastIndex(r => r.type === "compacted");
  need(lastCompacted >= 0, "Missing compacted record");
  const compacted = records[lastCompacted].payload;
  need(Array.isArray(compacted.guardian_history) && Array.isArray(compacted.replacement_history), "Native guardian and replacement history required");
  const guardian = compacted.guardian_history as Json[], replacement = compacted.replacement_history.map((item: Json) => publicMessage(item));
  need(plan.compactedPrefixCount === replacement.length && same(input.slice(0, plan.compactedPrefixCount).map((item: Json) => publicMessage(item)), replacement), "Captured prefix does not exactly match last native replacement history");

  const actual: Json[] = [], excluded = new Map<string, Json>(), policies = new Map<string, Json>();
  // Only native compaction-only lifecycle evidence may authorize summary tags.
  // Injected excerpts and completed user-turn replies must still use normal validation.
  const excludedCompactorTurns = new Map<string, string>();
  const postCompactionEvidence = new Map<string, Json>();
  let active: Turn | undefined, currentUserProven = false, omittedReasoning = 0;
  // Parse native lifecycle, not text labels: a compaction-only turn is never a
  // completed user turn, and injected evidence has no matching task_started.
  for (let index = 0; index < records.length; index++) {
    const record = records[index], p = record.payload;
    if (record.type === "event_msg" && p.type === "task_started") {
      need(!active && typeof p.turn_id === "string", "Ambiguous overlapping native turns");
      active = { id: p.turn_id, context: false, compacted: false, items: [] };
    } else if (record.type === "turn_context" && active) {
      need(p.turn_id === active.id, "Mismatched turn context"); active.context = true;
    } else if (record.type === "response_item") {
      if (active?.context) {
        need(p.internal_chat_message_metadata_passthrough?.turn_id === undefined || p.internal_chat_message_metadata_passthrough.turn_id === active.id, "Message provenance mismatches active turn");
        if (p.type === "message" && p.role === "user" && p.internal_chat_message_metadata_passthrough != null) {
          need(p.internal_chat_message_metadata_passthrough.content_item_kinds?.every((kind: string) => kind === "user.text"), "Injected policy/summary cannot be an actual user turn");
        }
        active.items.push(p);
        if (index > lastCompacted && p.type === "message" && p.role === "user" && same(publicMessage(p), currentUser)) currentUserProven = true;
      } else if (p.type === "message") {
        const message = publicMessage(p, active && p.role === "assistant" ? active.id : undefined);
        if (message.role === "user") {
          need(text(message).startsWith("# AGENTS.md instructions for ") && text(message).includes("<INSTRUCTIONS>"), "Unrecognized out-of-turn policy message");
          if (index > lastCompacted) policies.set(message.id, message);
        } else if (active) {
          // Native manual compaction has task_started but no turn_context.
          active.items.push(p);
        } else {
          const latest = actual.findLast(i => i.role === "assistant");
          need(latest && text(message) === boundedEvidence(text(latest)), "Unproven injected assistant evidence");
          excluded.set(message.id, message);
          if (index > lastCompacted) postCompactionEvidence.set(message.id, message);
        }
      } else if (active) active.items.push(p);
      else need(p.type === "reasoning", "Unsupported out-of-turn historical item");
    } else if (record.type === "compacted") {
      need(active, "Compaction without native turn");
      active.compacted = true;
      need(!active.items.some(i => i.type === "message" && i.role === "user"), "Mid-user-turn compaction is not supported by this counterfactual");
      for (const item of active.items) if (item.type === "message") {
        const m = publicMessage(item, active.id); need(m.role === "assistant", "Unexpected compaction user message");
        excluded.set(m.id, m); excludedCompactorTurns.set(m.id, active.id);
      } else need(item.type === "reasoning", "Historical tools are unsupported");
    } else if (record.type === "event_msg" && p.type === "task_complete") {
      need(active && p.turn_id === active.id, "Uncorrelated native completion");
      if (!active.compacted && index < lastCompacted) {
        need(active.context, "Completed user turn has no context");
        const messages: Json[] = [];
        for (const item of active.items) {
          if (item.type === "reasoning") { omittedReasoning++; continue; }
          need(item.type === "message", "Historical tools are unsupported");
          messages.push(publicMessage(item));
        }
        need(messages.length >= 2 && messages[0].role === "user" && messages.slice(1).every(m => m.role === "assistant"), "Ambiguous completed user-turn messages");
        need(messages.every(m => text(m).trim().length > 0), "Blank historical message");
        need(typeof p.last_agent_message === "string" && p.last_agent_message === text(messages[messages.length - 1]), "Final assistant does not match native completion");
        actual.push(...messages);
      }
      active = undefined;
    } else if (record.type === "event_msg" && ["turn_aborted", "task_failed", "error"].includes(p.type) && index < lastCompacted) {
      throw new Error("Failed/aborted prior turn is unsupported");
    }
  }
  need(currentUserProven && actual.length >= 2, "Missing actual prior history or current-user provenance");
  const actualByID = new Map(actual.map(m => [m.id, m]));
  need(actualByID.size === actual.length, "Duplicate historical IDs");
  const expectedIndices: number[] = [];
  guardian.forEach((item, index) => {
    if (item.type === "reasoning") return; // Explicitly excluded, never replayed.
    need(item.type === "message", "Historical guardian tools are unsupported");
    const message = publicMessage(item, actualByID.has(item.id) ? undefined : excludedCompactorTurns.get(item.id)), proven = actualByID.get(message.id);
    if (proven) { need(same(message, proven), "Guardian message differs from actual completed output"); expectedIndices.push(index); }
    else need(excluded.has(message.id) && same(message, excluded.get(message.id)), "Unproven guardian message or policy");
  });
  need(same(plan.guardianMessageIndices, expectedIndices), "Guardian indices omit/reorder/include unproven historical messages");
  const original = expectedIndices.map(i => publicMessage(guardian[i]));
  need(same(original, actual), "Guardian does not contain every completed turn exactly once in order");
  const historicalUsers = original.filter(m => m.role === "user").map(withoutID);
  need(same(replacement.slice(0, -1).map(withoutID), historicalUsers), "Replacement users do not match complete original user history");
  need(replacement.at(-1)?.role === "user" && text(replacement.at(-1)!) === compacted.message, "Unproven native summary boundary");

  const policySet = new Set(plan.preservedBeforeCurrentIndices), preserved: Json[] = [];
  need(plan.preservedBeforeCurrentIndices.every(i => i >= plan.compactedPrefixCount && i < plan.currentUserIndex), "Policy index crosses historical/current boundary");
  for (let i = plan.compactedPrefixCount; i < plan.currentUserIndex; i++) {
    const message = publicMessage(input[i]);
    if (policySet.has(i)) {
      need(message.role === "user" && policies.has(message.id) && same(message, policies.get(message.id)), "Policy item lacks exact native provenance");
      preserved.push(input[i]);
    } else need(message.role === "assistant" && postCompactionEvidence.has(message.id) && same(message, postCompactionEvidence.get(message.id)), "Unknown item between compacted prefix and current user");
  }
  need(preserved.length === policies.size && same(preserved.map(m => m.id), [...policies.keys()]), "Every current injected policy must remain in order");
  const suffix = input.slice(plan.currentUserIndex), prepared = structuredClone(request);
  prepared.input = [...original, ...preserved, ...suffix];
  const { input: beforeInput, ...beforeSettings } = request, { input: afterInput, ...afterSettings } = prepared;
  need(same(beforeSettings, afterSettings) && same(prepared.input.slice(original.length), [...preserved, ...suffix]), "Nonhistorical request changed");
  const raw = JSON.stringify(prepared);
  need(bytes(raw) <= REQUEST_LIMIT, "Counterfactual request exceeds 1 MiB");
  return { raw, audit: {
    version: 1, variant: "uncompacted-completed-text-history", historicalReasoning: "omitted-not-reconstructed",
    omittedHistoricalReasoningItems: omittedReasoning, lastCompactedRecordIndex: lastCompacted,
    originalMessageCount: original.length, compactedPrefixCount: replacement.length,
    removedInjectedEvidenceCount: plan.currentUserIndex - replacement.length - preserved.length,
    preservedPolicyCount: preserved.length, preservedSuffixItemCount: suffix.length,
    sourceRequestSHA256: sha(requestRaw), rolloutSHA256: sha(rolloutRaw), planSHA256: sha(JSON.stringify(plan)),
    counterfactualSHA256: sha(raw), unchangedSettingsSHA256: sha(canonical(beforeSettings)),
    unchangedPolicyAndCurrentSuffixSHA256: sha(canonical([...preserved, ...suffix]))
  } };
}

async function boundedFile(path: string, limit: number): Promise<string> {
  need(isAbsolute(path), "Paths must be absolute");
  const handle = await open(path, "r");
  try {
    const info = await handle.stat(); need(info.isFile() && info.size <= limit, "Input is not a bounded regular file");
    const buffer = Buffer.alloc(limit + 1);
    let used = 0;
    while (used < buffer.length) {
      const { bytesRead } = await handle.read(buffer, used, buffer.length - used, null);
      if (!bytesRead) break; used += bytesRead;
    }
    need(used <= limit, "Input grew beyond byte limit");
    return new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, used));
  } finally { await handle.close(); }
}
export function parsePairArgs(args: string[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i], value = args[i + 1];
    need(["--request", "--rollout", "--plan", "--out"].includes(key) && !Object.hasOwn(result, key) && typeof value === "string" && isAbsolute(value), "Expected unique absolute --request --rollout --plan --out paths");
    result[key] = value;
  }
  need(Object.keys(result).length === 4, "Missing required path"); return result;
}
if (import.meta.main) {
  try {
    const args = parsePairArgs(process.argv.slice(2));
    const [request, rollout, plan] = await Promise.all([
      boundedFile(args["--request"], REQUEST_LIMIT), boundedFile(args["--rollout"], ROLLOUT_LIMIT), boundedFile(args["--plan"], PLAN_LIMIT)
    ]);
    const result = preparePairedContext(request, rollout, pairingPlan(plan));
    await mkdir(args["--out"], { recursive: true, mode: 0o700 });
    await writeFile(join(args["--out"], "uncompacted.request.json"), result.raw, { flag: "wx", mode: 0o600 });
    await writeFile(join(args["--out"], "pair.audit.json"), JSON.stringify(result.audit, null, 2), { flag: "wx", mode: 0o600 });
    console.log(JSON.stringify(result.audit));
  } catch (error) { console.error(JSON.stringify({ error: String(error) })); process.exitCode = 1; }
}
