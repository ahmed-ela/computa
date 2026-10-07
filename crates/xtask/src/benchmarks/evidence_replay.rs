//! Recorded association experiments. Receipt bodies are data, never input authority.
use super::*;
use serde_json::json;
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug)]
pub struct RetentionReplay {
    pub request: Value,
    pub audit: Value,
}
fn receipts(items: &Value) -> Result<Vec<&Value>> {
    let items = items
        .as_array()
        .ok_or(BenchmarkError("evidence_history_array_required"))?;
    ensure(items.len() <= 1000, "evidence_history_bound")?;
    let (mut pending, mut completed, mut result) = (HashSet::new(), HashSet::new(), vec![]);
    for item in items {
        let kind = item["type"]
            .as_str()
            .ok_or(BenchmarkError("evidence_item_type_required"))?;
        if matches!(kind, "message" | "reasoning") {
            continue;
        }
        ensure(
            matches!(kind, "function_call" | "function_call_output"),
            "evidence_unknown_history_item",
        )?;
        let id = item["call_id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or(BenchmarkError("evidence_call_id_required"))?;
        let fields: &[&str] = if kind == "function_call" {
            &[
                "type",
                "call_id",
                "name",
                "arguments",
                "id",
                "status",
                "namespace",
            ]
        } else {
            &["type", "call_id", "output", "id"]
        };
        ensure(
            item.as_object()
                .is_some_and(|m| m.keys().all(|k| fields.contains(&k.as_str())))
                && (item["id"].is_null() || item["id"].is_string()),
            "evidence_receipt_metadata_unknown",
        )?;
        if kind == "function_call" {
            ensure(
                item["namespace"].is_null()
                    && (item["status"].is_null() || item["status"] == "completed")
                    && item["name"].as_str().is_some_and(|s| !s.is_empty())
                    && item["arguments"].is_string()
                    && !completed.contains(id)
                    && pending.insert(id),
                "evidence_function_identity_invalid",
            )?;
        } else {
            ensure(
                pending.remove(id) && completed.insert(id),
                "evidence_unmatched_output",
            )?;
            ensure(
                item["output"].is_string()
                    || item["output"].as_array().is_some_and(|parts| {
                        parts.len() <= 128
                            && parts.iter().all(|part| {
                                part.is_object()
                                    && ((part["type"] == "input_text" && part["text"].is_string())
                                        || (part["type"] == "input_image"
                                            && part["image_url"].is_string()))
                            })
                    }),
                "evidence_output_shape_invalid",
            )?;
        }
        result.push(item);
    }
    ensure(
        pending.is_empty() && completed.len() == 13 && result.len() == 26,
        "evidence_exact_thirteen_pairs_required",
    )?;
    Ok(result)
}
fn images(items: &Value) -> Result<Vec<Value>> {
    let items = items
        .as_array()
        .ok_or(BenchmarkError("evidence_history_array_required"))?;
    let mut images = vec![];
    for item in items {
        let parts = if item["type"] == "function_call_output" {
            &item["output"]
        } else {
            &item["content"]
        };
        if let Some(parts) = parts.as_array() {
            for part in parts.iter().filter(|part| part["type"] == "input_image") {
                images.push(json!({"callID":if item["type"] == "function_call_output" {item["call_id"].clone()} else {Value::Null},"image":part}));
            }
        }
    }
    Ok(images)
}
fn validate_template(request: &Value) -> Result<()> {
    ensure(
        request.is_object()
            && request["model"] == MODEL
            && request["stream"] == false
            && request["tools"]
                .as_array()
                .is_some_and(|tools| tools.len() == 13)
            && request["instructions"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
            && request["max_output_tokens"]
                .as_u64()
                .is_some_and(|n| (1..=2048).contains(&n))
            && request["previous_response_id"].is_null()
            && request["conversation"].is_null()
            && matches!(request["background"], Value::Null | Value::Bool(false)),
        "evidence_baseline_request_unsupported",
    )
}
/// Substitute outputs only. Exporter serializer metadata is validated and ignored.
pub fn prepare_retention_replay(baseline: &Value, exported: &Value) -> Result<RetentionReplay> {
    let request = &baseline["request"];
    validate_template(request)?;
    let original = receipts(&request["input"])?;
    let replacement = receipts(&exported["items"])?;
    for (before, after) in original.iter().zip(&replacement) {
        ensure(
            before["type"] == after["type"] && before["call_id"] == after["call_id"],
            "evidence_receipt_identity_changed",
        )?;
        if before["type"] == "function_call" {
            ensure(
                before["name"] == after["name"] && before["arguments"] == after["arguments"],
                "evidence_function_arguments_changed",
            )?;
        }
    }
    let before_images = images(&request["input"])?;
    ensure(
        before_images.len() == 1
            && !before_images[0]["callID"].is_null()
            && before_images == images(&exported["items"])?,
        "evidence_single_exact_image_required",
    )?;
    let outputs: BTreeMap<_, _> = replacement
        .iter()
        .filter(|v| v["type"] == "function_call_output")
        .map(|v| (v["call_id"].as_str().unwrap(), v["output"].clone()))
        .collect();
    let mut candidate = request.clone();
    let mut audit = vec![];
    for item in candidate["input"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .filter(|v| v["type"] == "function_call_output")
    {
        let id = item["call_id"].as_str().unwrap();
        let after = outputs
            .get(id)
            .ok_or(BenchmarkError("evidence_output_identity_missing"))?;
        let (old, new) = (item["output"].to_string(), after.to_string());
        audit.push(json!({"callIDSHA256":hash(id),"beforeSHA256":hash(&old),"afterSHA256":hash(&new),"beforeBytes":old.len(),"afterBytes":new.len(),"changed":item["output"] != *after}));
        item["output"] = after.clone();
    }
    let mut restored = candidate.clone();
    let original_outputs: BTreeMap<_, _> = original
        .iter()
        .filter(|v| v["type"] == "function_call_output")
        .map(|v| (v["call_id"].as_str().unwrap(), v["output"].clone()))
        .collect();
    for item in restored["input"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .filter(|v| v["type"] == "function_call_output")
    {
        item["output"] = original_outputs[item["call_id"].as_str().unwrap()].clone();
    }
    ensure(
        restored == *request && candidate.to_string().len() <= MAX_FILE,
        "evidence_non_output_request_changed",
    )?;
    let changed = audit.iter().filter(|v| v["changed"] == true).count();
    let audit = json!({"scope":"saved continuation; receipt body substitution only; no tool dispatch","normalizedJSONHashes":true,
        "baselineRequestSHA256":hash(request.to_string()),"candidateRequestSHA256":hash(candidate.to_string()),
        "instructionSHA256":hash(request["instructions"].to_string()),"toolsSHA256":hash(request["tools"].to_string()),
        "retainedImageSHA256":hash(before_images[0].to_string()),"exactCallOutputPairs":13,"exactImageCount":1,
        "nonOutputFieldsExact":true,"changedOutputCount":changed,"outputAudit":audit});
    Ok(RetentionReplay {
        request: candidate,
        audit,
    })
}
fn texts(item: &Value) -> Vec<&str> {
    if item["type"] != "message" {
        return vec![];
    }
    item["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| matches!(p["type"].as_str(), Some("input_text" | "output_text")))
        .filter_map(|p| p["text"].as_str())
        .collect()
}
fn projection(items: &[Value]) -> Result<Vec<Value>> {
    let mut result = vec![];
    for item in items {
        match item["type"].as_str() {
            Some("reasoning") => {},
            Some("message") => result.push(json!({"type":"message","role":item["role"],"content":item["content"]})),
            Some("function_call") => result.push(json!({"type":"function_call","call_id":item["call_id"],"name":item["name"],"arguments":item["arguments"]})),
            Some("function_call_output") => result.push(json!({"type":"function_call_output","call_id":item["call_id"],"output":item["output"]})),
            _ => return Err(BenchmarkError("evidence_unknown_regression_item")),
        }
    }
    Ok(result)
}
#[derive(Debug)]
pub struct RecordedRegression {
    pub summary_history: Vec<Value>,
    pub continuation: Vec<Value>,
    pub summary_index: usize,
    pub audit: Value,
}
/// Remove only the recorded trailing summary with exact bytes and exact provenance.
pub fn prepare_recorded_regression(
    records: &[Value],
    prefix: &str,
    policy: &str,
) -> Result<RecordedRegression> {
    ensure(
        !prefix.is_empty() && !policy.is_empty() && records.len() <= 100_000,
        "evidence_regression_input_bound",
    )?;
    let compact = records
        .iter()
        .filter(|r| r["type"] == "compacted")
        .collect::<Vec<_>>();
    ensure(compact.len() == 1, "evidence_one_compaction_required")?;
    let record = &compact[0]["payload"];
    let guardian = record["guardian_history"]
        .as_array()
        .ok_or(BenchmarkError("evidence_guardian_missing"))?;
    let replacement = record["replacement_history"]
        .as_array()
        .ok_or(BenchmarkError("evidence_replacement_missing"))?;
    let message = record["message"]
        .as_str()
        .ok_or(BenchmarkError("evidence_summary_missing"))?;
    let head = format!("{prefix}\n");
    let old = message
        .strip_prefix(&head)
        .filter(|s| !s.trim().is_empty())
        .ok_or(BenchmarkError("evidence_summary_prefix_mismatch"))?;
    let provenance = guardian
        .iter()
        .enumerate()
        .filter(|(_, i)| {
            i["internal_chat_message_metadata_passthrough"]["content_item_kinds"]
                .as_array()
                .is_some_and(|v| v.iter().any(|v| v == "compaction.summary"))
        })
        .collect::<Vec<_>>();
    ensure(
        provenance.len() == 1,
        "evidence_ambiguous_summary_provenance",
    )?;
    let (index, summary) = provenance[0];
    ensure(
        index + 1 == guardian.len()
            && summary["type"] == "message"
            && summary["role"] == "assistant"
            && summary["content"] == json!([{"type":"output_text","text":old}])
            && summary["internal_chat_message_metadata_passthrough"]["content_item_kinds"]
                == json!(["compaction.summary"]),
        "evidence_summary_identity_mismatch",
    )?;
    let has_old = |items: &[Value]| {
        items.iter().any(|i| {
            texts(i)
                .iter()
                .any(|s| s.contains(old) || s.contains(prefix))
        })
    };
    let prior = projection(&guardian[..index])?;
    ensure(!has_old(&prior), "evidence_prior_summary_contamination")?;
    let next = projection(replacement)?;
    let indices = next
        .iter()
        .enumerate()
        .filter(|(_, i)| i["role"] == "user" && texts(i).iter().any(|s| s.starts_with(&head)))
        .map(|(n, _)| n)
        .collect::<Vec<_>>();
    ensure(
        indices.len() == 1
            && next[indices[0]]["content"] == json!([{"type":"input_text","text":message}]),
        "evidence_replacement_summary_mismatch",
    )?;
    let inherited = next
        .iter()
        .enumerate()
        .filter(|(_, i)| i["role"] == "user" && texts(i).iter().any(|s| s.contains(policy)))
        .collect::<Vec<_>>();
    ensure(
        inherited.len() == 1
            && !has_old(&[inherited[0].1.clone()])
            && !prior
                .iter()
                .any(|i| texts(i).iter().any(|s| s.contains(policy))),
        "evidence_policy_identity_mismatch",
    )?;
    let original_questions = prior
        .iter()
        .filter(|i| i["role"] == "user")
        .collect::<Vec<_>>();
    let retained_questions = next
        .iter()
        .enumerate()
        .filter(|(n, i)| i["role"] == "user" && *n != indices[0] && *n != inherited[0].0)
        .map(|(_, i)| i)
        .collect::<Vec<_>>();
    ensure(
        original_questions.len() == 1 && original_questions == retained_questions,
        "evidence_original_question_changed",
    )?;
    let mut history = vec![inherited[0].1.clone()];
    history.extend(prior);
    let history_value = json!(history);
    let next_value = json!(next);
    let before = receipts(&history_value)?;
    let after = receipts(&next_value)?;
    let calls = |items: Vec<&Value>| {
        items
            .into_iter()
            .filter(|i| i["type"] == "function_call")
            .cloned()
            .collect::<Vec<_>>()
    };
    let old_images = images(&history_value)?;
    ensure(
        calls(before) == calls(after)
            && old_images.len() == 1
            && old_images == images(&next_value)?,
        "evidence_regression_receipts_changed",
    )?;
    ensure(
        !has_old(&history)
            && !has_old(
                &next
                    .iter()
                    .enumerate()
                    .filter(|(n, _)| *n != indices[0])
                    .map(|(_, i)| i.clone())
                    .collect::<Vec<_>>(),
            ),
        "evidence_old_summary_contamination",
    )?;
    let audit = json!({"removedOriginalSummaryCount":1,"oldSummaryAbsent":true,"originalUserQuestionExact":true,
        "inheritedPolicyExact":true,"inheritedPolicySHA256":hash(policy),"retainedCallCount":13,"retainedOutputCount":13,
        "retainedImageCount":1,"filteredReasoningCount":guardian[..index].iter().filter(|i| i["type"] == "reasoning").count(),
        "reconstructedHistoryNotOriginalWire":true,"noToolsExecuted":true});
    Ok(RecordedRegression {
        summary_history: history,
        continuation: next,
        summary_index: indices[0],
        audit,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn history() -> Vec<Value> {
        let mut items = vec![
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":"Which order is paid?"}]}),
        ];
        for n in 0..13 {
            items.push(json!({"type":"function_call","call_id":format!("call{n}"),"name":"computer_capture","arguments":"{}"}));
            items.push(json!({"type":"function_call_output","call_id":format!("call{n}"),"output":if n == 12 {json!([{"type":"input_text","text":"Current evidence"},{"type":"input_image","image_url":"data:image/png;base64,EXACT"}])} else {json!("Saved evidence")}}));
        }
        items
    }
    fn baseline(items: &[Value]) -> Value {
        json!({"request":{"model":MODEL,"stream":false,"tools":vec![json!({"type":"function","name":"computer_capture"});13],"instructions":"Retained production instructions","max_output_tokens":2048,"input":items}})
    }
    #[test]
    fn only_outputs_can_change_and_the_single_image_remains_exact() {
        let history = history();
        let baseline = baseline(&history);
        let mut exported = json!({"items":history});
        exported["items"][2]["output"] = json!("More complete evidence");
        exported["items"][1]["id"] = json!("known optional serializer metadata");
        let prepared = prepare_retention_replay(&baseline, &exported).unwrap();
        assert_eq!(prepared.audit["changedOutputCount"], 1);
        assert_eq!(
            prepared.request["input"][1],
            baseline["request"]["input"][1]
        );
        let mut tampered = exported.clone();
        tampered["items"][1]["arguments"] = json!("{\"changed\":true}");
        assert!(prepare_retention_replay(&baseline, &tampered).is_err());
        let mut tampered = exported.clone();
        tampered["items"][26]["output"][1]["image_url"] = json!("different");
        assert!(prepare_retention_replay(&baseline, &tampered).is_err());
        let mut tampered = exported;
        tampered["items"][1]["namespace"] = json!("wider authority");
        assert!(prepare_retention_replay(&baseline, &tampered).is_err());
    }
    #[test]
    fn paired_identity_rejects_reordered_unmatched_and_duplicate_receipts() {
        let history = history();
        let baseline = baseline(&history);
        let mut altered = history.clone();
        altered.swap(1, 3);
        assert!(prepare_retention_replay(&baseline, &json!({"items":altered})).is_err());
        let mut altered = history.clone();
        altered[2]["call_id"] = json!("missing");
        assert!(prepare_retention_replay(&baseline, &json!({"items":altered})).is_err());
        let mut altered = history;
        altered[3]["call_id"] = json!("call0");
        assert!(prepare_retention_replay(&baseline, &json!({"items":altered})).is_err());
    }
    fn regression() -> Vec<Value> {
        let mut guardian = history();
        guardian.push(json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"Unique old summary body"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["compaction.summary"]}}));
        let mut replacement = vec![
            json!({"type":"message","role":"user","content":[{"type":"input_text","text":"Retained inherited policy"}]}),
        ];
        replacement.extend(history());
        replacement.insert(2,json!({"type":"message","role":"user","content":[{"type":"input_text","text":"Summary prefix\nUnique old summary body"}]}));
        vec![
            json!({"type":"compacted","payload":{"guardian_history":guardian,"replacement_history":replacement,"message":"Summary prefix\nUnique old summary body"}}),
        ]
    }
    #[test]
    fn recorded_summary_is_removed_only_by_exact_trailing_provenance() {
        let records = regression();
        let prepared =
            prepare_recorded_regression(&records, "Summary prefix", "Retained inherited policy")
                .unwrap();
        assert_eq!(prepared.audit["retainedCallCount"], 13);
        assert_eq!(prepared.summary_index, 2);
        assert!(
            !json!(prepared.summary_history)
                .to_string()
                .contains("Unique old summary body")
        );
        let mut altered = records.clone();
        altered[0]["payload"]["guardian_history"][27]["content"][0]["text"] =
            json!("Different summary body");
        assert!(
            prepare_recorded_regression(&altered, "Summary prefix", "Retained inherited policy")
                .is_err()
        );
        let mut altered = records;
        altered[0]["payload"]["replacement_history"][1]["content"][0]["text"] =
            json!("Different user request");
        assert!(
            prepare_recorded_regression(&altered, "Summary prefix", "Retained inherited policy")
                .is_err()
        );
    }
}
