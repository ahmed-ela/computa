import { describe, expect, test } from "bun:test";
import { pairingPlan, parsePairArgs, preparePairedContext, REQUEST_LIMIT, ROLLOUT_LIMIT, type PairingPlan } from "./paired-context";

type Json = Record<string, any>;
function message(id: string, role: "user" | "assistant", text: string): Json {
  return { type: "message", id, role, content: [{ type: role === "user" ? "input_text" : "output_text", text }] };
}
const native = (m: Json) => ({ ...structuredClone(m), internal_chat_message_metadata_passthrough: null });
const record = (type: string, payload: Json): Json => ({ type, payload });
const event = (type: string, turn_id: string, extra: Json = {}) => record("event_msg", { type, turn_id, ...extra });
const response = (item: Json) => record("response_item", native(item));
function fixture() {
  const user = message("original-user", "user", "Remember the exact key KEY_🍀. Respond ACK only for this turn.");
  const assistant = message("original-assistant", "assistant", "ACK");
  const policy = message("live-policy", "user", "# AGENTS.md instructions for /synthetic\n\n<INSTRUCTIONS>Preserve StudyLock. No bypass.</INSTRUCTIONS>");
  const summary = message("native-summary", "assistant", "Key remembered; this is a summary, not a real prior reply.");
  const replacement = [message("compacted-user", "user", user.content[0].text), message("summary-wrapper", "user", "Native summary wrapper: " + summary.content[0].text)];
  const injection = message("injected-assistant", "assistant", assistant.content[0].text);
  const current = message("current-user", "user", "Call status once, then give only the original key.");
  const reasoning = { type: "reasoning", id: "historical-reasoning", summary: [], content: [{ type: "reasoning_text", text: "Old hidden reasoning must not be reconstructed." }], encrypted_content: null };
  const guardian = [native(user), reasoning, native(assistant), native(summary)];
  const compacted = { guardian_history: guardian, replacement_history: replacement.map(native), message: replacement[1].content[0].text };
  const records = [
    event("task_started", "prior"), record("turn_context", { turn_id: "prior" }), response(user), record("response_item", reasoning), response(assistant),
    event("task_complete", "prior", { last_agent_message: "ACK" }),
    event("task_started", "maintenance"), response(summary), record("compacted", compacted), event("task_complete", "maintenance", { last_agent_message: null }),
    response(policy), record("turn_context", { turn_id: "auto-compact-0" }), response(injection),
    event("task_started", "current"), record("turn_context", { turn_id: "current" }), response(current)
  ];
  const suffix = [current, { type: "reasoning", id: "unchanged-current-reasoning", content: [{ type: "reasoning_text", text: "Current reasoning is preserved." }] },
    message("blank-before-tool", "assistant", "\n\n"), { type: "function_call", id: "fc-test", name: "status", call_id: "call-test", arguments: "{}" },
    { type: "function_call_output", id: "fco-test", call_id: "call-test", output: '{"ok":true}' }];
  const body = { model: "synthetic-4b", instructions: "Keep every instruction and policy unchanged.", temperature: 0.7, top_p: 0.95,
    tools: [{ type: "function", name: "status", parameters: { type: "object", additionalProperties: false } }],
    tool_choice: "auto", reasoning: { effort: "medium" }, parallel_tool_calls: false, stream: true, store: false,
    prompt_cache_key: "unchanged-key", client_metadata: { synthetic: "only" }, input: [...replacement, policy, injection, ...suffix] };
  const plan: PairingPlan = { version: 1, compactedPrefixCount: 2, currentUserIndex: 4, guardianMessageIndices: [0, 2], preservedBeforeCurrentIndices: [2] };
  return { user, assistant, policy, summary, replacement, injection, current, guardian, compacted, records, suffix, body, plan };
}
function run(f = fixture()) {
  return preparePairedContext(JSON.stringify(f.body), f.records.map(r => JSON.stringify(r)).join("\n") + "\n", f.plan);
}
describe("offline same-request text-history counterfactual", () => {
  test("replaces only compacted history; exact policy and entire current tool suffix remain unchanged", () => {
    const f = fixture(), original = structuredClone(f), result = run(f), next = JSON.parse(result.raw);
    expect(next).toEqual({ ...f.body, input: [f.user, f.assistant, f.policy, ...f.suffix] });
    expect(f).toEqual(original);
    expect(next.input.slice(2)).toEqual(f.body.input.filter((_, i) => i === 2 || i >= 4));
    expect(result.audit.historicalReasoning).toBe("omitted-not-reconstructed");
    expect(result.audit.omittedHistoricalReasoningItems).toBe(1);
    expect(result.audit.removedInjectedEvidenceCount).toBe(1);
    expect(result.audit.sourceRequestSHA256).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.stringify(result.audit)).not.toContain("KEY_🍀");
    expect(JSON.stringify(result.audit)).not.toContain("No bypass");
  });
  test("preserves settings even when unusual but does not invent a sampler", () => {
    const f = fixture(); delete (f.body as any).temperature;
    (f.body as any).custom_sampler = { min_p: 0.03, nested: [true, null, "exact"] };
    const next = JSON.parse(run(f).raw);
    expect(next.temperature).toBeUndefined(); expect(next.custom_sampler).toEqual((f.body as any).custom_sampler);
  });
  test("JSON key order does not create false provenance mismatches", () => {
    const f = fixture(); f.guardian[0] = Object.fromEntries(Object.entries(f.guardian[0]).reverse());
    expect(() => run(f)).not.toThrow();
  });
  test("accepts installed native provenance fields without replaying them", () => {
    const f = fixture();
    const meta = (turn_id: string, kind: string) => ({ turn_id, create_time: 123.5, content_item_kinds: [kind] });
    for (const index of [2, 4]) f.records[index].payload.internal_chat_message_metadata_passthrough = meta("prior", index === 2 ? "user.text" : "unknown");
    f.guardian[0].internal_chat_message_metadata_passthrough = meta("prior", "user.text");
    f.guardian[2].internal_chat_message_metadata_passthrough = meta("prior", "unknown");
    f.compacted.replacement_history[1].internal_chat_message_metadata_passthrough = meta("maintenance", "compaction.summary");
    f.records[10].payload.internal_chat_message_metadata_passthrough = meta("auto-compact-0", "agents_md.instructions");
    const result = JSON.parse(run(f).raw);
    expect(result.input[0]).toEqual(f.user);
    expect(result.input[1]).toEqual(f.assistant);
    expect(result.input[2]).toEqual(f.policy);
    expect(result.input[0].internal_chat_message_metadata_passthrough).toBeUndefined();
  });
  test("accepts tagged native compactor output only as excluded lifecycle evidence", () => {
    const f = fixture();
    const metadata = { turn_id: "maintenance", content_item_kinds: ["compaction.summary"] };
    f.records[7].payload.internal_chat_message_metadata_passthrough = structuredClone(metadata);
    f.guardian[3].internal_chat_message_metadata_passthrough = structuredClone(metadata);
    const result = run(f), next = JSON.parse(result.raw);
    expect(next.input).toEqual([f.user, f.assistant, f.policy, ...f.suffix]);
    expect(result.audit.originalMessageCount).toBe(2);
    expect(next.input.some((item: Json) => item.id === f.summary.id)).toBe(false);
  });
  test("rejects compaction tags on ordinary replies or injected assistant evidence", () => {
    for (const target of ["completed", "guardian", "injection-record", "injection-request"]) {
      const f = fixture();
      const item = target === "completed" ? f.records[4].payload
        : target === "guardian" ? f.guardian[2]
        : target === "injection-record" ? f.records[12].payload : f.body.input[3];
      item.internal_chat_message_metadata_passthrough = {
        turn_id: target === "completed" || target === "guardian" ? "prior" : "auto-compact-0",
        content_item_kinds: ["compaction.summary"]
      };
      expect(() => run(f)).toThrow("Unknown native message metadata");
    }
  });
  test("rejects tagged compactor evidence with an uncorrelated turn", () => {
    for (const target of ["record", "guardian"]) {
      const f = fixture(), item = target === "record" ? f.records[7].payload : f.guardian[3];
      item.internal_chat_message_metadata_passthrough = { turn_id: "other", content_item_kinds: ["compaction.summary"] };
      expect(() => run(f)).toThrow("Compactor message provenance");
    }
  });
  test("rejects mismatched provenance and policy/summary labeled as actual user input", () => {
    for (const metadata of [
      { turn_id: "other", content_item_kinds: ["user.text"] },
      { turn_id: "prior", content_item_kinds: ["agents_md.instructions"] },
      { turn_id: "prior", content_item_kinds: ["compaction.summary"] },
      { turn_id: "prior", content_item_kinds: ["unknown-kind"] }
    ]) { const f = fixture(); f.records[2].payload.internal_chat_message_metadata_passthrough = metadata; expect(() => run(f)).toThrow(); }
  });
  test("fails on missing, duplicate, reordered or summary guardian selections", () => {
    for (const indices of [[0], [0, 0], [2, 0], [0, 2, 3], [0, 3]]) {
      const f = fixture(); f.plan.guardianMessageIndices = indices; expect(() => run(f)).toThrow();
    }
  });
  test("fails if selected output is fabricated despite matching IDs", () => {
    const f = fixture(); f.guardian[2].content[0].text = "a fabricated answer";
    expect(() => run(f)).toThrow("differs from actual");
  });
  test("fails if a completed user turn is omitted from guardian", () => {
    const f = fixture(); f.guardian.splice(2, 1); f.plan.guardianMessageIndices = [0, 2];
    expect(() => run(f)).toThrow();
  });
  test("fails if native completion disagrees with assistant text", () => {
    const f = fixture(); f.records[5].payload.last_agent_message = "different";
    expect(() => run(f)).toThrow("native completion");
  });
  test("fails if completed history has tool calls or outputs, even if absent from guardian", () => {
    for (const tool of [{ type: "function_call", name: "status", arguments: "{}", call_id: "old" },
      { type: "function_call_output", call_id: "old", output: "old result" }, { type: "custom_tool_call", input: "not allowed" }]) {
      const f = fixture(); f.records.splice(4, 0, record("response_item", tool));
      expect(() => run(f)).toThrow("Historical tools");
    }
  });
  test("fails on hidden guardian tools or unknown message provenance", () => {
    for (const item of [{ type: "function_call", name: "status" }, native(message("unproven", "assistant", "invented")), native(message("foreign-policy", "user", "policy"))]) {
      const f = fixture(); f.guardian.push(item); expect(() => run(f)).toThrow();
    }
  });
  test("fails on truncated, overlapping, mismatched, failed or mid-turn-compacted history", () => {
    const variants = [
      (f: ReturnType<typeof fixture>) => { f.records.splice(5, 1); },
      (f: ReturnType<typeof fixture>) => { f.records.splice(2, 0, event("task_started", "overlap")); },
      (f: ReturnType<typeof fixture>) => { f.records[1].payload.turn_id = "other"; },
      (f: ReturnType<typeof fixture>) => { f.records.splice(5, 0, event("turn_aborted", "prior")); },
      (f: ReturnType<typeof fixture>) => { f.records.splice(4, 0, record("compacted", f.compacted)); }
    ];
    for (const change of variants) { const f = fixture(); change(f); expect(() => run(f)).toThrow(); }
  });
  test("fails on changed or misplaced current policy and prevents dropping it", () => {
    const variants = [
      (f: ReturnType<typeof fixture>) => { f.body.input[2] = { ...f.policy, content: [{ type: "input_text", text: "weaker policy" }] }; },
      (f: ReturnType<typeof fixture>) => { f.plan.preservedBeforeCurrentIndices = []; },
      (f: ReturnType<typeof fixture>) => { f.plan.preservedBeforeCurrentIndices = [1, 2]; },
      (f: ReturnType<typeof fixture>) => { f.plan.preservedBeforeCurrentIndices = [3]; },
      (f: ReturnType<typeof fixture>) => { f.records.splice(10, 0, response(message("another-policy", "user", f.policy.content[0].text))); }
    ];
    for (const change of variants) { const f = fixture(); change(f); expect(() => run(f)).toThrow(); }
  });
  test("fails on changed current user or ambiguous user boundary", () => {
    const f = fixture(); f.body.input[4] = message("current-user", "user", "changed request");
    expect(() => run(f)).toThrow("current-user provenance");
    const g = fixture(); g.body.input.push(message("another-current", "user", "another request"));
    expect(() => run(g)).toThrow("final user");
  });
  test("fails on modified replacement prefix, missing users or unproven summary", () => {
    const variants = [
      (f: ReturnType<typeof fixture>) => { f.body.input[0] = message("compacted-user", "user", "modified old request"); },
      (f: ReturnType<typeof fixture>) => { f.compacted.message = "different summary"; },
      (f: ReturnType<typeof fixture>) => { f.compacted.replacement_history[0].content[0].text = "wrong old request"; f.body.input[0].content[0].text = "wrong old request"; },
      (f: ReturnType<typeof fixture>) => { f.plan.compactedPrefixCount = 1; }
    ];
    for (const change of variants) { const f = fixture(); change(f); expect(() => run(f)).toThrow(); }
  });
  test("fails on a fabricated injected reply instead of silently deleting it", () => {
    const f = fixture(); f.injection.content[0].text = "invented evidence";
    expect(() => run(f)).toThrow();
  });
  test("supports exact bounded unicode first/last excerpt from newest actual reply", () => {
    const f = fixture(), answer = "🍀".repeat(1000);
    f.assistant.content[0].text = answer;
    f.guardian[2].content[0].text = answer;
    f.records[4].payload.content[0].text = answer;
    f.records[5].payload.last_agent_message = answer;
    const header = "[Historical completed assistant reply; excerpt]\n", omission = "\n[... middle omitted ...]\n";
    const available = 2048 - Buffer.byteLength(header + omission);
    const excerpt = header + "🍀".repeat(Math.floor(Math.floor(available / 2) / 4)) + omission + "🍀".repeat(Math.floor(Math.ceil(available / 2) / 4));
    f.injection.content[0].text = excerpt;
    f.records[12].payload.content[0].text = excerpt;
    expect(JSON.parse(run(f).raw).input[1].content[0].text).toBe(answer);
    f.records[12].payload.content[0].text = excerpt + "x";
    expect(() => run(f)).toThrow("Unproven injected");
  });
  test("does not accept images, unknown metadata or elevated roles in historical messages", () => {
    for (const change of [
      (m: Json) => { m.content = [{ type: "input_image", image_url: "local" }]; },
      (m: Json) => { m.internal_chat_message_metadata_passthrough = { trusted: true }; },
      (m: Json) => { m.role = "system"; },
      (m: Json) => { m.capabilities = ["execute"]; }
    ]) { const f = fixture(); change(f.guardian[0]); expect(() => run(f)).toThrow(); }
  });
  test("rejects chained, hosted-tool, background and oversized inputs", () => {
    for (const change of [{ previous_response_id: "old" }, { conversation: "conversation" }, { background: true }, { tools: [{ type: "mcp" }] }]) {
      const f = fixture(); Object.assign(f.body, change); expect(() => run(f)).toThrow();
    }
    const f = fixture();
    expect(() => preparePairedContext(" ".repeat(REQUEST_LIMIT + 1), "", f.plan)).toThrow("byte limit");
    expect(() => preparePairedContext(JSON.stringify(f.body), " ".repeat(ROLLOUT_LIMIT + 1), f.plan)).toThrow("16 MiB");
  });
  test("last-compacted binding rejects a request from an older window", () => {
    const f = fixture();
    f.records.push(event("task_complete", "current", { last_agent_message: "ignored current output" }), event("task_started", "later-maintenance"),
      record("compacted", { ...f.compacted, replacement_history: [native(message("different", "user", "different"))] }));
    expect(() => run(f)).toThrow("Captured prefix");
  });
});
test("strict CLI has no network/execution flags; rejects duplicate, relative or missing paths", () => {
  const args = ["--request", "/tmp/r", "--rollout", "/tmp/l", "--plan", "/tmp/p", "--out", "/tmp/o"];
  expect(parsePairArgs(args)["--out"]).toBe("/tmp/o");
  for (const candidate of [args.slice(0, -1), [...args, "--request", "/tmp/x"], [...args, "--upstream", "https://example.com"], ["--request", "relative"]]) {
    expect(() => parsePairArgs(candidate)).toThrow();
  }
  expect(() => pairingPlan(JSON.stringify({ ...fixture().plan, allowUnsafe: true }))).toThrow();
});
