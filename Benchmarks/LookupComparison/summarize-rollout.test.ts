import { expect, test } from "bun:test";
import { summarizeLookupRollout } from "./summarize-rollout";

const turn = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222";
const cursor = "33333333-3333-4333-8333-333333333333", snapshot = "44444444-4444-4444-8444-444444444444";
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const row = (type: string, payload: any, seconds = 0) => ({ type, payload, timestamp: `2026-09-27T00:00:${String(seconds).padStart(2, "0")}Z` });
const event = (payload: any, seconds = 0) => row("event_msg", payload, seconds);
const call = (id: string, name: string, args: any = {}, seconds = 1) => row("response_item", {
  type: "function_call", name, call_id: id, arguments: JSON.stringify(args) }, seconds);
const output = (id: string, output: any, seconds = 2) => row("response_item", { type: "function_call_output", call_id: id, output }, seconds);
const result = (id: string, tool: string, success: boolean, turn_id = turn) => event({
  type: "dynamic_tool_call_response", turn_id, call_id: id, tool, arguments: { text: "PRIVATE_ARGUMENT" },
  content_items: [{ type: "inputText", text: "PRIVATE_RESULT" }], success, error: success ? null : "PRIVATE_ERROR",
  completed_at_ms: 0, duration: { secs: 0, nanos: 1 } });
const start = [event({ type: "task_started", turn_id: turn }), row("turn_context", { turn_id: turn, model })];
const end = event({ type: "task_complete", turn_id: turn, last_agent_message: "PRIVATE_ANSWER" }, 12);
const inventory = (next_cursor: string | null = cursor, returned = 1, total_count = 2) => JSON.stringify({
  items: returned ? [{ candidate_token: snapshot, title: "PRIVATE_TITLE", title_truncated: false,
    availability: "available", url: "https://private.invalid/document" }] : [], returned, total_count, next_cursor,
  continuation_tool: "computer_v2_continue", metadata_notice: "PRIVATE_NOTICE" });
const browser = (read = "", title = "PRIVATE_TITLE") =>
  `AXSNAPSHOT id=${snapshot} pid=42 bundle="com.google.Chrome" tab_handle=${turn} document_epoch=${other} source=chrome_devtools url="https://private.invalid" title="${title}"\n`
  + `READ view=content scope_node=document source_nodes=10 source_truncated=1 matches=2 shown=1 offset=0 output_truncated=1 field_truncated=1 no_matches=0 visibility=unknown next_cursor=${cursor} observation=live${read}\n`
  + 'CONTENT_EVIDENCE document_content_shown=1 navigation_shown=0 complementary_shown=0 banner_shown=0 contentinfo_shown=0 unknown_shown=0 scope_basis=observed_ancestry subject_relevance=not_verified\n'
  + '#0 role="AXButton" label="PRIVATE_TOOLBAR_INSIDE_MAIN" content_scope=main';
const native = () => `SEMANTIC_READ view=content visited=120 matched=2 offset=0 shown=1 source_truncated=1 output_truncated=0 source_limit_reached=1 next_cursor=- query_status=no_matches_in_visited_source consistency=live_validated_page\n`
  + `AXSNAPSHOT id=${snapshot} pid=42 app="PRIVATE_APP" bundle="private.bundle" root=0 shown=1 total=120 source_truncated=1 output_truncated=0\n#0 role=AXStaticText label="PRIVATE_BODY"`;
const audit = (records: any[]) => summarizeLookupRollout(records.map(record => JSON.stringify(record)).join("\n"), turn);

test("reference tools retain explicit outcome and read framing without exporting references", () => {
  const tools = ["computer_v2_read_page", "computer_v2_read_region", "computer_v2_press", "computer_v2_fill", "computer_v2_follow"];
  const records = [...start];
  tools.forEach((tool, index) => records.push(call(String(index), tool, { action_ref: "PRIVATE_REF" }),
    output(String(index), browser()), result(String(index), tool, index !== 2)));
  const measured = audit([...records, end]);
  expect(measured.toolCalls.map(call => call.tool)).toEqual(tools);
  expect(measured.outcomes.readRequests.calls).toBe(2);
  expect(measured.outcomes.inputRequests.calls).toBe(3);
  expect(measured.outcomes.inputRequests.failure).toBe(1);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(5);
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});

test("correlates explicit tool outcomes separately from receipt shapes and final claims", () => {
  const measured = audit([...start, call("tabs", "computer_v2_tabs"), output("tabs", inventory()),
    result("tabs", "computer_v2_tabs", true), call("press", "computer_v2_ax"), output("press", "PRIVATE_FAILURE"),
    result("press", "computer_v2_ax", false), call("unknown", "computer_v2_set_text"), output("unknown", "Success!"), end]);
  expect(measured.outcomes.all).toEqual({ calls: 3, success: 1, failure: 1, unknown: 1, conflicting: 0 });
  expect(measured.outcomes.inputRequests).toEqual({ calls: 2, success: 0, failure: 1, unknown: 1, conflicting: 0 });
  expect(measured.toolCalls[0].receiptLatencyMs).toBe(1000);
  expect(measured.turn).toEqual({ status: "completed", terminalObserved: true, elapsedMs: 12000 });
  expect(measured.modelIsQwen4B).toBe(true);
  expect(measured.answer.correctness).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
  expect(JSON.stringify(measured)).not.toContain("private.invalid");
  expect(JSON.stringify(measured)).not.toContain(snapshot);
});

test("inventory pagination remains metadata with no exhaustive or document coverage claim", () => {
  const measured = audit([...start, call("one", "computer_v2_tabs"), output("one", inventory()),
    call("two", "computer_v2_continue", { cursor }), output("two", inventory(null)), end]);
  expect(measured.reading.inventoryReceiptOccurrences).toBe(2);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.genericContinuationRequests).toBe(1);
  expect(measured.toolCalls[1].previouslyObservedCursorSource).toBe("inventory");
  expect(measured.toolCalls[1].toolResult).toBe("unknown");
  expect(measured.reading.exhaustiveInventoryCoverage).toBeNull();
  expect(measured.reading.uniqueDocumentsRead).toBeNull();
});

test("browser and native receipts retain bounded per-page metrics without promoting main controls into content", () => {
  const measured = audit([...start, call("browser", "computer_v2_snapshot", { view: "content" }), output("browser", browser()),
    call("continued", "computer_v2_continue", { cursor }), output("continued", [{ type: "input_text", text: browser().replace("observation=live", "observation=retained") },
      { type: "input_image", image_url: "PRIVATE_IMAGE" }]), call("native", "computer_v2_snapshot"), output("native", native()), end]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(2);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(1);
  expect(measured.toolCalls[0].readObservation.reportedStructuralCounts.document_content_shown).toBe(1);
  expect(measured.toolCalls[0].readObservation.fieldTruncated).toBe(true);
  expect(measured.toolCalls[1].previouslyObservedCursorSource).toBe("browser");
  expect(measured.toolCalls[2].readObservation.sourceLimitReached).toBe(true);
  expect(measured.reading.exhaustiveDocumentCoverage).toBeNull();
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(measured.answer.unsupportedClaims).toBeNull();
});

test("unrelated turns and compacted replacement history never contribute tools or answers", () => {
  const measured = audit([row("turn_context", { turn_id: other }), call("foreign", "computer_v2_snapshot"), output("foreign", browser()),
    ...start, call("read", "computer_v2_tabs"), output("read", inventory()),
    row("compacted", { message: "PRIVATE_SUMMARY", replacement_history: [call("retained", "computer_v2_snapshot"), output("retained", browser())] }),
    event({ type: "context_compacted" }), result("read", "computer_v2_tabs", false, other), end,
    row("turn_context", { turn_id: other }), call("later", "computer_v2_snapshot")]);
  expect(measured.outcomes.all.calls).toBe(1);
  expect(measured.outcomes.all.unknown).toBe(1);
  expect(measured.compactions).toEqual({ checkpointRecords: 1, notificationEvents: 1 });
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
});

test("duplicates never increase receipt counts and conflicting explicit outcomes remain unknown", () => {
  const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", browser()), output("read", browser()),
    output("orphan", browser()), result("read", "computer_v2_snapshot", true), result("read", "computer_v2_snapshot", false),
    result("missing", "computer_v2_tabs", true), result("read", "computer_v2_tabs", true)]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(1);
  expect(measured.integrity).toEqual({ duplicateOutputs: 1, orphanOutputs: 1, duplicateResults: 1, orphanResults: 1, invalidResults: 1 });
  expect(measured.outcomes.all.conflicting).toBe(1);
  expect(measured.outcomes.all.success).toBe(0);
  expect(measured.turn.status).toBe("unknown");
  expect(measured.turn.elapsedMs).toBeNull();
});

test("read-looking strings in user/assistant messages, unknown tools and non-header positions are ignored", () => {
  const measured = audit([...start,
    row("response_item", { type: "message", role: "user", content: [{ type: "input_text", text: browser() }] }),
    row("response_item", { type: "message", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: browser() }] }),
    call("unknown", "PRIVATE_UNKNOWN_TOOL"), output("unknown", browser()),
    call("body", "computer_v2_snapshot"), output("body", "PRIVATE_INTRO\n" + browser()),
    call("notread", "computer_v2_status"), output("notread", inventory()),
    call("wrapper", "computer_v2_snapshot"), output("wrapper", "NATIVE_AX scope=another_window\n" + native())]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.inventoryReceiptOccurrences).toBe(0);
  expect(measured.answer.finalMessages).toBe(1);
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});

test("duplicate header fields, unbalanced quotes and oversized headers cannot create coverage", () => {
  for (const body of [browser(" next_cursor=none"), browser(" view=links"), browser("", 'PRIVATE_UNCLOSED'),
    browser("", "x".repeat(32 * 1024))]) {
    const malformed = body.includes("PRIVATE_UNCLOSED") ? body.replace('title="PRIVATE_UNCLOSED"', 'title="PRIVATE_UNCLOSED') : body;
    expect(audit([...start, call("read", "computer_v2_snapshot"), output("read", malformed)]).reading.browserSemanticReceiptOccurrences).toBe(0);
  }
  const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", browser("", `next_cursor=${other}`)),
    call("continue", "computer_v2_continue", { cursor: other })]);
  expect(measured.toolCalls[1].previouslyObservedCursorSource).toBeNull();
});

test("empty and truncated/filter-miss receipts are observations, never verified negatives", () => {
  const measured = audit([...start, call("empty", "computer_v2_tabs"), output("empty", inventory(null, 0, 0)),
    call("miss", "computer_v2_snapshot", { query: "PRIVATE_FILTER" }), output("miss", native()), end]);
  expect(measured.toolCalls[0].readObservation.returned).toBe(0);
  expect(measured.toolCalls[1].readObservation.queryStatus).toBe("no_matches_in_visited_source");
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(measured.outcomes.all.unknown).toBe(2);
});

test("terminal failure and abort stay separate from completed turns and invalid time stays unknown", () => {
  expect(audit([...start, event({ type: "task_complete", turn_id: turn, error: { message: "PRIVATE_ERROR" } }, 3)]).turn.status).toBe("failed");
  expect(audit([...start, event({ type: "turn_aborted", turn_id: turn, reason: "interrupted" }, 3)]).turn).toEqual({
    status: "aborted", terminalObserved: true, elapsedMs: 3000 });
  expect(audit([...start, { ...end, timestamp: "not-a-date" }]).turn.elapsedMs).toBeNull();
});

test("malformed envelopes fail redacted, malformed arguments and output shapes remain explicit", () => {
  expect(() => summarizeLookupRollout('{"PRIVATE_SECRET":', turn)).toThrow("lookup_audit_failed_redacted");
  expect(() => audit([row("turn_context", { turn_id: other })])).toThrow("redacted");
  expect(() => audit([...start, call("same", "computer_v2_tabs"), call("same", "computer_v2_tabs")])).toThrow("redacted");
  const malformed = call("bad", "computer_v2_snapshot"); malformed.payload.arguments = "PRIVATE_MALFORMED";
  const measured = audit([...start, malformed, output("bad", [{ type: "unrecognized", text: browser() }])]);
  expect(measured.toolCalls[0].argumentsParsed).toBe(false);
  expect(measured.toolCalls[0].outputShapeRecognized).toBe(false);
  expect(measured.toolCalls[0].toolResult).toBe("unknown");
});

test("only actual native wrapper lines can expose progressive or plain native observations", () => {
  const wrapper = "NATIVE_AX scope=bound_window activation=none. Semantic AX/set_value only; global key/pointer tools are unavailable in this background binding. Read-only images grant no input authority. Dispatch is not outcome verification.";
  const plain = native().split("\n").slice(1).join("\n");
  const measured = audit([...start, call("progressive", "computer_v2_snapshot"), output("progressive", wrapper + "\n" + native()),
    call("plain", "computer_v2_snapshot"), output("plain", plain),
    call("fake", "computer_v2_snapshot"), output("fake", "NATIVE_AX scope=bound_window activation=none MALICIOUS\n" + native())]);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(2);
  expect(measured.toolCalls[1].readObservation.continuationMeasured).toBe(false);
  expect(measured.toolCalls[2].readObservation).toBeNull();
});

test("legacy continuations are counted and duplicate output cannot introduce a cursor", () => {
  const measured = audit([...start, call("inventory", "computer_v2_tabs"), output("inventory", inventory()),
    output("inventory", inventory(other)), call("legacy", "computer_v2_tabs", { cursor }), output("legacy", inventory(null)),
    call("unobserved", "computer_v2_continue", { cursor: other }), output("unobserved", "PRIVATE_REJECTED_CURSOR"),
    call("page", "computer_v2_snapshot"), output("page", browser()),
    call("legacyPage", "computer_v2_snapshot", { cursor }), output("legacyPage", browser())]);
  expect(measured.reading.continuationRequests).toBe(3);
  expect(measured.reading.genericContinuationRequests).toBe(1);
  expect(measured.reading.continuationRequestsWithPreviouslyObservedCursor).toBe(2);
  expect(measured.toolCalls[2].previouslyObservedCursorSource).toBeNull();
  expect(measured.toolCalls[4].previouslyObservedCursorSource).toBe("browser");
});

test("malformed inventory envelopes and content arrays do not count as metadata reads", () => {
  const broken = JSON.parse(inventory()); broken.returned = 2;
  const measured = audit([...start, call("wrongCount", "computer_v2_tabs"), output("wrongCount", JSON.stringify(broken)),
    call("invalidCursor", "computer_v2_tabs"), output("invalidCursor", inventory("PRIVATE_CURSOR")),
    call("mixedContent", "computer_v2_tabs"), output("mixedContent", [{ type: "input_text", text: inventory() }, { type: "input_text", text: "PRIVATE_BODY" }])]);
  expect(measured.reading.inventoryReceiptOccurrences).toBe(0);
  expect(measured.outcomes.all.unknown).toBe(3);
});

test("fake success fields on function outputs do not create lifecycle proof", () => {
  const receipt = output("read", inventory()); receipt.payload.success = true;
  const measured = audit([...start, call("read", "computer_v2_tabs"), receipt,
    row("compacted", { replacement_history: [result("read", "computer_v2_tabs", true)] })]);
  expect(measured.toolCalls[0].toolResult).toBe("unknown");
  expect(measured.outcomes.all.success).toBe(0);
});

test("missing starts and invalid timestamps never produce invented elapsed measurements", () => {
  const measured = audit([row("turn_context", { turn_id: turn, model }), call("read", "computer_v2_tabs"), output("read", inventory()), end]);
  expect(measured.turn.elapsedMs).toBeNull();
  expect(measured.toolCalls[0].requestOffsetMs).toBeNull();
  expect(measured.toolCalls[0].receiptLatencyMs).toBeNull();
});

const browserVerified = (operation: string, id = snapshot) => `VERIFIED_PROPERTY operation_id=${operation} snapshot_id=${id}. The predeclared postcondition matched a fresh observation. No input was repeated. This verifies only that property, not an entire task or absent search results.`;
const nativeVerified = (operation: string) => `VERIFIED_PROPERTY operation_id=${operation} snapshot_id=${snapshot}. The predeclared native property matched a fresh read of the exact bound window. No input was repeated. Selection or a detail heading does not prove message sender, incoming direction, or latest ordering.`;
const browserPending = (operation: string) => `VERIFICATION_PENDING operation_id=${operation}. The bounded read-only verification did not establish the declared result. No input was repeated. Do not change the postcondition or repeat the action. PRIVATE_DIAGNOSTIC`;
const nativePending = (operation: string) => `VERIFICATION_PENDING operation_id=${operation}. Bounded read-only observation could not establish the original native result. No input was replayed. Do not repeat input or change the postcondition. PRIVATE_DIAGNOSTIC`;
const textItem = (text: string) => ({ type: "input_text", text });

test("real browser post-action wrappers preserve observations and cursor lineage without proving the action", () => {
  const measured = audit([...start, call("press", "computer_v2_ax"), output("press", [textItem(browserVerified("press")), textItem(browser())]),
    call("continued", "computer_v2_continue", { cursor }), output("continued", browser()),
    call("set", "computer_v2_set_text"), output("set", browserVerified("set") + "\n" + browser()),
    call("pending", "computer_v2_ax"), output("pending", [textItem(browserPending("pending")), textItem(browser())])]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(4);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(3);
  expect(measured.toolCalls[1].previouslyObservedCursorSource).toBe("browser");
  expect(measured.outcomes.all.unknown).toBe(4);
  expect(measured.reading.postActionObservationsUnmeasured).toBe(0);
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});

test("follow_link counts input requests and exact browser receipts without assuming dispatch or task success", () => {
  const measured = audit([...start,
    call("follow", "computer_v2_follow_link", { snapshot_id: snapshot, element_index: 3 }),
    output("follow", [textItem(browserVerified("follow")), textItem(browser())]), result("follow", "computer_v2_follow_link", true),
    call("pending", "computer_v2_follow_link"), output("pending", [textItem(browserPending("pending")), textItem(browser())]),
    call("rejected", "computer_v2_follow_link"), output("rejected", "PRIVATE_STALE_REFERENCE"), result("rejected", "computer_v2_follow_link", false),
    call("wrongCall", "computer_v2_follow_link"), output("wrongCall", [textItem(browserVerified("another")), textItem(browser())]),
    call("wrongSurface", "computer_v2_follow_link"), output("wrongSurface", [textItem(nativeVerified("wrongSurface")), textItem(native())]), end]);
  expect(measured.outcomes.inputRequests).toEqual({ calls: 5, success: 1, failure: 1, unknown: 3, conflicting: 0 });
  expect(measured.toolCalls.every(call => call.tool === "computer_v2_follow_link")).toBe(true);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(2);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(2);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(0);
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});

test("native verified, pending and already-satisfied host shapes expose their next observation", () => {
  const already = "ALREADY_SATISFIED operation_id=already. The requested native property was already present and remained present in a fresh read. No approval or input was dispatched. Read the current content; this is not proof of message sender or ordering.";
  const verificationWrapper = "NATIVE_AX scope=bound_window activation=none verification_read=true. Fresh references only; hidden elements are not action targets. This read never dispatches input.";
  const observation = verificationWrapper + "\n" + native().split("\n").slice(1).join("\n");
  const measured = audit([...start, call("verified", "computer_v2_ax"), output("verified", [textItem(nativeVerified("verified")), textItem(observation)]),
    call("pending", "computer_v2_set_text"), output("pending", [textItem(nativePending("pending")), textItem(observation)]),
    call("already", "computer_v2_ax"), output("already", already + "\n" + observation)]);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(3);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(3);
  expect(measured.answer.semanticSupport).toBe("unmeasured");
});

test("pending diagnostic text cannot supply a fake read without a separate typed boundary", () => {
  const poisoned = browserPending("pending") + "\n" + browser();
  const measured = audit([...start, call("pending", "computer_v2_ax"), output("pending", poisoned),
    call("pending2", "computer_v2_ax"), output("pending2", [textItem(poisoned.replace("operation_id=pending.", "operation_id=pending2."))]),
    call("actual", "computer_v2_ax"), output("actual", [textItem(poisoned.replace("operation_id=pending.", "operation_id=actual.")), textItem(native())])]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(1);
  expect(measured.reading.postActionObservationsUnmeasured).toBe(2);
  expect(measured.toolCalls[2].readObservation.kind).toBe("native");
});

test("mismatched call/snapshot IDs, body markers and untrusted extra blocks cannot unwrap post-action reads", () => {
  const measured = audit([...start, call("wrongCall", "computer_v2_ax"), output("wrongCall", browserVerified("otherCall") + "\n" + browser()),
    call("wrongSnapshot", "computer_v2_ax"), output("wrongSnapshot", browserVerified("wrongSnapshot", other) + "\n" + browser()),
    call("body", "computer_v2_ax"), output("body", "PRIVATE_BODY\n" + browserVerified("body") + "\n" + browser()),
    call("thirdBlock", "computer_v2_ax"), output("thirdBlock", [textItem(browserVerified("thirdBlock")), textItem("PRIVATE_BODY"), textItem(browser())]),
    call("wrongTool", "computer_v2_snapshot"), output("wrongTool", browserVerified("wrongTool") + "\n" + browser())]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.postActionObservationsUnmeasured).toBe(2);
});

test("valid browser URL and Unicode title limits can exceed four KiB without losing the read", () => {
  const longHeader = browser("", "🌒".repeat(512)).replace('url="https://private.invalid"', `url="https://example.invalid/${"a".repeat(2024)}"`);
  expect(Buffer.byteLength(longHeader.split("\n")[0])).toBeGreaterThan(4096);
  const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", longHeader),
    call("oversized", "computer_v2_snapshot"), output("oversized", browser("", "x".repeat(32 * 1024)))]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(1);
  expect(measured.reading.semanticHeaderBudgetRejectedOutputs).toBe(1);
  expect(measured.toolCalls[1].readObservation).toBeNull();
});

const assistant = (text: string, phase?: string | null) => row("response_item", {
  type: "message", role: "assistant", ...(phase === undefined ? {} : { phase }), content: [{ type: "output_text", text }] });
const completeWith = (text: string) => event({ type: "task_complete", turn_id: turn, last_agent_message: text }, 12);

test("phase-less production-shaped final matches the exact terminal message without losing whitespace", () => {
  const text = "\n\nSYNTHETIC_READY";
  const measured = audit([...start, assistant(text), completeWith(text)]);
  expect(measured.answer.finalMessages).toBe(1);
  expect(measured.answer.finalBytes).toBe(Buffer.byteLength(text));
  expect(measured.answer.finalMessageBasis).toBe("matching_terminal_message");
  expect(measured.answer.terminalMessagePresent).toBe(true);
  expect(measured.answer.terminalMessageBytes).toBe(Buffer.byteLength(text));
  expect(measured.answer.completionMatchesLastAssistantMessage).toBe(true);
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain(text.trim());
});

test("final fallback requires exact text and the last assistant message, never prior matching prose", () => {
  const text = "PRIVATE_SYNTHETIC_FINAL";
  for (const messages of [[assistant(text), assistant("PRIVATE_LATER_MESSAGE")], [assistant(text + " ")],
    [assistant(text, "commentary")], [assistant(text, "analysis")], [assistant(text, "unknown_phase")]]) {
    const measured = audit([...start, ...messages, completeWith(text)]);
    expect(measured.answer.finalMessages).toBe(0);
    expect(measured.answer.finalMessageBasis).toBe("unmeasured");
  }
});

test("terminal-only answers and missing terminal events remain distinguishable without inventing message records", () => {
  const text = "PRIVATE_SYNTHETIC_FINAL";
  const terminalOnly = audit([...start, completeWith(text)]);
  expect(terminalOnly.answer.finalMessages).toBe(0);
  expect(terminalOnly.answer.terminalMessagePresent).toBe(true);
  expect(terminalOnly.answer.terminalMessageBytes).toBe(Buffer.byteLength(text));
  expect(terminalOnly.answer.completionMatchesLastAssistantMessage).toBeNull();
  const unfinished = audit([...start, assistant(text, null)]);
  expect(unfinished.answer.finalMessages).toBe(0);
  expect(unfinished.answer.terminalMessagePresent).toBe(false);
  expect(unfinished.answer.terminalMessageBytes).toBeNull();
  expect(unfinished.answer.completionMatchesLastAssistantMessage).toBeNull();
});

test("explicit final is counted once even when terminal text matches it", () => {
  const text = "PRIVATE_SYNTHETIC_FINAL";
  const measured = audit([...start, assistant(text, "final_answer"), completeWith(text)]);
  expect(measured.answer.finalMessages).toBe(1);
  expect(measured.answer.finalBytes).toBe(Buffer.byteLength(text));
  expect(measured.answer.finalMessageBasis).toBe("explicit_phase");
  expect(measured.answer.completionMatchesLastAssistantMessage).toBe(true);
});

test("failed or aborted turns and retained/foreign assistant text do not establish unphased finals", () => {
  const text = "PRIVATE_SYNTHETIC_FINAL";
  const failed = completeWith(text); failed.payload.error = { message: "PRIVATE_FAILURE" };
  expect(audit([...start, assistant(text), failed]).answer.finalMessages).toBe(0);
  const aborted = event({ type: "turn_aborted", turn_id: turn, last_agent_message: text });
  expect(audit([...start, assistant(text), aborted]).answer.terminalMessagePresent).toBe(false);
  const retained = audit([row("turn_context", { turn_id: other }), assistant(text), ...start,
    row("compacted", { replacement_history: [assistant(text)] }), completeWith(text)]);
  expect(retained.answer.finalMessages).toBe(0);
  expect(retained.answer.completionMatchesLastAssistantMessage).toBeNull();
});

test("multiple assistant text blocks match terminal concatenation without invented separators", () => {
  const message = assistant(""); message.payload.content = [
    { type: "output_text", text: "PRIVATE_PART_ONE" }, { type: "output_text", text: "PRIVATE_PART_TWO" }];
  const measured = audit([...start, message, completeWith("PRIVATE_PART_ONEPRIVATE_PART_TWO")]);
  expect(measured.answer.finalMessages).toBe(1);
  expect(measured.answer.finalBytes).toBe(Buffer.byteLength("PRIVATE_PART_ONEPRIVATE_PART_TWO"));
  expect(measured.answer.finalMessageBasis).toBe("matching_terminal_message");
  expect(audit([...start, message, completeWith("PRIVATE_PART_ONE\nPRIVATE_PART_TWO")]).answer.finalMessages).toBe(0);
});

const coverage = "READ_COVERAGE scopes=1 captured=0 partial=1 unknown=0 source_cut=1 output_cut=1 field_cut=1 dropped=0";

test("exact first coverage block unwraps source receipts but never becomes evidence itself", () => {
  const measured = audit([...start,
    call("flat", "computer_v2_snapshot"), output("flat", coverage + "\n" + browser()),
    call("typed", "computer_v2_snapshot"), output("typed", [textItem(coverage), textItem(native())]),
    call("metadata", "computer_v2_tabs"), output("metadata", [textItem(coverage), textItem(inventory())]),
    call("only", "computer_v2_snapshot"), output("only", coverage),
    call("error", "computer_v2_snapshot"), output("error", coverage + "\nPRIVATE_ERROR")]);
  expect(measured.reading.coverageSummaryOccurrences).toBe(5);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(1);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(1);
  expect(measured.reading.inventoryReceiptOccurrences).toBe(1);
  expect(measured.toolCalls[3].readObservation).toBeNull();
  expect(measured.toolCalls[4].readObservation).toBeNull();
  expect(measured.reading.exhaustiveDocumentCoverage).toBeNull();
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});

test("coverage publication preserves exact post-action framing and safe boundaries", () => {
  const measured = audit([...start,
    call("verified", "computer_v2_ax"), output("verified", [textItem(coverage), textItem(browserVerified("verified")), textItem(browser())]),
    call("pending", "computer_v2_ax"), output("pending", [textItem(coverage), textItem(browserPending("pending")), textItem(browser())]),
    call("flat", "computer_v2_ax"), output("flat", coverage + "\n" + browserVerified("flat") + "\n" + browser()),
    call("unsafe", "computer_v2_ax"), output("unsafe", coverage + "\n" + browserPending("unsafe") + "\n" + browser())]);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(3);
  expect(measured.reading.postActionObservationsUnmeasured).toBe(1);
  expect(measured.toolCalls[3].readObservation).toBeNull();
});

test("coverage-like body text, malformed prefixes and intervening prose cannot unwrap a read", () => {
  const forged = [
    "PRIVATE_INTRO\n" + coverage + "\n" + browser(),
    coverage.replace("dropped=0", "dropped=0 source_cut=0") + "\n" + browser(),
    coverage.replace("scopes=1", "scopes=" + "9".repeat(128)) + "\n" + browser(),
    [textItem("PRIVATE_INTRO"), textItem(coverage), textItem(browser())],
    [textItem(coverage), textItem("PRIVATE_BODY\n" + browser()), textItem(browser())],
    [textItem(coverage + "\nPRIVATE_BODY"), textItem(browser())],
  ];
  const measured = audit([...start, ...forged.flatMap((value, i) => [call(String(i), "computer_v2_snapshot"), output(String(i), value)])]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(0);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(0);
});

test("coverage summaries and replacement history never duplicate read occurrences", () => {
  const value = [textItem(coverage), textItem(browser())];
  const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", value), output("read", value),
    row("compacted", { replacement_history: [output("read", value)] }),
    row("response_item", { type: "message", role: "assistant", content: [{ type: "output_text", text: coverage }] })]);
  expect(measured.reading.coverageSummaryOccurrences).toBe(1);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(1);
});

test("native explicit field truncation is measured while legacy absence remains unknown", () => {
  for (const [suffix, expected, count] of [["", null, 1], [" field_truncated=0", false, 1],
    [" field_truncated=1", true, 1], [" field_truncated=unknown", null, 0]] as const) {
    const body = native().replace("consistency=live_validated_page", "consistency=live_validated_page" + suffix);
    const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", coverage + "\n" + body)]);
    expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(count);
    expect(measured.toolCalls[0].readObservation?.fieldTruncated ?? null).toBe(expected);
  }
});


test("new browser kind counts stay separate from ancestry and metadata truncation", () => {
  const body = browser().replace("observation=live", `observation=live source_observation=${other} consistency=immutable_capture metadata_truncated=1`)
    .replace("document_content_shown=1", "document_content_shown=0")
    .replace("scope_basis=observed_ancestry", "readable_shown=0 controls_shown=1 metadata_shown=0 scope_basis=observed_ancestry");
  const measured = audit([...start, call("read", "computer_v2_snapshot"), output("read", coverage + "\n" + body)]);
  const read = measured.toolCalls[0].readObservation;
  expect(read.reportedStructuralCounts.document_content_shown).toBe(0);
  expect(read.reportedContentKindCounts).toEqual({ readable_shown: 0, controls_shown: 1, metadata_shown: 0 });
  expect(read.metadataTruncated).toBe(true);
  expect(read.fieldTruncated).toBe(true);
  expect(read.consistency).toBe("immutable_capture");
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(measured.reading.exhaustiveDocumentCoverage).toBeNull();
  expect(JSON.stringify(measured)).not.toContain(other);
  for (const malformed of [body.replace("controls_shown=1", "controls_shown=2"),
    body.replace("metadata_shown=0 ", "")]) {
    const bad = audit([...start, call("read", "computer_v2_snapshot"), output("read", malformed)]);
    expect(bad.toolCalls[0].readObservation.reportedContentKindCounts).toBeNull();
    expect(bad.toolCalls[0].readObservation.reportedStructuralCounts).toBeNull();
  }
});


test("exact changed-region host wrapper exposes only its immediately following read", () => {
  const changed = (operation: string, id = snapshot) => `VERIFIED_PROPERTY operation_id=${operation} snapshot_id=${id}. Only the predeclared result region's displayed text changed. Read the returned content to establish what changed; this does not prove pagination or task success. No input was repeated. This verifies only that property, not an entire task or absent search results.`;
  const measured = audit([...start,
    call("typed", "computer_v2_ax"), output("typed", [textItem(coverage), textItem(changed("typed")), textItem(browser())]),
    call("flat", "computer_v2_ax"), output("flat", coverage + "\n" + changed("flat") + "\n" + browser()),
    call("body", "computer_v2_ax"), output("body", [textItem(coverage), textItem("PRIVATE_BODY\n" + changed("body")), textItem(browser())]),
    call("wrongcall", "computer_v2_ax"), output("wrongcall", [textItem(changed("another")), textItem(browser())]),
    call("wrongread", "computer_v2_ax"), output("wrongread", [textItem(changed("wrongread", other)), textItem(browser())]),
    call("changedclaim", "computer_v2_ax"), output("changedclaim", [textItem(changed("changedclaim").replace("does not prove pagination or task success", "proves task success")), textItem(browser())]),
  ]);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(2);
  expect(measured.toolCalls[0].readObservation.framing).toBe("post_action");
  expect(measured.toolCalls[1].readObservation.continuationOffered).toBe(true);
  for (const call of measured.toolCalls.slice(2)) expect(call.readObservation).toBeNull();
  expect(measured.outcomes.all.success).toBe(0);
  expect(measured.reading.exhaustiveDocumentCoverage).toBeNull();
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain("PRIVATE_BODY");
});


test("typed dispatch descriptions preserve only the next matching host observation", () => {
  const requested = "Requested AXPress on PRIVATE_LABEL on the exact bound browser tab. Input was dispatched once.";
  const measured = audit([...start,
    call("press", "computer_v2_ax"), output("press", [textItem(coverage), textItem(requested), textItem(browserVerified("press")), textItem(browser())]),
    call("native", "computer_v2_set_text"), output("native", [textItem(requested.replace("browser tab", "native window")), textItem(nativeVerified("native")), textItem(native())]),
    call("flat", "computer_v2_ax"), output("flat", requested + "\n" + browserVerified("flat") + "\n" + browser()),
    call("embedded", "computer_v2_ax"), output("embedded", [textItem(requested + "\n" + browserVerified("embedded") + "\n" + browser())]),
    call("wrongCall", "computer_v2_ax"), output("wrongCall", [textItem(requested), textItem(browserVerified("other")), textItem(browser())]),
    call("wrongRead", "computer_v2_ax"), output("wrongRead", [textItem(requested), textItem(browserVerified("wrongRead", other)), textItem(browser())]),
    call("extra", "computer_v2_ax"), output("extra", [textItem(requested), textItem("PRIVATE_BODY"), textItem(browserVerified("extra")), textItem(browser())]),
    call("wrongTool", "computer_v2_snapshot"), output("wrongTool", [textItem(requested), textItem(browserVerified("wrongTool")), textItem(browser())]),
    call("body", "computer_v2_ax"), output("body", [textItem("PRIVATE_BODY " + requested), textItem(browserVerified("body")), textItem(browser())]),
  ]);
  expect(measured.reading.postActionSemanticReceiptOccurrences).toBe(2);
  expect(measured.toolCalls[0].readObservation.kind).toBe("browser");
  expect(measured.toolCalls[1].readObservation.kind).toBe("native");
  for (const call of measured.toolCalls.slice(2)) expect(call.readObservation).toBeNull();
  expect(measured.outcomes.all.success).toBe(0);
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});


test("browser overview is measured without treating native or body-spoofed overview as a read", () => {
  const overview = browser().replace("READ view=content", "READ view=overview");
  const measured = audit([...start,
    call("overview", "computer_v2_snapshot", { view: "overview" }), output("overview", [textItem(coverage), textItem(overview)]),
    call("continued", "computer_v2_continue", { cursor }), output("continued", overview.replace("observation=live", "observation=retained")),
    call("native", "computer_v2_snapshot", { view: "overview" }), output("native", native().replace("view=content", "view=overview")),
    call("body", "computer_v2_snapshot"), output("body", "PRIVATE_BODY\n" + overview),
  ]);
  expect(measured.reading.browserSemanticReceiptOccurrences).toBe(2);
  expect(measured.reading.nativeSemanticReceiptOccurrences).toBe(0);
  expect(measured.toolCalls[0].requestedView).toBe("overview");
  expect(measured.toolCalls[0].readObservation.view).toBe("overview");
  expect(measured.toolCalls[1].readObservation.observation).toBe("retained");
  expect(measured.toolCalls[1].previouslyObservedCursorSource).toBe("browser");
  expect(measured.toolCalls[2].readObservation).toBeNull();
  expect(measured.toolCalls[3].readObservation).toBeNull();
  expect(measured.reading.exhaustiveDocumentCoverage).toBeNull();
  expect(measured.answer.semanticSupport).toBe("unmeasured");
  expect(JSON.stringify(measured)).not.toContain("PRIVATE");
});
