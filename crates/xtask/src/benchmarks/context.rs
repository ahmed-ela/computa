//! Exact bounded context replays. Tool calls are recorded as data and never run.
use super::*;
use serde_json::json;
use std::{
    path::Path,
    time::{Duration, Instant},
};
const BODY_LIMIT: usize = 1024 * 1024;
const RESPONSE_LIMIT: usize = 8 * 1024 * 1024;
fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::String(value) => !value.is_empty(),
        Value::Number(value) => value.as_f64() != Some(0.0),
        _ => true,
    }
}
pub fn context_request(raw: &str) -> Result<Value> {
    ensure(raw.len() <= BODY_LIMIT, "context_request_exceeds_one_mib")?;
    let body = parse(raw.as_bytes())?;
    ensure(
        body.is_object()
            && body["model"]
                .as_str()
                .is_some_and(|model| !model.is_empty())
            && body["input"].is_array(),
        "context_requires_explicit_model_history",
    )?;
    ensure(
        !truthy(&body["previous_response_id"])
            && !truthy(&body["conversation"])
            && !truthy(&body["background"]),
        "context_chained_background_requests_unsupported",
    )?;
    ensure(
        body.get("tools").is_none()
            || body["tools"].as_array().is_some_and(|tools| {
                tools.iter().all(|tool| {
                    tool.is_object() && tool["type"] == "function" && tool["name"].is_string()
                })
            }),
        "context_only_inert_custom_function_tools",
    )?;
    Ok(body)
}
#[derive(Debug)]
pub struct PreparedReplay {
    pub raw: String,
    pub changed_sampler: bool,
    pub inserted_assistant_history: bool,
}
pub fn prepare_context_replay(
    raw: &str,
    temperature: Option<f64>,
    assistant_raw: Option<&str>,
) -> Result<PreparedReplay> {
    let mut body = context_request(raw)?;
    ensure(
        temperature.is_none_or(|value| value == 0.0),
        "context_only_explicit_temperature_zero",
    )?;
    if let Some(assistant_raw) = assistant_raw {
        ensure(
            assistant_raw.len() <= 2048,
            "context_assistant_history_exceeds_bound",
        )?;
        let item = parse(assistant_raw.as_bytes())?;
        ensure(
            item.is_object()
                && item["type"] == "message"
                && item["role"] == "assistant"
                && item
                    .as_object()
                    .unwrap()
                    .keys()
                    .all(|key| ["type", "role", "id", "content", "phase"].contains(&key.as_str())),
            "context_expected_original_assistant_message",
        )?;
        ensure(
            item["content"].as_array().is_some_and(|parts| {
                !parts.is_empty()
                    && parts.iter().all(|part| {
                        part.is_object()
                            && part["type"] == "output_text"
                            && part["text"].is_string()
                            && part
                                .as_object()
                                .unwrap()
                                .keys()
                                .all(|key| ["type", "text"].contains(&key.as_str()))
                    })
            }),
            "context_assistant_history_requires_only_output_text",
        )?;
        let input = body["input"].as_array_mut().unwrap();
        let index = input
            .iter()
            .rposition(|item| item["type"] == "message" && item["role"] == "user")
            .ok_or(BenchmarkError("context_no_latest_user_request"))?;
        input.insert(index, item);
    }
    if let Some(temperature) = temperature {
        body["temperature"] = json!(temperature);
    }
    let prepared = if temperature.is_none() && assistant_raw.is_none() {
        raw.to_owned()
    } else {
        body.to_string()
    };
    ensure(
        prepared.len() <= BODY_LIMIT,
        "context_modified_request_exceeds_one_mib",
    )?;
    Ok(PreparedReplay {
        raw: prepared,
        changed_sampler: temperature.is_some(),
        inserted_assistant_history: assistant_raw.is_some(),
    })
}
pub fn summarize_context_response(
    raw: &str,
    content_type: &str,
    elapsed_ms: f64,
    status: u16,
) -> Result<Value> {
    ensure(
        raw.len() <= RESPONSE_LIMIT,
        "context_response_exceeds_eight_mib",
    )?;
    let response = if content_type.contains("text/event-stream") {
        let mut decoder = SseDecoder::default();
        let events = decoder.push(raw)?;
        decoder.finish()?;
        ensure(
            !events.iter().any(|event| {
                event["type"].as_str().is_some_and(|kind| {
                    [
                        "error",
                        "provider.error",
                        "response.failed",
                        "response.incomplete",
                    ]
                    .contains(&kind)
                })
            }),
            "context_sse_failure_incomplete",
        )?;
        let endings = events
            .iter()
            .filter(|event| event["type"] == "response.completed")
            .collect::<Vec<_>>();
        ensure(
            endings.len() == 1,
            "context_expected_exactly_one_completed_response",
        )?;
        endings[0]["response"].clone()
    } else {
        parse(raw.as_bytes())?
    };
    ensure((200..300).contains(&status), "context_http_error")?;
    ensure(
        response.is_object() && !truthy(&response["error"]) && response["status"] == "completed",
        "context_response_not_completed",
    )?;
    let output = response.get("output").cloned().unwrap_or(json!([]));
    ensure(output.is_array(), "context_invalid_response_output")?;
    Ok(
        json!({"responseID":response["id"],"status":response["status"],"elapsedMs":elapsed_ms,"finalText":final_text(&response),"toolCallNames":output.as_array().unwrap().iter().filter(|item|item["type"]=="function_call").map(|item|item["name"].clone()).collect::<Vec<_>>(),"inputTokens":response["usage"]["input_tokens"],"outputTokens":response["usage"]["output_tokens"],"cachedTokens":response["usage"]["input_tokens_details"]["cached_tokens"]}),
    )
}
fn exclusive(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| BenchmarkError("context_artifact_create_failed"))?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| BenchmarkError("context_artifact_write_failed"))
}
struct ResponseEvidence<'a> {
    kind: &'a str,
    elapsed: f64,
    status: u16,
    transport_error: Option<&'static str>,
}
fn save_response(
    out: &Path,
    prefix: &str,
    raw: &str,
    prepared: Option<&PreparedReplay>,
    evidence: ResponseEvidence<'_>,
) -> Result<Value> {
    let ResponseEvidence {
        kind,
        elapsed,
        status,
        transport_error,
    } = evidence;
    exclusive(
        &out.join(format!(
            "{prefix}.response.{}",
            if kind.contains("event-stream") {
                "sse"
            } else {
                "json"
            }
        )),
        raw.as_bytes(),
    )?;
    let mut result = if let Some(error) = transport_error {
        json!({"error":error,"status":status,"elapsedMs":elapsed})
    } else {
        summarize_context_response(raw, kind, elapsed, status)
            .unwrap_or_else(|error| json!({"error":error.0,"status":status,"elapsedMs":elapsed}))
    };
    if let Some(prepared) = prepared {
        result["changedSampler"] = json!(prepared.changed_sampler);
        result["insertedAssistantHistory"] = json!(prepared.inserted_assistant_history);
    }
    exclusive(
        &out.join(format!("{prefix}.summary.json")),
        &serde_json::to_vec_pretty(&result)
            .map_err(|_| BenchmarkError("context_summary_serialize_failed"))?,
    )?;
    Ok(result)
}
pub async fn context_replay(
    request: &Path,
    output: &Path,
    count: usize,
    temperature: Option<f64>,
    assistant: Option<&Path>,
) -> Result<Vec<Value>> {
    ensure(
        (1..=10).contains(&count),
        "context_replay_count_must_be_one_through_ten",
    )?;
    let raw = read_text(request)?;
    let assistant = assistant.map(read_text).transpose()?;
    let prepared = prepare_context_replay(&raw, temperature, assistant.as_deref())?;
    let output = private_output(output)?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|_| BenchmarkError("context_client_failed"))?;
    let mut summaries = vec![];
    for index in 1..=count {
        let prefix = format!("{index:03}-{}", uuid::Uuid::new_v4());
        let started = Instant::now();
        exclusive(
            &output.join(format!("{prefix}.request.json")),
            prepared.raw.as_bytes(),
        )?;
        let request = async {
            let mut response = client
                .post("http://127.0.0.1:1234/v1/responses")
                .header("content-type", "application/json")
                .body(prepared.raw.clone())
                .send()
                .await
                .map_err(|_| BenchmarkError("context_transport_failed"))?;
            let status = response.status().as_u16();
            let kind = response
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok())
                .unwrap_or("application/json")
                .to_owned();
            let mut bytes = vec![];
            while let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| BenchmarkError("context_stream_transport_failed"))?
            {
                ensure(
                    bytes.len() + chunk.len() <= RESPONSE_LIMIT,
                    "context_response_exceeds_eight_mib",
                )?;
                bytes.extend_from_slice(&chunk);
            }
            let text = String::from_utf8(bytes)
                .map_err(|_| BenchmarkError("context_response_invalid_utf8"))?;
            Ok::<_, BenchmarkError>((text, kind, status))
        };
        let result = match tokio::time::timeout(Duration::from_secs(120), request).await {
            Ok(Ok((text, kind, status))) => save_response(
                &output,
                &prefix,
                &text,
                Some(&prepared),
                ResponseEvidence {
                    kind: &kind,
                    elapsed: started.elapsed().as_secs_f64() * 1000.0,
                    status,
                    transport_error: None,
                },
            )?,
            Ok(Err(error)) => save_response(
                &output,
                &prefix,
                "",
                Some(&prepared),
                ResponseEvidence {
                    kind: "application/json",
                    elapsed: started.elapsed().as_secs_f64() * 1000.0,
                    status: 0,
                    transport_error: Some(error.0),
                },
            )?,
            Err(_) => save_response(
                &output,
                &prefix,
                "",
                Some(&prepared),
                ResponseEvidence {
                    kind: "application/json",
                    elapsed: started.elapsed().as_secs_f64() * 1000.0,
                    status: 0,
                    transport_error: Some("context_request_timeout"),
                },
            )?,
        };
        let failed = result.get("error").is_some();
        summaries.push(result);
        if failed {
            break;
        }
    }
    Ok(summaries)
}

struct Incoming {
    method: String,
    path: String,
    authorization: Option<String>,
    body: Vec<u8>,
}
async fn incoming(stream: &mut tokio::net::TcpStream) -> Result<Incoming> {
    use tokio::io::AsyncReadExt;
    let mut bytes = vec![];
    let mut buffer = [0u8; 4096];
    let end;
    loop {
        let count = stream
            .read(&mut buffer)
            .await
            .map_err(|_| BenchmarkError("context_capture_read_failed"))?;
        ensure(count > 0, "context_capture_missing_header")?;
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(index) = bytes.windows(4).position(|value| value == b"\r\n\r\n") {
            end = index;
            break;
        }
        ensure(bytes.len() <= 32768, "context_capture_header_exceeds_bound")?;
    }
    ensure(end <= 32768, "context_capture_header_exceeds_bound")?;
    let header = std::str::from_utf8(&bytes[..end])
        .map_err(|_| BenchmarkError("context_capture_header_invalid_utf8"))?;
    let mut lines = header.split("\r\n");
    let first = lines.next().unwrap_or("");
    let parts = first.split(' ').collect::<Vec<_>>();
    ensure(
        parts.len() == 3
            && matches!(parts[2], "HTTP/1.0" | "HTTP/1.1")
            && parts[1].starts_with('/')
            && parts[1].len() <= 2048,
        "context_capture_invalid_request_line",
    )?;
    let method = parts[0].to_owned();
    let path = parts[1].split('?').next().unwrap().to_owned();
    let mut headers = std::collections::HashMap::new();
    for line in lines {
        let (key, value) = line
            .split_once(':')
            .ok_or(BenchmarkError("context_capture_invalid_header"))?;
        let key = key.to_ascii_lowercase();
        let value = value.trim();
        ensure(
            !key.is_empty()
                && !key
                    .chars()
                    .any(|character| character.is_whitespace() || character.is_control())
                && !value.chars().any(char::is_control)
                && headers.insert(key, value.to_owned()).is_none(),
            "context_capture_duplicate_invalid_header",
        )?;
    }
    ensure(
        !headers.contains_key("transfer-encoding"),
        "context_capture_chunked_request_unsupported",
    )?;
    let length = headers
        .get("content-length")
        .map(|value| {
            value
                .parse::<usize>()
                .map_err(|_| BenchmarkError("context_capture_invalid_content_length"))
        })
        .transpose()?
        .unwrap_or(0);
    ensure(
        length <= BODY_LIMIT,
        "context_capture_request_exceeds_bound",
    )?;
    let authorization = headers.get("authorization").cloned();
    if let Some(value) = &authorization {
        ensure(
            value.len() <= 4096,
            "context_capture_authorization_exceeds_bound",
        )?;
    }
    let mut body = bytes[end + 4..].to_vec();
    ensure(
        body.len() <= length,
        "context_capture_pipelining_unsupported",
    )?;
    while body.len() < length {
        let count = stream
            .read(&mut buffer)
            .await
            .map_err(|_| BenchmarkError("context_capture_body_read_failed"))?;
        ensure(
            count > 0 && body.len() + count <= length,
            "context_capture_body_length_mismatch",
        )?;
        body.extend_from_slice(&buffer[..count]);
    }
    Ok(Incoming {
        method,
        path,
        authorization,
        body,
    })
}
async fn http_header(stream: &mut tokio::net::TcpStream, status: u16, kind: &str) -> Result<()> {
    use tokio::io::AsyncWriteExt;
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        429 => "Too Many Requests",
        502 => "Bad Gateway",
        _ => "Response",
    };
    stream.write_all(format!("HTTP/1.1 {status} {reason}\r\nConnection: close\r\nContent-Type: {kind}\r\nCache-Control: no-store\r\n\r\n").as_bytes()).await.map_err(|_|BenchmarkError("context_capture_client_closed"))
}
async fn capture_connection(
    mut stream: tokio::net::TcpStream,
    output: std::sync::Arc<std::path::PathBuf>,
    count: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    client: reqwest::Client,
    upstream: String,
) -> Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let request = tokio::time::timeout(Duration::from_secs(10), incoming(&mut stream))
        .await
        .map_err(|_| BenchmarkError("context_capture_request_header_timeout"))??;
    let models = request.method == "GET"
        && ["/v1/models", "/api/v1/models"].contains(&request.path.as_str());
    if !models && (request.method != "POST" || request.path != "/v1/responses") {
        http_header(&mut stream, 404, "text/plain").await?;
        return Ok(());
    }
    let prefix = if models {
        None
    } else {
        let index = count
            .fetch_update(
                std::sync::atomic::Ordering::AcqRel,
                std::sync::atomic::Ordering::Acquire,
                |index| (index < 30).then_some(index + 1),
            )
            .map_err(|_| BenchmarkError("context_capture_limit_reached"));
        let index = match index {
            Ok(index) => index + 1,
            Err(_) => {
                http_header(&mut stream, 429, "text/plain").await?;
                return Ok(());
            }
        };
        let text = std::str::from_utf8(&request.body)
            .map_err(|_| BenchmarkError("context_capture_request_invalid_utf8"))?;
        context_request(text)?;
        let prefix = format!("{index:03}-{}", uuid::Uuid::new_v4());
        exclusive(
            &output.join(format!("{prefix}.request.json")),
            &request.body,
        )?;
        Some(prefix)
    };
    let started = Instant::now();
    let mut builder = if models {
        client.get(format!("{upstream}{}", request.path))
    } else {
        client
            .post(format!("{upstream}{}", request.path))
            .header("content-type", "application/json")
            .body(request.body)
    };
    if let Some(authorization) = request.authorization {
        builder = builder.header("authorization", authorization);
    }
    let result = builder.send().await;
    let mut response = match result {
        Ok(response) => response,
        Err(_) => {
            if let Some(prefix) = prefix {
                save_response(
                    &output,
                    &prefix,
                    "",
                    None,
                    ResponseEvidence {
                        kind: "application/json",
                        elapsed: started.elapsed().as_secs_f64() * 1000.0,
                        status: 502,
                        transport_error: Some("context_upstream_unavailable"),
                    },
                )?;
            }
            let _ = http_header(&mut stream, 502, "text/plain").await;
            return Ok(());
        }
    };
    let status = response.status().as_u16();
    let kind = response
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.chars().any(char::is_control))
        .unwrap_or("application/json")
        .to_owned();
    let mut bytes = vec![];
    let mut failure = None;
    let mut cancelled = http_header(&mut stream, status, &kind).await.is_err();
    if !cancelled {
        let mut unexpected = [0u8; 1];
        loop {
            let next = tokio::select! {
                _ = stream.read(&mut unexpected) => {cancelled = true; break;},
                next = response.chunk() => next,
            };
            match next {
                Ok(Some(chunk)) => {
                    if bytes.len() + chunk.len() > RESPONSE_LIMIT {
                        failure = Some("context_response_exceeds_eight_mib");
                        break;
                    }
                    bytes.extend_from_slice(&chunk);
                    if stream.write_all(&chunk).await.is_err() {
                        cancelled = true;
                        break;
                    }
                }
                Ok(None) => break,
                Err(_) => {
                    failure = Some("context_stream_transport_failed");
                    break;
                }
            }
        }
    }
    drop(response);
    if let Some(prefix) = prefix {
        let text = std::str::from_utf8(&bytes);
        if let Ok(text) = text {
            save_response(
                &output,
                &prefix,
                text,
                None,
                ResponseEvidence {
                    kind: &kind,
                    elapsed: started.elapsed().as_secs_f64() * 1000.0,
                    status,
                    transport_error: if cancelled { None } else { failure },
                },
            )?;
        } else {
            exclusive(
                &output.join(format!(
                    "{prefix}.response.{}",
                    if kind.contains("event-stream") {
                        "sse"
                    } else {
                        "json"
                    }
                )),
                &bytes,
            )?;
            exclusive(&output.join(format!("{prefix}.summary.json")),json!({"error":"context_response_invalid_utf8","status":status,"elapsedMs":started.elapsed().as_secs_f64()*1000.0}).to_string().as_bytes())?;
        }
    }
    let _ = stream.shutdown().await;
    Ok(())
}
/// Fixed loopback upstream and a bounded capture listener; no credentials or
/// response headers are stored. Tool outputs remain inert diagnostic data.
pub async fn context_capture(output: &Path, port: u16) -> Result<()> {
    ensure(
        port >= 1024 && port != 1234,
        "context_capture_requires_nonprivileged_nonupstream_port",
    )?;
    let output = std::sync::Arc::new(private_output(output)?);
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .await
        .map_err(|_| BenchmarkError("context_capture_bind_failed"))?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|_| BenchmarkError("context_client_failed"))?;
    let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(32));
    let mut tasks = tokio::task::JoinSet::new();
    println!(
        "{}",
        json!({"ready":true,"host":"127.0.0.1","port":listener.local_addr().map_err(|_|BenchmarkError("context_capture_address_failed"))?.port()})
    );
    loop {
        tokio::select! {_=tokio::signal::ctrl_c()=>break,Some(_)=tasks.join_next(),if !tasks.is_empty()=>{},accepted=listener.accept()=>{let(stream,peer)=accepted.map_err(|_|BenchmarkError("context_capture_accept_failed"))?;if !peer.ip().is_loopback(){continue;}let Ok(permit)=permits.clone().try_acquire_owned()else{continue;};let output=output.clone();let count=count.clone();let client=client.clone();tasks.spawn(async move{let _permit=permit;capture_connection(stream,output,count,client,"http://127.0.0.1:1234".into()).await});}}
    }
    // Capture tasks have exact 120-second transport deadlines and finish their
    // private receipt artifacts before process exit. No new request is accepted.
    while tasks.join_next().await.is_some() {}
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> String {
        format!("{}\n",serde_json::to_string_pretty(&json!({"model":"synthetic","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"policy"}]},{"type":"message","role":"user","content":[{"type":"input_text","text":"current"}]}],"tools":[{"type":"function","name":"status","parameters":{"type":"object"}}],"stream":true})).unwrap())
    }
    fn completed() -> Value {
        json!({"id":"response_test","status":"completed","error":null,"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"retained ✓"}]},{"type":"function_call","name":"not_executed","arguments":"{}","call_id":"unused"}],"usage":{"input_tokens":50,"output_tokens":3,"input_tokens_details":{"cached_tokens":40}}})
    }
    #[test]
    fn unchanged_replay_preserves_source_bytes_and_explicit_edits_preserve_settings() {
        let raw = request();
        let original = prepare_context_replay(&raw, None, None).unwrap();
        assert_eq!(original.raw, raw);
        assert!(!original.changed_sampler);
        let assistant=json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"ACTUAL_ACK"}]}).to_string();
        let edited = prepare_context_replay(&raw, Some(0.0), Some(&assistant)).unwrap();
        let value = parse(edited.raw.as_bytes()).unwrap();
        assert_eq!(value["input"][1]["role"], "assistant");
        assert_eq!(value["input"][2]["content"][0]["text"], "current");
        assert_eq!(value["temperature"], 0.0);
        assert_eq!(value["tools"], parse(raw.as_bytes()).unwrap()["tools"]);
        assert!(edited.changed_sampler && edited.inserted_assistant_history);
    }
    #[test]
    fn replay_rejects_role_escalation_hosted_tools_and_chaining() {
        let raw = request();
        for assistant in [
            json!({"type":"message","role":"system","content":[]}),
            json!({"type":"reasoning","role":"assistant","content":[]}),
            json!({"type":"message","role":"assistant","content":[{"type":"function_call","name":"delete"}]}),
        ] {
            assert!(prepare_context_replay(&raw, None, Some(&assistant.to_string())).is_err());
        }
        let mut body = parse(raw.as_bytes()).unwrap();
        body["previous_response_id"] = json!("chained");
        assert!(context_request(&body.to_string()).is_err());
        assert!(prepare_context_replay(&raw, Some(1.0), None).is_err());
    }
    #[test]
    fn context_summary_uses_terminal_once_without_executing_or_counting_deltas() {
        let completion = completed();
        let sse = format!(
            "data: {{\"type\":\"response.output_text.delta\",\"delta\":\"ignored\"}}\r\n\r\ndata: {}\r\n\r\ndata: [DONE]\r\n\r\n",
            json!({"type":"response.completed","response":completion})
        );
        let result = summarize_context_response(&sse, "text/event-stream", 123.0, 200).unwrap();
        assert_eq!(result["finalText"], "retained ✓");
        assert_eq!(result["toolCallNames"], json!(["not_executed"]));
        assert_eq!(result["cachedTokens"], 40);
        assert!(
            summarize_context_response(&(sse.clone() + &sse), "text/event-stream", 1.0, 200)
                .is_err()
        );
        assert!(
            summarize_context_response(&completion.to_string(), "application/json", 1.0, 500)
                .is_err()
        );
    }
    #[tokio::test]
    async fn mock_capture_preserves_bytes_and_distinguishes_cancel_after_terminal() {
        use tokio::io::AsyncWriteExt;
        for complete in [false, true] {
            let output = tempfile::tempdir().unwrap();
            let raw = request();
            let sent = if complete {
                format!(
                    "data: {}\n\n",
                    json!({"type":"response.completed","response":completed()})
                )
            } else {
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n".into()
            };
            let upstream = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
                .await
                .unwrap();
            let upstream_url = format!("http://{}", upstream.local_addr().unwrap());
            let expected = raw.clone();
            let upstream_sent = sent.clone();
            let upstream_task = tokio::spawn(async move {
                let (mut socket, _) = upstream.accept().await.unwrap();
                let request = incoming(&mut socket).await.unwrap();
                assert_eq!(request.body, expected.as_bytes());
                assert_eq!(
                    request.authorization.as_deref(),
                    Some("Bearer SYNTHETIC_TEST_SECRET")
                );
                socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nSet-Cookie: SYNTHETIC_COOKIE\r\nConnection: close\r\n\r\n{upstream_sent}").as_bytes()).await.unwrap();
                std::future::pending::<()>().await;
            });
            let proxy = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
                .await
                .unwrap();
            let proxy_url = format!("http://{}/v1/responses", proxy.local_addr().unwrap());
            let directory = std::sync::Arc::new(output.path().to_path_buf());
            let proxy_task = tokio::spawn(async move {
                let (socket, _) = proxy.accept().await.unwrap();
                capture_connection(
                    socket,
                    directory,
                    std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0)),
                    reqwest::Client::new(),
                    upstream_url,
                )
                .await
                .unwrap();
            });
            let mut response = reqwest::Client::new()
                .post(proxy_url)
                .header("authorization", "Bearer SYNTHETIC_TEST_SECRET")
                .body(raw.clone())
                .send()
                .await
                .unwrap();
            let mut received = vec![];
            while received.len() < sent.len() {
                received.extend_from_slice(&response.chunk().await.unwrap().unwrap());
            }
            assert_eq!(received, sent.as_bytes());
            drop(response);
            tokio::time::timeout(Duration::from_secs(3), proxy_task)
                .await
                .unwrap()
                .unwrap();
            upstream_task.abort();
            let files = std::fs::read_dir(output.path())
                .unwrap()
                .map(|item| item.unwrap().path())
                .collect::<Vec<_>>();
            assert_eq!(files.len(), 3);
            let summary_path = files
                .iter()
                .find(|path| path.to_string_lossy().ends_with("summary.json"))
                .unwrap();
            let summary = parse(&std::fs::read(summary_path).unwrap()).unwrap();
            assert_eq!(summary.get("error").is_none(), complete);
            if complete {
                assert_eq!(summary["finalText"], "retained ✓");
            }
            let captured = files
                .iter()
                .find(|path| path.to_string_lossy().ends_with("response.sse"))
                .unwrap();
            assert_eq!(std::fs::read(captured).unwrap(), sent.as_bytes());
            for path in files {
                let text = std::fs::read_to_string(path).unwrap();
                assert!(!text.contains("SYNTHETIC_TEST_SECRET"));
                assert!(!text.contains("SYNTHETIC_COOKIE"));
            }
        }
    }
}
