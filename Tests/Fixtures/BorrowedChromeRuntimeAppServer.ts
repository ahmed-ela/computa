#!/usr/bin/env bun
// Deterministic production-Core JSON-RPC exercise. The injected Swift adapter
// is inert; this fixture has no browser connection, model, settings or input.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const root = process.env.CODEX_HOME!;
const mode = readFileSync(join(root, "mode"), "utf8");
const threadId = "borrowed-runtime-thread";
let turnId = "borrowed-runtime-turn", turnCount = 0;
const emit = (value: unknown) => process.stdout.write(JSON.stringify(value) + "\n");
const result = (id: unknown, value: unknown = {}) => emit({ id, result: value });
const notify = (method: string, params: Record<string, unknown>) => emit({ method, params: { threadId, ...params } });
let step = 0, finished = false, snapshot = "", staleSnapshot = "", firstCandidate = "", actionOperation = "";
let oldInventoryCursor = "", pageContinuationCursor = "";
const results: { tool: string; success: boolean; text: string }[] = [];
const attemptedTools: string[] = [];
let lastTool = "";
let waiting: ReturnType<typeof setInterval> | undefined;
function call(tool: string, args: Record<string, unknown> = {}) {
  lastTool = tool;
  attemptedTools.push(tool);
  writeFileSync(join(root, "attempted-tools.json"), JSON.stringify(attemptedTools));
  emit({ id: `borrowed-request-${step}`, method: "item/tool/call", params: {
    threadId, turnId, callId: `borrowed-call-${step}`, tool, arguments: args,
  } });
}
function finalAnswer(text: string) {
  notify("item/completed", { turnId, item: { id: `answer-${turnCount}`, type: "agentMessage", phase: "final_answer", text } });
}
function verify(index: number, expected: string) {
  call("computer_v2_verify", { operation_id: actionOperation, snapshot_id: snapshot,
    element_index: index, property: "value", expected });
}
function counterPress() {
  call("computer_v2_ax", { snapshot_id: snapshot, element_index: 0, ax_action: "AXPress",
    postcondition: { kind: "value", element_index: 2, expected: "1" } });
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
  writeFileSync(join(root, "results.json"), JSON.stringify(results));
  if (lastTool === "computer_v2_verify" && success) {
    // Verification itself performs a fresh read. Its returned observation is
    // now the action capability; the pre-verification snapshot is stale.
    snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
    if (!snapshot) return finish(false);
  }
  if (mode.startsWith("pagination-")) return paginationWorkflow(success, text);
  if (mode.startsWith("followup-")) return followupBinding(success, text);
  if (mode.startsWith("runtime-verify-")) return runtimeVerification(success, text);
  if (mode === "unsupported-actions") return unsupportedActions(success, text);
  if (mode === "editable-focus-recovery") return editableFocusRecovery(success, text);
  if (mode === "stale-text-recovery") return staleTextRecovery(success, text);
  if (mode === "search-fill-no-submit" || mode === "positive-read-press") return evidenceWorkflow(success, text);
  if (mode === "no-connection") return finish(!success && text.includes("not connected"));
  if (mode === "false-search-final") {
    finalAnswer("HALLUCINATED_SEARCH: I searched your mail and found no matching flight.");
    return finish(!success);
  }
  if (mode === "wrong-site") {
    if (step++ === 0) {
      if (!success) return finish(false);
      return call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token });
    }
    finalAnswer("WRONG_SITE_SUCCESS_MUST_NOT_APPEAR");
    return finish(!success && text.includes("does not match the requested"));
  }
  if (mode === "background-open") {
    finalAnswer("FOREGROUND_FALLBACK_SUCCESS_MUST_NOT_APPEAR");
    return finish(!success && text.includes("outside the requested scope"));
  }
  if (mode === "repeated-bind") {
    if (success) return finish(false);
    if (!text.includes("not connected") || text.includes("No current borrowed Chrome inventory")) return finish(false);
    if (step++ >= 4) return finish(false);
    return call("computer_v2_bind_tab", { candidate_token: step % 2 === 0
      ? "22222222-2222-4222-8222-222222222222" : "11111111-1111-4111-8111-111111111111" });
  }
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
  if (step >= 12) {
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
        counterPress(); break;
      case 5: call("computer_v2_snapshot"); break;
      case 6:
        if (!text.includes('value="1"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        actionOperation = "borrowed-call-5";
        verify(2, "1"); break;
      case 7:
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "HDé7 東京 👋" }); break;
      case 8: call("computer_v2_snapshot"); break;
      case 9:
        if (!text.includes("HDé7 東京 👋")) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        actionOperation = "borrowed-call-8";
        verify(1, "HDé7 東京 👋"); break;
      case 10:
        // Rebinding the same exact opaque token remains a read-only identity
        // operation; fetch a fresh page solely to obtain that token again.
        call("computer_v2_tabs", { page_size: 2 }); break;
      case 11:
        call("computer_v2_capture"); break;
      case 12:
        call("computer_v2_keypress", { key: "a", modifiers: [] }); break;
      case 13:
        call("computer_v2_type", { text: "must-not-type" }); break;
      case 14:
        call("computer_v2_click", { capture_id: "11111111-1111-4111-8111-111111111111", x: 1, y: 1 }); break;
      case 15: finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function paginationWorkflow(success: boolean, text: string) {
  try {
    if (mode === "pagination-alias-recovery") {
      switch (step++) {
        case 0:
          if (success || text.includes("RUNTIME_ACTION_EVIDENCE")) return finish(false);
          call("computer_v2_tabs", { page_size: 1 }); break;
        case 1: {
          if (!success) return finish(false);
          const page = JSON.parse(text);
          if (!page.next_cursor || page.returned !== 1 || page.total_count !== 2) return finish(false);
          call("computer_v2_continue", { cursor: page.next_cursor }); break;
        }
        case 2: {
          if (!success) return finish(false);
          const page = JSON.parse(text);
          if (page.total_count !== 2 || page.returned !== 1 || page.next_cursor) return finish(false);
          finalAnswer("UNKNOWN_CONTINUATION_RECOVERY_COMPLETE");
          finish(true); break;
        }
        default: finish(false);
      }
      return;
    }
    if (mode === "pagination-followup") {
      if (turnCount === 1) {
        if (step !== 0 || !success) return finish(false);
        const page = JSON.parse(text);
        oldInventoryCursor = page.next_cursor;
        if (page.returned !== 1 || page.total_count !== 2 || !oldInventoryCursor) return finish(false);
        finalAnswer("FIRST_INVENTORY_PAGE_OBSERVED");
        return finish(true);
      }
      switch (step++) {
        case 100:
          if (success || !text.includes("preflight_rejection=freshInventoryRequired")) return finish(false);
          call("computer_v2_tabs", { page_size: 1 }); break;
        case 101: {
          if (!success) return finish(false);
          const page = JSON.parse(text);
          if (!page.next_cursor || page.next_cursor === oldInventoryCursor) return finish(false);
          firstCandidate = page.items[0].candidate_token;
          call("computer_v2_continue", { cursor: page.next_cursor }); break;
        }
        case 102: {
          if (!success) return finish(false);
          const page = JSON.parse(text);
          if (page.total_count !== 2 || page.returned !== 1 || page.next_cursor
              || page.items[0].candidate_token === firstCandidate) return finish(false);
          finalAnswer("FOLLOWUP_INVENTORY_RECOVERY_COMPLETE");
          finish(true); break;
        }
        default: finish(false);
      }
      return;
    }
    if (mode === "pagination-repeat-invalid") {
      if (step === 0) {
        if (!success) return finish(false);
      } else if (success || !text.includes("preflight_rejection=freshInventoryRequired")) return finish(false);
      if (step++ >= 5) return finish(false);
      return call("computer_v2_tabs", { cursor: "99999999-9999-4999-8999-999999999999" });
    }
    if (mode !== "pagination-mixed-sources") return finish(false);
    if (step === 4) {
      if (success || !text.includes("preflight_rejection=freshInventoryRequired")) return finish(false);
    } else if (!success) return finish(false);
    switch (step++) {
      case 0:
        call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot", { view: "content" }); break;
      case 2:
        pageContinuationCursor = /next_cursor=([0-9a-f-]+)/i.exec(text)?.[1] ?? "";
        if (!pageContinuationCursor || !text.includes("output_truncated=1")) return finish(false);
        call("computer_v2_continue", { cursor: pageContinuationCursor }); break;
      case 3:
        pageContinuationCursor = /next_cursor=([0-9a-f-]+)/i.exec(text)?.[1] ?? "";
        if (!pageContinuationCursor || !text.includes("READ view=content")) return finish(false);
        // Deliberately send a page cursor to the legacy inventory operation.
        // Rejection must preserve the page cursor and authorized connection.
        call("computer_v2_tabs", { cursor: pageContinuationCursor }); break;
      case 4: call("computer_v2_tabs", { page_size: 1 }); break;
      case 5: {
        const page = JSON.parse(text);
        if (!page.next_cursor) return finish(false);
        call("computer_v2_continue", { cursor: page.next_cursor }); break;
      }
      case 6: {
        const page = JSON.parse(text);
        if (page.total_count !== 2 || page.next_cursor) return finish(false);
        call("computer_v2_continue", { cursor: pageContinuationCursor }); break;
      }
      case 7:
        if (!text.includes("READ view=content") || !text.includes("Synthetic fixture paragraph")) return finish(false);
        finalAnswer("PAGINATION_SOURCES_RECOVERED");
        finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function followupBinding(success: boolean, text: string) {
  try {
    if (turnCount === 1) {
      if (!success) return finish(false);
      switch (step++) {
        case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
        case 1: call("computer_v2_snapshot"); break;
        case 2:
          staleSnapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
          if (!staleSnapshot) return finish(false);
          finalAnswer("FIRST_TURN_OBSERVED");
          finish(true); break;
        default: finish(false);
      }
      return;
    }
    if (mode === "followup-scope-change") {
      if (step !== 100 || success || !text.includes("previous tab cannot safely be resumed")) return finish(false);
      finalAnswer("WRONG_CONTINUATION_MUST_NOT_APPEAR");
      return finish(true);
    }
    if (mode === "followup-origin-race") {
      if (step !== 100 || success || !text.includes("changed site while it was being reacquired")) return finish(false);
      finalAnswer("WRONG_ORIGIN_CONTENT_MUST_NOT_APPEAR");
      return finish(true);
    }
    if (mode === "followup-unbound-schema") {
      if (step === 100) {
        if (success || !text.includes("preflight_rejection=invalidArguments") || !text.includes("dispatch=not_dispatched")) return finish(false);
        step++;
        return call("computer_v2_snapshot");
      }
      if (step !== 101 || !success || !/AXSNAPSHOT id=[0-9A-F-]+/i.test(text)) return finish(false);
      finalAnswer("FOLLOWUP_SCHEMA_RECOVERY_COMPLETE");
      return finish(true);
    }
    if (step === 100) {
      if (success || !text.includes("preflight_rejection=bindingRequired") || !text.includes("dispatch=not_dispatched")) return finish(false);
    } else if (!success) return finish(false);
    switch (step++) {
      case 100:
        // A carried-over AX ID must not dispatch. The runtime has restored
        // only the exact tab identity; the model must request a fresh read.
        call("computer_v2_snapshot"); break;
      case 101:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        if (!snapshot || snapshot === staleSnapshot) return finish(false);
        counterPress(); break;
      case 102:
        if (!text.includes("No unresolved action receipts.") || !text.includes("preflight_corrected_not_performed")) return finish(false);
        actionOperation = "borrowed-call-102";
        call("computer_v2_snapshot"); break;
      case 103:
        if (!text.includes('value="1"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        verify(2, "1"); break;
      case 104:
        if (!text.includes("VERIFIED_PROPERTY operation_id=borrowed-call-102") || !text.includes('value="1"')) return finish(false);
        finalAnswer("FOLLOWUP_RECOVERY_COMPLETE");
        finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function editableFocusRecovery(success: boolean, text: string) {
  if (step === 3) {
    if (success || !text.includes("No approval or action was requested")
        || !text.includes("computer_v2_set_text directly")) return finish(false);
  } else if (!success) return finish(false);
  try {
    switch (step++) {
      case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot"); break;
      case 2:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        call("computer_v2_ax", { snapshot_id: snapshot, element_index: 1, ax_action: "AXPress" }); break;
      case 3:
        // Unsupported field focus is known not to have dispatched. Direct
        // set_text uses that same retained field, without a blind click retry.
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "Recovered direct text" }); break;
      case 4:
        if (!text.includes('value="Recovered direct text"') || !text.includes("No unresolved action receipts.")) return finish(false);
        finalAnswer("DIRECT_TEXT_RECOVERY_COMPLETE");
        finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function runtimeVerification(success: boolean, text: string) {
  try {
    if (step < 3 && !success) return finish(false);
    switch (step++) {
      case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot"); break;
      case 2:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        if (!snapshot) return finish(false);
        if (mode === "runtime-verify-compaction") {
          // The Swift adapter pauses the first post-dispatch read. Inject the
          // real protocol lifecycle while that read is suspended; this covers
          // Core receipt survival, not execution of the model-side compactor.
          waiting = setInterval(() => {
            if (!existsSync(join(root, "press-dispatched"))) return;
            clearInterval(waiting);
            const item = { id: "verification-pending-compaction", type: "contextCompaction" };
            notify("item/started", { turnId, item });
            notify("item/completed", { turnId, item });
            writeFileSync(join(root, "compaction-injected"), "yes");
          }, 10);
        }
        if (mode === "runtime-verify-no-plan") {
          call("computer_v2_ax", { snapshot_id: snapshot, element_index: 0, ax_action: "AXPress" });
        } else counterPress();
        break;
      case 3:
        if (mode === "runtime-verify-no-plan") {
          if (success || !text.includes("requires postcondition before input")
              || !text.includes("dispatch=not_dispatched")) return finish(false);
          finalAnswer("UNPLANNED_PRESS_FALSE_SUCCESS_MUST_NOT_APPEAR");
        } else if (mode === "runtime-verify-wrong-result") {
          if (!text.includes("VERIFICATION_PENDING") || text.includes("VERIFIED_PROPERTY")) return finish(false);
          finalAnswer("WRONG_RESULT_FALSE_SUCCESS_MUST_NOT_APPEAR");
        } else {
          if (!success || !text.includes("VERIFIED_PROPERTY operation_id=borrowed-call-3")
              || !text.includes("No unresolved action receipts.")) return finish(false);
          finalAnswer("RUNTIME_AUTOMATIC_VERIFICATION_COMPLETE");
        }
        // No model-authored verify/read or repeated action is issued after the
        // mutation: the native runtime is solely responsible for the proof.
        finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function staleTextRecovery(success: boolean, text: string) {
  if (step === 4) {
    if (success || !text.includes("snapshot is missing or stale")) return finish(false);
  } else if (!success) return finish(false);
  try {
    switch (step++) {
      case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot"); break;
      case 2:
        staleSnapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        if (!staleSnapshot) return finish(false);
        call("computer_v2_snapshot"); break;
      case 3:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        if (!snapshot || snapshot === staleSnapshot) return finish(false);
        call("computer_v2_set_text", { snapshot_id: staleSnapshot, element_index: 1, text: "Recovered current text" }); break;
      case 4:
        // A rejected stale capability cannot dispatch input. The fresh
        // capability identifies the same backend field and exact text intent.
        call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "Recovered current text" }); break;
      case 5:
        if (!text.includes('value="Recovered current text"') || !text.includes("No unresolved action receipts.")) return finish(false);
        finalAnswer("STALE_TEXT_RECOVERY_COMPLETE");
        finish(true); break;
      default: finish(false);
    }
  } catch { finish(false); }
}
function evidenceWorkflow(success: boolean, text: string) {
  if (!success) return finish(false);
  try {
    switch (step++) {
      case 0: call("computer_v2_bind_tab", { candidate_token: JSON.parse(text).items[0].candidate_token }); break;
      case 1: call("computer_v2_snapshot"); break;
      case 2:
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        if (mode === "search-fill-no-submit") {
          call("computer_v2_set_text", { snapshot_id: snapshot, element_index: 1, text: "United flight" });
        } else counterPress();
        break;
      case 3:
        if (mode === "search-fill-no-submit") {
          // The input receipt is resolved, but no submit action or query/results
          // observation exists. The app must still reject this false conclusion.
          if (!text.includes('value="United flight"') || !text.includes("No unresolved action receipts.")) return finish(false);
          finalAnswer("SEARCH_FILL_FALSE_NEGATIVE: I searched your mail and found no matching flight.");
          finish(true);
        } else call("computer_v2_snapshot");
        break;
      case 4:
        if (!text.includes('value="1"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        actionOperation = "borrowed-call-3";
        verify(2, "1"); break;
      case 5:
        finalAnswer("VERIFIED_ACTION_COMPLETE");
        finish(true); break;
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
        actionOperation = "borrowed-call-9";
        verify(1, "Supported direct text"); break;
      case 11: counterPress(); break;
      case 12: call("computer_v2_snapshot"); break;
      case 13:
        if (!text.includes('value="1"')) return finish(false);
        snapshot = /AXSNAPSHOT id=([0-9A-F-]+)/i.exec(text)?.[1] ?? "";
        actionOperation = "borrowed-call-12";
        verify(2, "1"); break;
      case 14: finish(true); break;
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
      turnCount++;
      turnId = turnCount === 1 ? "borrowed-runtime-turn" : `borrowed-runtime-turn-${turnCount}`;
      finished = false;
      result(message.id, { turn: { id: turnId, status: "inProgress", items: [] } });
      notify("turn/started", { turn: { id: turnId, status: "inProgress", items: [] } });
      if (turnCount > 1 && mode === "pagination-followup") {
        step = 100;
        setTimeout(() => call("computer_v2_tabs", { cursor: oldInventoryCursor }), 10);
      } else if (turnCount > 1 && mode.startsWith("followup-")) {
        step = 100;
        setTimeout(() => {
          if (mode === "followup-unbound-schema") call("computer_v2_snapshot", { view: "not-a-valid-view" });
          else if (mode === "followup-binding-recovery") call("computer_v2_ax", { snapshot_id: staleSnapshot, element_index: 0, ax_action: "AXPress" });
          else call("computer_v2_snapshot");
        }, 10);
      } else if (turnCount > 1) {
        finalAnswer("NEXT_TURN_OK");
        finish(true);
      } else if (mode === "background-open") {
        setTimeout(() => call("computer_v2_open", { bundle_id: "com.google.Chrome" }), 10);
      } else if (mode === "pagination-alias-recovery") {
        setTimeout(() => call("computer_v2_continue", { cursor: "99999999-9999-4999-8999-999999999999" }), 10);
      } else setTimeout(() => call("computer_v2_tabs", { page_size: 1 }), 10);
      break;
    case "turn/interrupt":
      writeFileSync(join(root, "interrupted"), "yes");
      result(message.id);
      if (mode === "repeated-bind") finalAnswer("LATE_SEARCH_SUCCESS_MUST_NOT_APPEAR");
      if (mode === "pagination-repeat-invalid") finalAnswer("LATE_INVENTORY_SUCCESS_MUST_NOT_APPEAR");
      if (mode === "runtime-verify-cancel") finalAnswer("CANCELLED_VERIFICATION_FALSE_SUCCESS_MUST_NOT_APPEAR");
      finish(true); break;
    default: emit({ id: message.id, error: { code: -32601, message: "Unexpected borrowed fixture method" } });
  }
}).on("close", () => process.exit(0));
