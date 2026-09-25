// Read-only, redacted audit of existing loopback captures. Makes no requests.
// bun audit-wire.ts /absolute/capture-directory /absolute/fixture-directory [...]
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";

type ObjectValue = Record<string, any>;
const maximumFileBytes = 16 * 1024 * 1024;
const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
function check(ok: unknown, code: string): asserts ok { if (!ok) throw new Error(code); }
function read(file: string): Buffer {
  check(statSync(file).size <= maximumFileBytes, "file_too_large");
  const bytes = readFileSync(file);
  check(bytes.length <= maximumFileBytes, "file_grew_beyond_limit");
  return bytes;
}
function parse(value: string | Buffer): ObjectValue {
  try { return JSON.parse(value.toString()); } catch { throw new Error("invalid_json_redacted"); }
}
function canonical(value: any): string | undefined {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort()
    .map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}
function differences(expected: any, actual: any, path = ""): string[] {
  if (canonical(expected) === canonical(actual)) return [];
  if (expected && actual && !Array.isArray(expected) && !Array.isArray(actual)
    && typeof expected === "object" && typeof actual === "object") {
    return [...new Set([...Object.keys(expected), ...Object.keys(actual)])].sort().flatMap(key =>
      differences(expected[key], actual[key], `${path}.${key}`));
  }
  // Only schema paths, never descriptions or other string values, are emitted.
  return [`${path}:${actual === undefined ? "missing_on_wire" : expected === undefined ? "added_on_wire" : "changed"}`];
}

// Parse every request on each connection, not just the first JSON-looking body.
// Captures use Content-Length. Reject other framing instead of guessing boundaries.
function requests(file: string): { body: ObjectValue; bytes: Buffer; message: number }[] {
  const bytes = read(file), result = [];
  let offset = 0, message = 0;
  while (offset < bytes.length) {
    check(++message <= 64, "too_many_http_messages");
    const end = bytes.indexOf("\r\n\r\n", offset);
    check(end >= offset && end - offset <= 64 * 1024, "invalid_http_header_boundary");
    const lines = bytes.subarray(offset, end).toString("latin1").split("\r\n");
    const requestLine = /^(\S+) (\S+) HTTP\/1\.[01]$/.exec(lines.shift() ?? "");
    check(requestLine, "invalid_http_request_line");
    const headers = new Map<string, string>();
    for (const line of lines) {
      const colon = line.indexOf(":");
      check(colon > 0, "invalid_http_header");
      const key = line.slice(0, colon).toLowerCase();
      check(!headers.has(key), "duplicate_http_header");
      headers.set(key, line.slice(colon + 1).trim());
    }
    check(!headers.has("transfer-encoding"), "unsupported_http_transfer_encoding");
    check(!headers.has("content-encoding") || headers.get("content-encoding") === "identity",
      "unsupported_http_content_encoding");
    const length = headers.get("content-length") ?? "0";
    check(/^\d+$/.test(length), "invalid_http_content_length");
    const count = Number(length), bodyStart = end + 4;
    check(Number.isSafeInteger(count) && count <= maximumFileBytes
      && bodyStart + count <= bytes.length, "incomplete_or_oversized_http_body");
    const body = bytes.subarray(bodyStart, bodyStart + count);
    if (requestLine[1] === "POST" && requestLine[2] === "/v1/responses") {
      result.push({ body: parse(body), bytes: body, message });
    }
    offset = bodyStart + count;
  }
  return result;
}

try {
  const [captureDirectory, ...fixtureDirectories] = process.argv.slice(2);
  check(captureDirectory && fixtureDirectories.length > 0 && fixtureDirectories.length <= 8
    && [captureDirectory, ...fixtureDirectories].every(isAbsolute), "absolute_capture_and_fixture_paths_required");
  const policyFile = "/Users/ahmedelamin/AGENTS.md";
  const policy = read(policyFile);
  const policyText = policy.toString("utf8");
  check(policy.length > 0 && Buffer.from(policyText, "utf8").equals(policy), "policy_encoding_invalid");
  const files = readdirSync(captureDirectory).filter(name => /^connection-\d+\.client-to-upstream\.bin$/.test(name)).sort();
  check(files.length > 0 && files.length <= 64, "capture_file_count_out_of_bounds");
  const wire = files.flatMap(file => requests(join(captureDirectory, file)).map(request => ({ file, ...request })));
  const audits = fixtureDirectories.map(directory => {
    const protocol = read(join(directory, "within-protocol.jsonl")).toString().trim().split("\n").map(line => {
      const record = parse(line);
      check(typeof record.wireBase64 === "string", "protocol_wire_missing");
      return parse(Buffer.from(record.wireBase64, "base64"));
    });
    const starts = protocol.filter(record => record.method === "thread/start");
    check(starts.length === 1, "expected_one_thread_start");
    const params = starts[0].params, tools: ObjectValue[] = params.dynamicTools;
    check(typeof params.baseInstructions === "string" && Array.isArray(tools), "missing_thread_contract");
    const expectedModel = params.model ?? "lmstudio-community/Qwen3.5-4B-MLX-4bit";
    check(typeof expectedModel === "string", "invalid_expected_model");
    const toolAudit = read(join(directory, "within-tool-audit.jsonl")).toString().trim().split("\n")
      .map(parse).filter(record => record.kind === "query-recovery");
    const threadIDs = new Set(toolAudit.map(record => record.threadId));
    check(threadIDs.size === 1, "expected_one_audited_thread");
    const fixture = parse(read(join(directory, "ax-query-recovery.json")));
    const matching = wire.filter(request => threadIDs.has(request.body.client_metadata?.thread_id));
    check(matching.length > 0, "no_correlated_wire_requests");
    const reports = matching.map(request => {
      const body = request.body, actualTools: ObjectValue[] = body.tools;
      check(Array.isArray(actualTools) && Array.isArray(body.input), "wire_contract_shape_invalid");
      const exactPolicyOccurrences = body.input.filter((item: ObjectValue) => item.type === "message"
        && item.role === "user" && Array.isArray(item.content)).flatMap((item: ObjectValue) => item.content)
        .filter((part: ObjectValue) => part.type === "input_text" && typeof part.text === "string"
          && part.text.includes(policyText)).length;
      const schemas = tools.map(tool => {
        const matches = actualTools.filter(actual => actual.name === tool.name);
        check(matches.length === 1, "dynamic_tool_missing_or_duplicate");
        return { tool: tool.name, descriptionExact: matches[0].description === tool.description,
          schemaDifferences: differences(tool.inputSchema, matches[0].parameters) };
      });
      const receipts = toolAudit.flatMap(record => body.input
        .filter((item: ObjectValue) => item.type === "function_call_output" && item.call_id === record.callId)
        .map((item: ObjectValue) => {
          const text = item.output;
          check(typeof text === "string", "unexpected_tool_output_encoding");
          const fixtureKey = ["query", "direct-query"].includes(record.stage) ? "targeted" : record.stage;
          return { stage: record.stage, byteCount: Buffer.byteLength(text), sha256: hash(text),
            auditHashExact: hash(text) === record.payloadSHA256,
            fixtureExact: typeof fixture[fixtureKey] === "string" ? text === fixture[fixtureKey] : null,
            siblingHeadingCount: (text.match(/sibling_heading=/g) ?? []).length };
        }));
      return { file: request.file, message: request.message, bodyBytes: request.bytes.length,
        bodySHA256: hash(request.bytes), instructionsExact: body.instructions === params.baseInstructions,
        modelExact: body.model === expectedModel, inheritedPolicyExact: exactPolicyOccurrences === 1,
        exactPolicyOccurrences,
        instructionsSHA256: hash(body.instructions), dynamicToolCount: tools.length,
        wireToolCount: actualTools.length, additionalToolNames: actualTools
          .filter(actual => !tools.some(tool => tool.name === actual.name)).map(actual => actual.name), schemas, receipts };
    });
    return { requestCount: reports.length, threadIDHash: hash([...threadIDs][0]),
      expectedInstructionsBytes: Buffer.byteLength(params.baseInstructions),
      expectedInstructionsSHA256: hash(params.baseInstructions),
      expectedInitialSHA256: hash(fixture.initial),
      contentVerified: reports.every(report => report.instructionsExact && report.modelExact && report.inheritedPolicyExact
        && report.schemas.every(schema => schema.descriptionExact)
        && report.receipts.every(receipt => receipt.auditHashExact && receipt.fixtureExact !== false))
        && reports.some(report => report.receipts.some(receipt => receipt.stage === "initial"
          && receipt.fixtureExact && receipt.siblingHeadingCount > 0)),
      schemaFullyPreserved: reports.every(report => report.schemas.every(schema => schema.schemaDifferences.length === 0)),
      requests: reports };
  });
  const policyUnchangedDuringAudit = read(policyFile).equals(policy);
  check(policyUnchangedDuringAudit, "policy_changed_during_audit");
  console.log(JSON.stringify({ readOnly: true, headersEmitted: false, promptsEmitted: false,
    reasoningEmitted: false, policyBytes: policy.length, policySHA256: hash(policy), policyUnchangedDuringAudit,
    recordedConnections: files.length, responsesRequests: wire.length, audits }, null, 2));
  if (audits.some(audit => !audit.contentVerified)) process.exitCode = 1;
} catch {
  // JSON and filesystem errors can contain sensitive excerpts or paths.
  console.error(JSON.stringify({ auditComplete: false, error: "wire_audit_failed_redacted" }));
  process.exitCode = 1;
}
