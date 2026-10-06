use super::*;
use serde_json::json;
use std::{collections::HashSet, path::Path, time::Instant};
const INSTRUCTIONS: &str = "Read only the supplied synthetic AX observation. Lines are relevance-ranked, not page order. The header parents=[child:parent,...] map and each line's parent preserve observed containment. Parent paths may include group IDs whose lines are omitted. sibling_heading is observed direct-sibling context, not proof of semantic ownership. Follow those paths to associate a fact with the requested card; sharing only a page or root does not mean sharing a card. Unknown or truncated ancestry does not establish association. Do not associate adjacent unrelated facts. If the requested order's status is not supported by the shown elements, answer UNOBSERVED. Return only the exact status or UNOBSERVED, no explanation.";
const OUTCOMES: [&str; 5] = [
    "answered_correct",
    "answered_wrong",
    "no_final_answer",
    "server_error",
    "transport_error",
];
fn ids() -> Vec<String> {
    ["flat", "nested"]
        .into_iter()
        .flat_map(|shape| {
            ["normal", "reversed"].into_iter().flat_map(move |order| {
                ["full", "limited"].into_iter().flat_map(move |bound| {
                    ["ancestry", "without_ancestry"]
                        .into_iter()
                        .map(move |variant| format!("{shape}-{order}-{bound}-{variant}"))
                })
            })
        })
        .collect()
}
fn validate(value: &Value) -> Result<&Vec<Value>> {
    let fixtures = value
        .as_array()
        .ok_or(BenchmarkError("expected_16_synthetic_paired_fixtures"))?;
    ensure(
        fixtures.len() == 16,
        "expected_16_synthetic_paired_fixtures",
    )?;
    let expected = ids();
    let mut seen = HashSet::new();
    for fixture in fixtures {
        let id = fixture["id"]
            .as_str()
            .ok_or(BenchmarkError("fixture_id_invalid"))?;
        ensure(
            expected.iter().any(|expected| expected == id) && seen.insert(id),
            "fixture_id_invalid_or_duplicate",
        )?;
        let variant = fixture["variant"]
            .as_str()
            .ok_or(BenchmarkError("fixture_variant_invalid"))?;
        ensure(
            matches!(variant, "ancestry" | "without_ancestry")
                && id.ends_with(&format!("-{variant}")),
            "fixture_variant_invalid",
        )?;
        let observation = fixture["observation"]
            .as_str()
            .ok_or(BenchmarkError("fixture_observation_invalid"))?;
        ensure(
            !observation.trim().is_empty() && utf16_len(observation) <= 3000,
            "fixture_observation_invalid",
        )?;
        let expected = fixture["expected"]
            .as_str()
            .ok_or(BenchmarkError("fixture_expected_invalid"))?;
        ensure(
            !expected.trim().is_empty() && utf16_len(expected) <= 200,
            "fixture_expected_invalid",
        )?;
        let observed = fixture["targetObserved"]
            .as_bool()
            .ok_or(BenchmarkError("fixture_visibility_missing"))?;
        ensure(
            (expected == "UNOBSERVED") != observed,
            "fixture_visibility_contradiction",
        )?;
    }
    Ok(fixtures)
}
fn summary(
    fixtures: &[Value],
    validated: bool,
    rows: &[Value],
    state: &str,
    reason: Option<&str>,
) -> Value {
    let attempted: HashSet<_> = rows.iter().filter_map(|row| row["id"].as_str()).collect();
    let planned = if validated {
        fixtures
            .iter()
            .filter_map(|fixture| fixture["id"].as_str())
            .map(str::to_owned)
            .collect()
    } else {
        ids()
    };
    let unrun: Vec<_> = planned
        .into_iter()
        .filter(|id| !attempted.contains(id.as_str()))
        .collect();
    let counts = OUTCOMES
        .into_iter()
        .map(|outcome| {
            (
                outcome.to_owned(),
                json!(rows.iter().filter(|row| row["outcome"] == outcome).count()),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    json!({"scope":"synthetic extraction; not end-to-end","model":MODEL,"state":state,"fixtures_validated":validated,"planned_count":16,"attempted_count":rows.len(),"unrun_count":unrun.len(),"unrun_ids":unrun,"stop_reason":reason,"outcome_counts":counts,"rows":rows})
}
/// Serial legacy Responses extraction. No tool call or desktop action is executed.
pub async fn ax_run(fixture_path: &Path, output_directory: &Path, lms: &Path) -> Result<Value> {
    let output = private_output(output_directory)?;
    let (mut fixtures, mut rows, mut validated) = (vec![], vec![], false);
    let result: Result<()> = async {
        let source = read_json(fixture_path)?;
        fixtures = validate(&source)?.clone();
        validated = true;
        save(&output, "summary.json", &summary(&fixtures, true, &rows, "running", None))?;
        let client = client()?;
        for fixture in &fixtures {
            require_idle(lms).await?;
            let request = json!({
                "model": MODEL,
                "stream": false,
                "temperature": 0.1,
                "max_output_tokens": 2048,
                "instructions": INSTRUCTIONS,
                "input": [{"role": "user", "content": [{
                    "type": "input_text",
                    "text": format!("What is the delivery status text shown for Order A?\n\n{}", fixture["observation"].as_str().unwrap())
                }]}]
            });
            let started = Instant::now();
            let mut result = Value::Null;
            let mut output_text = String::new();
            let mut outcome = "transport_error";
            let mut failure = None;
            let mut http_status = None;
            match response(&client, &request).await {
                Ok((status, body)) => {
                    http_status = Some(status);
                    outcome = "server_error";
                    if !(200..300).contains(&status) {
                        failure = Some(format!("Local server HTTP {status}"));
                    } else {
                        match body {
                            Ok(value) => {
                                result = value;
                                if !result.is_object() || !result["output"].is_array() {
                                    failure = Some("Malformed local Responses payload".into());
                                } else {
                                    output_text = final_answer(&result);
                                    if (!result["error"].is_null() && result["error"] != false)
                                        || !matches!(result["status"].as_str(), Some("completed" | "incomplete"))
                                    {
                                        failure = Some("Local response error or unsuccessful status".into());
                                    } else if output_text.is_empty() {
                                        outcome = "no_final_answer";
                                        failure = Some("No final answer within the generation bound".into());
                                    } else if result["status"] != "completed" {
                                        failure = Some("Local response incomplete; partial text is not an answered extraction".into());
                                    } else {
                                        outcome = if fixture["expected"] == output_text { "answered_correct" } else { "answered_wrong" };
                                    }
                                }
                            }
                            Err(_) => failure = Some("Malformed local Responses payload".into()),
                        }
                    }
                }
                Err(error) => failure = Some(error.0.to_owned()),
            }
            let answered = matches!(outcome, "answered_correct" | "answered_wrong");
            let row = json!({
                "id": fixture["id"], "variant": fixture["variant"], "expected": fixture["expected"],
                "output": output_text, "outcome": outcome,
                "correct": if answered { Some(outcome == "answered_correct") } else { None },
                "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0,
                "status": result["status"], "error": result["error"], "failure": failure,
                "http_status": http_status, "model": result["model"], "usage": result["usage"],
                "effective_temperature": result["temperature"],
                "max_output_tokens": result.get("max_output_tokens").unwrap_or(&request["max_output_tokens"])
            });
            rows.push(row.clone());
            save(&output, &format!("{}.json", fixture["id"].as_str().unwrap()),
                &json!({"request": request, "response": result, "metrics": row}))?;
            save(&output, "summary.json", &summary(&fixtures, true, &rows, "running", None))?;
            if !answered {
                return Err(BenchmarkError(match outcome {
                    "no_final_answer" => "no_final_answer",
                    "server_error" => "server_error",
                    _ => "transport_error",
                }));
            }
        }
        Ok(())
    }.await;
    let final_summary = summary(
        &fixtures,
        validated,
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
    fn fixtures() -> Value {
        json!(ids().into_iter().map(|id|json!({"variant":if id.ends_with("-without_ancestry"){"without_ancestry"}else{"ancestry"},"id":id,"observation":"AXSNAPSHOT synthetic","expected":"UNOBSERVED","targetObserved":false})).collect::<Vec<_>>())
    }
    #[test]
    fn batch_validation_rejects_duplicate_and_visibility_before_any_model_check() {
        let mut value = fixtures();
        assert!(validate(&value).is_ok());
        value[3] = value[2].clone();
        assert!(validate(&value).is_err());
        let mut value = fixtures();
        value[1]["targetObserved"] = json!(true);
        assert!(validate(&value).is_err());
    }
    #[tokio::test]
    async fn invalid_batch_preserves_unattempted_summary_without_provider_access() {
        let temp = tempfile::tempdir().unwrap();
        std::fs::set_permissions(temp.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let fixture = temp.path().join("fixtures.json");
        std::fs::write(&fixture, b"[]").unwrap();
        assert!(
            ax_run(&fixture, temp.path(), Path::new("/missing/lms"))
                .await
                .is_err()
        );
        let saved = read_json(&temp.path().join("summary.json")).unwrap();
        assert_eq!(saved["state"], "stopped");
        assert_eq!(saved["attempted_count"], 0);
        assert_eq!(saved["unrun_count"], 16);
        assert_eq!(saved["fixtures_validated"], false);
    }
}
