//! Offline, selected-turn receipt measurements. Source labels, URLs, arguments,
//! reasoning and answer text are never serialized in the redacted audit result.
use super::*;
use regex::Regex;
use serde_json::json;
use std::collections::{BTreeMap, HashMap};
const BASE_TOOLS: [&str; 16] = [
    "computer_v2_status",
    "computer_v2_apps",
    "computer_v2_open",
    "computer_v2_tabs",
    "computer_v2_bind_tab",
    "computer_v2_snapshot",
    "computer_v2_continue",
    "computer_v2_ax",
    "computer_v2_set_text",
    "computer_v2_capture",
    "computer_v2_ground_click",
    "computer_v2_click",
    "computer_v2_pointer",
    "computer_v2_keypress",
    "computer_v2_type",
    "computer_v2_verify",
];
const EXTRA_TOOLS: [&str; 6] = [
    "computer_v2_follow_link",
    "computer_v2_read_page",
    "computer_v2_read_region",
    "computer_v2_press",
    "computer_v2_fill",
    "computer_v2_follow",
];
const POST_TOOLS: [&str; 6] = [
    "computer_v2_ax",
    "computer_v2_set_text",
    "computer_v2_follow_link",
    "computer_v2_press",
    "computer_v2_fill",
    "computer_v2_follow",
];
const READ_TOOLS: [&str; 12] = [
    "computer_v2_tabs",
    "computer_v2_continue",
    "computer_v2_snapshot",
    "computer_v2_bind_tab",
    "computer_v2_open",
    "computer_v2_ax",
    "computer_v2_set_text",
    "computer_v2_follow_link",
    "computer_v2_read_page",
    "computer_v2_read_region",
    "computer_v2_press",
    "computer_v2_fill",
];
const MAX_ROLLOUT: usize = 64 * 1024 * 1024;
fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("fixed valid benchmark regular expression")
}
fn uuid(value: &str) -> bool {
    value.len() == 36
        && [8, 13, 18, 23]
            .into_iter()
            .all(|index| value.as_bytes()[index] == b'-')
        && uuid::Uuid::parse_str(value).is_ok()
}
fn stamp(value: &Value) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|value| value.timestamp_millis())
}
fn difference(end: Option<i64>, start: Option<i64>) -> Option<i64> {
    end.zip(start)
        .and_then(|(end, start)| (end >= start).then_some(end - start))
}
fn count(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .filter(|value| *value <= 9_007_199_254_740_991)
}
fn inc(value: &mut Value, key: &str) {
    value[key] = json!(value[key].as_u64().unwrap_or(0) + 1);
}
fn known_tool(name: &str, extra: bool) -> &str {
    if BASE_TOOLS.contains(&name) || extra && EXTRA_TOOLS.contains(&name) {
        name
    } else {
        "other_tool"
    }
}
fn read_tool(name: &str) -> bool {
    READ_TOOLS.contains(&name) || name == "computer_v2_follow"
}
fn input_tool(name: &str) -> bool {
    POST_TOOLS.contains(&name)
        || [
            "computer_v2_ground_click",
            "computer_v2_click",
            "computer_v2_pointer",
            "computer_v2_keypress",
            "computer_v2_type",
        ]
        .contains(&name)
}
/// Typed image-bearing receipts and strings retain their exact host boundaries.
pub fn receipt_text(value: &Value) -> Option<String> {
    if let Some(text) = value.as_str() {
        return Some(text.into());
    }
    let items = value.as_array()?;
    let mut text = vec![];
    for item in items {
        if !item.is_object() {
            return None;
        }
        match item["type"].as_str()? {
            "input_text" => text.push(item["text"].as_str()?),
            "input_image" => {}
            _ => return None,
        }
    }
    Some(text.join("\n"))
}
fn records(raw: &str, turn: &str) -> Result<Vec<Value>> {
    ensure(
        uuid(turn) && raw.len() <= MAX_ROLLOUT,
        "rollout_audit_failed_redacted",
    )?;
    let lines = raw.trim_end().split('\n').collect::<Vec<_>>();
    ensure(lines.len() <= 100000, "rollout_audit_failed_redacted")?;
    let mut records = vec![];
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let value = parse(line.trim_end_matches('\r').as_bytes())
            .map_err(|_| BenchmarkError("rollout_audit_failed_redacted"))?;
        ensure(
            value.is_object() && value["type"].is_string() && value["payload"].is_object(),
            "rollout_audit_failed_redacted",
        )?;
        records.push(value);
    }
    Ok(records)
}
pub fn audit_clickability(path: &Path, turn: &str, marker: Option<&str>) -> Result<Value> {
    summarize_clickability(&read_large_rollout(path)?, turn, marker)
}
pub fn audit_lookup(path: &Path, turn: &str) -> Result<Value> {
    summarize_lookup(&read_large_rollout(path)?, turn)
}
pub(super) fn read_large_rollout(path: &Path) -> Result<String> {
    ensure(path.is_absolute(), "absolute_rollout_path_required")?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| BenchmarkError("rollout_read_failed_redacted"))?;
    let meta = file
        .metadata()
        .map_err(|_| BenchmarkError("rollout_metadata_failed_redacted"))?;
    ensure(
        meta.is_file() && meta.len() <= MAX_ROLLOUT as u64,
        "rollout_file_invalid",
    )?;
    let mut bytes = vec![];
    file.take((MAX_ROLLOUT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| BenchmarkError("rollout_read_failed_redacted"))?;
    ensure(bytes.len() <= MAX_ROLLOUT, "rollout_grew_beyond_limit")?;
    String::from_utf8(bytes).map_err(|_| BenchmarkError("rollout_invalid_utf8"))
}
pub fn summarize_clickability(raw: &str, turn: &str, marker: Option<&str>) -> Result<Value> {
    ensure(
        marker.is_none_or(|marker| re(r"^[A-Z][A-Z0-9_]{7,79}$").is_match(marker)),
        "rollout_audit_failed_redacted",
    )?;
    let mut active = None;
    let mut seen = false;
    let mut complete = false;
    let mut compacted = 0;
    let mut start = None;
    let mut end = None;
    let mut completion = None;
    let mut model = None;
    let (mut orphan, mut duplicates, mut selected) = (0, 0, 0);
    let mut calls: Vec<Value> = vec![];
    let mut ids: HashMap<String, usize> = HashMap::new();
    let mut messages: Vec<(String, String)> = vec![];
    let action_row =
        re(r#" actions=\["AXPress"\] press_source=(browser_clickability|focusable_pointer)$"#);
    let verified = re(r"^VERIFIED_PROPERTY operation_id=([^\s]+) snapshot_id=");
    let runtime = re(
        r"^operation=([^\s]+) tool=(computer_v2_[a-z_]+) dispatch=(not_dispatched|dispatched|unknown)(?: foreground_effect=[a-z_]+)? status=(failed|unverified|preflight_corrected_not_performed)(?: preflight_rejection=[a-zA-Z]+)?$",
    );
    for record in records(raw, turn)? {
        let p = &record["payload"];
        let kind = record["type"].as_str().unwrap();
        let ptype = p["type"].as_str().unwrap_or("");
        if kind == "event_msg" && ptype == "task_started" {
            active = p["turn_id"].as_str().map(str::to_owned);
            if active.as_deref() == Some(turn) {
                seen = true;
                if start.is_none() {
                    start = stamp(&record["timestamp"]);
                }
            }
        }
        if kind == "turn_context" {
            active = p["turn_id"].as_str().map(str::to_owned);
            if active.as_deref() == Some(turn) {
                seen = true;
                model = Some(
                    p["model"]
                        .as_str()
                        .is_some_and(|model| model.to_lowercase().contains("qwen3.5-4b")),
                );
            }
        }
        if active.as_deref() != Some(turn) {
            continue;
        }
        selected += 1;
        if kind == "compacted" {
            compacted += 1;
            continue;
        }
        if kind == "event_msg" && ["task_complete", "task_aborted"].contains(&ptype) {
            ensure(p["turn_id"] == turn, "rollout_audit_failed_redacted")?;
            complete = ptype == "task_complete";
            end = stamp(&record["timestamp"]);
            completion = p["last_agent_message"].as_str().map(str::to_owned);
            active = None;
            continue;
        }
        if kind != "response_item" {
            continue;
        }
        if ptype == "message" && p["role"] == "assistant" {
            let text = p["content"]
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter(|item| {
                            [Some("output_text"), Some("text")].contains(&item["type"].as_str())
                        })
                        .filter_map(|item| item["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            let phase = p["phase"]
                .as_str()
                .filter(|phase| ["commentary", "final_answer", "final"].contains(phase))
                .unwrap_or("unspecified");
            messages.push((phase.into(), text));
            continue;
        }
        if ptype == "function_call" {
            let id = p["call_id"]
                .as_str()
                .ok_or(BenchmarkError("rollout_audit_failed_redacted"))?;
            ensure(
                id.len() <= 256 && !ids.contains_key(id) && calls.len() < 512,
                "rollout_audit_failed_redacted",
            )?;
            let args = p["arguments"]
                .as_str()
                .and_then(|text| parse(text.as_bytes()).ok())
                .or_else(|| p["arguments"].is_object().then(|| p["arguments"].clone()))
                .unwrap_or(json!({}));
            let action = args["ax_action"].as_str().filter(|action| {
                ["AXPress", "AXRaise", "AXConfirm", "AXShowMenu"].contains(action)
            });
            let name = p["name"].as_str().unwrap_or("");
            let index = calls.len();
            ids.insert(id.to_owned(), index);
            calls.push(json!({"number":index+1,"tool":known_tool(name,false),"requestedAction":action,"requestOffsetMs":stamp(&record["timestamp"]).zip(start).map(|(now,start)|now-start),"responseOffsetMs":null,"receiptLatencyMs":null,"outputs":0,"outputBytes":0,"sources":{"browser_clickability":0,"focusable_pointer":0},"markerObserved":false,"nativeFailure":false,"dispatch":null,"verification":false,"latestReceiptStatus":null,"errorIndicators":[]}));
            continue;
        }
        if ptype != "function_call_output" {
            continue;
        }
        let Some(index) = p["call_id"].as_str().and_then(|id| ids.get(id)).copied() else {
            orphan += 1;
            continue;
        };
        let call = &mut calls[index];
        inc(call, "outputs");
        if call["outputs"].as_u64().unwrap() > 1 {
            duplicates += 1;
        }
        if call["outputs"] == 1
            && let Some(delta) = stamp(&record["timestamp"])
                .zip(start)
                .map(|(now, start)| now - start)
        {
            call["responseOffsetMs"] = json!(delta);
            call["receiptLatencyMs"] = json!(
                call["requestOffsetMs"]
                    .as_i64()
                    .map(|request| delta - request)
            );
        }
        let Some(output) = receipt_text(&p["output"]) else {
            continue;
        };
        call["outputBytes"] = json!(call["outputBytes"].as_u64().unwrap() + output.len() as u64);
        let first = output
            .lines()
            .next()
            .unwrap_or("")
            .strip_prefix("Error: ")
            .unwrap_or(output.lines().next().unwrap_or(""));
        for (code, prefix) in [
            (
                "missing_baseline",
                "The action has no pre-action observation for comparison.",
            ),
            (
                "property_mismatch",
                "The expected property was not observed; the outcome remains unverified.",
            ),
            (
                "unchanged_property",
                "That property was already present before the action; it does not verify a changed outcome.",
            ),
            ("invalid_arguments", "Invalid computer V2 argument:"),
            ("unsupported_browser_action", "Unsupported browser action"),
            ("interrupted", "Tool execution was interrupted"),
        ] {
            if first.starts_with(prefix)
                && !call["errorIndicators"]
                    .as_array()
                    .unwrap()
                    .contains(&json!(code))
            {
                call["errorIndicators"]
                    .as_array_mut()
                    .unwrap()
                    .push(json!(code));
            }
        }
        if [
            "computer_v2_snapshot",
            "computer_v2_ax",
            "computer_v2_verify",
        ]
        .contains(&call["tool"].as_str().unwrap_or(""))
        {
            for row in output
                .lines()
                .filter(|line| re(r#"^#\d+ role=""#).is_match(line))
            {
                if let Some(source) = action_row.captures(row) {
                    inc(&mut call["sources"], &source[1]);
                }
            }
            call["markerObserved"] = json!(marker.is_some_and(|marker| output.contains(marker)));
        }
        if call["tool"] == "computer_v2_verify"
            && let Some(capture) = verified.captures(&output)
            && let Some(other) = ids.get(&capture[1])
        {
            calls[*other]["verification"] = json!(true);
        }
        let marker = format!("RUNTIME_ACTION_EVIDENCE turn={turn}");
        if let Some(checkpoint) = output
            .rfind(&marker)
            .filter(|offset| *offset == 0 || output.as_bytes()[offset - 1] == b'\n')
        {
            for row in output[checkpoint + marker.len()..].lines() {
                let Some(receipt) = runtime.captures(row) else {
                    continue;
                };
                let Some(other) = ids.get(&receipt[1]) else {
                    continue;
                };
                if calls[*other]["tool"] != receipt[2] {
                    continue;
                }
                let call = &mut calls[*other];
                call["dispatch"] = json!(&receipt[3]);
                call["latestReceiptStatus"] = json!(&receipt[4]);
                if &receipt[4] == "failed" {
                    call["nativeFailure"] = json!(true);
                }
            }
        }
    }
    ensure(seen, "rollout_audit_failed_redacted")?;
    let finals = messages
        .iter()
        .filter(|(phase, text)| {
            ["final_answer", "final"].contains(&phase.as_str())
                || completion.as_deref() == Some(text)
        })
        .collect::<Vec<_>>();
    Ok(
        json!({"schemaVersion":1,"readOnly":true,"redacted":true,"sourceSHA256":hash(raw),"selectedTurnSHA256":hash(turn),"selectedRecords":selected,"modelIsQwen4B":model,"turnComplete":complete,"durationMs":end.zip(start).map(|(end,start)|end-start),"compactions":compacted,"requestedTools":calls.iter().map(|call|call["tool"].clone()).collect::<Vec<_>>(),"counts":{"calls":calls.len(),"outputs":calls.iter().filter_map(|call|call["outputs"].as_u64()).sum::<u64>(),"nativeFailedOperations":calls.iter().filter(|call|call["nativeFailure"]==true).count(),"outputsWithRecognizedErrors":calls.iter().filter(|call|!call["errorIndicators"].as_array().unwrap().is_empty()).count(),"explicitlyDispatchedOperations":calls.iter().filter(|call|call["dispatch"]=="dispatched").count(),"verifiedProperties":calls.iter().filter(|call|call["verification"]==true).count(),"orphanOutputs":orphan,"duplicateOutputs":duplicates},"toolCalls":calls,"assistant":{"messages":messages.len(),"finalMessages":finals.len(),"finalBytes":finals.iter().map(|(_,text)|text.len()).sum::<usize>(),"completionMatchesFinal":completion.is_some()&&finals.iter().any(|(_,text)|completion.as_deref()==Some(text)),"expectedMarkerInFinal":marker.is_some_and(|marker|finals.iter().any(|(_,text)|text.contains(marker)))},"limitations":["Tool output alone is not a success or dispatch receipt.","Verified properties are not proof of whole-task completion or absence of search results.","Receipt latency is rollout timestamp difference, not a profiler measurement.","This rollout does not prove foreground, pointer or clipboard preservation."]}),
    )
}

type Header = BTreeMap<String, String>;
fn fields(line: &str, prefix: &str) -> Option<Header> {
    if !line.starts_with(&format!("{prefix} ")) || line.len() > 32768 {
        return None;
    }
    let mut tokens = vec![];
    let mut token = String::new();
    let (mut quoted, mut escaped) = (false, false);
    for character in line.chars() {
        if escaped {
            token.push(character);
            escaped = false;
            continue;
        }
        if character == '\\' && quoted {
            token.push(character);
            escaped = true;
            continue;
        }
        if character == '"' {
            quoted = !quoted;
            token.push(character);
            continue;
        }
        if character.is_whitespace() && !quoted {
            if !token.is_empty() {
                tokens.push(std::mem::take(&mut token));
            }
        } else {
            token.push(character);
        }
    }
    if quoted || escaped {
        return None;
    }
    if !token.is_empty() {
        tokens.push(token);
    }
    let mut header = Header::new();
    for token in tokens.into_iter().skip(1) {
        let (key, value) = token.split_once('=')?;
        if key.is_empty()
            || !key
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
            || value.is_empty()
            || header.insert(key.into(), value.into()).is_some()
        {
            return None;
        }
    }
    Some(header)
}
fn hnumber(header: &Header, key: &str) -> Value {
    header
        .get(key)
        .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|value| *value <= 9_007_199_254_740_991)
        .map_or(Value::Null, |value| json!(value))
}
fn hbit(header: &Header, key: &str) -> Value {
    match header.get(key).map(String::as_str) {
        Some("1") => json!(true),
        Some("0") => json!(false),
        _ => Value::Null,
    }
}
fn is(header: &Header, key: &str, values: &[&str]) -> bool {
    header
        .get(key)
        .is_some_and(|value| values.contains(&value.as_str()))
}
fn cursor(value: Option<&str>, terminal: &[&str]) -> Option<Option<String>> {
    value.and_then(|value| {
        if uuid(value) {
            Some(Some(value.to_lowercase()))
        } else if terminal.contains(&value) {
            Some(None)
        } else {
            None
        }
    })
}
struct ReadReceipt {
    kind: &'static str,
    next: Option<String>,
    snapshot: Option<String>,
    metrics: Value,
}
fn inventory(text: &str) -> Option<ReadReceipt> {
    let value = parse(text.as_bytes()).ok()?;
    let returned = count(&value["returned"])?;
    let total = count(&value["total_count"])?;
    let items = value["items"].as_array()?;
    if !value.is_object()
        || value["continuation_tool"] != "computer_v2_continue"
        || !value["metadata_notice"].is_string()
        || returned != items.len() as u64
        || returned > 100
        || total > 2048
        || total < returned
        || !(value["next_cursor"].is_null() || value["next_cursor"].as_str().is_some_and(uuid))
        || returned == 0 && (total != 0 || !value["next_cursor"].is_null())
    {
        return None;
    }
    let mut tokens = std::collections::HashSet::new();
    let (mut titles, mut urls) = (0, 0);
    for item in items {
        let token = item["candidate_token"].as_str()?;
        if !item.is_object()
            || !uuid(token)
            || !tokens.insert(token.to_lowercase())
            || !item["title"].is_string()
            || !item["title_truncated"].is_boolean()
            || !item["availability"].is_string()
            || !(item["url"].is_string() || item["url_omitted"] == true)
        {
            return None;
        }
        titles += usize::from(item["title_truncated"] == true);
        urls += usize::from(item["url_omitted"] == true);
    }
    Some(ReadReceipt {
        kind: "inventory",
        next: value["next_cursor"].as_str().map(str::to_lowercase),
        snapshot: None,
        metrics: json!({"returned":returned,"reportedTotal":total,"truncatedTitles":titles,"omittedURLs":urls}),
    })
}
const NATIVE_WRAPPERS: [&str; 2] = [
    "NATIVE_AX scope=bound_window activation=none. Semantic AX/set_value only; global key/pointer tools are unavailable in this background binding. Read-only images grant no input authority. Dispatch is not outcome verification.",
    "NATIVE_AX scope=bound_window activation=none verification_read=true. Fresh references only; hidden elements are not action targets. This read never dispatches input.",
];
fn semantic(text: &str) -> Option<ReadReceipt> {
    let lines = text.split('\n').take(4).collect::<Vec<_>>();
    let offset = usize::from(
        lines
            .first()
            .is_some_and(|line| NATIVE_WRAPPERS.contains(line)),
    );
    let native = fields(lines.get(offset).copied().unwrap_or(""), "SEMANTIC_READ");
    let snapshot = fields(
        lines
            .get(offset + usize::from(native.is_some()))
            .copied()
            .unwrap_or(""),
        "AXSNAPSHOT",
    )?;
    let id = snapshot.get("id")?.clone();
    if !uuid(&id) {
        return None;
    }
    if let Some(native) = native {
        let next = cursor(native.get("next_cursor").map(String::as_str), &["-"])?;
        if !is(&native, "view", &["all", "content", "headings", "links"])
            || !is(&native, "consistency", &["live_validated_page"])
            || !is(
                &native,
                "query_status",
                &["matched", "no_matches_in_visited_source", "not_requested"],
            )
        {
            return None;
        }
        let mut metrics = json!({"view":native["view"],"visited":hnumber(&native,"visited"),"matched":hnumber(&native,"matched"),"offset":hnumber(&native,"offset"),"shown":hnumber(&native,"shown"),"sourceTruncated":hbit(&native,"source_truncated"),"outputTruncated":hbit(&native,"output_truncated"),"sourceLimitReached":hbit(&native,"source_limit_reached"),"queryStatus":native["query_status"],"observation":"live_validated_page"});
        if metrics.as_object()?.values().any(Value::is_null) {
            return None;
        }
        metrics["fieldTruncated"] = hbit(&native, "field_truncated");
        if native.contains_key("field_truncated") && metrics["fieldTruncated"].is_null() {
            return None;
        }
        return Some(ReadReceipt {
            kind: "native",
            next,
            snapshot: Some(id),
            metrics,
        });
    }
    if is(&snapshot, "source", &["chrome_devtools"]) && offset == 0 {
        let read = fields(lines.get(1).copied().unwrap_or(""), "READ")?;
        let evidence = fields(lines.get(2).copied().unwrap_or(""), "CONTENT_EVIDENCE");
        if !is(
            &read,
            "view",
            &["overview", "all", "content", "headings", "links"],
        ) || !is(&read, "observation", &["live", "retained"])
            || !is(&read, "visibility", &["unknown"])
        {
            return None;
        }
        let next = cursor(read.get("next_cursor").map(String::as_str), &["none"])?;
        let mut metrics = json!({"view":read["view"],"sourceNodes":hnumber(&read,"source_nodes"),"matches":hnumber(&read,"matches"),"shown":hnumber(&read,"shown"),"offset":hnumber(&read,"offset"),"sourceTruncated":hbit(&read,"source_truncated"),"outputTruncated":hbit(&read,"output_truncated"),"fieldTruncated":hbit(&read,"field_truncated"),"noMatches":hbit(&read,"no_matches"),"observation":read["observation"]});
        if metrics.as_object()?.values().any(Value::is_null) {
            return None;
        }
        metrics["metadataTruncated"] = hbit(&read, "metadata_truncated");
        if read.contains_key("metadata_truncated") && metrics["metadataTruncated"].is_null() {
            return None;
        }
        if read.contains_key("consistency")
            && (!is(&read, "consistency", &["immutable_capture"])
                || !read
                    .get("source_observation")
                    .is_some_and(|value| uuid(value)))
        {
            return None;
        }
        metrics["consistency"] = read
            .get("consistency")
            .map_or(Value::Null, |value| json!(value));
        metrics["reportedStructuralCounts"] = Value::Null;
        metrics["reportedContentKindCounts"] = Value::Null;
        if let Some(evidence) = evidence.filter(|evidence| {
            is(evidence, "scope_basis", &["observed_ancestry"])
                && is(evidence, "subject_relevance", &["not_verified"])
        }) {
            let shown = metrics["shown"].as_u64()?;
            let kinds = ["readable_shown", "controls_shown", "metadata_shown"];
            let mut values = serde_json::Map::new();
            for name in kinds {
                values.insert(name.into(), hnumber(&evidence, name));
            }
            let kinds_present = kinds.iter().any(|name| evidence.contains_key(*name));
            if values.values().all(|value| !value.is_null())
                && values.values().filter_map(Value::as_u64).sum::<u64>() <= shown
            {
                metrics["reportedContentKindCounts"] = Value::Object(values);
            }
            let names = [
                "document_content_shown",
                "navigation_shown",
                "complementary_shown",
                "banner_shown",
                "contentinfo_shown",
                "unknown_shown",
            ];
            let mut values = serde_json::Map::new();
            for name in names {
                values.insert(name.into(), hnumber(&evidence, name));
            }
            let total = values.values().filter_map(Value::as_u64).sum::<u64>();
            if values.values().all(|value| !value.is_null())
                && if kinds_present {
                    !metrics["reportedContentKindCounts"].is_null() && total <= shown
                } else {
                    total == shown
                }
            {
                metrics["reportedStructuralCounts"] = Value::Object(values);
            }
        }
        return Some(ReadReceipt {
            kind: "browser",
            next,
            snapshot: Some(id),
            metrics,
        });
    }
    let mut metrics = json!({"shown":hnumber(&snapshot,"shown"),"capturedNodes":hnumber(&snapshot,"total"),"sourceTruncated":hbit(&snapshot,"source_truncated"),"outputTruncated":hbit(&snapshot,"output_truncated")});
    if snapshot.contains_key("source") || metrics.as_object()?.values().any(Value::is_null) {
        return None;
    }
    metrics["continuationMeasured"] = json!(false);
    metrics["fieldTruncated"] = Value::Null;
    Some(ReadReceipt {
        kind: "native",
        next: None,
        snapshot: Some(id),
        metrics,
    })
}
struct Wrapper {
    kind: &'static str,
    snapshot: Option<String>,
}
fn post_wrapper(line: &str, call: &str) -> Option<Wrapper> {
    let verified =
        re(r"(?i)^VERIFIED_PROPERTY operation_id=(\S+) snapshot_id=([0-9a-f-]{36})\. (.+)$");
    if let Some(value) = verified.captures(line) {
        let messages = [
            "The predeclared postcondition matched a fresh observation. No input was repeated. This verifies only that property, not an entire task or absent search results.",
            "Only the predeclared result region's displayed text changed. Read the returned content to establish what changed; this does not prove pagination or task success. No input was repeated. This verifies only that property, not an entire task or absent search results.",
            "The predeclared native property matched a fresh read of the exact bound window. No input was repeated. Selection or a detail heading does not prove message sender, incoming direction, or latest ordering.",
        ];
        if &value[1] == call && uuid(&value[2]) && messages.contains(&&value[3]) {
            return Some(Wrapper {
                kind: "verified",
                snapshot: Some(value[2].into()),
            });
        }
    }
    if let Some(value) = re(r"^ALREADY_SATISFIED operation_id=(\S+)\. (.+)$").captures(line)
        && &value[1] == call
        && &value[2]
            == "The requested native property was already present and remained present in a fresh read. No approval or input was dispatched. Read the current content; this is not proof of message sender or ordering."
    {
        return Some(Wrapper {
            kind: "already_satisfied",
            snapshot: None,
        });
    }
    if let Some(value) = re(r"^VERIFICATION_PENDING operation_id=(\S+)\. (.*)$").captures(line)
        && &value[1]==call&&["The bounded read-only verification did not establish the declared result. No input was repeated. Do not change the postcondition or repeat the action. ","Bounded read-only observation could not establish the original native result. No input was replayed. Do not repeat input or change the postcondition. "].iter().any(|message|value[2].starts_with(message)){return Some(Wrapper{kind:"pending",snapshot:None});
    }
    None
}
fn oversized(text: &str) -> bool {
    let lines = text.split('\n').take(4).collect::<Vec<_>>();
    let offset = usize::from(
        lines
            .first()
            .is_some_and(|line| line.starts_with("NATIVE_AX scope=bound_window ")),
    );
    let first = lines.get(offset).copied().unwrap_or("");
    if !(first.starts_with("AXSNAPSHOT id=") || first.starts_with("SEMANTIC_READ ")) {
        return false;
    }
    let second = lines.get(offset + 1).copied().unwrap_or("");
    first.len() > 32768
        || (second.starts_with("READ ") || second.starts_with("AXSNAPSHOT id="))
            && second.len() > 32768
}
fn coverage(output: &Value) -> (Value, bool) {
    let summary = |value: &str| {
        value.len()<=128&&re(r"^READ_COVERAGE scopes=\d+ captured=\d+ partial=\d+ unknown=\d+ source_cut=\d+ output_cut=\d+ field_cut=\d+ dropped=[01]$").is_match(value)
    };
    if let Some(items) = output.as_array()
        && items.first().is_some_and(|item| {
            item["type"] == "input_text" && item["text"].as_str().is_some_and(summary)
        })
    {
        return (json!(&items[1..]), true);
    }
    if let Some(text) = output.as_str() {
        let (first, rest) = text.split_once('\n').unwrap_or((text, ""));
        if summary(first) {
            return (json!(rest), true);
        }
    }
    (output.clone(), false)
}
struct ParsedReceipt {
    read: Option<ReadReceipt>,
    framing: Option<&'static str>,
    unmeasured: bool,
    oversized: bool,
}
fn semantic_receipt(output: &Value, tool: &str, call: &str) -> ParsedReceipt {
    let mut output = output.clone();
    if POST_TOOLS.contains(&tool)&&let Some(items)=output.as_array()&&items.len()>=2&&items[0]["type"]=="input_text"&&items[1]["type"]=="input_text"&&items[0]["text"].as_str().is_some_and(|text|text.len()<=32768&&re(r"^Requested [^\r\n]+ on the exact bound (?:browser tab|native window)\. Input was dispatched once\.$").is_match(text))&&items[1]["text"].as_str().is_some_and(|text|post_wrapper(text.split('\n').next().unwrap_or(""),call).is_some()){output=json!(&items[1..]);}
    let first = output
        .as_str()
        .or_else(|| {
            output
                .as_array()
                .and_then(|items| items.first())
                .filter(|item| item["type"] == "input_text")
                .and_then(|item| item["text"].as_str())
        })
        .unwrap_or("");
    let follow = ["computer_v2_follow_link", "computer_v2_follow"].contains(&tool);
    if let Some(read) = semantic(first).filter(|read| !follow || read.kind == "browser") {
        return ParsedReceipt {
            read: Some(read),
            framing: Some("standalone"),
            unmeasured: false,
            oversized: false,
        };
    }
    let (first_line, rest) = first.split_once('\n').unwrap_or((first, ""));
    let wrapper = POST_TOOLS
        .contains(&tool)
        .then(|| post_wrapper(first_line, call))
        .flatten();
    let Some(wrapper) = wrapper else {
        return ParsedReceipt {
            read: None,
            framing: None,
            unmeasured: false,
            oversized: oversized(first),
        };
    };
    let observation = if wrapper.kind != "pending" && first.contains('\n') {
        Some(rest)
    } else {
        output
            .as_array()
            .and_then(|items| items.get(1))
            .filter(|item| item["type"] == "input_text")
            .and_then(|item| item["text"].as_str())
    };
    let read = observation.and_then(semantic).filter(|read| {
        (!follow || read.kind == "browser")
            && wrapper.snapshot.as_ref().is_none_or(|snapshot| {
                read.snapshot
                    .as_ref()
                    .is_some_and(|value| value.eq_ignore_ascii_case(snapshot))
            })
    });
    let unmeasured = read.is_none();
    ParsedReceipt {
        read,
        framing: Some("post_action"),
        unmeasured,
        oversized: observation.is_some_and(oversized),
    }
}

pub fn summarize_lookup(raw: &str, turn: &str) -> Result<Value> {
    let (mut active, mut seen, mut terminal) = (None, false, false);
    let (mut start, mut end) = (None, None);
    let mut status = "unknown";
    let mut model = None;
    let (mut selected, mut checkpoints, mut notifications) = (0, 0, 0);
    let (
        mut orphan_outputs,
        mut duplicate_outputs,
        mut orphan_results,
        mut duplicate_results,
        mut invalid_results,
    ) = (0, 0, 0, 0, 0);
    let (mut final_messages, mut final_bytes) = (0, 0);
    let mut last_assistant: Option<(Option<String>, usize, bool)> = None;
    let (mut terminal_digest, mut terminal_bytes) = (None, None);
    let mut issued: HashMap<String, &str> = HashMap::new();
    let mut ids: HashMap<String, usize> = HashMap::new();
    let mut calls: Vec<Value> = vec![];
    let mut original_tools: Vec<String> = vec![];
    for record in records(raw, turn)? {
        let p = &record["payload"];
        let kind = record["type"].as_str().unwrap();
        let ptype = p["type"].as_str().unwrap_or("");
        if kind == "event_msg" && ["task_started", "turn_started"].contains(&ptype) {
            active = p["turn_id"].as_str().map(str::to_owned);
            if active.as_deref() == Some(turn) && !terminal {
                seen = true;
                if start.is_none() {
                    start = stamp(&record["timestamp"]);
                }
            }
        }
        if kind == "turn_context" {
            active = p["turn_id"].as_str().map(str::to_owned);
            if active.as_deref() == Some(turn) && !terminal {
                seen = true;
                if let Some(name) = p["model"].as_str() {
                    let selected = name == MODEL;
                    model = Some(model.unwrap_or(true) && selected);
                }
            }
        }
        if active.as_deref() != Some(turn)
            || terminal
            || p["turn_id"].as_str().is_some_and(|id| id != turn)
        {
            continue;
        }
        selected += 1;
        if kind == "compacted" {
            checkpoints += 1;
            continue;
        }
        if kind == "event_msg" && ptype == "context_compacted" {
            notifications += 1;
            continue;
        }
        if kind == "event_msg"
            && ["task_complete", "turn_complete", "turn_aborted"].contains(&ptype)
        {
            if p["turn_id"] != turn {
                continue;
            }
            status = if ptype == "turn_aborted" {
                "aborted"
            } else if !p["error"].is_null() {
                "failed"
            } else {
                "completed"
            };
            if ptype != "turn_aborted"
                && let Some(text) = p["last_agent_message"].as_str()
            {
                terminal_digest = Some(hash(text));
                terminal_bytes = Some(text.len());
            }
            terminal = true;
            end = stamp(&record["timestamp"]);
            active = None;
            continue;
        }
        if kind == "event_msg" && ptype == "dynamic_tool_call_response" {
            let Some(index) = p["call_id"].as_str().and_then(|id| ids.get(id)).copied() else {
                orphan_results += 1;
                continue;
            };
            if p["turn_id"] != turn
                || p["tool"] != original_tools[index]
                || !p["success"].is_boolean()
            {
                invalid_results += 1;
                continue;
            }
            let call = &mut calls[index];
            if call["resultEvents"].as_u64().unwrap() > 0 {
                duplicate_results += 1;
            }
            inc(call, "resultEvents");
            let result = if p["success"] == true {
                "success"
            } else {
                "failure"
            };
            call["toolResult"] = json!(if call["toolResult"] == "unknown"
                || call["toolResult"] == result
            {
                result
            } else {
                "conflicting"
            });
            continue;
        }
        if kind != "response_item" {
            continue;
        }
        if ptype == "message" && p["role"] == "assistant" {
            let items = p["content"].as_array();
            let text_items = items
                .map(|items| {
                    items
                        .iter()
                        .filter(|item| {
                            item.is_object()
                                && [Some("text"), Some("output_text")]
                                    .contains(&item["type"].as_str())
                                && item["text"].is_string()
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let text = text_items
                .iter()
                .filter_map(|item| item["text"].as_str())
                .collect::<Vec<_>>()
                .concat();
            let text_only =
                items.is_some_and(|items| !items.is_empty() && items.len() == text_items.len());
            last_assistant = Some((
                (text_only && !text.is_empty()).then(|| hash(&text)),
                text.len(),
                p["phase"].is_null(),
            ));
            if p["phase"]
                .as_str()
                .is_some_and(|phase| ["final_answer", "final"].contains(&phase))
            {
                final_messages += 1;
                final_bytes += text.len();
            }
            continue;
        }
        if ptype == "function_call" {
            let id = p["call_id"]
                .as_str()
                .ok_or(BenchmarkError("lookup_audit_failed_redacted"))?;
            let name = p["name"]
                .as_str()
                .ok_or(BenchmarkError("lookup_audit_failed_redacted"))?;
            ensure(
                !id.is_empty() && id.len() <= 256 && !ids.contains_key(id) && calls.len() < 512,
                "lookup_audit_failed_redacted",
            )?;
            let args = p["arguments"]
                .as_str()
                .and_then(|text| parse(text.as_bytes()).ok())
                .filter(Value::is_object);
            let requested_cursor = args
                .as_ref()
                .and_then(|args| args["cursor"].as_str())
                .filter(|value| uuid(value))
                .map(str::to_lowercase);
            let index = calls.len();
            ids.insert(id.to_owned(), index);
            original_tools.push(name.into());
            calls.push(json!({"number":index+1,"tool":known_tool(name,true),"requestKind":if input_tool(name){"input"}else if ["computer_v2_tabs","computer_v2_snapshot","computer_v2_continue","computer_v2_read_page","computer_v2_read_region"].contains(&name){"read"}else{"other"},"argumentsParsed":args.is_some(),"requestedView":args.as_ref().and_then(|args|args["view"].as_str()).filter(|view|["overview","all","content","headings","links"].contains(view)),"continuationRequested":name=="computer_v2_continue"||requested_cursor.is_some(),"previouslyObservedCursorSource":requested_cursor.as_ref().and_then(|cursor|issued.get(cursor)),"requestOffsetMs":difference(stamp(&record["timestamp"]),start),"responseOffsetMs":null,"receiptLatencyMs":null,"outputs":0,"resultEvents":0,"toolResult":"unknown","readObservation":null,"outputShapeRecognized":null,"postActionObservationUnmeasured":false,"semanticHeaderBudgetRejected":false,"coverageSummaryObserved":false}));
            continue;
        }
        if ptype != "function_call_output" {
            continue;
        }
        let Some(index) = p["call_id"].as_str().and_then(|id| ids.get(id)).copied() else {
            orphan_outputs += 1;
            continue;
        };
        let call = &mut calls[index];
        let previous = call["outputs"].as_u64().unwrap();
        inc(call, "outputs");
        if previous > 0 {
            duplicate_outputs += 1;
            continue;
        }
        call["responseOffsetMs"] = json!(difference(stamp(&record["timestamp"]), start));
        call["receiptLatencyMs"] = json!(difference(
            call["responseOffsetMs"].as_i64(),
            call["requestOffsetMs"].as_i64()
        ));
        let text = receipt_text(&p["output"]);
        call["outputShapeRecognized"] = json!(text.is_some());
        let tool = call["tool"].as_str().unwrap().to_owned();
        if text.is_none() || !read_tool(&tool) {
            continue;
        }
        let (output, observed) = coverage(&p["output"]);
        call["coverageSummaryObserved"] = json!(observed);
        let metadata = ["computer_v2_tabs", "computer_v2_continue"]
            .contains(&tool.as_str())
            .then(|| inventory(&receipt_text(&output).unwrap_or_default()))
            .flatten();
        let parsed = if let Some(read) = metadata {
            ParsedReceipt {
                read: Some(read),
                framing: Some("standalone"),
                unmeasured: false,
                oversized: false,
            }
        } else {
            semantic_receipt(&output, &tool, p["call_id"].as_str().unwrap())
        };
        call["postActionObservationUnmeasured"] = json!(parsed.unmeasured);
        call["semanticHeaderBudgetRejected"] = json!(parsed.oversized);
        let Some(read) = parsed
            .read
            .filter(|read| tool != "computer_v2_tabs" || read.kind == "inventory")
        else {
            continue;
        };
        let mut observation = read.metrics;
        observation["kind"] = json!(read.kind);
        observation["framing"] = json!(parsed.framing);
        observation["continuationOffered"] = json!(read.next.is_some());
        call["readObservation"] = observation;
        if let Some(next) = read.next {
            issued.insert(next, read.kind);
        }
    }
    ensure(seen, "lookup_audit_failed_redacted")?;
    let matches = terminal_digest
        .as_ref()
        .zip(
            last_assistant
                .as_ref()
                .and_then(|(digest, _, _)| digest.as_ref()),
        )
        .map(|(terminal, last)| terminal == last);
    let mut basis = if final_messages > 0 {
        "explicit_phase"
    } else {
        "unmeasured"
    };
    if final_messages == 0
        && status == "completed"
        && last_assistant
            .as_ref()
            .is_some_and(|(_, _, unphased)| *unphased)
        && matches == Some(true)
    {
        final_messages = 1;
        final_bytes = last_assistant.as_ref().unwrap().1;
        basis = "matching_terminal_message";
    }
    let outcomes = |kind: Option<&str>| {
        let selected = calls
            .iter()
            .filter(|call| kind.is_none_or(|kind| call["requestKind"] == kind))
            .collect::<Vec<_>>();
        json!({"calls":selected.len(),"success":selected.iter().filter(|call|call["toolResult"]=="success").count(),"failure":selected.iter().filter(|call|call["toolResult"]=="failure").count(),"unknown":selected.iter().filter(|call|call["toolResult"]=="unknown").count(),"conflicting":selected.iter().filter(|call|call["toolResult"]=="conflicting").count()})
    };
    let observations = calls
        .iter()
        .filter(|call| !call["readObservation"].is_null())
        .collect::<Vec<_>>();
    Ok(
        json!({"schemaVersion":1,"readOnly":true,"redacted":true,"sourceSHA256":hash(raw),"selectedTurnSHA256":hash(turn),"selectedRecords":selected,"modelIsQwen4B":model,"turn":{"status":status,"terminalObserved":terminal,"elapsedMs":difference(end,start)},"compactions":{"checkpointRecords":checkpoints,"notificationEvents":notifications},"outcomes":{"all":outcomes(None),"readRequests":outcomes(Some("read")),"inputRequests":outcomes(Some("input"))},"integrity":{"orphanOutputs":orphan_outputs,"duplicateOutputs":duplicate_outputs,"orphanResults":orphan_results,"duplicateResults":duplicate_results,"invalidResults":invalid_results},"reading":{"inventoryReceiptOccurrences":observations.iter().filter(|call|call["readObservation"]["kind"]=="inventory").count(),"browserSemanticReceiptOccurrences":observations.iter().filter(|call|call["readObservation"]["kind"]=="browser").count(),"nativeSemanticReceiptOccurrences":observations.iter().filter(|call|call["readObservation"]["kind"]=="native").count(),"postActionSemanticReceiptOccurrences":observations.iter().filter(|call|call["readObservation"]["framing"]=="post_action").count(),"postActionObservationsUnmeasured":calls.iter().filter(|call|call["postActionObservationUnmeasured"]==true).count(),"semanticHeaderBudgetRejectedOutputs":calls.iter().filter(|call|call["semanticHeaderBudgetRejected"]==true).count(),"coverageSummaryOccurrences":calls.iter().filter(|call|call["coverageSummaryObserved"]==true).count(),"continuationRequests":calls.iter().filter(|call|call["continuationRequested"]==true).count(),"genericContinuationRequests":calls.iter().filter(|call|call["tool"]=="computer_v2_continue").count(),"continuationRequestsWithPreviouslyObservedCursor":calls.iter().filter(|call|call["continuationRequested"]==true&&!call["previouslyObservedCursorSource"].is_null()).count(),"continuationRequestsReturningReadReceipt":observations.iter().filter(|call|call["continuationRequested"]==true).count(),"uniqueDocumentsRead":null,"exhaustiveInventoryCoverage":null,"exhaustiveDocumentCoverage":null},"answer":{"finalMessages":final_messages,"finalBytes":final_bytes,"finalMessageBasis":basis,"terminalMessagePresent":terminal_digest.is_some(),"terminalMessageBytes":terminal_bytes,"completionMatchesLastAssistantMessage":matches,"semanticSupport":"unmeasured","correctness":"unmeasured","unsupportedClaims":null,"refusal":"unmeasured"},"toolCalls":calls,"limitations":["Tool success/failure requires a correlated dynamic_tool_call_response event; output strings and arrays omit that flag.","A host-shaped read receipt is an observation, not proof of tool success, readable content, relevance or task completion.","Counts are receipt occurrences. Captures, filters, subtrees and repeated pages are never combined into exhaustive coverage.","Observed cursor linkage is historical, not proof that the cursor remains authorized, current or accepted.","Post-action reads require an exact host wrapper and a safe observation boundary; flattened pending diagnostics are unmeasured.","Semantic headers are bounded to 32 KiB each; oversized or unrecognized framing leaves the read observation null.","READ_COVERAGE is recognized only as an exact bounded first block/line; its historical counts never create read observations or completeness claims.","Checkpoint records and compaction notifications are reported separately and must not be added together.","An unphased final response is counted only when the completed turn's terminal message exactly matches its last assistant response; terminal-only text is reported separately.","Timing is rollout timestamp difference; terminal completion is not answer correctness. Unmeasured values require separate review."]}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    const TURN: &str = "11111111-1111-4111-8111-111111111111";
    const ID: &str = "22222222-2222-4222-8222-222222222222";
    fn row(kind: &str, payload: Value) -> Value {
        json!({"type":kind,"payload":payload,"timestamp":"2026-09-27T00:00:00Z"})
    }
    fn response(payload: Value) -> Value {
        row("response_item", payload)
    }
    fn start() -> Vec<Value> {
        vec![
            row("event_msg", json!({"type":"task_started","turn_id":TURN})),
            row("turn_context", json!({"turn_id":TURN,"model":MODEL})),
        ]
    }
    fn call(id: &str, tool: &str, args: Value) -> Value {
        response(
            json!({"type":"function_call","call_id":id,"name":tool,"arguments":args.to_string()}),
        )
    }
    fn output(id: &str, body: Value) -> Value {
        response(json!({"type":"function_call_output","call_id":id,"output":body}))
    }
    fn raw(records: Vec<Value>) -> String {
        records
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn browser(next: &str) -> String {
        format!(
            "AXSNAPSHOT id={ID} source=chrome_devtools title=\"PRIVATE_EMAIL\"\nREAD view=content source_nodes=8 matches=2 shown=2 offset=0 source_truncated=0 output_truncated=0 field_truncated=0 no_matches=0 observation=live visibility=unknown next_cursor={next}\nCONTENT_EVIDENCE scope_basis=observed_ancestry subject_relevance=not_verified readable_shown=1 controls_shown=1 metadata_shown=0 document_content_shown=1 navigation_shown=0 complementary_shown=0 banner_shown=0 contentinfo_shown=0 unknown_shown=0\n#2 role=\"AXStaticText\" value=\"PRIVATE_BODY\""
        )
    }
    #[test]
    fn clickability_requires_host_dispatch_checkpoint_and_actual_verification_tool() {
        let mut records = start();
        records.extend([
            call("snapshot","computer_v2_snapshot",json!({})),output("snapshot",json!("#1 role=\"AXGroup\" label=\"PRIVATE_LABEL\" actions=[\"AXPress\"] press_source=focusable_pointer")),
            call("click","computer_v2_ax",json!({"ax_action":"AXPress","text":"PRIVATE_ARGUMENT"})),output("click",json!(format!("Requested.\nRUNTIME_ACTION_EVIDENCE turn={TURN}\noperation=click tool=computer_v2_ax dispatch=dispatched status=unverified"))),
            call("verify","computer_v2_verify",json!({})),output("verify",json!([{"type":"input_text","text":"VERIFIED_PROPERTY operation_id=click snapshot_id=private. Matched.\nMACTOPUS_CLICKABILITY_OK"},{"type":"input_image","image_url":"PRIVATE_IMAGE"}])),
            response(json!({"type":"message","role":"assistant","phase":"final","content":[{"type":"output_text","text":"MACTOPUS_CLICKABILITY_OK"}]})),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":TURN,"last_agent_message":"MACTOPUS_CLICKABILITY_OK"},"timestamp":"2026-09-27T00:00:12Z"})]);
        let audit =
            summarize_clickability(&raw(records), TURN, Some("MACTOPUS_CLICKABILITY_OK")).unwrap();
        assert_eq!(audit["durationMs"], 12000);
        assert_eq!(audit["toolCalls"][0]["sources"]["focusable_pointer"], 1);
        assert_eq!(audit["toolCalls"][1]["dispatch"], "dispatched");
        assert_eq!(audit["counts"]["verifiedProperties"], 1);
        assert_eq!(audit["assistant"]["expectedMarkerInFinal"], true);
        let serialized = audit.to_string();
        assert!(!serialized.contains("PRIVATE"));
        assert!(!serialized.contains("MACTOPUS_CLICKABILITY_OK"));
    }
    #[test]
    fn clickability_never_promotes_claims_duplicate_outputs_or_retained_history() {
        let mut records = start();
        records.extend([
            row(
                "compacted",
                json!({"replacement_history":[call("retained","computer_v2_ax",json!({}))]}),
            ),
            call("click", "computer_v2_ax", json!({})),
            output(
                "click",
                json!("VERIFIED_PROPERTY operation_id=click snapshot_id=fake. Success."),
            ),
            output("click", json!("duplicate")),
            output("missing", json!("PRIVATE_ORPHAN")),
        ]);
        let audit = summarize_clickability(&raw(records), TURN, None).unwrap();
        assert_eq!(audit["counts"]["calls"], 1);
        assert_eq!(audit["counts"]["duplicateOutputs"], 1);
        assert_eq!(audit["counts"]["orphanOutputs"], 1);
        assert_eq!(audit["counts"]["verifiedProperties"], 0);
        assert_eq!(audit["compactions"], 1);
        assert_eq!(audit["turnComplete"], false);
        assert!(audit["toolCalls"][0]["dispatch"].is_null());
    }
    #[test]
    fn lookup_receipts_are_observations_and_only_correlated_result_events_prove_tool_result() {
        let mut records = start();
        records.extend([call("read","computer_v2_read_page",json!({"view":"content"})),output("read",json!(browser(ID))),row("event_msg",json!({"type":"dynamic_tool_call_response","turn_id":TURN,"call_id":"read","tool":"computer_v2_read_page","success":true})),call("next","computer_v2_continue",json!({"cursor":ID})),output("next",json!(browser("none")))]);
        let audit = summarize_lookup(&raw(records), TURN).unwrap();
        assert_eq!(audit["outcomes"]["readRequests"]["success"], 1);
        assert_eq!(audit["outcomes"]["readRequests"]["unknown"], 1);
        assert_eq!(audit["reading"]["browserSemanticReceiptOccurrences"], 2);
        assert_eq!(
            audit["reading"]["continuationRequestsWithPreviouslyObservedCursor"],
            1
        );
        assert_eq!(
            audit["toolCalls"][1]["previouslyObservedCursorSource"],
            "browser"
        );
        assert!(audit["reading"]["exhaustiveDocumentCoverage"].is_null());
        assert!(!audit.to_string().contains("PRIVATE"));
    }
    #[test]
    fn malformed_or_source_spoofed_headers_do_not_create_read_observations() {
        let valid = browser("none");
        assert!(semantic(&valid).is_some());
        for text in [
            valid.replace("shown=2", "shown=2 shown=2"),
            valid.replace("visibility=unknown", "visibility=verified"),
            format!("PRIVATE_PREFIX\n{valid}"),
            valid.replace(
                "subject_relevance=not_verified",
                "subject_relevance=verified",
            ),
        ] {
            let mut records = start();
            records.extend([
                call("read", "computer_v2_snapshot", json!({})),
                output("read", json!(text)),
            ]);
            let audit = summarize_lookup(&raw(records), TURN).unwrap();
            if audit["toolCalls"][0]["readObservation"].is_object() {
                assert!(
                    audit["toolCalls"][0]["readObservation"]["reportedStructuralCounts"].is_null()
                );
            } else {
                assert_eq!(audit["reading"]["browserSemanticReceiptOccurrences"], 0);
            }
        }
        let spoof = "AXSNAPSHOT id=22222222-2222-4222-8222-222222222222 source=chrome_devtools title=\"shown=2 next_cursor=none\"\nREAD view=content source_nodes=8 matches=2 shown=2 offset=0 source_truncated=0 output_truncated=0 field_truncated=0 no_matches=0 observation=live visibility=unknown next_cursor=none";
        assert!(semantic(spoof).is_some());
        assert!(fields("READ view=\"malformed", "READ").is_none());
    }
    #[test]
    fn pending_post_action_diagnostics_need_a_preserved_typed_observation_boundary() {
        let pending = "VERIFICATION_PENDING operation_id=press. The bounded read-only verification did not establish the declared result. No input was repeated. Do not change the postcondition or repeat the action. PRIVATE_DIAGNOSTIC";
        let valid = browser("none");
        let flattened = semantic_receipt(
            &json!(format!("{pending}\n{valid}")),
            "computer_v2_press",
            "press",
        );
        assert!(flattened.read.is_none());
        assert!(flattened.unmeasured);
        let typed = semantic_receipt(
            &json!([{"type":"input_text","text":pending},{"type":"input_text","text":valid}]),
            "computer_v2_press",
            "press",
        );
        assert!(typed.read.is_some());
        assert_eq!(typed.framing, Some("post_action"));
        let wrong = semantic_receipt(
            &json!([{"type":"input_text","text":pending},{"type":"input_text","text":browser("none")}]),
            "computer_v2_press",
            "another",
        );
        assert!(wrong.read.is_none());
    }
    #[test]
    fn final_unphased_message_requires_exact_last_message_terminal_match() {
        let mut records = start();
        records.extend([response(json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"PRIVATE_"},{"type":"output_text","text":"FINAL"}]})),row("event_msg",json!({"type":"turn_complete","turn_id":TURN,"last_agent_message":"PRIVATE_FINAL"}))]);
        let audit = summarize_lookup(&raw(records), TURN).unwrap();
        assert_eq!(audit["answer"]["finalMessages"], 1);
        assert_eq!(
            audit["answer"]["finalMessageBasis"],
            "matching_terminal_message"
        );
        assert_eq!(audit["answer"]["finalBytes"], 13);
        assert!(!audit.to_string().contains("PRIVATE"));
        let mut records = start();
        records.extend([response(json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"PRIVATE_FINAL"}]})),response(json!({"type":"message","role":"assistant","content":[{"type":"output_text","text":"DIFFERENT"}]})),row("event_msg",json!({"type":"turn_complete","turn_id":TURN,"last_agent_message":"PRIVATE_FINAL"}))]);
        let audit = summarize_lookup(&raw(records), TURN).unwrap();
        assert_eq!(audit["answer"]["finalMessages"], 0);
        assert_eq!(
            audit["answer"]["completionMatchesLastAssistantMessage"],
            false
        );
    }
    #[test]
    fn coverage_summary_never_counts_as_an_observation_and_oversized_headers_are_rejected() {
        let summary = "READ_COVERAGE scopes=1 captured=0 partial=1 unknown=0 source_cut=0 output_cut=0 field_cut=1 dropped=0";
        let mut records = start();
        records.extend([
            call("read", "computer_v2_read_page", json!({})),
            output("read", json!(summary)),
        ]);
        let audit = summarize_lookup(&raw(records), TURN).unwrap();
        assert_eq!(audit["reading"]["coverageSummaryOccurrences"], 1);
        assert_eq!(audit["reading"]["browserSemanticReceiptOccurrences"], 0);
        let huge = format!(
            "AXSNAPSHOT id={ID} source=chrome_devtools title=\"{}\"\nREAD view=content",
            "界".repeat(11000)
        );
        assert!(oversized(&huge));
        assert!(semantic(&huge).is_none());
    }
    #[test]
    fn typed_receipts_reject_unrecognized_parts_and_missing_text() {
        assert_eq!(
            receipt_text(
                &json!([{"type":"input_text","text":"a"},{"type":"input_image","image_url":"PRIVATE"},{"type":"input_text","text":"b"}])
            ),
            Some("a\nb".into())
        );
        assert!(receipt_text(&json!([{"type":"output_text","text":"a"}])).is_none());
        assert!(receipt_text(&json!([{"type":"input_text"}])).is_none());
    }
}
