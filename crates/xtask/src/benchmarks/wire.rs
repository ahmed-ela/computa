use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::json;
use std::collections::{BTreeMap, HashSet};
pub(super) struct WireRequest {
    pub body: Value,
    pub bytes: Vec<u8>,
    pub message: usize,
}
pub(super) struct Capture {
    pub requests: Vec<WireRequest>,
    pub messages: usize,
}
fn boundary(bytes: &[u8], start: usize) -> Option<usize> {
    bytes
        .get(start..)?
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .map(|index| index + start)
}
/// Parse every HTTP message. No header or body bytes are included in errors.
pub(super) fn requests(bytes: &[u8]) -> Result<Capture> {
    ensure(bytes.len() <= MAX_FILE, "capture_too_large")?;
    let (mut offset, mut message) = (0, 0);
    let mut result = vec![];
    while offset < bytes.len() {
        message += 1;
        ensure(message <= 64, "too_many_http_messages")?;
        let end = boundary(bytes, offset).ok_or(BenchmarkError("invalid_http_header_boundary"))?;
        ensure(end - offset <= 64 * 1024, "invalid_http_header_boundary")?;
        let header = std::str::from_utf8(&bytes[offset..end])
            .map_err(|_| BenchmarkError("invalid_http_header_encoding"))?;
        ensure(header.is_ascii(), "invalid_http_header_encoding")?;
        let mut lines = header.split("\r\n");
        let request_line = lines
            .next()
            .ok_or(BenchmarkError("invalid_http_request_line"))?;
        let parts: Vec<_> = request_line.split(' ').collect();
        ensure(
            parts.len() == 3
                && !parts[0].is_empty()
                && !parts[1].is_empty()
                && matches!(parts[2], "HTTP/1.0" | "HTTP/1.1")
                && !parts[..2]
                    .iter()
                    .any(|part| part.chars().any(char::is_whitespace)),
            "invalid_http_request_line",
        )?;
        let mut headers = BTreeMap::new();
        for line in lines {
            let (key, value) = line
                .split_once(':')
                .ok_or(BenchmarkError("invalid_http_header"))?;
            ensure(
                !key.is_empty()
                    && key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
                "invalid_http_header",
            )?;
            let key = key.to_ascii_lowercase();
            ensure(
                headers.insert(key, value.trim()).is_none(),
                "duplicate_http_header",
            )?;
        }
        ensure(
            !headers.contains_key("transfer-encoding"),
            "unsupported_http_transfer_encoding",
        )?;
        ensure(
            headers
                .get("content-encoding")
                .is_none_or(|value| *value == "identity"),
            "unsupported_http_content_encoding",
        )?;
        let length = headers.get("content-length").copied().unwrap_or("0");
        ensure(
            !length.is_empty() && length.bytes().all(|byte| byte.is_ascii_digit()),
            "invalid_http_content_length",
        )?;
        let count = length
            .parse::<usize>()
            .map_err(|_| BenchmarkError("invalid_http_content_length"))?;
        let body_start = end + 4;
        ensure(
            count <= MAX_FILE && count <= bytes.len() - body_start,
            "incomplete_or_oversized_http_body",
        )?;
        let body = &bytes[body_start..body_start + count];
        if parts[0] == "POST" && parts[1] == "/v1/responses" {
            ensure(
                headers.contains_key("content-length"),
                "responses_content_length_required",
            )?;
            result.push(WireRequest {
                body: parse(body)?,
                bytes: body.to_vec(),
                message,
            });
        }
        offset = body_start + count;
    }
    Ok(Capture {
        requests: result,
        messages: message,
    })
}
pub(super) fn canonical(value: &Value) -> String {
    match value {
        Value::Array(items) => format!(
            "[{}]",
            items.iter().map(canonical).collect::<Vec<_>>().join(",")
        ),
        Value::Object(object) => {
            let ordered: BTreeMap<_, _> = object.iter().collect();
            format!(
                "{{{}}}",
                ordered
                    .into_iter()
                    .map(|(key, value)| format!(
                        "{}:{}",
                        serde_json::to_string(key).unwrap(),
                        canonical(value)
                    ))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        }
        _ => value.to_string(),
    }
}
fn differences(expected: Option<&Value>, actual: Option<&Value>, path: &str) -> Vec<String> {
    if expected.map(canonical) == actual.map(canonical) {
        return vec![];
    }
    if let (Some(Value::Object(expected)), Some(Value::Object(actual))) = (expected, actual) {
        let keys = expected
            .keys()
            .chain(actual.keys())
            .collect::<std::collections::BTreeSet<_>>();
        return keys
            .into_iter()
            .flat_map(|key| {
                differences(expected.get(key), actual.get(key), &format!("{path}.{key}"))
            })
            .collect();
    }
    vec![format!(
        "{path}:{}",
        if actual.is_none() {
            "missing_on_wire"
        } else if expected.is_none() {
            "added_on_wire"
        } else {
            "changed"
        }
    )]
}
fn jsonl(path: &Path) -> Result<Vec<Value>> {
    let text = read_text(path)?;
    ensure(!text.trim().is_empty(), "empty_jsonl")?;
    ensure(text.lines().count() <= 100_000, "too_many_jsonl_records")?;
    text.trim()
        .lines()
        .map(|line| parse(line.as_bytes()))
        .collect()
}
/// Read-only redacted capture audit. Prompt/header/reasoning bodies stay local.
pub fn audit_wire(
    capture_directory: &Path,
    fixture_directories: &[PathBuf],
    policy_file: &Path,
) -> Result<Value> {
    ensure(
        capture_directory.is_absolute()
            && !fixture_directories.is_empty()
            && fixture_directories.len() <= 8
            && fixture_directories.iter().all(|path| path.is_absolute()),
        "absolute_capture_and_fixture_paths_required",
    )?;
    let policy = read(policy_file)?;
    ensure(!policy.is_empty(), "policy_encoding_invalid")?;
    let policy_text =
        std::str::from_utf8(&policy).map_err(|_| BenchmarkError("policy_encoding_invalid"))?;
    let mut files = std::fs::read_dir(capture_directory)
        .map_err(|_| BenchmarkError("capture_directory_unavailable"))?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let number = name
                .strip_prefix("connection-")?
                .strip_suffix(".client-to-upstream.bin")?;
            (!number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit())).then_some(name)
        })
        .collect::<Vec<_>>();
    files.sort();
    ensure(
        !files.is_empty() && files.len() <= 64,
        "capture_file_count_out_of_bounds",
    )?;
    let mut wire = vec![];
    for file in &files {
        for request in requests(&read(&capture_directory.join(file))?)?.requests {
            wire.push((file, request));
        }
    }
    let mut audits = vec![];
    for directory in fixture_directories {
        let protocol = jsonl(&directory.join("within-protocol.jsonl"))?
            .into_iter()
            .map(|record| {
                let wire = record["wireBase64"]
                    .as_str()
                    .ok_or(BenchmarkError("protocol_wire_missing"))?;
                let bytes = STANDARD
                    .decode(wire)
                    .map_err(|_| BenchmarkError("protocol_wire_invalid"))?;
                parse(&bytes)
            })
            .collect::<Result<Vec<_>>>()?;
        let starts = protocol
            .iter()
            .filter(|record| record["method"] == "thread/start")
            .collect::<Vec<_>>();
        ensure(starts.len() == 1, "expected_one_thread_start")?;
        let params = &starts[0]["params"];
        let instructions = params["baseInstructions"]
            .as_str()
            .ok_or(BenchmarkError("missing_thread_contract"))?;
        let tools = params["dynamicTools"]
            .as_array()
            .ok_or(BenchmarkError("missing_thread_contract"))?;
        ensure(tools.len() <= 256, "too_many_dynamic_tools")?;
        let expected_model = params
            .get("model")
            .filter(|value| !value.is_null())
            .map_or(Ok(MODEL), |value| {
                value
                    .as_str()
                    .ok_or(BenchmarkError("invalid_expected_model"))
            })?;
        let tool_audit = jsonl(&directory.join("within-tool-audit.jsonl"))?
            .into_iter()
            .filter(|record| record["kind"] == "query-recovery")
            .collect::<Vec<_>>();
        let thread_ids: HashSet<_> = tool_audit
            .iter()
            .filter_map(|record| record["threadId"].as_str())
            .collect();
        ensure(
            thread_ids.len() == 1
                && tool_audit
                    .iter()
                    .all(|record| record["threadId"].is_string()),
            "expected_one_audited_thread",
        )?;
        let fixture = read_json(&directory.join("ax-query-recovery.json"))?;
        let matching = wire
            .iter()
            .filter(|(_, request)| {
                request.body["client_metadata"]["thread_id"]
                    .as_str()
                    .is_some_and(|id| thread_ids.contains(id))
            })
            .collect::<Vec<_>>();
        ensure(!matching.is_empty(), "no_correlated_wire_requests")?;
        let mut reports = vec![];
        for (file, request) in matching {
            let body = &request.body;
            let actual_tools = body["tools"]
                .as_array()
                .ok_or(BenchmarkError("wire_contract_shape_invalid"))?;
            let input = body["input"]
                .as_array()
                .ok_or(BenchmarkError("wire_contract_shape_invalid"))?;
            let occurrences = input
                .iter()
                .filter(|item| item["type"] == "message" && item["role"] == "user")
                .flat_map(|item| item["content"].as_array().into_iter().flatten())
                .filter(|part| {
                    part["type"] == "input_text"
                        && part["text"]
                            .as_str()
                            .is_some_and(|text| text.contains(policy_text))
                })
                .count();
            let mut schemas = vec![];
            for tool in tools {
                let matches = actual_tools
                    .iter()
                    .filter(|actual| actual["name"] == tool["name"])
                    .collect::<Vec<_>>();
                ensure(matches.len() == 1, "dynamic_tool_missing_or_duplicate")?;
                schemas.push(json!({"tool":tool["name"],"descriptionExact":matches[0]["description"]==tool["description"],"schemaDifferences":differences(tool.get("inputSchema"),matches[0].get("parameters"),"")}));
            }
            let mut receipts = vec![];
            for record in &tool_audit {
                for item in input.iter().filter(|item| {
                    item["type"] == "function_call_output" && item["call_id"] == record["callId"]
                }) {
                    let text = item["output"]
                        .as_str()
                        .ok_or(BenchmarkError("unexpected_tool_output_encoding"))?;
                    let stage = record["stage"]
                        .as_str()
                        .ok_or(BenchmarkError("receipt_stage_invalid"))?;
                    let key = if matches!(stage, "query" | "direct-query") {
                        "targeted"
                    } else {
                        stage
                    };
                    receipts.push(json!({"stage":stage,"byteCount":text.len(),"sha256":hash(text),"auditHashExact":record["payloadSHA256"]==hash(text),"fixtureExact":fixture[key].as_str().map(|expected|expected==text),"siblingHeadingCount":text.matches("sibling_heading=").count()}));
                }
            }
            reports.push(json!({"file":file,"message":request.message,"bodyBytes":request.bytes.len(),"bodySHA256":hash(&request.bytes),"instructionsExact":body["instructions"]==instructions,"modelExact":body["model"]==expected_model,"inheritedPolicyExact":occurrences==1,"exactPolicyOccurrences":occurrences,"instructionsSHA256":hash(body["instructions"].as_str().ok_or(BenchmarkError("wire_instructions_invalid"))?),"dynamicToolCount":tools.len(),"wireToolCount":actual_tools.len(),"additionalToolNames":actual_tools.iter().filter(|actual|!tools.iter().any(|tool|tool["name"]==actual["name"])).map(|actual|actual["name"].clone()).collect::<Vec<_>>(),"schemas":schemas,"receipts":receipts}));
        }
        let content_verified = reports.iter().all(|report| {
            report["instructionsExact"] == true
                && report["modelExact"] == true
                && report["inheritedPolicyExact"] == true
                && report["schemas"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|schema| schema["descriptionExact"] == true)
                && report["receipts"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .all(|receipt| {
                        receipt["auditHashExact"] == true && receipt["fixtureExact"] != false
                    })
        }) && reports.iter().any(|report| {
            report["receipts"]
                .as_array()
                .unwrap()
                .iter()
                .any(|receipt| {
                    receipt["stage"] == "initial"
                        && receipt["fixtureExact"] == true
                        && receipt["siblingHeadingCount"]
                            .as_u64()
                            .is_some_and(|count| count > 0)
                })
        });
        let schema_preserved = reports.iter().all(|report| {
            report["schemas"]
                .as_array()
                .unwrap()
                .iter()
                .all(|schema| schema["schemaDifferences"].as_array().unwrap().is_empty())
        });
        let first_thread = thread_ids.iter().next().unwrap();
        audits.push(json!({"requestCount":reports.len(),"threadIDHash":hash(first_thread),"expectedInstructionsBytes":instructions.len(),"expectedInstructionsSHA256":hash(instructions),"expectedInitialSHA256":hash(fixture["initial"].as_str().ok_or(BenchmarkError("initial_fixture_invalid"))?),"contentVerified":content_verified,"schemaFullyPreserved":schema_preserved,"requests":reports}));
    }
    ensure(read(policy_file)? == policy, "policy_changed_during_audit")?;
    Ok(
        json!({"readOnly":true,"headersEmitted":false,"promptsEmitted":false,"reasoningEmitted":false,"policyBytes":policy.len(),"policySHA256":hash(&policy),"policyUnchangedDuringAudit":true,"recordedConnections":files.len(),"responsesRequests":wire.len(),"audits":audits}),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    fn request(body: &str) -> Vec<u8> {
        format!("POST /v1/responses HTTP/1.1\r\nContent-Length: {}\r\nAuthorization: private-not-output\r\n\r\n{body}",body.len()).into_bytes()
    }
    #[test]
    fn every_captured_http_message_is_parsed_and_unsupported_framing_fails() {
        let mut bytes = request("{\"a\":1}");
        bytes.extend(request("{\"a\":2}"));
        let parsed = requests(&bytes).unwrap();
        assert_eq!(parsed.messages, 2);
        assert_eq!(parsed.requests.len(), 2);
        assert_eq!(parsed.requests[1].body["a"], 2);
        for bytes in [
            b"POST /v1/responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".to_vec(),
            b"POST /v1/responses HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n{}"
                .to_vec(),
            request("{\"a\":1,\"a\":2}"),
            b"POST /v1/responses HTTP/1.1\r\nContent-Length: 99\r\n\r\n{}".to_vec(),
        ] {
            assert!(requests(&bytes).is_err());
        }
    }
    #[test]
    fn schema_diff_emits_paths_only_and_preserves_array_comparison() {
        let expected =
            json!({"private":"never-reproduce-value","schema":{"required":["x"],"type":"object"}});
        let actual =
            json!({"private":"different-secret","schema":{"required":["y"],"type":"object"}});
        let paths = differences(Some(&expected), Some(&actual), "");
        assert_eq!(paths, vec![".private:changed", ".schema.required:changed"]);
        assert!(!paths.join(" ").contains("never-reproduce"));
    }
}
