//! Bounded Responses SSE and explicit observation provenance for headless probes.
use super::*;
use serde_json::json;
#[derive(Default)]
pub struct SseDecoder {
    pending: String,
}
impl SseDecoder {
    pub fn push(&mut self, text: &str) -> Result<Vec<Value>> {
        self.pending.push_str(text);
        self.pending = self.pending.replace("\r\n", "\n");
        ensure(
            utf16_len(&self.pending) <= 2 * 1024 * 1024,
            "sse_frame_exceeds_bound",
        )?;
        let mut events = vec![];
        while let Some(end) = self.pending.find("\n\n") {
            let frame = self.pending[..end].to_owned();
            self.pending.drain(..end + 2);
            let data = frame
                .lines()
                .filter_map(|line| line.strip_prefix("data:"))
                .map(str::trim_start)
                .collect::<Vec<_>>()
                .join("\n");
            if data.is_empty() || data == "[DONE]" {
                continue;
            }
            let mut value = parse(data.as_bytes())?;
            ensure(value.is_object(), "invalid_sse_json")?;
            if !value["type"].is_string() {
                ensure(!value["error"].is_null(), "sse_json_missing_event_type")?;
                value = json!({"type":"provider.error","error":value["error"]});
            }
            events.push(value);
        }
        Ok(events)
    }
    pub fn finish(&self) -> Result<()> {
        ensure(self.pending.trim().is_empty(), "truncated_sse_frame")
    }
}
pub fn stream_completed<'a>(events: &'a [Value], model: &str) -> Result<&'a Value> {
    ensure(
        !events.iter().any(|event| {
            event["type"]
                .as_str()
                .is_some_and(|kind| ["error", "provider.error", "response.failed"].contains(&kind))
        }),
        "provider_stream_error",
    )?;
    let endings = events
        .iter()
        .filter(|event| event["type"] == "response.completed")
        .collect::<Vec<_>>();
    ensure(endings.len() == 1, "expected_exactly_one_completed_event")?;
    let response = &endings[0]["response"];
    ensure(
        response["status"] == "completed"
            && response["error"].is_null()
            && response["incomplete_details"].is_null()
            && response["model"] == model
            && response["output"].is_array(),
        "invalid_completed_response",
    )?;
    let usage = &response["usage"];
    let input = usage["input_tokens"]
        .as_u64()
        .filter(|count| *count > 0)
        .ok_or(BenchmarkError("invalid_token_usage"))?;
    let output = usage["output_tokens"]
        .as_u64()
        .filter(|count| *count > 0)
        .ok_or(BenchmarkError("invalid_token_usage"))?;
    ensure(
        input.checked_add(output) == usage["total_tokens"].as_u64(),
        "invalid_token_usage",
    )?;
    let created = events
        .iter()
        .filter(|event| event["type"] == "response.created")
        .collect::<Vec<_>>();
    ensure(
        created.len() == 1 && created[0]["response"]["id"] == response["id"],
        "response_identity_mismatch",
    )?;
    Ok(response)
}
pub fn final_text(response: &Value) -> String {
    response["output"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "message" && item["role"] == "assistant")
        .flat_map(|item| item["content"].as_array().into_iter().flatten())
        .filter(|part| part["type"] == "output_text")
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .concat()
}
pub fn consistent_text(events: &[Value], response: &Value) -> Result<String> {
    let deltas = events
        .iter()
        .filter(|event| event["type"] == "response.output_text.delta")
        .map(|event| {
            event["delta"]
                .as_str()
                .ok_or(BenchmarkError("invalid_public_text_delta"))
        })
        .collect::<Result<Vec<_>>>()?
        .concat();
    ensure(
        deltas == final_text(response),
        "output_deltas_final_text_differ",
    )?;
    Ok(deltas)
}
pub fn exact_text(events: &[Value], response: &Value, expected: &str) -> Result<()> {
    ensure(
        consistent_text(events, response)?.trim() == expected,
        "output_text_differs_from_exact_oracle",
    )?;
    ensure(
        !response["output"]
            .as_array()
            .is_some_and(|output| output.iter().any(|item| item["type"] == "function_call")),
        "unexpected_function_call",
    )
}
pub fn stream_function_call<'a>(
    events: &[Value],
    response: &'a Value,
    name: &str,
    arguments: &str,
) -> Result<&'a Value> {
    let calls = response["output"]
        .as_array()
        .ok_or(BenchmarkError("invalid_response_output"))?
        .iter()
        .filter(|item| item["type"] == "function_call")
        .collect::<Vec<_>>();
    ensure(calls.len() == 1, "expected_one_function_call")?;
    let call = calls[0];
    let args = call["arguments"]
        .as_str()
        .ok_or(BenchmarkError("invalid_function_arguments"))?;
    ensure(
        call["name"] == name
            && call["call_id"].as_str().is_some_and(|id| !id.is_empty())
            && call["id"].as_str().is_some_and(|id| !id.is_empty())
            && parse(args.as_bytes())? == parse(arguments.as_bytes())?,
        "function_identity_arguments_mismatch",
    )?;
    let matching = |kind: &str| {
        events
            .iter()
            .enumerate()
            .filter(|(_, event)| {
                event["type"] == kind
                    && (event["item"]["id"] == call["id"] || event["item_id"] == call["id"])
            })
            .collect::<Vec<_>>()
    };
    let added = matching("response.output_item.added");
    let args_events = matching("response.function_call_arguments.done");
    let done = matching("response.output_item.done");
    ensure(
        added.len() == 1 && args_events.len() == 1 && done.len() == 1,
        "function_lifecycle_identity_mismatch",
    )?;
    let done_args = args_events[0]
        .1
        .get("arguments")
        .unwrap_or(&args_events[0].1["item"]["arguments"]);
    ensure(
        added[0].0 < args_events[0].0
            && args_events[0].0 < done[0].0
            && done[0].1["item"]["call_id"] == call["call_id"]
            && done[0].1["item"]["arguments"] == call["arguments"]
            && done_args == &call["arguments"],
        "function_lifecycle_call_id_mismatch",
    )?;
    Ok(call)
}
#[derive(Clone, Debug)]
pub enum ObservationMode {
    UpstreamMetrics,
    OwnedBoundary { instance: String },
    RustBoundary { instance: String },
}
impl ObservationMode {
    pub fn parse(value: &str) -> Result<Self> {
        if value == "metrics" {
            return Ok(Self::UpstreamMetrics);
        }
        if let Some(instance) = value.strip_prefix("guarded:")
            && instance.len() == 36
            && instance == instance.to_lowercase()
            && uuid::Uuid::parse_str(instance).is_ok()
        {
            return Ok(Self::OwnedBoundary {
                instance: instance.into(),
            });
        }
        if let Some(instance) = value.strip_prefix("rust:")
            && instance.len() == 36
            && instance == instance.to_lowercase()
            && uuid::Uuid::parse_str(instance).is_ok()
        {
            return Ok(Self::RustBoundary {
                instance: instance.into(),
            });
        }
        Err(BenchmarkError("observation_requires_exact_owned_instance"))
    }
    pub fn path(&self) -> &'static str {
        match self {
            Self::UpstreamMetrics => "/v1/metrics",
            Self::OwnedBoundary { .. } | Self::RustBoundary { .. } => "/health",
        }
    }
    pub fn inspect(&self, value: &Value, model: &str) -> Result<Value> {
        let count = |value: &Value| {
            value
                .as_u64()
                .is_some_and(|value| value <= 9_007_199_254_740_991)
        };
        match self {
            Self::OwnedBoundary { instance } | Self::RustBoundary { instance } => {
                let rust = matches!(self, Self::RustBoundary { .. });
                ensure(
                    value["status"] == "healthy"
                        && value["backend"] == if rust { "computa-rust-mlx" } else { "mlx-vlm" }
                        && value["version"] == if rust { "mlex-0.1.3" } else { "0.7.1" }
                        && value["heydash_instance"] == *instance
                        && value["busy"].is_boolean()
                        && value["context_limit"] == 16384
                        && ["active_bytes", "cache_bytes", "peak_bytes"]
                            .iter()
                            .all(|key| count(&value["memory"][*key])),
                    "guarded_health_identity_schema_mismatch",
                )?;
                Ok(
                    json!({"source":if rust { "owned_rust_boundary" } else { "owned_boundary" },"idle":value["busy"]==false,"instance":instance,"boundaryBusy":value["busy"],"workerInFlight":null,"workerQueueDepth":null,"loadedModel":null,"memory":value["memory"],"raw":value}),
                )
            }
            Self::UpstreamMetrics => {
                ensure(
                    count(&value["summary"]["in_flight"])
                        && count(&value["server"]["request_queue_depth"]),
                    "upstream_metrics_schema_mismatch",
                )?;
                Ok(
                    json!({"source":"upstream_metrics","idle":value["summary"]["in_flight"]==0&&value["server"]["request_queue_depth"]==0&&value["server"]["loaded_model"]==model,"instance":null,"boundaryBusy":null,"workerInFlight":value["summary"]["in_flight"],"workerQueueDepth":value["server"]["request_queue_depth"],"loadedModel":value["server"]["loaded_model"],"memory":null,"raw":value}),
                )
            }
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CancelAt {
    None,
    FirstPublicText,
    ResponseCreated,
    DelayedAfterCreated,
}
pub const DELAYED_CANCELLATION_MS: u64 = 250;
pub fn cancellation_reached(events: &[Value], mode: CancelAt) -> bool {
    match mode {
        CancelAt::ResponseCreated => events
            .iter()
            .any(|event| event["type"] == "response.created"),
        CancelAt::FirstPublicText => events.iter().any(|event| {
            event["type"] == "response.output_text.delta"
                && event["delta"].as_str().is_some_and(|text| !text.is_empty())
        }),
        _ => false,
    }
}
pub fn delayed_cancellation_reached(events: &[Value], mode: CancelAt) -> bool {
    mode == CancelAt::DelayedAfterCreated
        && events
            .iter()
            .any(|event| event["type"] == "response.created")
}
pub fn assert_early_cancellation(events: &[Value], cancelled: bool) -> Result<()> {
    let created = events
        .iter()
        .filter(|event| event["type"] == "response.created")
        .collect::<Vec<_>>();
    ensure(
        cancelled
            && created.len() == 1
            && created[0]["response"]["id"]
                .as_str()
                .is_some_and(|id| !id.is_empty()),
        "early_cancellation_missing_response_start",
    )?;
    ensure(
        !events.iter().any(|event| {
            event["type"] == "response.output_text.delta"
                && event["delta"].as_str().is_some_and(|text| !text.is_empty())
        }),
        "public_text_arrived_before_early_disconnect",
    )?;
    ensure(
        !events.iter().any(|event| {
            event["type"].as_str().is_some_and(|kind| {
                [
                    "response.completed",
                    "response.failed",
                    "response.incomplete",
                ]
                .contains(&kind)
            })
        }),
        "response_ended_before_early_disconnect",
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_handles_split_crlf_and_rejects_partial_tail() {
        let mut decoder = SseDecoder::default();
        assert!(
            decoder
                .push("data: {\"type\":\"response.created\"}\r")
                .unwrap()
                .is_empty()
        );
        assert_eq!(decoder.push("\n\r\n").unwrap().len(), 1);
        decoder.finish().unwrap();
        decoder.push("data: {}").unwrap();
        assert!(decoder.finish().is_err());
    }
    #[test]
    fn unknown_error_events_and_duplicate_completion_fail_closed() {
        let mut decoder = SseDecoder::default();
        let events = decoder
            .push("data: {\"error\":{\"message\":\"PRIVATE\"}}\n\n")
            .unwrap();
        assert_eq!(events[0]["type"], "provider.error");
        assert!(stream_completed(&events, MODEL).is_err());
        let events = vec![
            json!({"type":"response.completed"}),
            json!({"type":"response.completed"}),
        ];
        assert!(stream_completed(&events, MODEL).is_err());
    }
    #[test]
    fn guarded_boundary_metrics_never_invent_gpu_worker_values() {
        let instance = "11111111-1111-4111-8111-111111111111";
        let mode = ObservationMode::parse(&format!("guarded:{instance}")).unwrap();
        let value = json!({"status":"healthy","backend":"mlx-vlm","version":"0.7.1","heydash_instance":instance,"busy":false,"context_limit":16384,"memory":{"active_bytes":1,"cache_bytes":0,"peak_bytes":2}});
        let observation = mode.inspect(&value, MODEL).unwrap();
        assert_eq!(observation["idle"], true);
        assert!(observation["workerInFlight"].is_null());
        let mut wrong = value;
        wrong["heydash_instance"] = json!("another");
        assert!(mode.inspect(&wrong, MODEL).is_err());
    }
    #[test]
    fn rust_worker_health_requires_an_explicit_distinct_owned_mode() {
        let instance = "11111111-1111-4111-8111-111111111111";
        let rust = ObservationMode::parse(&format!("rust:{instance}")).unwrap();
        let legacy = ObservationMode::parse(&format!("guarded:{instance}")).unwrap();
        let value = json!({"status":"healthy","backend":"computa-rust-mlx","version":"mlex-0.1.3","heydash_instance":instance,"busy":false,"context_limit":16384,"memory":{"active_bytes":0,"cache_bytes":0,"peak_bytes":0}});
        assert_eq!(
            rust.inspect(&value, MODEL).unwrap()["source"],
            "owned_rust_boundary"
        );
        assert!(legacy.inspect(&value, MODEL).is_err());
        let mut wrong = value;
        wrong["version"] = json!("unqualified");
        assert!(rust.inspect(&wrong, MODEL).is_err());
    }
    #[test]
    fn early_disconnect_gate_rejects_text_from_the_same_created_chunk() {
        let events = vec![
            json!({"type":"response.created","response":{"id":"owned"}}),
            json!({"type":"response.output_text.delta","delta":"x"}),
        ];
        assert!(cancellation_reached(&events, CancelAt::ResponseCreated));
        assert!(assert_early_cancellation(&events, true).is_err());
        assert!(assert_early_cancellation(&events[..1], true).is_ok());
    }
}
