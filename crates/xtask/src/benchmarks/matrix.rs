use super::{BenchmarkError, Result};
use serde_json::{Value, json};
use std::collections::BTreeMap;
fn executed(row: &Value) -> bool {
    row["result"] == "pass"
        || row["result"] == "fail" && !row["test_seconds"].is_null()
        || row["result"] == "timeout"
        || row["result"] == "killed"
}
fn seconds(row: &Value) -> Option<f64> {
    row["test_seconds"]
        .as_f64()
        .or_else(|| row["wall_seconds"].as_f64())
        .filter(|value| value.is_finite())
}
fn percentile(mut values: Vec<f64>, quantile: f64) -> Value {
    if values.is_empty() {
        return Value::Null;
    }
    values.sort_by(f64::total_cmp);
    json!(values[(values.len() as f64 * quantile).ceil() as usize - 1])
}
/// Exact legacy 4B/9B nearest-rank task summaries. These are whole task times.
pub fn summarize_computer_matrix(rows: &[Value]) -> Result<Value> {
    if rows.len() > 100_000 {
        return Err(BenchmarkError("too_many_trials"));
    }
    let mut groups: BTreeMap<(&str, &str), Vec<&Value>> = BTreeMap::new();
    for row in rows {
        if matches!(row["model"].as_str(), Some("4b" | "9b")) {
            let model = row["model"].as_str().unwrap();
            let task = row["task"]
                .as_str()
                .ok_or(BenchmarkError("trial_task_invalid"))?;
            groups.entry((model, task)).or_default().push(row);
        }
    }
    Ok(Value::Array(groups.into_iter().map(|((model,task),trials)|{let count=|result:&str|trials.iter().filter(|row|row["result"]==result).count();let times=trials.iter().filter(|row|executed(row)).filter_map(|row|seconds(row)).collect::<Vec<_>>();json!({"model":model,"task":task,"trials":trials.len(),"strict_passes":count("pass"),"failures":count("fail"),"timeouts":count("timeout")+count("killed"),"skipped":count("skip"),"unverified":count("unverified"),"nonexecuted_failures":trials.iter().filter(|row|row["result"]=="fail"&&row["test_seconds"].is_null()).count(),"executed_trials":trials.iter().filter(|row|executed(row)).count(),"task_seconds_p50":percentile(times.clone(),0.5),"task_seconds_p95":percentile(times,0.95),"successful_task_seconds_p50":percentile(trials.iter().filter(|row|row["result"]=="pass").filter_map(|row|seconds(row)).collect(),0.5)})}).collect()))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matrix_excludes_27b_and_counts_nonexecuted_failures_separately() {
        let rows = vec![
            json!({"model":"4b","task":"a","result":"pass","test_seconds":2}),
            json!({"model":"4b","task":"a","result":"fail","wall_seconds":100}),
            json!({"model":"4b","task":"a","result":"timeout","wall_seconds":10}),
            json!({"model":"4b","task":"a","result":"fail","test_seconds":4}),
            json!({"model":"27b","task":"a","result":"pass","test_seconds":1}),
        ];
        let summary = summarize_computer_matrix(&rows).unwrap();
        assert_eq!(summary.as_array().unwrap().len(), 1);
        assert_eq!(summary[0]["executed_trials"], 3);
        assert_eq!(summary[0]["nonexecuted_failures"], 1);
        assert_eq!(summary[0]["task_seconds_p50"], 4.0);
        assert_eq!(summary[0]["task_seconds_p95"], 10.0);
        assert_eq!(summary[0]["successful_task_seconds_p50"], 2.0);
    }
}
