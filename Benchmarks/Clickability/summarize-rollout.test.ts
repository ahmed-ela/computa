import { expect, test } from "bun:test";
import { summarizeRollout } from "./summarize-rollout";

const turn = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222";
const marker = "MACTOPUS_CLICKABILITY_OK";
const row = (type: string, payload: any, timestamp = "2026-09-27T00:00:00Z") => ({ type, payload, timestamp });
const response = (payload: any) => row("response_item", payload);
const call = (id: string, name: string) => response({ type: "function_call", call_id: id, name,
  arguments: JSON.stringify({ ax_action: "AXPress", text: "PRIVATE_ARGUMENT_EMAIL" }) });
const output = (id: string, body: unknown) => response({ type: "function_call_output", call_id: id, output: body });
const evidence = (status = "unverified", dispatch = "dispatched") =>
  `RUNTIME_ACTION_EVIDENCE turn=${turn}\nComputer-use outcome not verified.\noperation=click tool=computer_v2_ax dispatch=${dispatch} status=${status}`;
function audit(records: any[]) { return summarizeRollout(records.map(item => JSON.stringify(item)).join("\n"), turn, marker); }
const start = [row("event_msg", { type: "task_started", turn_id: turn }),
  row("turn_context", { turn_id: turn, model: "local/Qwen3.5-4B-MLX-4bit" })];

test("supports string receipts, exact tool sequence, typed image receipts and native verification", () => {
  const result = audit([...start, call("snapshot", "computer_v2_snapshot"), output("snapshot",
    '#1 role="AXGroup" label="PRIVATE_EMAIL" enabled=true settable=false actions=["AXPress"] press_source=focusable_pointer'),
  call("click", "computer_v2_ax"), output("click", `Requested AXPress on PRIVATE_LABEL.\n${evidence()}`),
  call("verify", "computer_v2_verify"), output("verify", [{ type: "input_text",
    text: `VERIFIED_PROPERTY operation_id=click snapshot_id=private-id. Matched.\n#2 role="AXStaticText" label="${marker}"` },
  { type: "input_image", image_url: "data:image/png;base64,PRIVATE_IMAGE" }]),
  response({ type: "message", role: "assistant", phase: "final_answer", content: [{ type: "output_text", text: marker }] }),
  row("event_msg", { type: "task_complete", turn_id: turn, last_agent_message: marker }, "2026-09-27T00:00:12Z")]);
  expect(result.requestedTools).toEqual(["computer_v2_snapshot", "computer_v2_ax", "computer_v2_verify"]);
  expect(result.toolCalls[0].sources.focusable_pointer).toBe(1);
  expect(result.toolCalls[1].dispatch).toBe("dispatched");
  expect(result.toolCalls[1].verification).toBe(true);
  expect(result.counts.verifiedProperties).toBe(1);
  expect(result.assistant.expectedMarkerInFinal).toBe(true);
  expect(result.assistant.completionMatchesFinal).toBe(true);
  expect(result.durationMs).toBe(12_000);
  expect(result.modelIsQwen4B).toBe(true);
  expect(JSON.stringify(result)).not.toContain("PRIVATE_");
  expect(JSON.stringify(result)).not.toContain(marker);
});

test("a successful-looking output or final claim never implies dispatch or verification", () => {
  const result = audit([...start, call("click", "computer_v2_ax"), output("click", "Succeeded. PRIVATE_RESULT"),
    response({ type: "message", role: "assistant", content: [{ type: "output_text", text: "I did it. PRIVATE_FINAL" }] }),
    row("event_msg", { type: "task_complete", turn_id: turn, last_agent_message: "I did it. PRIVATE_FINAL" })]);
  expect(result.toolCalls[0].dispatch).toBeNull();
  expect(result.counts.verifiedProperties).toBe(0);
  expect(result.assistant.finalMessages).toBe(1);
  expect(JSON.stringify(result)).not.toContain("PRIVATE");
});

test("excludes unrelated turns, reasoning, user claims and retained compaction history", () => {
  const result = audit([row("turn_context", { turn_id: other }), call("other", "private_tool_name"), output("other", "PRIVATE_OTHER"),
    ...start, response({ type: "message", role: "user", content: [{ type: "input_text", text: "PRIVATE_USER" }] }),
    response({ type: "reasoning", summary: [{ text: `VERIFIED_PROPERTY operation_id=click snapshot_id=fake. ${marker}` }] }),
    row("compacted", { replacement_history: [call("fake", "computer_v2_ax"), output("fake", evidence())] }),
    call("click", "computer_v2_ax"), output("click", evidence("failed", "not_dispatched")),
    row("event_msg", { type: "task_complete", turn_id: turn }), row("turn_context", { turn_id: other }),
    call("after", "computer_v2_ax")]);
  expect(result.counts.calls).toBe(1);
  expect(result.counts.nativeFailedOperations).toBe(1);
  expect(result.counts.verifiedProperties).toBe(0);
  expect(result.toolCalls[0].dispatch).toBe("not_dispatched");
  expect(result.compactions).toBe(1);
  expect(JSON.stringify(result)).not.toContain("PRIVATE");
  expect(JSON.stringify(result)).not.toContain("private_tool_name");
});

test("verification text in an unrelated tool is not an authorized verification receipt", () => {
  const result = audit([...start, call("click", "computer_v2_ax"),
    output("click", "VERIFIED_PROPERTY operation_id=click snapshot_id=fake. Matched."),
    call("snapshot", "computer_v2_snapshot"), output("snapshot", `#1 role="AXGroup" label="press_source=browser_clickability" actions=[]`)]);
  expect(result.counts.verifiedProperties).toBe(0);
  expect(result.toolCalls[1].sources.browser_clickability).toBe(0);
});

test("reports duplicate/orphan outputs and incomplete turns without claiming a completed result", () => {
  const result = audit([...start, call("click", "computer_v2_ax"), output("click", "one"),
    output("click", "two"), output("missing", "PRIVATE_ORPHAN")]);
  expect(result.counts.duplicateOutputs).toBe(1);
  expect(result.counts.orphanOutputs).toBe(1);
  expect(result.turnComplete).toBe(false);
});

test("rejects missing selected turn and duplicate call identities", () => {
  expect(() => audit([row("turn_context", { turn_id: other })])).toThrow("redacted");
  expect(() => audit([...start, call("same", "computer_v2_ax"), call("same", "computer_v2_ax")])).toThrow("redacted");
});


test("generic read continuation retains its known tool name", () => {
  const result = audit([...start, call("continue", "computer_v2_continue"), output("continue", "PRIVATE_READ")]);
  expect(result.requestedTools).toEqual(["computer_v2_continue"]);
  expect(result.counts.calls).toBe(1);
  expect(JSON.stringify(result)).not.toContain("PRIVATE_READ");
});
