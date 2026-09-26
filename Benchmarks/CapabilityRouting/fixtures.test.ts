import { describe, expect, test } from "bun:test";
import { makeCapabilityRoutingFixtures, scoreCapabilityRouting } from "./fixtures";

describe("frozen synthetic capability-routing cases", () => {
  test("four development and eight holdout cases are deterministic, independent and synthetic", () => {
    const cases = makeCapabilityRoutingFixtures();
    expect(cases).toHaveLength(12);
    expect(cases.filter(c => c.split === "development")).toHaveLength(4);
    expect(cases.filter(c => c.split === "holdout")).toHaveLength(8);
    expect(new Set(cases.map(c => c.id)).size).toBe(12);
    expect(cases.every(c => c.synthetic && c.observedHost.bundleID.startsWith("example.synthetic."))).toBe(true);
    expect(new Set(cases.map(c => c.domain)).size).toBe(5);
    expect(makeCapabilityRoutingFixtures()).toEqual(cases);
    cases[0].receipts[0].output = "Changed";
    expect(makeCapabilityRoutingFixtures()[0].receipts[0].output).not.toBe("Changed");
  });

  test("open targets come only from the observed local inventory and are not guest-name or local-browser distractors", () => {
    for (const c of makeCapabilityRoutingFixtures().filter(c => c.stage === "inventory")) {
      expect(c.receipts.map(r => r.name)).toEqual(["computer_v2_status", "computer_v2_apps"]);
      const apps = c.receipts[1].output.split("\n").slice(1).map(line => JSON.parse(line));
      const target = apps.filter(a => a.bundle_id === c.observedHost.bundleID);
      expect(target).toHaveLength(1); expect(target[0].name).toBe(c.observedHost.name);
      expect(c.expectedNextAction).toEqual({ kind: "call", name: "computer_v2_open", allowedArguments: [{ bundle_id: target[0].bundle_id }] });
      for (const other of apps.filter(a => a.bundle_id !== c.observedHost.bundleID)) {
        expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_open", arguments: JSON.stringify({ bundle_id: other.bundle_id }) }], text: "" }).passed).toBe(false);
      }
    }
  });

  test("opaque surfaces are already bound, complete but uninformative AX rather than truncated content", () => {
    for (const c of makeCapabilityRoutingFixtures().filter(c => c.stage === "sparse_ax")) {
      expect(c.receipts.map(r => r.name)).toEqual(["computer_v2_status", "computer_v2_open", "computer_v2_snapshot"]);
      expect(JSON.parse(c.receipts[1].output).bound).toBe(true);
      expect(c.receipts[2].output).toContain("shown=3 total=3 source_truncated=0 output_truncated=0");
      expect(c.receipts[2].output).toContain('role="AXImage"');
      expect(c.expectedNextAction.kind).toBe("call");
      expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_capture", arguments: "{}" }], text: "" }).outcome).toBe("correct_call");
      expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_capture", arguments: '{"include_accessibility":true}' }], text: "" }).passed).toBe(true);
      expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_snapshot", arguments: '{"query":"remote"}' }], text: "" }).passed).toBe(false);
    }
  });

  test("negative controls require no action and nonempty text, without claiming explanation factuality", () => {
    const negatives = makeCapabilityRoutingFixtures().filter(c => c.expectedNextAction.kind === "abstain");
    expect(negatives).toHaveLength(4);
    expect(new Set(negatives.map(c => c.expectedNextAction.kind === "abstain" ? c.expectedNextAction.reason : "")))
      .toEqual(new Set(["permissions_denied", "explicit_block", "login_required"]));
    for (const c of negatives) {
      expect(scoreCapabilityRouting(c, { toolCalls: [], text: "User attention is required." }).outcome).toBe("correct_abstention");
      expect(scoreCapabilityRouting(c, { toolCalls: [], text: " \n" }).outcome).toBe("empty_abstention");
      expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_capture", arguments: "{}" }], text: "Cannot proceed." }).outcome).toBe("action_when_abstention_required");
      const data = c.receipts.map(r => r.output).join("\n");
      expect(/denied|blocked_by_remote_policy|login_required/.test(data)).toBe(true);
    }
  });

  test("every positive has an exact next call and refusals do not pass successful routing", () => {
    for (const c of makeCapabilityRoutingFixtures()) {
      if (c.expectedNextAction.kind !== "call") continue;
      for (const args of c.expectedNextAction.allowedArguments) {
        const call = { name: c.expectedNextAction.name, arguments: JSON.stringify(args) };
        expect(scoreCapabilityRouting(c, { toolCalls: [call], text: "Checking the requested window." }).passed).toBe(true);
        expect(scoreCapabilityRouting(c, { toolCalls: [call, call], text: "" }).outcome).toBe("multiple_actions");
      }
      expect(scoreCapabilityRouting(c, { toolCalls: [], text: "Remote computer use is impossible." }).outcome).toBe("missing_action");
    }
  });

  test("URL navigation, browser mode, display overrides, additional calls and invented targets fail", () => {
    const open = makeCapabilityRoutingFixtures()[0], capture = makeCapabilityRoutingFixtures()[1];
    for (const args of [
      { bundle_id: open.observedHost.bundleID, url: "https://example.invalid/" },
      { bundle_id: open.observedHost.bundleID, browser_mode: "existing" }, { bundle_id: "example.synthetic.not-observed" }, {},
    ]) expect(scoreCapabilityRouting(open, { toolCalls: [{ name: "computer_v2_open", arguments: JSON.stringify(args) }], text: "" }).passed).toBe(false);
    for (const args of [{ display_id: 1 }, { include_accessibility: "false" }, { url: "https://example.invalid/" }, { shows_cursor: "true" }]) {
      expect(scoreCapabilityRouting(capture, { toolCalls: [{ name: "computer_v2_capture", arguments: JSON.stringify(args) }], text: "" }).passed).toBe(false);
    }
  });

  test("argument parser rejects duplicate decoded keys, malformed types and trailing content", () => {
    const c = makeCapabilityRoutingFixtures()[0], bundle = c.observedHost.bundleID;
    for (const raw of [
      `{"bundle_id":"wrong","bundle_id":"${bundle}"}`, `{"bundle_id":"wrong","\\u0062undle_id":"${bundle}"}`,
      "[]", "null", '{"bundle_id":42}', '{"bundle_id":{}}', '{"bundle_id":null}', '{"bundle_id":"bad\\q"}',
      `{"bundle_id":"${bundle}",}`, `{"bundle_id":"${bundle}"}{}`, "x".repeat(2049),
    ]) expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_open", arguments: raw }], text: "" }).outcome).toBe("invalid_arguments");
    expect(scoreCapabilityRouting(c, { toolCalls: [{ name: "computer_v2_open", arguments: ` \n{ "\\u0062undle_id" : "${bundle}" }\t` }], text: "" }).passed).toBe(true);
  });

  test("receipt identities, payload bounds and single-target prompts are stable", () => {
    const ids = new Set<string>();
    for (const c of makeCapabilityRoutingFixtures()) {
      expect(c.prompt).toContain(c.observedHost.name);
      expect(c.prompt).not.toContain("computer_v2_");
      expect(c.receipts.length).toBeLessThanOrEqual(3);
      for (const r of c.receipts) {
        expect(ids.has(r.callID)).toBe(false); ids.add(r.callID);
        expect(r.output.length).toBeLessThan(2000);
        expect(() => JSON.parse(r.arguments)).not.toThrow();
      }
    }
  });
});
