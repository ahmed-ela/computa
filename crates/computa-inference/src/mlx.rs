//! MLX lives on one owned worker thread. No Python loader, networking, remote
//! model code, shared KV/prefix cache, or request-controlled model path exists.
pub use crate::generation::{InferenceError, Memory, Reply, Usage};
use crate::{
    live::{Delta, LiveOutput},
    output::{self, OfferedTool, ToolCall},
    request::{self, Request},
};
use computa_contracts::models::LocalModel;
use mlex::{
    generate::{GenerateOptions, Session},
    prompt_cache::PromptCacheConfig,
    sampling::SamplingConfig,
    tokenizer::{ChatMessage, ContentPart, ImageContent},
    tools::{Tool, ToolCall as HistoricalCall},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    time::Duration,
};
pub struct OwnedModel {
    models: HashMap<LocalModel, PathBuf>,
    selected: Option<LocalModel>,
    session: Option<Session>,
}
impl OwnedModel {
    pub fn new(models: HashMap<LocalModel, PathBuf>) -> Result<Self, InferenceError> {
        memory_limits()?;
        Ok(Self {
            models,
            selected: None,
            session: None,
        })
    }
    pub fn selected(&self) -> Option<LocalModel> {
        self.selected
    }
    pub fn generate(
        &mut self,
        request: Request,
        mut alive: impl FnMut() -> bool,
    ) -> Result<Reply, InferenceError> {
        let reply = self.generate_stream(request, &mut alive, |_| true);
        release_request_memory()?;
        reply
    }
    pub fn generate_stream(
        &mut self,
        request: Request,
        mut alive: impl FnMut() -> bool,
        mut emit: impl FnMut(Delta) -> bool,
    ) -> Result<Reply, InferenceError> {
        if self.selected.is_some_and(|s| s != request.model) {
            return Err(InferenceError::RestartRequired);
        }
        let tools = output::offered_tools(&request.raw)?;
        let messages = messages(&request.raw, &tools)?;
        let schemas: Vec<_> = tools
            .iter()
            .map(|(full, t)| {
                Tool::new(
                    full,
                    t.schema["description"].as_str().unwrap_or(""),
                    t.schema["parameters"].clone(),
                )
            })
            .collect();
        if !alive() {
            return Err(InferenceError::Cancelled);
        }
        if self.session.is_none() {
            // Keep the pin even if allocation/loading fails: no different model
            // may acquire this worker's resident allocation after a failed load.
            self.selected = Some(request.model);
            let path = self
                .models
                .get(&request.model)
                .ok_or(InferenceError::Unavailable)?;
            self.session = Some(
                Session::load_with_cache_config(
                    path,
                    PromptCacheConfig {
                        max_entries: 0,
                        ttl: Duration::ZERO,
                        min_cacheable_tokens: usize::MAX,
                    },
                )
                .map_err(|_| InferenceError::Unavailable)?,
            );
        }
        let session = self.session.as_ref().ok_or(InferenceError::Unavailable)?;
        let schemas = (!schemas.is_empty()).then_some(schemas.as_slice());
        let (encoded, media) = session
            .encode_chat_with_media_full(&messages, schemas, Some(true))
            .map_err(|_| InferenceError::Input)?;
        let prompt = session
            .tokenizer()
            .apply_chat_template_full(&messages, true, schemas, Some(true))
            .map_err(|_| InferenceError::Input)?;
        let mut live = LiveOutput::new(prompt.trim_end().ends_with("<think>"));
        if let Some(budget) = request::context_budget(encoded.len(), request.max_output_tokens) {
            return Err(InferenceError::Context(budget));
        }
        if !alive() {
            return Err(InferenceError::Cancelled);
        }
        let temperature = request
            .raw
            .get("temperature")
            .map(|v| {
                v.as_f64()
                    .filter(|v| v.is_finite() && (0.0..=2.0).contains(v))
                    .ok_or(InferenceError::Input)
            })
            .transpose()?
            .unwrap_or(0.0) as f32;
        // Prepare media once and keep one request-local KV allocation. The
        // upstream convenience loop skips the last sampled token when forcing
        // a reasoning close; this explicit continuation feeds that token before
        // the close marker, preserving the actual causal prefix and allowance.
        let options = GenerateOptions {
            max_tokens: request.max_output_tokens,
            sampling: SamplingConfig {
                temperature,
                top_p: 1.0,
                top_k: None,
                seed: Some(0),
            },
            enable_thinking: Some(true),
            reasoning_budget_tokens: None,
            prompt_cache: Some(false),
        };
        let mut capture = Capture::default();
        let mut caches = session.debug_new_caches();
        let generated = session
            .generate_with_media(&encoded, &media, &mut caches, options, |token| {
                capture.observe(
                    session,
                    token,
                    &mut live,
                    &mut alive,
                    &mut emit,
                    CaptureLimits {
                        output: request.max_output_tokens,
                        thinking: Some(request.thinking_budget),
                    },
                )
            })
            .map_err(|_| InferenceError::Generation)?;
        if !capture.cancelled && generated != capture.ids {
            return Err(InferenceError::Generation);
        }
        if capture.force_close && !capture.cancelled && capture.fault.is_none() {
            let close = session
                .tokenizer()
                .encode(crate::live::FORCED_REASONING_CLOSE)
                .map_err(|_| InferenceError::Generation)?;
            if close.is_empty() || capture.ids.len() + close.len() >= request.max_output_tokens {
                return Err(InferenceError::Length(capture.usage(encoded.len())));
            }
            if session
                .tokenizer()
                .decode_raw(&close)
                .map_err(|_| InferenceError::Generation)?
                != crate::live::FORCED_REASONING_CLOSE
            {
                return Err(InferenceError::Generation);
            }
            let last = *capture.ids.last().ok_or(InferenceError::Generation)?;
            let mut suffix = vec![last];
            suffix.extend_from_slice(&close);
            if !alive() {
                capture.cancelled = true;
            } else {
                // These IDs are fed to the same KV prefix and counted, but
                // their host-authored separators are never visible model text.
                capture.ids.extend_from_slice(&close);
                capture.clean_stop = false;
                match live.force_reasoning_close() {
                    Ok(deltas) => {
                        for delta in deltas {
                            if !emit(delta) {
                                capture.cancelled = true;
                                break;
                            }
                        }
                    }
                    Err(error) => capture.fault = Some(error),
                }
            }
            if !capture.cancelled && capture.fault.is_none() {
                let offset = capture.ids.len();
                let mut continuation = options;
                continuation.max_tokens = request.max_output_tokens - offset;
                let generated = session
                    .generate_with_media(
                        &suffix,
                        &mlex::generate::MediaInputs::default(),
                        &mut caches,
                        continuation,
                        |token| {
                            capture.observe(
                                session,
                                token,
                                &mut live,
                                &mut alive,
                                &mut emit,
                                CaptureLimits {
                                    output: request.max_output_tokens,
                                    thinking: None,
                                },
                            )
                        },
                    )
                    .map_err(|_| InferenceError::Generation)?;
                if !capture.cancelled && generated != capture.ids[offset..] {
                    return Err(InferenceError::Generation);
                }
            }
        }
        let synchronized = mlex::array::synchronize();
        if capture.cancelled || !alive() {
            return Err(InferenceError::Cancelled);
        }
        synchronized.map_err(|_| InferenceError::Generation)?;
        if let Some(error) = capture.fault {
            return Err(InferenceError::Output(error));
        }
        if capture.exceeded || !capture.clean_stop {
            return Err(InferenceError::Length(capture.usage(encoded.len())));
        }
        let output_tokens = capture.ids.len();
        let eos = session.tokenizer().eos_token_ids();
        let content: Vec<_> = capture
            .ids
            .into_iter()
            .filter(|id| !eos.contains(id))
            .collect();
        let raw = session
            .tokenizer()
            .decode_raw(&content)
            .map_err(|_| InferenceError::Generation)?;
        if raw != live.raw() {
            return Err(InferenceError::Generation);
        }
        let (finalized, tail) = live.finish(&tools, true)?;
        for delta in tail {
            if !emit(delta) {
                return Err(InferenceError::Cancelled);
            }
        }
        let calls = finalized.calls;
        enforce_choices(&request.raw, &calls)?;
        let text = finalized.text;
        if calls.is_empty() && text.is_empty() {
            return Err(InferenceError::Generation);
        }
        let usage = Usage {
            input_tokens: encoded.len(),
            output_tokens,
            total_tokens: encoded.len() + output_tokens,
        };
        Ok(Reply {
            text,
            reasoning: finalized.reasoning,
            calls,
            usage,
        })
    }
}
#[derive(Default)]
struct Capture {
    ids: Vec<u32>,
    clean_stop: bool,
    cancelled: bool,
    exceeded: bool,
    fault: Option<output::OutputError>,
    thinking_tokens: usize,
    force_close: bool,
}
#[derive(Clone, Copy)]
struct CaptureLimits {
    output: usize,
    thinking: Option<usize>,
}
impl Capture {
    fn usage(&self, input_tokens: usize) -> Usage {
        Usage {
            input_tokens,
            output_tokens: self.ids.len(),
            total_tokens: input_tokens + self.ids.len(),
        }
    }
    fn observe(
        &mut self,
        session: &Session,
        token: mlex::generate::GeneratedToken,
        live: &mut LiveOutput,
        alive: &mut impl FnMut() -> bool,
        emit: &mut impl FnMut(Delta) -> bool,
        limits: CaptureLimits,
    ) -> bool {
        if !alive() {
            self.cancelled = true;
            return false;
        }
        if self.ids.len() >= limits.output {
            self.exceeded = true;
            return false;
        }
        self.ids.push(token.id);
        self.clean_stop = token.finished;
        if token.finished {
            return true;
        }
        let was_reasoning = live.reasoning_open();
        let piece = match session.tokenizer().decode_piece_raw(token.id) {
            Ok(piece) => piece,
            Err(_) => {
                self.fault = Some(output::OutputError::Malformed);
                return false;
            }
        };
        let deltas = match live.feed(&piece) {
            Ok(deltas) => deltas,
            Err(error) => {
                self.fault = Some(error);
                return false;
            }
        };
        for delta in deltas {
            if !emit(delta) {
                self.cancelled = true;
                return false;
            }
        }
        if was_reasoning || live.reasoning_open() {
            self.thinking_tokens += 1;
        }
        if limits
            .thinking
            .is_some_and(|budget| live.reasoning_open() && self.thinking_tokens >= budget)
        {
            self.force_close = true;
            return false;
        }
        true
    }
}
fn enforce_choices(raw: &Value, calls: &[ToolCall]) -> Result<(), InferenceError> {
    if raw.get("parallel_tool_calls") == Some(&Value::Bool(false)) && calls.len() > 1 {
        return Err(InferenceError::Output(output::OutputError::Malformed));
    }
    match raw.get("tool_choice") {
        Some(Value::String(choice)) if choice == "none" && !calls.is_empty() => {
            Err(output::OutputError::Unoffered.into())
        }
        Some(Value::String(choice)) if choice == "required" && calls.is_empty() => {
            Err(output::OutputError::Malformed.into())
        }
        Some(Value::Object(choice)) => {
            let expected = choice
                .get("name")
                .and_then(Value::as_str)
                .ok_or(InferenceError::Input)?;
            if calls.is_empty() || calls.iter().any(|c| c.name != expected) {
                Err(output::OutputError::Unoffered.into())
            } else {
                Ok(())
            }
        }
        _ => Ok(()),
    }
}
fn messages(
    raw: &Value,
    tools: &BTreeMap<String, OfferedTool>,
) -> Result<Vec<ChatMessage>, InferenceError> {
    let mut result = Vec::new();
    let mut instructions = Vec::new();
    if let Some(text) = raw.get("instructions").filter(|v| !v.is_null()) {
        instructions.push(text.as_str().ok_or(InferenceError::Input)?.to_owned());
    }
    if let Some(input) = raw["input"].as_str() {
        if !instructions.is_empty() {
            result.push(ChatMessage::system(instructions.join("\n\n")));
        }
        result.push(ChatMessage::user(input));
        return Ok(result);
    }
    for item in raw["input"].as_array().ok_or(InferenceError::Input)? {
        match item["type"].as_str() {
            Some("function_call") => {
                let name = item["name"].as_str().ok_or(InferenceError::Input)?;
                let full = item["namespace"]
                    .as_str()
                    .map_or_else(|| name.into(), |ns| format!("{ns}.{name}"));
                let args = if let Some(text) = item["arguments"].as_str() {
                    computa_contracts::strict_json::parse(text.as_bytes())
                        .map_err(|_| InferenceError::Input)?
                } else {
                    item["arguments"].clone()
                };
                if !args.is_object() {
                    return Err(InferenceError::Input);
                }
                let call = HistoricalCall {
                    id: item["call_id"]
                        .as_str()
                        .ok_or(InferenceError::Input)?
                        .into(),
                    name: full,
                    arguments: args,
                };
                result.push(ChatMessage::assistant_with_tool_calls("", vec![call]));
            }
            Some("function_call_output") => {
                let mut message = ChatMessage::tool_result(
                    item["call_id"].as_str().ok_or(InferenceError::Input)?,
                    "",
                );
                message.content = content(&item["output"])?;
                result.push(message);
            }
            Some("reasoning") => {
                let summary = item
                    .get("summary")
                    .and_then(Value::as_array)
                    .ok_or(InferenceError::Input)?
                    .iter()
                    .map(|part| part["text"].as_str().ok_or(InferenceError::Input))
                    .collect::<Result<Vec<_>, _>>()?
                    .join("\n");
                if !summary.is_empty() {
                    result.push(ChatMessage::assistant_with_reasoning("", summary));
                }
            }
            None | Some("message") => {
                let role = item["role"]
                    .as_str()
                    .filter(|r| matches!(*r, "user" | "assistant" | "system" | "developer"))
                    .ok_or(InferenceError::Input)?;
                let parts = content(&item["content"])?;
                if matches!(role, "system" | "developer") {
                    // Qwen's pinned template has one leading system turn and
                    // no developer role. Keep every instruction in request
                    // order; no instructions become lower-priority user text.
                    let text = parts
                        .into_iter()
                        .map(|part| match part {
                            ContentPart::Text(text) => Ok(text),
                            _ => Err(InferenceError::Input),
                        })
                        .collect::<Result<Vec<_>, _>>()?
                        .join("\n");
                    instructions.push(text);
                } else {
                    result.push(ChatMessage {
                        role: role.into(),
                        content: parts,
                        ..Default::default()
                    });
                }
            }
            _ => return Err(InferenceError::Input),
        }
    }
    if !instructions.is_empty() {
        result.insert(0, ChatMessage::system(instructions.join("\n\n")));
    }
    // Looking up current schemas cannot mutate the full historical transcript.
    let _ = tools;
    Ok(result)
}

#[cfg(test)]
mod message_tests {
    use super::*;
    #[test]
    fn upstream_instructions_and_developer_history_fit_one_leading_system_turn() {
        let raw = json!({"instructions":"Base café 🌳","input":[
            {"type":"message","role":"system","content":"System policy"},
            {"role":"user","content":[{"type":"input_text","text":"Question"}]},
            {"type":"message","role":"developer","content":[{"type":"input_text","text":"Developer first"},{"type":"input_text","text":"Developer second"}]},
            {"type":"function_call","name":"read","namespace":"computer","call_id":"call-1","arguments":"{}"},
            {"type":"function_call_output","call_id":"call-1","output":"Observed content"},
            {"role":"assistant","content":"Answer"},
            {"role":"system","content":"Later policy"}
        ]});
        let messages = messages(&raw, &BTreeMap::new()).unwrap();
        assert_eq!(
            messages.iter().map(|m| m.role.as_str()).collect::<Vec<_>>(),
            ["system", "user", "assistant", "tool", "assistant"]
        );
        assert_eq!(
            messages[0].text(),
            "Base café 🌳\n\nSystem policy\n\nDeveloper first\n\nDeveloper second\n\nLater policy"
        );
        assert_eq!(messages[1].text(), "Question");
        assert_eq!(messages[2].tool_calls[0].name, "computer.read");
        assert_eq!(messages[3].tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(messages[3].text(), "Observed content");
        assert_eq!(messages[4].text(), "Answer");
    }
    #[test]
    fn string_input_keeps_instructions_and_rejects_nontext_policy() {
        let messages = messages(
            &json!({"instructions":"Policy","input":"Hello"}),
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(messages[0].role, "system");
        assert_eq!(messages[0].text(), "Policy");
        assert_eq!(messages[1].text(), "Hello");
        assert!(
            super::messages(
                &json!({"instructions":{},"input":"Hello"}),
                &BTreeMap::new()
            )
            .is_err()
        );
        assert!(super::messages(&json!({"input":[{"role":"developer","content":[{"type":"input_file","file_id":"unavailable"}]}]}),&BTreeMap::new()).is_err());
    }
    #[test]
    fn text_parts_keep_a_boundary_between_the_human_prompt_and_host_context() {
        let messages = messages(
            &json!({"input":[{"role":"user","content":[
                {"type":"input_text","text":"Reply with exactly READY."},
                {"type":"input_text","text":"APP_RUNTIME_INTERACTION_POLICY: background_only."}
            ]}]}),
            &BTreeMap::new(),
        )
        .unwrap();
        assert_eq!(
            messages[0].text(),
            "Reply with exactly READY.\n\nAPP_RUNTIME_INTERACTION_POLICY: background_only."
        );
        assert_eq!(messages[0].content.len(), 1);
    }
}
fn content(raw: &Value) -> Result<Vec<ContentPart>, InferenceError> {
    if let Some(text) = raw.as_str() {
        return Ok(vec![ContentPart::Text(text.into())]);
    }
    let mut result = Vec::new();
    for part in raw.as_array().ok_or(InferenceError::Input)? {
        match part["type"].as_str() {
            Some("text" | "input_text" | "output_text" | "summary_text") => {
                let text = part["text"].as_str().ok_or(InferenceError::Input)?;
                if let Some(ContentPart::Text(previous)) = result.last_mut() {
                    // The pinned template concatenates separate text parts.
                    // Preserve their boundary without changing their bytes or
                    // moving text across an intervening screenshot.
                    previous.push_str("\n\n");
                    previous.push_str(text);
                } else {
                    result.push(ContentPart::Text(text.into()));
                }
            }
            Some("input_image" | "image_url") => {
                let source = part["image_url"]
                    .as_str()
                    .or_else(|| part["image_url"]["url"].as_str())
                    .ok_or(InferenceError::Input)?;
                result.push(ContentPart::Image(ImageContent {
                    bytes: request::decode_image(source).map_err(|_| InferenceError::Input)?,
                }));
            }
            _ => return Err(InferenceError::Input),
        }
    }
    Ok(result)
}

// Exact C ABI from the pinned mlx-c memory.h linked by mlex. These functions
// write one size_t into live stack storage and return a status code.
unsafe extern "C" {
    fn mlx_clear_cache() -> i32;
    fn mlx_set_cache_limit(previous: *mut usize, limit: usize) -> i32;
    fn mlx_set_memory_limit(previous: *mut usize, limit: usize) -> i32;
    fn mlx_get_active_memory(result: *mut usize) -> i32;
    fn mlx_get_cache_memory(result: *mut usize) -> i32;
    fn mlx_get_peak_memory(result: *mut usize) -> i32;
}
pub fn release_request_memory() -> Result<(), InferenceError> {
    mlex::array::synchronize().map_err(|_| InferenceError::Generation)?;
    // SAFETY: exact zero-argument mlx-c ABI; only the owned MLX thread invokes
    // it after request-local caches/tensors have dropped and Metal synchronized.
    if unsafe { mlx_clear_cache() } == 0 {
        Ok(())
    } else {
        Err(InferenceError::Generation)
    }
}
fn memory_limits() -> Result<(), InferenceError> {
    let mut previous = 0;
    // SAFETY: stack pointer is aligned, writable, non-null, lives across both
    // synchronous C calls; signatures match pinned mlx-c memory.h.
    let status = unsafe {
        (
            mlx_set_cache_limit(&mut previous, 256 * 1024 * 1024),
            mlx_set_memory_limit(&mut previous, 10 * 1024 * 1024 * 1024),
        )
    };
    if status == (0, 0) {
        Ok(())
    } else {
        Err(InferenceError::Unavailable)
    }
}
pub fn memory() -> Result<Memory, InferenceError> {
    let mut value = Memory {
        active_bytes: 0,
        cache_bytes: 0,
        peak_bytes: 0,
    };
    // SAFETY: each pointer references its own live, aligned size_t field; all
    // calls are synchronous and use the pinned mlx-c declarations above.
    let statuses = unsafe {
        (
            mlx_get_active_memory(&mut value.active_bytes),
            mlx_get_cache_memory(&mut value.cache_bytes),
            mlx_get_peak_memory(&mut value.peak_bytes),
        )
    };
    if statuses == (0, 0, 0) {
        Ok(value)
    } else {
        Err(InferenceError::Generation)
    }
}
pub fn failed_response(id: &str, error: &InferenceError) -> Value {
    if let InferenceError::Length(usage) = error {
        return json!({"id":id,"object":"response","status":"incomplete","output":[],"output_text":"","error":null,"incomplete_details":{"reason":"max_output_tokens"},"usage":usage,"store":false,"end_turn":false});
    }
    let mut response = json!({"id":id,"object":"response","status":"failed","output":[],"error":{"code":"invalid_prompt","message":error.to_string()}});
    if let InferenceError::Context(budget) = error {
        response["error"]["code"] = json!("context_length_exceeded");
        response["context_budget"] = serde_json::to_value(budget).unwrap_or(Value::Null);
    }
    response
}
