//! Provenance-bound text-history counterfactual. Historical reasoning is omitted
//! explicitly; neither hidden reasoning nor tool results are reconstructed.
use super::*;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{HashMap, HashSet};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingPlan {
    pub version: u8,
    pub compacted_prefix_count: usize,
    pub current_user_index: usize,
    pub guardian_message_indices: Vec<usize>,
    pub preserved_before_current_indices: Vec<usize>,
}
impl PairingPlan {
    fn validate(&self) -> Result<()> {
        let indices = |values: &[usize]| {
            values.windows(2).all(|window| window[0] < window[1])
                && values.iter().all(|value| *value <= 9_007_199_254_740_991)
        };
        ensure(
            self.version == 1
                && self.compacted_prefix_count > 0
                && self.current_user_index > self.compacted_prefix_count,
            "pair_invalid_plan_boundaries",
        )?;
        ensure(
            indices(&self.guardian_message_indices)
                && indices(&self.preserved_before_current_indices)
                && self.guardian_message_indices.len() >= 2
                && !self.preserved_before_current_indices.is_empty(),
            "pair_explicit_history_policy_indices_required",
        )
    }
}
pub fn parse_pairing_plan(raw: &str) -> Result<PairingPlan> {
    ensure(raw.len() <= 65536, "pair_plan_exceeds_bound")?;
    let value = parse(raw.as_bytes())?;
    let plan: PairingPlan =
        serde_json::from_value(value).map_err(|_| BenchmarkError("pair_plan_fields_invalid"))?;
    plan.validate()?;
    Ok(plan)
}
fn public_message(value: &Value, compactor: Option<&str>) -> Result<Value> {
    let fields = value
        .as_object()
        .ok_or(BenchmarkError("pair_expected_text_message"))?;
    ensure(
        value["type"] == "message"
            && value["role"]
                .as_str()
                .is_some_and(|role| ["user", "assistant"].contains(&role))
            && fields.keys().all(|key| {
                [
                    "type",
                    "id",
                    "role",
                    "content",
                    "phase",
                    "internal_chat_message_metadata_passthrough",
                ]
                .contains(&key.as_str())
            }),
        "pair_unknown_message_fields",
    )?;
    let parts = value["content"]
        .as_array()
        .ok_or(BenchmarkError("pair_text_content_required"))?;
    if let Some(metadata) = value
        .get("internal_chat_message_metadata_passthrough")
        .filter(|value| !value.is_null())
    {
        let fields = metadata
            .as_object()
            .ok_or(BenchmarkError("pair_unknown_native_message_metadata"))?;
        let kinds = metadata["content_item_kinds"]
            .as_array()
            .ok_or(BenchmarkError("pair_unknown_native_message_metadata"))?;
        let permitted = if value["role"] == "assistant" {
            kinds.iter().all(|kind| kind == "unknown")
                || compactor.is_some() && kinds.iter().all(|kind| kind == "compaction.summary")
        } else {
            kinds.iter().all(|kind| {
                kind.as_str().is_some_and(|kind| {
                    ["user.text", "agents_md.instructions", "compaction.summary"].contains(&kind)
                })
            })
        };
        ensure(
            fields.keys().all(|key| {
                ["turn_id", "create_time", "content_item_kinds"].contains(&key.as_str())
            }) && metadata["turn_id"]
                .as_str()
                .is_some_and(|id| !id.is_empty())
                && metadata
                    .get("create_time")
                    .is_none_or(|value| value.as_f64().is_some_and(f64::is_finite))
                && kinds.len() == parts.len()
                && permitted,
            "pair_unknown_native_message_metadata",
        )?;
        ensure(
            compactor.is_none_or(|id| metadata["turn_id"] == id),
            "pair_compactor_provenance_mismatch",
        )?;
    }
    ensure(
        value["id"].as_str().is_some_and(|id| !id.is_empty()),
        "pair_native_message_id_required",
    )?;
    ensure(
        value["phase"].is_null()
            || value["phase"]
                .as_str()
                .is_some_and(|phase| ["commentary", "final_answer"].contains(&phase)),
        "pair_unsupported_message_phase",
    )?;
    let expected = if value["role"] == "user" {
        "input_text"
    } else {
        "output_text"
    };
    ensure(
        !parts.is_empty()
            && parts.iter().all(|part| {
                part.as_object().is_some_and(|fields| {
                    fields.len() == 2 && fields.contains_key("type") && fields.contains_key("text")
                }) && part["type"] == expected
                    && part["text"].is_string()
            }),
        "pair_only_exact_text_content_supported",
    )?;
    let mut message =
        json!({"type":"message","id":value["id"],"role":value["role"],"content":parts});
    if !value["phase"].is_null() {
        message["phase"] = value["phase"].clone();
    }
    Ok(message)
}
fn text(value: &Value) -> String {
    value["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .concat()
}
fn without_id(mut value: Value) -> Value {
    value.as_object_mut().unwrap().remove("id");
    value
}
fn evidence(original: &str) -> String {
    if original.len() <= 2048 {
        return original.into();
    }
    let header = "[Historical completed assistant reply; excerpt]\n";
    let omission = "\n[... middle omitted ...]\n";
    let available = 2048 - header.len() - omission.len();
    let first_limit = available / 2;
    let mut first = String::new();
    for scalar in original.chars() {
        if first.len() + scalar.len_utf8() > first_limit {
            break;
        }
        first.push(scalar);
    }
    let mut last = vec![];
    let mut bytes = 0;
    for scalar in original.chars().rev() {
        if bytes + scalar.len_utf8() > available - first_limit {
            break;
        }
        last.push(scalar);
        bytes += scalar.len_utf8();
    }
    format!(
        "{header}{first}{omission}{}",
        last.into_iter().rev().collect::<String>()
    )
}
struct Turn {
    id: String,
    context: bool,
    compacted: bool,
    items: Vec<Value>,
}
#[derive(Debug)]
pub struct PairedContext {
    pub raw: String,
    pub audit: Value,
}
pub fn prepare_paired_context(
    request_raw: &str,
    rollout_raw: &str,
    plan: &PairingPlan,
) -> Result<PairedContext> {
    plan.validate()?;
    let mut request = context_request(request_raw)?;
    let input = request["input"].as_array().unwrap().clone();
    ensure(
        plan.current_user_index < input.len()
            && input
                .iter()
                .rposition(|item| item["type"] == "message" && item["role"] == "user")
                == Some(plan.current_user_index),
        "pair_current_user_must_be_final_user_message",
    )?;
    let current = public_message(&input[plan.current_user_index], None)?;
    ensure(
        rollout_raw.len() <= 16 * 1024 * 1024,
        "pair_rollout_exceeds_bound",
    )?;
    let lines = rollout_raw.trim_end().split('\n').collect::<Vec<_>>();
    ensure(
        !lines.is_empty() && lines.len() <= 100000,
        "pair_rollout_line_limit_exceeded",
    )?;
    let records = lines
        .iter()
        .map(|line| {
            let value = parse(line.trim_end_matches('\r').as_bytes())?;
            ensure(
                value.is_object() && value["type"].is_string() && value["payload"].is_object(),
                "pair_malformed_rollout_record",
            )?;
            Ok(value)
        })
        .collect::<Result<Vec<_>>>()?;
    let last = records
        .iter()
        .rposition(|record| record["type"] == "compacted")
        .ok_or(BenchmarkError("pair_missing_compacted_record"))?;
    let compacted = &records[last]["payload"];
    let guardian = compacted["guardian_history"]
        .as_array()
        .ok_or(BenchmarkError("pair_native_guardian_history_required"))?;
    let replacement = compacted["replacement_history"]
        .as_array()
        .ok_or(BenchmarkError("pair_native_replacement_history_required"))?
        .iter()
        .map(|item| public_message(item, None))
        .collect::<Result<Vec<_>>>()?;
    ensure(
        plan.compacted_prefix_count == replacement.len()
            && input
                .get(..plan.compacted_prefix_count)
                .ok_or(BenchmarkError("pair_prefix_out_of_bounds"))?
                .iter()
                .map(|item| public_message(item, None))
                .collect::<Result<Vec<_>>>()?
                == replacement,
        "pair_prefix_does_not_match_last_native_history",
    )?;
    let mut actual: Vec<Value> = vec![];
    let mut excluded: HashMap<String, Value> = HashMap::new();
    let mut policies: Vec<Value> = vec![];
    let mut excluded_turns: HashMap<String, String> = HashMap::new();
    let mut post_evidence: HashMap<String, Value> = HashMap::new();
    let mut active: Option<Turn> = None;
    let mut current_proven = false;
    let mut omitted_reasoning = 0;
    for (index, record) in records.iter().enumerate() {
        let kind = record["type"].as_str().unwrap();
        let p = &record["payload"];
        let ptype = p["type"].as_str().unwrap_or("");
        if kind == "event_msg" && ptype == "task_started" {
            ensure(
                active.is_none() && p["turn_id"].is_string(),
                "pair_ambiguous_overlapping_native_turns",
            )?;
            active = Some(Turn {
                id: p["turn_id"].as_str().unwrap().into(),
                context: false,
                compacted: false,
                items: vec![],
            });
        } else if kind == "turn_context" && active.is_some() {
            let turn = active.as_mut().unwrap();
            ensure(p["turn_id"] == turn.id, "pair_mismatched_turn_context")?;
            turn.context = true;
        } else if kind == "response_item" {
            if active.as_ref().is_some_and(|turn| turn.context) {
                let turn = active.as_mut().unwrap();
                let metadata = &p["internal_chat_message_metadata_passthrough"];
                ensure(
                    metadata
                        .get("turn_id")
                        .is_none_or(|id| id.as_str() == Some(turn.id.as_str())),
                    "pair_message_provenance_mismatches_active_turn",
                )?;
                if ptype == "message" && p["role"] == "user" && !metadata.is_null() {
                    ensure(
                        metadata["content_item_kinds"]
                            .as_array()
                            .is_some_and(|kinds| kinds.iter().all(|kind| kind == "user.text")),
                        "pair_injected_policy_summary_not_actual_user_turn",
                    )?;
                }
                turn.items.push(p.clone());
                if index > last
                    && ptype == "message"
                    && p["role"] == "user"
                    && public_message(p, None)? == current
                {
                    current_proven = true;
                }
            } else if ptype == "message" {
                let message = public_message(
                    p,
                    active
                        .as_ref()
                        .filter(|_| p["role"] == "assistant")
                        .map(|turn| turn.id.as_str()),
                )?;
                if message["role"] == "user" {
                    let body = text(&message);
                    ensure(
                        body.starts_with("# AGENTS.md instructions for ")
                            && body.contains("<INSTRUCTIONS>"),
                        "pair_unrecognized_out_of_turn_policy",
                    )?;
                    if index > last {
                        let id = message["id"].as_str().unwrap();
                        if let Some(existing) =
                            policies.iter_mut().find(|existing| existing["id"] == id)
                        {
                            *existing = message;
                        } else {
                            policies.push(message);
                        }
                    }
                } else if let Some(turn) = active.as_mut() {
                    turn.items.push(p.clone());
                } else {
                    let latest = actual
                        .iter()
                        .rfind(|item| item["role"] == "assistant")
                        .ok_or(BenchmarkError("pair_unproven_injected_assistant_evidence"))?;
                    ensure(
                        text(&message) == evidence(&text(latest)),
                        "pair_unproven_injected_assistant_evidence",
                    )?;
                    let id = message["id"].as_str().unwrap().to_owned();
                    excluded.insert(id.clone(), message.clone());
                    if index > last {
                        post_evidence.insert(id, message);
                    }
                }
            } else if let Some(turn) = active.as_mut() {
                turn.items.push(p.clone());
            } else {
                ensure(
                    ptype == "reasoning",
                    "pair_unsupported_out_of_turn_historical_item",
                )?;
            }
        } else if kind == "compacted" {
            let turn = active
                .as_mut()
                .ok_or(BenchmarkError("pair_compaction_without_native_turn"))?;
            turn.compacted = true;
            ensure(
                !turn
                    .items
                    .iter()
                    .any(|item| item["type"] == "message" && item["role"] == "user"),
                "pair_mid_user_turn_compaction_unsupported",
            )?;
            for item in &turn.items {
                if item["type"] == "message" {
                    let message = public_message(item, Some(&turn.id))?;
                    ensure(
                        message["role"] == "assistant",
                        "pair_unexpected_compaction_user_message",
                    )?;
                    let id = message["id"].as_str().unwrap().to_owned();
                    excluded.insert(id.clone(), message);
                    excluded_turns.insert(id, turn.id.clone());
                } else {
                    ensure(
                        item["type"] == "reasoning",
                        "pair_historical_tools_unsupported",
                    )?;
                }
            }
        } else if kind == "event_msg" && ptype == "task_complete" {
            let turn = active
                .take()
                .ok_or(BenchmarkError("pair_uncorrelated_native_completion"))?;
            ensure(
                p["turn_id"] == turn.id,
                "pair_uncorrelated_native_completion",
            )?;
            if !turn.compacted && index < last {
                ensure(turn.context, "pair_completed_user_turn_without_context")?;
                let mut messages = vec![];
                for item in turn.items {
                    if item["type"] == "reasoning" {
                        omitted_reasoning += 1;
                        continue;
                    }
                    ensure(
                        item["type"] == "message",
                        "pair_historical_tools_unsupported",
                    )?;
                    messages.push(public_message(&item, None)?);
                }
                ensure(
                    messages.len() >= 2
                        && messages[0]["role"] == "user"
                        && messages[1..]
                            .iter()
                            .all(|message| message["role"] == "assistant"),
                    "pair_ambiguous_completed_user_turn_messages",
                )?;
                ensure(
                    messages
                        .iter()
                        .all(|message| !text(message).trim().is_empty()),
                    "pair_blank_historical_message",
                )?;
                ensure(
                    p["last_agent_message"].as_str() == Some(&text(messages.last().unwrap())),
                    "pair_final_assistant_does_not_match_completion",
                )?;
                actual.extend(messages);
            }
        } else if kind == "event_msg"
            && index < last
            && ["turn_aborted", "task_failed", "error"].contains(&ptype)
        {
            return Err(BenchmarkError("pair_failed_aborted_prior_turn_unsupported"));
        }
    }
    ensure(
        current_proven && actual.len() >= 2,
        "pair_missing_prior_history_current_provenance",
    )?;
    let actual_by_id = actual
        .iter()
        .map(|message| (message["id"].as_str().unwrap(), message))
        .collect::<HashMap<_, _>>();
    ensure(
        actual_by_id.len() == actual.len(),
        "pair_duplicate_historical_ids",
    )?;
    let mut expected_indices = vec![];
    for (index, item) in guardian.iter().enumerate() {
        if item["type"] == "reasoning" {
            continue;
        }
        ensure(
            item["type"] == "message",
            "pair_historical_guardian_tools_unsupported",
        )?;
        let id = item["id"].as_str().unwrap_or("");
        let message = public_message(
            item,
            if actual_by_id.contains_key(id) {
                None
            } else {
                excluded_turns.get(id).map(String::as_str)
            },
        )?;
        if let Some(proven) = actual_by_id.get(id) {
            ensure(
                &message == *proven,
                "pair_guardian_message_differs_from_actual_output",
            )?;
            expected_indices.push(index);
        } else {
            ensure(
                excluded.get(id) == Some(&message),
                "pair_unproven_guardian_message_policy",
            )?;
        }
    }
    ensure(
        plan.guardian_message_indices == expected_indices,
        "pair_guardian_indices_omit_reorder_unproven_history",
    )?;
    let original = expected_indices
        .iter()
        .map(|index| public_message(&guardian[*index], None))
        .collect::<Result<Vec<_>>>()?;
    ensure(
        original == actual,
        "pair_guardian_not_every_completed_turn_once_in_order",
    )?;
    let users = original
        .iter()
        .filter(|message| message["role"] == "user")
        .cloned()
        .map(without_id)
        .collect::<Vec<_>>();
    ensure(
        replacement[..replacement.len() - 1]
            .iter()
            .cloned()
            .map(without_id)
            .collect::<Vec<_>>()
            == users,
        "pair_replacement_users_do_not_match_original_history",
    )?;
    let last_replacement = replacement.last().unwrap();
    ensure(
        last_replacement["role"] == "user"
            && compacted["message"].as_str() == Some(&text(last_replacement)),
        "pair_unproven_native_summary_boundary",
    )?;
    let policy_set = plan
        .preserved_before_current_indices
        .iter()
        .copied()
        .collect::<HashSet<_>>();
    let mut preserved = vec![];
    ensure(
        plan.preserved_before_current_indices
            .iter()
            .all(|index| *index >= plan.compacted_prefix_count && *index < plan.current_user_index),
        "pair_policy_index_crosses_boundary",
    )?;
    for (index, item) in input
        .iter()
        .enumerate()
        .take(plan.current_user_index)
        .skip(plan.compacted_prefix_count)
    {
        let message = public_message(item, None)?;
        let id = message["id"].as_str().unwrap();
        if policy_set.contains(&index) {
            ensure(
                message["role"] == "user" && policies.iter().any(|policy| policy == &message),
                "pair_policy_lacks_exact_native_provenance",
            )?;
            preserved.push(item.clone());
        } else {
            ensure(
                message["role"] == "assistant" && post_evidence.get(id) == Some(&message),
                "pair_unknown_item_before_current_user",
            )?;
        }
    }
    ensure(
        preserved.len() == policies.len()
            && preserved
                .iter()
                .map(|message| &message["id"])
                .eq(policies.iter().map(|message| &message["id"])),
        "pair_every_current_policy_must_remain_in_order",
    )?;
    let suffix = &input[plan.current_user_index..];
    let mut prepared = original.clone();
    prepared.extend(preserved.clone());
    prepared.extend_from_slice(suffix);
    let mut settings = request.clone();
    settings.as_object_mut().unwrap().remove("input");
    request["input"] = json!(prepared);
    let raw = request.to_string();
    ensure(
        raw.len() <= 1024 * 1024,
        "pair_counterfactual_request_exceeds_bound",
    )?;
    let policy_suffix = preserved.iter().chain(suffix).cloned().collect::<Vec<_>>();
    Ok(PairedContext {
        raw: raw.clone(),
        audit: json!({"version":1,"variant":"uncompacted-completed-text-history","historicalReasoning":"omitted-not-reconstructed","omittedHistoricalReasoningItems":omitted_reasoning,"lastCompactedRecordIndex":last,"originalMessageCount":original.len(),"compactedPrefixCount":replacement.len(),"removedInjectedEvidenceCount":plan.current_user_index-replacement.len()-preserved.len(),"preservedPolicyCount":preserved.len(),"preservedSuffixItemCount":suffix.len(),"sourceRequestSHA256":hash(request_raw),"rolloutSHA256":hash(rollout_raw),"planSHA256":hash(serde_json::to_vec(plan).map_err(|_|BenchmarkError("pair_plan_serialize_failed"))?),"counterfactualSHA256":hash(&raw),"unchangedSettingsSHA256":hash(settings.to_string()),"unchangedPolicyAndCurrentSuffixSHA256":hash(json!(policy_suffix).to_string())}),
    })
}
pub fn paired_context_files(
    request: &Path,
    rollout: &Path,
    plan: &Path,
    output: &Path,
) -> Result<Value> {
    let prepared = prepare_paired_context(
        &read_text(request)?,
        &read_text(rollout)?,
        &parse_pairing_plan(&read_text(plan)?)?,
    )?;
    let output = private_output(output)?;
    for (name, bytes) in [
        ("uncompacted.request.json", prepared.raw.as_bytes().to_vec()),
        (
            "pair.audit.json",
            serde_json::to_vec_pretty(&prepared.audit)
                .map_err(|_| BenchmarkError("pair_audit_serialize_failed"))?,
        ),
    ] {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(output.join(name))
            .map_err(|_| BenchmarkError("pair_artifact_create_failed"))?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| BenchmarkError("pair_artifact_write_failed"))?;
    }
    Ok(prepared.audit)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn message(id: &str, role: &str, text: &str) -> Value {
        json!({"type":"message","id":id,"role":role,"content":[{"type":if role=="user"{"input_text"}else{"output_text"},"text":text}]})
    }
    fn record(kind: &str, payload: Value) -> Value {
        json!({"type":kind,"payload":payload})
    }
    fn event(kind: &str, id: &str, extra: Value) -> Value {
        let mut payload = extra;
        payload["type"] = json!(kind);
        payload["turn_id"] = json!(id);
        record("event_msg", payload)
    }
    fn fixture() -> (Value, Vec<Value>, PairingPlan) {
        let user = message("original-user", "user", "Remember KEY_🍀. Reply ACK.");
        let assistant = message("original-assistant", "assistant", "ACK");
        let policy = message(
            "policy",
            "user",
            "# AGENTS.md instructions for /synthetic\n<INSTRUCTIONS>Preserve standing policy.</INSTRUCTIONS>",
        );
        let summary = message("summary", "assistant", "Native summary.");
        let replacement = vec![
            message("compacted-user", "user", "Remember KEY_🍀. Reply ACK."),
            message("summary-wrapper", "user", "Native summary wrapper."),
        ];
        let injection = message("injected", "assistant", "ACK");
        let current = message("current", "user", "Call status, then answer the key.");
        let reasoning = json!({"type":"reasoning","id":"historical-reasoning","content":[{"type":"reasoning_text","text":"Never reconstructed"}]});
        let compacted = json!({"guardian_history":[user,reasoning,assistant,summary],"replacement_history":replacement,"message":"Native summary wrapper."});
        let records = vec![
            event("task_started", "prior", json!({})),
            record("turn_context", json!({"turn_id":"prior"})),
            record("response_item", user.clone()),
            record("response_item", reasoning),
            record("response_item", assistant.clone()),
            event(
                "task_complete",
                "prior",
                json!({"last_agent_message":"ACK"}),
            ),
            event("task_started", "maintenance", json!({})),
            record("response_item", summary),
            record("compacted", compacted),
            event(
                "task_complete",
                "maintenance",
                json!({"last_agent_message":null}),
            ),
            record("response_item", policy.clone()),
            record("turn_context", json!({"turn_id":"auto-compact-0"})),
            record("response_item", injection.clone()),
            event("task_started", "current-turn", json!({})),
            record("turn_context", json!({"turn_id":"current-turn"})),
            record("response_item", current.clone()),
        ];
        let body = json!({"model":"synthetic","instructions":"Unchanged instructions","custom_sampler":{"min_p":0.03,"nested":[true,null,"exact"]},"tools":[{"type":"function","name":"status","parameters":{"type":"object"}}],"input":[replacement[0],replacement[1],policy,injection,current,{"type":"reasoning","id":"current-reasoning","content":[{"type":"reasoning_text","text":"Unchanged current reasoning"}]},{"type":"function_call","call_id":"current-tool","name":"status","arguments":"{}"},{"type":"function_call_output","call_id":"current-tool","output":"done"}]});
        let plan = PairingPlan {
            version: 1,
            compacted_prefix_count: 2,
            current_user_index: 4,
            guardian_message_indices: vec![0, 2],
            preserved_before_current_indices: vec![2],
        };
        (body, records, plan)
    }
    fn run(body: &Value, records: &[Value], plan: &PairingPlan) -> Result<PairedContext> {
        prepare_paired_context(
            &body.to_string(),
            &(records
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\n")
                + "\n"),
            plan,
        )
    }
    #[test]
    fn counterfactual_restores_only_proven_completed_text_and_preserves_full_current_suffix() {
        let (body, records, plan) = fixture();
        let result = run(&body, &records, &plan).unwrap();
        let prepared = parse(result.raw.as_bytes()).unwrap();
        assert_eq!(prepared["input"][0], records[2]["payload"]);
        assert_eq!(prepared["input"][1], records[4]["payload"]);
        assert_eq!(prepared["input"][2], body["input"][2]);
        assert_eq!(
            &prepared["input"].as_array().unwrap()[3..],
            &body["input"].as_array().unwrap()[4..]
        );
        assert_eq!(prepared["custom_sampler"], body["custom_sampler"]);
        assert!(prepared.get("temperature").is_none());
        assert_eq!(result.audit["omittedHistoricalReasoningItems"], 1);
        assert_eq!(result.audit["removedInjectedEvidenceCount"], 1);
        assert!(!result.audit.to_string().contains("KEY_🍀"));
        assert_eq!(
            result.audit["historicalReasoning"],
            "omitted-not-reconstructed"
        );
    }
    #[test]
    fn guardian_selection_fabrication_policy_and_completion_changes_fail_closed() {
        for mutation in 0..8 {
            let (mut body, mut records, mut plan) = fixture();
            match mutation {
                0 => plan.guardian_message_indices = vec![0, 3],
                1 => {
                    records[8]["payload"]["guardian_history"][2]["content"][0]["text"] =
                        json!("fabricated")
                }
                2 => records[5]["payload"]["last_agent_message"] = json!("different"),
                3 => body["input"][2]["content"][0]["text"] = json!("weaker policy"),
                4 => body["input"][4]["content"][0]["text"] = json!("changed current request"),
                5 => records.insert(
                    4,
                    record(
                        "response_item",
                        json!({"type":"function_call","name":"delete","arguments":"{}"}),
                    ),
                ),
                6 => {
                    records[2]["payload"]["internal_chat_message_metadata_passthrough"] =
                        json!({"turn_id":"prior","content_item_kinds":["agents_md.instructions"]})
                }
                _ => {
                    records[7]["payload"]["internal_chat_message_metadata_passthrough"] =
                        json!({"turn_id":"other","content_item_kinds":["compaction.summary"]})
                }
            }
            assert!(run(&body, &records, &plan).is_err(), "mutation {mutation}");
        }
    }
    #[test]
    fn native_summary_tags_require_the_exact_compactor_lifecycle_and_are_never_replayed() {
        let (body, mut records, plan) = fixture();
        let metadata = json!({"turn_id":"maintenance","content_item_kinds":["compaction.summary"]});
        records[7]["payload"]["internal_chat_message_metadata_passthrough"] = metadata.clone();
        records[8]["payload"]["guardian_history"][3]["internal_chat_message_metadata_passthrough"] =
            metadata;
        let prepared = parse(run(&body, &records, &plan).unwrap().raw.as_bytes()).unwrap();
        assert!(
            !prepared["input"]
                .as_array()
                .unwrap()
                .iter()
                .any(|item| item["id"] == "summary")
        );
        records[4]["payload"]["internal_chat_message_metadata_passthrough"] =
            json!({"turn_id":"prior","content_item_kinds":["compaction.summary"]});
        assert!(run(&body, &records, &plan).is_err());
    }
    #[test]
    fn plan_and_unicode_evidence_bounds_do_not_reconstruct_unknown_history() {
        let (_, _, plan) = fixture();
        let mut value = serde_json::to_value(&plan).unwrap();
        value["unexpected"] = json!(true);
        assert!(parse_pairing_plan(&value.to_string()).is_err());
        let raw = "界🦀".repeat(1000);
        let clipped = evidence(&raw);
        assert!(clipped.len() <= 2048);
        assert!(clipped.contains("middle omitted"));
        assert!(clipped.is_char_boundary(clipped.len()));
    }
}
