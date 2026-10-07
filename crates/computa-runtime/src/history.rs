//! Hydrate the existing App Server timeline; native failures suppress invalid assistant receipts.
use computa_contracts::{Identifier, ui::*};
use computa_state::evidence::FailureRecord;
use serde_json::Value;
use sha2::Digest;
use std::collections::HashSet;
pub fn entries(result: &Value, failures: &[FailureRecord]) -> Vec<EntrySnapshot> {
    let thread = result.get("thread").unwrap_or(result);
    let Some(turns) = thread["turns"].as_array() else {
        return failure_entries(failures);
    };
    let rejected: HashSet<_> = failures.iter().map(|r| r.turn_id.as_str()).collect();
    let mut entries = vec![];
    let mut seen = HashSet::new();
    for turn in turns {
        let turn_id = turn["id"].as_str().unwrap_or("");
        let timestamp = turn["startedAt"].as_f64().unwrap_or(0.0);
        let group = turn["items"]
            .as_array()
            .and_then(|items| items.iter().find(|i| i["type"] == "userMessage"))
            .and_then(|i| i["id"].as_str())
            .and_then(|s| Identifier::new(s).ok());
        if let Some(items) = turn["items"].as_array() {
            for item in items {
                let Some(id) = item["id"].as_str().and_then(|s| Identifier::new(s).ok()) else {
                    continue;
                };
                if !seen.insert(id.clone()) {
                    continue;
                }
                if let Some(entry) = item_entry(
                    item,
                    id,
                    timestamp,
                    group.clone(),
                    rejected.contains(turn_id),
                ) {
                    entries.push(entry);
                }
            }
        }
    }
    entries.extend(failure_entries(failures));
    entries.sort_by(|a, b| a.timestamp.total_cmp(&b.timestamp));
    entries
}
pub fn item_entry(
    item: &Value,
    id: Identifier,
    timestamp: f64,
    group: Option<Identifier>,
    reject_assistant: bool,
) -> Option<EntrySnapshot> {
    let (kind, title, body, phase, tool) = match item["type"].as_str()? {
        "userMessage" => {
            let text = content_text(&item["content"], true);
            if text.trim().is_empty() {
                return None;
            }
            (EntryKind::User, "You".into(), text, None, None)
        }
        "agentMessage" => {
            if reject_assistant {
                return None;
            }
            let text = item["text"].as_str()?.to_owned();
            if text.is_empty() {
                return None;
            }
            let phase = item["phase"]
                .as_str()
                .and_then(|s| serde_json::from_value(Value::String(s.into())).ok());
            (EntryKind::Assistant, "Computa".into(), text, phase, None)
        }
        "reasoning" => {
            let text = reasoning_text(item);
            if text.is_empty() {
                return None;
            }
            (EntryKind::Reasoning, "Reasoning".into(), text, None, None)
        }
        "commandExecution" | "mcpToolCall" | "dynamicToolCall" | "webSearch" => {
            let name = item["tool"]
                .as_str()
                .or(item["name"].as_str())
                .or(item["command"].as_str())
                .unwrap_or("Tool")
                .to_owned();
            let output = item["aggregatedOutput"]
                .as_str()
                .map(str::to_owned)
                .or_else(|| item.get("contentItems").map(|v| content_text(v, false)))
                .or_else(|| item.get("result").map(Value::to_string));
            let status = item["status"].as_str().unwrap_or("completed").to_owned();
            let input =
                item.get("arguments")
                    .or(item.get("command"))
                    .map_or_else(String::new, |v| {
                        if let Some(s) = v.as_str() {
                            s.to_owned()
                        } else {
                            v.to_string()
                        }
                    });
            let tool = ToolSnapshot {
                name: name.clone(),
                summary: name.clone(),
                tone: if status == "failed" {
                    Tone::Red
                } else {
                    Tone::Neutral
                },
                status,
                input,
                output: output.clone(),
                duration: item["durationMs"].as_f64().map(|n| n / 1000.0),
            };
            (
                EntryKind::Tool,
                name,
                output.unwrap_or_default(),
                None,
                Some(tool),
            )
        }
        _ => return None,
    };
    Some(EntrySnapshot {
        id,
        kind,
        title,
        body,
        timestamp,
        worked_for_seconds: None,
        is_streaming: Some(item["status"] == "inProgress"),
        activity_group_id: group,
        assistant_phase: phase,
        tool,
    })
}
pub fn content_text(value: &Value, skip_guidance: bool) -> String {
    let Some(items) = value.as_array() else {
        return value.as_str().unwrap_or("").into();
    };
    items
        .iter()
        .enumerate()
        .filter_map(|(index, i)| match i["type"].as_str() {
            Some("text" | "inputText" | "input_text") => i["text"]
                .as_str()
                .filter(|s| !skip_guidance || index == 0 || !s.starts_with("APP_RUNTIME_")),
            Some("image" | "localImage" | "inputImage" | "input_image") => Some("[Image]"),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}
fn reasoning_text(item: &Value) -> String {
    for key in ["content", "summary"] {
        if let Some(items) = item[key].as_array() {
            let texts: Vec<_> = items
                .iter()
                .filter_map(|v| v.as_str().or(v["text"].as_str()))
                .collect();
            if !texts.is_empty() {
                return texts.join("\n");
            }
        }
    }
    String::new()
}
fn failure_entries(records: &[FailureRecord]) -> Vec<EntrySnapshot> {
    records
        .iter()
        .filter_map(|r| {
            Some(EntrySnapshot {
                id: Identifier::new(format!(
                    "native_failure_{}",
                    hex::encode(sha2::Sha256::digest(
                        format!("{}:{}", r.turn_id, r.call_id).as_bytes()
                    ))
                ))
                .ok()?,
                kind: EntryKind::System,
                title: "Computer action unverified".into(),
                body: r.message.clone(),
                timestamp: r.timestamp_unix(),
                worked_for_seconds: None,
                is_streaming: Some(false),
                activity_group_id: None,
                assistant_phase: None,
                tool: Some(ToolSnapshot {
                    name: r.tool_name.clone(),
                    summary: r.message.clone(),
                    status: "failed".into(),
                    tone: Tone::Red,
                    input: String::new(),
                    output: Some(r.diagnostic_text.clone()),
                    duration: None,
                }),
            })
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_user_text_with_guidance_prefix_is_preserved() {
        let parts = json!([
            {"type":"text","text":"APP_RUNTIME_ is a literal part of my request."},
            {"type":"text","text":"APP_RUNTIME_INTERACTION_POLICY: background_only"}
        ]);
        assert_eq!(
            content_text(&parts, true),
            "APP_RUNTIME_ is a literal part of my request."
        );
        assert!(content_text(&parts, false).contains("INTERACTION_POLICY"));
    }
    use serde_json::json;
    #[test]
    fn old_history_is_preserved_and_bad_assistant_hidden() {
        let r = computa_state::evidence::outcome_record(
            "thread".into(),
            "turn".into(),
            "failure".into(),
            "computer_outcome".into(),
            false,
            1,
            0,
            100.0,
        )
        .unwrap();
        let result = json!({"thread":{"turns":[{"id":"turn","startedAt":90,"items":[{"id":"user","type":"userMessage","content":[{"type":"text","text":"Original user"},{"type":"text","text":"APP_RUNTIME_secret"}]},{"id":"assistant","type":"agentMessage","text":"Unsupported success"},{"id":"tool","type":"dynamicToolCall","tool":"computer_v2_press","arguments":{},"status":"failed","contentItems":[{"type":"inputText","text":"unverified"}]}]}]}});
        let e = entries(&result, &[r]);
        assert_eq!(e.len(), 3);
        assert_eq!(e[0].body, "Original user");
        assert!(!e.iter().any(|e| e.kind == EntryKind::Assistant));
        assert_eq!(e[2].timestamp, 100.0);
    }
}
