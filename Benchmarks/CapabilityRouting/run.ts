// Serial next-action diagnostic only. No generated tool call is ever dispatched.
import { readFileSync, writeFileSync, renameSync, lstatSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { isAbsolute, join } from "node:path";
import { makeCapabilityRoutingFixtures, scoreCapabilityRouting, type CapabilityRoutingFixture } from "./fixtures";
import { candidates, type Arm } from "./prompts";
import { makeInspectionRoutes } from "./inspection-routes";
import { withHostContract } from "./host-contract";
import { annotateExplicitAppMention } from "./explicit-app-mention";
import { makeMentionSafetyFixtures } from "./mention-safety-fixtures";

const [split, root, rolloutPath, armList = split === "inspection" ? "baseline,capability_header" : split === "contract" ? "baseline,host_contract" : ["mention", "mention-safety"].includes(split) ? "baseline,explicit_mention" : "baseline,inspect,boundary", developmentSummary] = Bun.argv.slice(2);
if (!["development", "holdout", "recorded", "inspection", "contract", "mention", "mention-safety"].includes(split)
    || ![root, rolloutPath].every(p => p && isAbsolute(p))) {
  throw new Error("Usage: run.ts development|holdout|recorded|inspection|contract|mention|mention-safety PRIVATE_OUTPUT BASELINE_ROLLOUT [arms]");
}
const directory = lstatSync(root);
if (!directory.isDirectory() || directory.isSymbolicLink() || (directory.mode & 0o077) !== 0 || readdirSync(root).length) {
  throw new Error("Fresh empty private output directory required");
}
const retrospective = split === "inspection" || split === "contract" || split === "mention";
const mentionMode = split === "mention" || split === "mention-safety";
const arms = armList.split(",") as (Arm | "capability_header" | "host_contract" | "explicit_mention")[];
if (split === "inspection" ? armList !== "baseline,capability_header" || !!developmentSummary
    : split === "contract" ? armList !== "baseline,host_contract" || !!developmentSummary
    : mentionMode ? armList !== "baseline,explicit_mention" || !!developmentSummary
    : !arms.length || new Set(arms).size !== arms.length || arms.some(a => !Object.hasOwn(candidates, a))) throw new Error("Invalid arms");
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const headerSourceSHA256 = split === "inspection" ? hash(readFileSync(join(import.meta.dir, "inspection-routes.ts"), "utf8")) : null;
const contractSourceSHA256 = split === "contract" ? hash(readFileSync(join(import.meta.dir, "host-contract.ts"), "utf8")) : null;
const mentionSourceSHA256 = mentionMode ? hash(readFileSync(join(import.meta.dir, "explicit-app-mention.ts"), "utf8")) : null;
const raw = readFileSync(rolloutPath, "utf8");
const events = raw.trim().split("\n").map(line => JSON.parse(line));
const metadata = events.find(e => e.type === "session_meta")?.payload;
const context = events.find(e => e.type === "turn_context")?.payload;
const items = events.filter(e => e.type === "response_item").map(e => e.payload);
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const base = metadata?.base_instructions?.text;
const policyMessage = items.find(i => i.type === "message" && i.role === "user");
const policy = readFileSync("/Users/ahmedelamin/AGENTS.md", "utf8").trim();
if (context?.model !== model || typeof base !== "string" || !base.startsWith("You are HeyDash.")) throw new Error("Wrong baseline");
const inheritedPolicyMessages = items.filter(i => i.type === "message" && i.role === "user"
  && i.content?.some((c: any) => c.type === "input_text" && c.text.includes(policy)));
if (inheritedPolicyMessages.length !== 1 || inheritedPolicyMessages[0] !== policyMessage) throw new Error("Missing or ambiguous inherited policy");
if (metadata.dynamic_tools?.length !== 12) throw new Error("Unexpected tool contract");
const tools = metadata.dynamic_tools.map((t: any) => ({ type: "function", name: t.name, description: t.description, parameters: t.inputSchema }));
const hostTools = split === "contract" ? withHostContract(tools) : null;
const corpus = makeCapabilityRoutingFixtures();
const corpusSHA256 = hash(JSON.stringify(corpus));
if (split === "holdout") {
  if (arms.length !== 2 || arms[0] !== "baseline" || arms[1] === "baseline" || !developmentSummary || !isAbsolute(developmentSummary)) {
    throw new Error("Holdout requires baseline,one_frozen_candidate plus an absolute completed development summary");
  }
  const development = JSON.parse(readFileSync(developmentSummary, "utf8"));
  if (development.state !== "completed" || development.split !== "development" || development.corpusSHA256 !== corpusSHA256
      || development.candidatesSHA256 !== hash(JSON.stringify(candidates)) || development.baselineSHA256 !== hash(raw)
      || development.rows.filter((r: any) => r.arm === arms[1]).length !== 4) {
    throw new Error("Development evidence or frozen corpus/candidates changed");
  }
}
type RoutingCase = Pick<CapabilityRoutingFixture, "id" | "split" | "domain" | "stage" | "prompt" | "receipts" | "expectedNextAction">;
let cases: RoutingCase[] = split === "mention-safety" ? makeMentionSafetyFixtures() : retrospective ? corpus : corpus.filter(f => f.split === split);
if (split === "recorded") {
  const users = items.filter(i => i.type === "message" && i.role === "user");
  const calls = items.filter(i => i.type === "function_call");
  if (users.length !== 2 || calls.length !== 2 || calls.map(c => c.name).join(",") !== "computer_v2_status,computer_v2_apps") throw new Error("Recorded case changed");
  const receipts = calls.map(c => {
    const output = items.filter(i => i.type === "function_call_output" && i.call_id === c.call_id);
    if (output.length !== 1 || typeof output[0].output !== "string") throw new Error("Invalid recorded receipt");
    return { callID: c.call_id, name: c.name, arguments: c.arguments, output: output[0].output };
  });
  cases = [0, 1, 2].map(i => ({ id: `recorded-${i + 1}`, split: "development", domain: "remote_viewer", stage: "inventory",
    prompt: users[1].content.map((c: any) => c.text ?? "").join("\n"), receipts,
    expectedNextAction: { kind: "call", name: "computer_v2_open", allowedArguments: [{ bundle_id: "com.apple.ScreenSharing" }] },
  } as RoutingCase));
}
if (cases.length !== (split === "mention-safety" ? 6 : retrospective ? 12 : split === "development" ? 4 : split === "holdout" ? 8 : 3)) throw new Error("Unexpected frozen case count");
const rows: any[] = [];
let state = "running", failure: string | null = null;
const save = () => {
  const summary = { scope: split === "mention-safety" ? "fresh six-case mention safety regression; next-action/no-action only, not explanation quality or end-to-end execution" : retrospective ? "retrospective regression replay of the frozen 12-case corpus; NOT new held-out evidence or end-to-end execution" : "next-action provider diagnostic, not end-to-end task or desktop execution", split, model, state, failure,
    ...(split === "inspection" ? { headerSource: "inspection-routes.ts makeInspectionRoutes(parsed recorded status receipt)", headerSourceSHA256,
      intervention: "prepend header only to computer_v2_apps output; instructions and other receipts unchanged",
      permissionFidelityLimitation: "Frozen synthetic denied values retained; production uses not-granted. Unknown grants fail closed." } : {}),
    ...(split === "contract" ? { contractSource: "host-contract.ts withHostContract(specs)", contractSourceSHA256, candidateToolsSHA256: hash(JSON.stringify(hostTools)),
      intervention: "only computer_v2_open bundle_id parameter description changed; instructions, policy, and every receipt unchanged",
      permissionFidelityLimitation: "Frozen synthetic denied values retained; production uses not-granted." } : {}),
    ...(mentionMode ? { mentionSource: "explicit-app-mention.ts annotateExplicitAppMention(prompt, original apps output)", mentionSourceSHA256,
      intervention: "annotate/reorder only one explicitly mentioned app row; no intent or permission inference; instructions/tools/other receipts unchanged",
      comparisonWarning: "Pairs whose receipt is unchanged are unchanged-input controls, not causal evidence for the annotation.",
      safetyFixtureSourceSHA256: split === "mention-safety" ? hash(readFileSync(join(import.meta.dir, "mention-safety-fixtures.ts"), "utf8")) : null } : {}),
    baselineSHA256: hash(raw), instructionSHA256: hash(base), policySHA256: hash(policy),
    inheritedPolicyContentSHA256: hash(JSON.stringify(policyMessage.content)), toolsSHA256: hash(JSON.stringify(tools)),
    casesSHA256: hash(JSON.stringify(cases)), corpusSHA256, candidatesSHA256: hash(JSON.stringify(candidates)),
    developmentSummarySHA256: developmentSummary ? hash(readFileSync(developmentSummary, "utf8")) : null,
    differencesFromProduction: ["direct Responses request, not owned App Server", "reasoning and assistant commentary omitted", split === "contract" ? "candidate changes one bundle_id description; built-in request_user_input omitted" : "dynamic tool schema preserved from session metadata; built-in request_user_input omitted", "synthetic receipts except explicitly recorded mode", "temperature 0.1; max_output_tokens 2048; stream false", "no tool dispatch"], rows };
  const temp = join(root, "summary.json.tmp");
  writeFileSync(temp, JSON.stringify(summary, null, 2), { mode: 0o600 });
  renameSync(temp, join(root, "summary.json"));
};
async function requireIdle() {
  const child = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"], { stdout: "pipe", stderr: "pipe" });
  const loaded = JSON.parse(await new Response(child.stdout).text());
  if (await child.exited !== 0 || loaded.length !== 1 || loaded[0].identifier !== model
      || loaded[0].status !== "idle" || loaded[0].queued !== 0 || loaded[0].parallel !== 1) throw new Error("Sole model is not idle; no request sent");
}
try {
  save();
  for (let index = 0; index < cases.length; index++) {
    const fixture = cases[index];
    const pairWouldChangeReceipt = mentionMode && fixture.receipts.some(r => r.name === "computer_v2_apps" && annotateExplicitAppMention(fixture.prompt, r.output) !== r.output);
    let inspectionHeader = "";
    if (split === "inspection") {
      const statuses = fixture.receipts.filter(r => r.name === "computer_v2_status");
      if (statuses.length !== 1) throw new Error("Inspection replay requires exactly one recorded status receipt");
      inspectionHeader = makeInspectionRoutes(JSON.parse(statuses[0].output)) + "\n";
    }
    const order = [...arms.slice(index % arms.length), ...arms.slice(0, index % arms.length)];
    for (const arm of order) {
      await requireIdle();
      const input: any[] = [{ type: "message", role: "user", content: policyMessage.content },
        { type: "message", role: "user", content: [{ type: "input_text", text: fixture.prompt }] }];
      let receiptChanged = false;
      for (const r of fixture.receipts) {
        input.push({ type: "function_call", name: r.name, call_id: r.callID, arguments: r.arguments });
        const output = arm === "explicit_mention" && r.name === "computer_v2_apps" ? annotateExplicitAppMention(fixture.prompt, r.output)
          : (arm === "capability_header" && r.name === "computer_v2_apps" ? inspectionHeader : "") + r.output;
        receiptChanged ||= output !== r.output;
        input.push({ type: "function_call_output", call_id: r.callID, output });
      }
      const extraInstructions = arm === "capability_header" || arm === "host_contract" || arm === "explicit_mention" ? "" : candidates[arm];
      const requestTools = arm === "host_contract" ? hostTools! : tools;
      const request = { model, instructions: base + (extraInstructions ? "\n" + extraInstructions : ""), input, tools: requestTools,
        temperature: 0.1, max_output_tokens: 2048, stream: false };
      const start = performance.now();
      const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
        headers: { "content-type": "application/json" }, body: JSON.stringify(request), signal: AbortSignal.timeout(60_000) });
      if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
      const result: any = await response.json();
      const elapsedMS = performance.now() - start;
      if (result.error || result.model !== model || !Array.isArray(result.output)) throw new Error("Invalid provider response");
      const toolCalls = result.output.filter((i: any) => i.type === "function_call").map((i: any) => ({ name: i.name, arguments: i.arguments }));
      const text = result.output.filter((i: any) => i.type === "message" && i.role === "assistant").flatMap((i: any) => i.content ?? [])
        .filter((c: any) => c.type === "output_text").map((c: any) => c.text).join("").trim();
      const score = result.status === "completed" && !result.incomplete_details
        ? scoreCapabilityRouting(fixture, { toolCalls, text })
        : { passed: false, outcome: "incomplete_provider_response" };
      const id = `${fixture.id}-${arm}`;
      writeFileSync(join(root, `${id}.json`), JSON.stringify({ request, response: result, score }, null, 2), { mode: 0o600 });
      rows.push({ id: fixture.id, arm, stage: fixture.stage, elapsedMS, status: result.status, incomplete: result.incomplete_details ?? null,
        ...(split === "inspection" ? { headerApplied: arm === "capability_header" && fixture.receipts.some(r => r.name === "computer_v2_apps"), headerSHA256: hash(inspectionHeader) } : {}),
        ...(split === "contract" ? { hostContractApplied: arm === "host_contract", requestToolsSHA256: hash(JSON.stringify(requestTools)) } : {}),
        ...(mentionMode ? { receiptChanged, pairWouldChangeReceipt, comparisonClass: pairWouldChangeReceipt ? "changed_receipt_pair" : "unchanged_input_control" } : {}),
        score, callNames: toolCalls.map((c: any) => c.name), textCharacters: text.length, usage: result.usage });
      save();
      console.log(JSON.stringify({ id, elapsedMS: Math.round(elapsedMS), score }));
    }
  }
  state = "completed";
} catch (error) {
  state = "failed"; failure = error instanceof Error ? error.message : String(error); process.exitCode = 1;
} finally { save(); }
