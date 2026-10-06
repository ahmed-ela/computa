use super::*;
use serde_json::json;
use std::{path::Path, time::Instant};
struct Case {
    identifier: &'static str,
    fixture: Value,
    expected: &'static str,
    request: Value,
    arms: [&'static str; 2],
}
fn read_request(captures: &Path, number: u32) -> Result<Value> {
    let capture = wire::requests(&read(
        &captures.join(format!("connection-{number:02}.client-to-upstream.bin")),
    )?)?;
    ensure(
        capture.messages == 1 && capture.requests.len() == 1,
        "expected_one_complete_responses_request",
    )?;
    Ok(capture.requests.into_iter().next().unwrap().body)
}
fn validate(cases: &[Case], policy: &str) -> Result<()> {
    for case in cases {
        let request = &case.request;
        let input = request["input"]
            .as_array()
            .ok_or(BenchmarkError("wire_fixture_preconditions_failed"))?;
        ensure(input.len() >= 2, "wire_fixture_preconditions_failed")?;
        let last = &input[input.len() - 1];
        let call = &input[input.len() - 2];
        ensure(
            request["model"] == MODEL
                && request["tools"]
                    .as_array()
                    .is_some_and(|tools| tools.len() == 13)
                && request["instructions"] == cases[0].request["instructions"]
                && wire::canonical(&request["tools"])
                    == wire::canonical(&cases[0].request["tools"])
                && input.iter().any(|item| {
                    item["content"].as_array().is_some_and(|content| {
                        content.iter().any(|part| {
                            part["type"] == "input_text"
                                && part["text"]
                                    .as_str()
                                    .is_some_and(|text| text.contains(policy))
                        })
                    })
                })
                && last["type"] == "function_call_output"
                && last["output"] == case.fixture["initial"]
                && call["name"] == "computer_v2_snapshot"
                && call["call_id"] == last["call_id"],
            "wire_fixture_preconditions_failed",
        )?;
        ensure(
            call["arguments"].as_str().is_some_and(|arguments| {
                parse(arguments.as_bytes()).is_ok_and(|arguments| arguments == json!({}))
            }),
            "wire_fixture_preconditions_failed",
        )?;
        for (stage, budget) in [("initial", 3000), ("targeted", 1000)] {
            let observation = case.fixture[stage]
                .as_str()
                .ok_or(BenchmarkError("fixture_observation_invalid"))?;
            ensure(
                (stage == "initial" && !observation.contains(case.expected))
                    || (stage == "targeted" && observation.contains(case.expected)),
                "wire_fixture_missing_status_precondition_failed",
            )?;
            ensure(
                group_ax_snapshot_parents(observation, budget) != observation,
                "treatment_must_change_validated_representation",
            )?;
        }
    }
    Ok(())
}
fn summary(
    cases: &[Case],
    policy: &str,
    rows: &[Value],
    state: &str,
    reason: Option<&str>,
) -> Value {
    json!({"scope":"synthetic exact captured prefix; representation-only paired replay; no desktop","model":MODEL,"state":state,"stopReason":reason,"plannedLanes":4,"attemptedLanes":rows.len(),"instructionSHA256":hash(cases[0].request["instructions"].as_str().unwrap_or("")),"policySHA256":hash(policy),"differencesFromProduction":["stream=false","max_output_tokens=2048","temperature=0.1","no App Server after captured prefix"],"rows":rows})
}
fn accepted_query(call: &Value, fixture: &Value, step: usize, count: usize) -> bool {
    if step != 0 || count != 1 || call["name"] != "computer_v2_snapshot" {
        return false;
    }
    let Some(arguments) = call["arguments"]
        .as_str()
        .and_then(|arguments| parse(arguments.as_bytes()).ok())
    else {
        return false;
    };
    let Some(object) = arguments.as_object().filter(|object| object.len() == 1) else {
        return false;
    };
    let Some(query) = object.get("query").and_then(Value::as_str) else {
        return false;
    };
    ["queryLiteral", "shortQuery"]
        .iter()
        .filter_map(|key| fixture[*key].as_str())
        .filter(|literal| !literal.is_empty())
        .any(|literal| query.trim().to_lowercase() == literal.to_lowercase())
}
/// Four serial captured-prefix lanes, at most one literal synthetic query each.
/// Provider tool calls are recorded; none can reach the native harness.
pub async fn replay_layout(
    capture_root: &Path,
    fixture_a: &Path,
    fixture_b: &Path,
    output_directory: &Path,
    policy_file: &Path,
    lms: &Path,
) -> Result<Value> {
    ensure(
        [
            capture_root,
            fixture_a,
            fixture_b,
            output_directory,
            policy_file,
            lms,
        ]
        .iter()
        .all(|path| path.is_absolute()),
        "absolute_paths_required",
    )?;
    let output = private_output(output_directory)?;
    let policy = read_text(policy_file)?;
    ensure(!policy.is_empty(), "empty_policy")?;
    let cases = vec![
        Case {
            identifier: "order-a-first",
            fixture: read_json(fixture_a)?,
            expected: "Arrives Tuesday",
            request: read_request(capture_root, 3)?,
            arms: ["flat", "blocks"],
        },
        Case {
            identifier: "cedar-second",
            fixture: read_json(fixture_b)?,
            expected: "Expected Thursday",
            request: read_request(capture_root, 6)?,
            arms: ["blocks", "flat"],
        },
    ];
    validate(&cases, &policy)?;
    let mut rows: Vec<Value> = vec![];
    let result: Result<()> = async {
        save(&output, "summary.json", &summary(&cases, &policy, &rows, "running", None))?;
        let client = client()?;
        for case in &cases {
            for arm in case.arms {
                let mut request = case.request.clone();
                request["stream"] = json!(false);
                request["max_output_tokens"] = json!(2048);
                request["temperature"] = json!(0.1);
                if arm == "blocks" {
                    request["input"].as_array_mut().unwrap().last_mut().unwrap()["output"] = json!(
                        group_ax_snapshot_parents(case.fixture["initial"].as_str().unwrap(), 3000)
                    );
                }
                let mut before = request.clone();
                before["input"].as_array_mut().unwrap().last_mut().unwrap()["output"] = case.fixture["initial"].clone();
                let mut control = case.request.clone();
                control["stream"] = json!(false);
                control["max_output_tokens"] = json!(2048);
                control["temperature"] = json!(0.1);
                ensure(wire::canonical(&before) == wire::canonical(&control), "non_observation_treatment_change")?;
                let identifier = format!("{}-{arm}", case.identifier);
                rows.push(json!({
                    "id": identifier, "arm": arm, "expected": case.expected,
                    "queryIssued": false, "outcome": "pending", "calls": [], "requests": [], "elapsed_ms": 0
                }));
                save(&output, "summary.json", &summary(&cases, &policy, &rows, "running", None))?;
                let row_index = rows.len() - 1;
                let started = Instant::now();
                for step in 0..2 {
                    ensure(read_text(policy_file)? == policy, "policy_changed_during_replay")?;
                    require_idle(lms).await?;
                    let sent = Instant::now();
                    let (status, result) = response(&client, &request).await?;
                    ensure((200..300).contains(&status), "provider_http_error")?;
                    let result = result?;
                    save(&output, &format!("{identifier}-{step}.json"), &json!({"request": request, "response": result}))?;
                    rows[row_index]["requests"].as_array_mut().unwrap().push(json!({
                        "elapsed_ms": sent.elapsed().as_secs_f64() * 1000.0,
                        "usage": result["usage"], "status": result["status"]
                    }));
                    ensure(result["error"].is_null() && result["output"].is_array() && result["model"] == MODEL,
                        "invalid_provider_response")?;
                    let provider_output = result["output"].as_array().unwrap();
                    let calls = provider_output.iter().filter(|item| item["type"] == "function_call").collect::<Vec<_>>();
                    let final_text = final_answer(&result);
                    rows[row_index]["calls"].as_array_mut().unwrap().extend(
                        calls.iter().map(|item| json!({"name": item["name"], "arguments": item["arguments"]}))
                    );
                    if result["status"] != "completed" {
                        rows[row_index]["outcome"] = json!("incomplete");
                        break;
                    }
                    if calls.is_empty() {
                        rows[row_index]["answer"] = json!(final_text);
                        rows[row_index]["outcome"] = json!(if final_text.is_empty() {
                            "no_final_answer"
                        } else if final_text == case.expected && rows[row_index]["queryIssued"] == true {
                            "correct_after_query"
                        } else {
                            "nonexact_answer"
                        });
                        break;
                    }
                    if !accepted_query(calls[0], &case.fixture, step, calls.len()) {
                        rows[row_index]["outcome"] = json!("unsupported_call_no_dispatch");
                        break;
                    }
                    rows[row_index]["queryIssued"] = json!(true);
                    let input = request["input"].as_array_mut().unwrap();
                    input.extend(provider_output.iter().cloned());
                    let observation = case.fixture["targeted"].as_str().unwrap();
                    input.push(json!({
                        "type": "function_call_output", "call_id": calls[0]["call_id"],
                        "output": if arm == "blocks" { group_ax_snapshot_parents(observation, 1000) } else { observation.to_owned() }
                    }));
                }
                rows[row_index]["elapsed_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
                if rows[row_index]["outcome"] == "pending" {
                    rows[row_index]["outcome"] = json!("no_final_answer");
                }
                save(&output, "summary.json", &summary(&cases, &policy, &rows, "running", None))?;
            }
        }
        ensure(read_text(policy_file)? == policy, "policy_changed_during_replay")?;
        Ok(())
    }.await;

    if result.is_err()
        && let Some(row) = rows.last_mut().filter(|row| row["outcome"] == "pending")
    {
        row["outcome"] = json!("transport_or_provider_failure");
    }
    let final_summary = summary(
        &cases,
        &policy,
        &rows,
        if result.is_ok() {
            "completed"
        } else {
            "stopped"
        },
        result.as_ref().err().map(|error| error.0),
    );
    save(&output, "summary.json", &final_summary)?;
    result?;
    Ok(final_summary)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn replay_accepts_only_one_exact_literal_fixture_query() {
        let fixture = json!({"queryLiteral":"Order A","shortQuery":"order"});
        let call = json!({"name":"computer_v2_snapshot","arguments":"{\"query\":\" ORDER A \"}"});
        assert!(accepted_query(&call, &fixture, 0, 1));
        assert!(!accepted_query(&call, &fixture, 1, 1));
        assert!(!accepted_query(&call, &fixture, 0, 2));
        let mut changed = call.clone();
        changed["arguments"] = json!("{\"query\":\"Order A\",\"other\":true}");
        assert!(!accepted_query(&changed, &fixture, 0, 1));
        changed["name"] = json!("computer_v2_press");
        assert!(!accepted_query(&changed, &fixture, 0, 1));
    }
}
