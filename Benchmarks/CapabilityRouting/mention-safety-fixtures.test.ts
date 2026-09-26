import { expect, test } from "bun:test";
import { makeMentionSafetyFixtures } from "./mention-safety-fixtures";
import { annotateExplicitAppMention } from "./explicit-app-mention";
import { scoreCapabilityRouting } from "./fixtures";

test("six deterministic fresh fixtures retain canonical native rows and separate oracles", () => {
  const fixtures = makeMentionSafetyFixtures(); expect(fixtures).toHaveLength(6);
  expect(fixtures).toEqual(makeMentionSafetyFixtures()); expect(new Set(fixtures.map(f => f.id)).size).toBe(6);
  for (const f of fixtures) {
    expect(f.receipts.map(r => r.name)).toEqual(["computer_v2_status", "computer_v2_apps"]);
    expect(JSON.parse(f.receipts[0].output)).toEqual({ accessibility: "granted", screenRecording: "granted" });
    const serializedRows = f.receipts[1].output.split("\n").slice(1);
    const apps = serializedRows.map(line => JSON.parse(line));
    expect(apps).toHaveLength(3);
    for (const app of apps) expect(Object.keys(app).sort()).toEqual(["active", "bundle_id", "name", "pid"]);
    for (const [index, app] of apps.entries()) {
      expect(serializedRows[index]).toBe(JSON.stringify(Object.fromEntries(Object.entries(app).sort(([a], [b]) => a.localeCompare(b)))));
    }
    if (f.expectedNextAction.kind === "call") {
      const args = f.expectedNextAction.allowedArguments[0];
      expect(apps.some(app => app.bundle_id === args.bundle_id)).toBe(true);
      expect(scoreCapabilityRouting(f, { toolCalls: [{ name: "computer_v2_open", arguments: JSON.stringify(args) }], text: "" }).passed).toBe(true);
    } else {
      expect(scoreCapabilityRouting(f, { toolCalls: [], text: "A virtual machine is an isolated software-defined computer." }).passed).toBe(true);
      expect(scoreCapabilityRouting(f, { toolCalls: [{ name: "computer_v2_open", arguments: JSON.stringify({ bundle_id: apps[0].bundle_id }) }], text: "" }).passed).toBe(false);
    }
  }
});

test("fresh cases exercise changed receipts and unchanged-input controls without intent inference", () => {
  const fixtures = makeMentionSafetyFixtures();
  const changed = fixtures.map(f => annotateExplicitAppMention(f.prompt, f.receipts[1].output) !== f.receipts[1].output);
  expect(changed).toEqual([true, false, true, false, true, true]);
  const negative = JSON.parse(annotateExplicitAppMention(fixtures[0].prompt, fixtures[0].receipts[1].output).split("\n")[1]);
  expect(negative.name).toBe("Glass Browser"); expect(negative.user_request_mentions_app).toBe(true);
  expect(fixtures[0].expectedNextAction.kind).toBe("abstain");
});
