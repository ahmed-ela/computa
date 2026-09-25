// Narrow, serial extraction experiment. No tools, browser actions, or private data.
// This is not an App Server or end-to-end computer-use acceptance gate.
import { rename } from "node:fs/promises";

const [fixturePath, outputDirectory] = Bun.argv.slice(2);
if (!fixturePath?.startsWith("/") || !outputDirectory?.startsWith("/")) throw new Error("Use absolute fixture and output-directory paths");
const model = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
type Outcome = "answered_correct" | "answered_wrong" | "no_final_answer" | "server_error" | "transport_error";
type Fixture = { id: string; variant: "ancestry" | "without_ancestry"; observation: string; expected: string; targetObserved: boolean };
const outcomes: Outcome[] = ["answered_correct", "answered_wrong", "no_final_answer", "server_error", "transport_error"];
const expectedIDs = ["flat", "nested"].flatMap(shape => ["normal", "reversed"].flatMap(order =>
  ["full", "limited"].flatMap(bound => ["ancestry", "without_ancestry"].map(variant => `${shape}-${order}-${bound}-${variant}`))));
let fixtures: Fixture[] = [];
let fixturesValidated = false;
const rows: Record<string, unknown>[] = [];
let state: "validating" | "running" | "completed" | "stopped" = "validating";
let stopReason: string | null = null;

async function saveSummary() {
  const attemptedIDs = new Set(rows.map(row => row.id));
  const unrunIDs = (fixturesValidated ? fixtures.map(fixture => fixture.id) : expectedIDs)
    .filter(id => !attemptedIDs.has(id));
  const summary = { scope: "synthetic extraction; not end-to-end", model, state,
    fixtures_validated: fixturesValidated, planned_count: 16, attempted_count: rows.length,
    unrun_count: unrunIDs.length, unrun_ids: unrunIDs, stop_reason: stopReason,
    outcome_counts: Object.fromEntries(outcomes.map(outcome => [outcome, rows.filter(row => row.outcome === outcome).length])), rows };
  // Replace atomically so an interrupted write leaves the previous partial summary intact.
  const temporaryPath = `${outputDirectory}/summary.json.tmp`;
  await Bun.write(temporaryPath, JSON.stringify(summary, null, 2));
  await rename(temporaryPath, `${outputDirectory}/summary.json`);
}

try {
  const source = await Bun.file(fixturePath).json();
  if (!Array.isArray(source) || source.length !== 16) throw new Error("Expected exactly 16 synthetic paired fixtures");
  // Validate the entire batch before even checking model state, not one fixture at a time.
  const seen = new Set<string>();
  for (const fixture of source) {
    if (!fixture || typeof fixture !== "object" || !expectedIDs.includes(fixture.id) || seen.has(fixture.id)) {
      throw new Error("Invalid or duplicate fixture ID");
    }
    seen.add(fixture.id);
    if (!["ancestry", "without_ancestry"].includes(fixture.variant) || !fixture.id.endsWith(`-${fixture.variant}`)) {
      throw new Error("Invalid fixture variant");
    }
    if (typeof fixture.observation !== "string" || !fixture.observation.trim() || fixture.observation.length > 3000) {
      throw new Error("Invalid observation bound");
    }
    if (typeof fixture.expected !== "string" || !fixture.expected.trim() || fixture.expected.length > 200) {
      throw new Error("Invalid expected answer");
    }
    if (typeof fixture.targetObserved !== "boolean" || (fixture.expected === "UNOBSERVED") === fixture.targetObserved) {
      throw new Error("Regenerate fixtures: expected answer must agree with actual target visibility");
    }
  }
  fixtures = source;
  fixturesValidated = true;
  state = "running";
  await saveSummary();

  for (const fixture of fixtures) {
    const check = Bun.spawn(["/Users/ahmedelamin/.lmstudio/bin/lms", "ps", "--json"], { stdout: "pipe", stderr: "pipe" });
    const models = JSON.parse(await new Response(check.stdout).text());
    if (await check.exited !== 0 || models.length !== 1 || models[0].identifier !== model
        || models[0].status !== "idle" || models[0].queued !== 0 || models[0].parallel !== 1) {
      throw new Error("Expected one idle serial 4B instance; stop without changing model state");
    }
    const body = { model, stream: false, temperature: 0.1, max_output_tokens: 2048,
      instructions: "Read only the supplied synthetic AX observation. Lines are relevance-ranked, not page order. The header parents=[child:parent,...] map and each line's parent preserve observed containment. Parent paths may include group IDs whose lines are omitted. sibling_heading is observed direct-sibling context, not proof of semantic ownership. Follow those paths to associate a fact with the requested card; sharing only a page or root does not mean sharing a card. Unknown or truncated ancestry does not establish association. Do not associate adjacent unrelated facts. If the requested order's status is not supported by the shown elements, answer UNOBSERVED. Return only the exact status or UNOBSERVED, no explanation.",
      input: [{ role: "user", content: [{ type: "input_text", text: `What is the delivery status text shown for Order A?\n\n${fixture.observation}` }] }] };
    const started = performance.now();
    let result: any = null;
    let output = "";
    let outcome: Outcome = "transport_error";
    let failure: string | null = null;
    let httpStatus: number | null = null;
    try {
      const response = await fetch("http://127.0.0.1:1234/v1/responses", { method: "POST", redirect: "error",
        headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(45000) });
      httpStatus = response.status;
      if (!response.ok) {
        outcome = "server_error";
        failure = `Local server HTTP ${response.status}`;
      } else {
        outcome = "server_error";
        result = await response.json();
        if (!result || typeof result !== "object" || !Array.isArray(result.output)) {
          failure = "Malformed local Responses payload";
        } else {
          output = result.output.filter((item: any) => item?.type === "message" && item.role === "assistant")
            .flatMap((item: any) => Array.isArray(item.content) ? item.content : [])
            .filter((item: any) => item?.type === "output_text" && typeof item.text === "string")
            .map((item: any) => item.text).join("").trim();
          if (result.error || !["completed", "incomplete"].includes(result.status)) {
            failure = "Local response error or unsuccessful status";
          } else if (!output) {
            outcome = "no_final_answer";
            failure = "No final answer within the generation bound";
          } else if (result.status !== "completed") {
            failure = "Local response incomplete; partial text is not an answered extraction";
          } else {
            outcome = output === fixture.expected ? "answered_correct" : "answered_wrong";
          }
        }
      }
    } catch (error) {
      // Invalid JSON is a server failure; timeouts/body-transfer failures remain
      // transport failures even when HTTP headers arrived before the failure.
      outcome = error instanceof SyntaxError ? "server_error" : "transport_error";
      failure = error instanceof Error ? error.message : String(error);
    }
    const answered = outcome === "answered_correct" || outcome === "answered_wrong";
    const row = { id: fixture.id, variant: fixture.variant, expected: fixture.expected, output, outcome,
      correct: answered ? outcome === "answered_correct" : null,
      elapsed_ms: performance.now() - started, status: result?.status ?? null,
      error: result?.error ?? null, failure, http_status: httpStatus,
      model: result?.model ?? null, usage: result?.usage ?? null, effective_temperature: result?.temperature ?? null,
      max_output_tokens: result?.max_output_tokens ?? body.max_output_tokens };
    rows.push(row);
    await Bun.write(`${outputDirectory}/${fixture.id}.json`, JSON.stringify({ request: body, response: result, metrics: row }, null, 2));
    await saveSummary();
    console.log(JSON.stringify(row));
    if (!answered) throw new Error(`${outcome}: ${failure}; stop, do not retry`);
  }
  state = "completed";
} catch (error) {
  state = "stopped";
  stopReason = error instanceof Error ? error.message : String(error);
  throw error;
} finally {
  await saveSummary();
}
