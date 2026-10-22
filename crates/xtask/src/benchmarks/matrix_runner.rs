//! Serial model-driven qualification orchestration. A missing live gate pauses
//! its trials; direct AX fixtures and inference-only probes cannot replace it.
use super::*;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    future::Future,
    pin::Pin,
    time::{Duration, Instant},
};

const TASK_ORDER: &[&str] = &["status", "semantic", "combined", "visual", "interrupt"];
const MODEL_ORDER: &[&str] = &["4b", "9b", "27b"];
const DEFAULT_TASKS: &str = "status,semantic,combined,visual";
const DEFAULT_MODELS: &str = "4b,9b";
const TRIAL_DEADLINE: Duration = Duration::from_secs(950);
const CLEANUP_DEADLINE: Duration = Duration::from_secs(10);

#[derive(Clone, Debug)]
pub struct MatrixRunOptions {
    pub output: PathBuf,
    pub models: String,
    pub tasks: String,
    pub repetitions: u8,
    pub dry_run: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatrixTask {
    Status,
    Semantic,
    Combined,
    Visual,
    Interrupt,
}
impl MatrixTask {
    fn parse(value: &str) -> Result<Self> {
        Ok(match value {
            "status" => Self::Status,
            "semantic" => Self::Semantic,
            "combined" => Self::Combined,
            "visual" => Self::Visual,
            "interrupt" => Self::Interrupt,
            _ => return Err(BenchmarkError("unknown_matrix_task")),
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Semantic => "semantic",
            Self::Combined => "combined",
            Self::Visual => "visual",
            Self::Interrupt => "interrupt",
        }
    }
}
fn model_id(model: &str) -> &'static str {
    match model {
        "4b" => "lmstudio-community/Qwen3.5-4B-MLX-4bit",
        "9b" => "lmstudio-community/Qwen3.5-9B-MLX-4bit",
        "27b" => "mlx-community/Qwen3.8-27B-4bit",
        _ => unreachable!("validated canonical matrix model"),
    }
}
fn select<'a>(value: &str, default: &str, order: &'a [&'a str]) -> Result<Vec<&'a str>> {
    let value = if value == "all" { default } else { value };
    let requested = value.split(',').collect::<Vec<_>>();
    ensure(
        !requested.is_empty() && requested.iter().all(|name| order.contains(name)),
        "invalid_matrix_selection",
    )?;
    // Preserve the shell runner's canonical ordering and duplicate collapse.
    Ok(order
        .iter()
        .copied()
        .filter(|name| requested.contains(name))
        .collect())
}
fn definition(task: MatrixTask) -> Value {
    let (legacy, oracle, tools, approvals) = match task {
        MatrixTask::Status => (
            "LocalQwenLiveTests/testProductionRuntimeExecutesReadOnlyComputerTool",
            "Production Runtime selected-model turn; exactly one computer_v2_status({}); exact LOCAL_COMPUTER_TOOL_OK assistant and correlated wire/rollout evidence.",
            vec!["computer_v2_status"],
            vec![],
        ),
        MatrixTask::Semantic => (
            "LocalQwenLiveTests/testProductionRuntimePressesCalculatorDigitOneWithV2",
            "Exact Calculator open, literal digit-1 snapshot, observed snapshot/element AXPress, fresh Edit-field snapshot; independent exact-PID AX display transition; exact token and wire/rollout evidence; only open/ax approved.",
            vec![
                "computer_v2_open",
                "computer_v2_snapshot",
                "computer_v2_ax",
                "computer_v2_snapshot",
            ],
            vec!["open", "ax"],
        ),
        MatrixTask::Combined => (
            "LocalQwenLiveTests/testProductionRuntimeUsesCombinedCalculatorCaptureWithV2",
            "Exact Calculator open, one capture(include_accessibility=true) containing synchronized AX plus correlated PNG, observed digit-1 AXPress, fresh final snapshot; independent exact-PID display transition and exact marker; no image coordinates; only open/ax approved.",
            vec![
                "computer_v2_open",
                "computer_v2_capture",
                "computer_v2_ax",
                "computer_v2_snapshot",
            ],
            vec!["open", "ax"],
        ),
        MatrixTask::Visual => (
            "CalculatorVisualV2LiveTests/testModelClicksCalculatorDigitOneFromDisplayCapture",
            "Exact Calculator open, native-window capture, one ground_click on its exact capture_id/target; fresh image+AX post-action observation, independent exact-PID digit append, exact marker and wire/rollout evidence; no estimated coordinates or repeated click; only open/click approved.",
            vec![
                "computer_v2_open",
                "computer_v2_capture",
                "computer_v2_ground_click",
            ],
            vec!["open", "click"],
        ),
        MatrixTask::Interrupt => (
            "LocalQwenLiveTests/testProductionRuntimeInterruptsActiveTurn",
            "Actual Production Runtime streamed delta while running, correlated turn/interrupt request/ack then interrupted terminal; same task/thread follow-up completes exact marker/deltas with a distinct turn; no tools; exact selected model and verified runtime cleanup.",
            vec![],
            vec![],
        ),
    };
    let scope_variant = match task {
        MatrixTask::Semantic | MatrixTask::Combined | MatrixTask::Visual => {
            "Disposable exact-PID calculator-equivalent AppKit fixture. Same digit append, observed reference/capture, independent display and approval oracles; does not mutate the user's Calculator."
        }
        MatrixTask::Status | MatrixTask::Interrupt => {
            "Current Rust Production Runtime with the exact selected local model and private task history."
        }
    };
    let rust_tools = match task {
        MatrixTask::Status => vec!["computer_v2_status"],
        MatrixTask::Semantic => vec![
            "computer_v2_open",
            "computer_v2_read_page",
            "computer_v2_press",
            "computer_v2_read_page",
        ],
        MatrixTask::Combined => vec![
            "computer_v2_open",
            "computer_v2_capture",
            "computer_v2_press",
            "computer_v2_read_page",
        ],
        MatrixTask::Visual => vec![
            "computer_v2_open",
            "computer_v2_capture",
            "computer_v2_ground_click",
            "computer_v2_verify",
        ],
        MatrixTask::Interrupt => vec![],
    };
    let rust_approvals = match task {
        MatrixTask::Status | MatrixTask::Interrupt => vec![],
        MatrixTask::Semantic | MatrixTask::Combined => vec!["open", "press"],
        MatrixTask::Visual => vec!["open", "click"],
    };
    json!({"task":task,"legacy_gate":legacy,"rust_gate":format!("computa-model-driven-matrix-v1/{}",task.name()),
        "rust_scope_variant":scope_variant,"scope_variant_is_explicit":true,
        "legacy_oracle":oracle,"legacy_allowed_tools":tools,"rust_allowed_tools":rust_tools,"legacy_allowed_approvals":approvals,"rust_allowed_approvals":rust_approvals,
        "rust_terminal_marker_pattern":format!("COMPUTA_MATRIX_{}_OK_<{}>",task.name().to_ascii_uppercase(),"trial_uuid"),
        "rust_oracle":"Exactly correlated Production Runtime tool/approval order, opaque observation/action references, independent owned fixture result (where applicable), exact per-trial or owned-fixture terminal marker, compiled gate/wire/rollout/oracle digests and confirmed owned cleanup.",
        "required_evidence":["selected model on Production Runtime thread","correlated private wire and rollout","independent gate oracle","exact owned cleanup"],
        "availability":"missing_production_rust_fixture","legacy_source_is_qualification_only":true})
}
/// Pure selection. The defaults never include the optional interruption or27B.
pub fn computer_matrix_plan(models: &str, tasks: &str, repetitions: u8) -> Result<Value> {
    ensure(
        (1..=20).contains(&repetitions),
        "matrix_repetitions_out_of_range",
    )?;
    let models = select(models, DEFAULT_MODELS, MODEL_ORDER)?;
    let tasks = select(tasks, DEFAULT_TASKS, TASK_ORDER)?;
    let mut trials = vec![];
    for model in &models {
        for task in &tasks {
            let task = MatrixTask::parse(task)?;
            for rep in 1..=repetitions {
                trials.push(
                    json!({"model":model,"model_id":model_id(model),"task":task,"trial":rep,
                    "gate":definition(task)["rust_gate"],"result":"planned"}),
                );
            }
        }
    }
    Ok(
        json!({"protocol":"computa-rust-computer-matrix-v1","models":models,"tasks":tasks,
        "repetitions":repetitions,"total_trials":trials.len(),"trials":trials,
        "gates":tasks.iter().map(|name|definition(MatrixTask::parse(name).unwrap())).collect::<Vec<_>>(),
        "serial":true,"trial_deadline_seconds":950,"cleanup_deadline_seconds":10,
        "defaults_exclude":["27b","interrupt"],"legacy_fixture_protocol_unchanged":true,
        "port_state":"runner_available_live_model_gates_missing"}),
    )
}

#[derive(Clone, Debug)]
pub struct MatrixTrial {
    pub id: uuid::Uuid,
    pub task: MatrixTask,
    pub model: String,
    pub model_id: String,
    pub repetition: u8,
    pub directory: PathBuf,
}
#[derive(Clone, Debug)]
pub struct MatrixEvidence {
    pub trial_id: uuid::Uuid,
    pub task: MatrixTask,
    pub model_id: String,
    pub wire_sha256: String,
    pub rollout_sha256: String,
    pub independent_oracle_sha256: String,
    pub oracle_passed: bool,
}
#[derive(Clone, Debug)]
pub enum MatrixOutcome {
    Verified(MatrixEvidence),
    Failed(&'static str),
    Skipped(&'static str),
}
pub type MatrixFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T>> + Send + 'a>>;
/// Trusted first-party live driver seam. Each driver must run the exact gate
/// oracle above against Production Runtime and retain resources for cleanup
/// even when its qualification future is cancelled. Never supplied by a model.
pub trait MatrixQualifier: Send + Sync {
    fn source_sha256(&self, task: MatrixTask, model: &str) -> Option<String>;
    fn qualify<'a>(&'a self, trial: &'a MatrixTrial) -> MatrixFuture<'a, MatrixOutcome>;
    /// Resolve only this exact trial's owned processes/session/lease receipts.
    fn cleanup<'a>(&'a self, trial: &'a MatrixTrial) -> MatrixFuture<'a, ()>;
}
struct MissingLiveGates;
impl MatrixQualifier for MissingLiveGates {
    fn source_sha256(&self, _task: MatrixTask, _model: &str) -> Option<String> {
        None
    }
    fn qualify<'a>(&'a self, _trial: &'a MatrixTrial) -> MatrixFuture<'a, MatrixOutcome> {
        Box::pin(async { Err(BenchmarkError("matrix_live_gate_unavailable")) })
    }
    fn cleanup<'a>(&'a self, _trial: &'a MatrixTrial) -> MatrixFuture<'a, ()> {
        Box::pin(async { Err(BenchmarkError("matrix_no_trial_was_started")) })
    }
}
fn digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn verify_evidence(evidence: &MatrixEvidence, trial: &MatrixTrial) -> Result<()> {
    ensure(
        evidence.trial_id == trial.id
            && evidence.task == trial.task
            && evidence.model_id == trial.model_id
            && [
                &evidence.wire_sha256,
                &evidence.rollout_sha256,
                &evidence.independent_oracle_sha256,
            ]
            .iter()
            .all(|hash| digest(hash)),
        "matrix_trial_evidence_mismatch",
    )
}
fn stamp() -> String {
    chrono::DateTime::<chrono::Utc>::from(std::time::SystemTime::now())
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}
fn checkpoint(output: &Path, plan: &Value, rows: &[Value], state: &str) -> Result<Value> {
    let mut summary = plan.clone();
    let object = summary.as_object_mut().unwrap();
    object.insert("state".into(), json!(state));
    object.insert("trials".into(), json!(rows));
    object.insert(
        "executed_trials".into(),
        json!(rows.iter().filter(|row| row["executed"] == true).count()),
    );
    object.insert("totals".into(), json!({"pass":rows.iter().filter(|row|row["result"]=="pass").count(),
        "fail":rows.iter().filter(|row|row["result"]=="fail").count(),"timeout":rows.iter().filter(|row|row["result"]=="timeout").count(),
        "skip":rows.iter().filter(|row|row["result"]=="skip").count(),"paused":rows.iter().filter(|row|row["result"]=="paused").count(),
        "cleanup_unconfirmed":rows.iter().filter(|row|row["result"]=="cleanup_unconfirmed").count()}));
    object.insert("qualification_claim".into(), json!("Only pass rows with exact correlated native gate evidence and confirmed owned cleanup are qualified. Paused, skipped and planned rows prove no live fixture execution."));
    save(output, "summary.json", &summary)?;
    let jsonl = rows
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
    ensure(jsonl.len() <= 1024 * 1024, "matrix_trial_log_bound")?;
    save(output, "trials.json", &json!(rows))?;
    // This file is recreated atomically, never appended from an untrusted gate.
    let temporary = output.join(format!(".trials-{}.tmp", uuid::Uuid::new_v4()));
    let name = temporary.file_name().unwrap().to_str().unwrap();
    super::opaque::write_new(output, name, format!("{jsonl}\n").as_bytes())?;
    std::fs::rename(temporary, output.join("trials.jsonl"))
        .map_err(|_| BenchmarkError("matrix_checkpoint_write_failed"))?;
    Ok(summary)
}
/// Without an explicitly supplied driver this entry point plans/pauses.
/// Implemented native gates are selected through the separate qualifier seam.
pub async fn run_computer_matrix(options: &MatrixRunOptions) -> Result<Value> {
    run_computer_matrix_with_qualifier(options, &MissingLiveGates).await
}
pub async fn run_computer_matrix_with_qualifier(
    options: &MatrixRunOptions,
    qualifier: &dyn MatrixQualifier,
) -> Result<Value> {
    let mut plan = computer_matrix_plan(&options.models, &options.tasks, options.repetitions)?;
    let models = plan["models"].as_array().unwrap().clone();
    let mut present = 0usize;
    let mut required = 0usize;
    for gate in plan["gates"].as_array_mut().unwrap() {
        let task = MatrixTask::parse(gate["task"].as_str().unwrap())?;
        let sources = models
            .iter()
            .filter_map(|model| {
                let model = model.as_str().unwrap();
                qualifier
                    .source_sha256(task, model)
                    .filter(|source| digest(source))
                    .map(|source| (model.to_owned(), json!(source)))
            })
            .collect::<serde_json::Map<_, _>>();
        gate["availability"] = json!(if sources.is_empty() {
            "missing_production_rust_fixture"
        } else {
            "first_party_driver_present_for_listed_models"
        });
        gate["driver_source_sha256_by_model"] = json!(sources);
        present += gate["driver_source_sha256_by_model"]
            .as_object()
            .unwrap()
            .len();
        required += models.len();
    }
    plan["port_state"] = json!(if present == 0 {
        "runner_available_live_model_gates_missing"
    } else if present == required {
        "explicit_driver_available_for_selected_gates"
    } else {
        "explicit_driver_available_selected_gates_missing"
    });
    if options.dry_run {
        return Ok(plan);
    }
    let output = private_output(&options.output)?;
    ensure(
        std::fs::read_dir(&output)
            .map_err(|_| BenchmarkError("matrix_output_unreadable"))?
            .next()
            .is_none(),
        "fresh_matrix_output_required",
    )?;
    let stopped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let signal_flag = stopped.clone();
    let signal = tokio::spawn(async move {
        #[cfg(unix)]
        {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
            tokio::select! { _=tokio::signal::ctrl_c()=>{}, _=async {if let Some(term)=&mut term {term.recv().await;}else{std::future::pending::<()>().await;}}=>{} }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        signal_flag.store(true, std::sync::atomic::Ordering::Release);
    });
    let operation = async {
        let mut rows = vec![];
        let mut blocked = false;
        checkpoint(&output,&plan,&rows,"running")?;
        for planned in plan["trials"].as_array().unwrap() {
            let mut row = planned.clone();
            let model = row["model"].as_str().unwrap();
            let task = MatrixTask::parse(row["task"].as_str().unwrap())?;
            let source = qualifier.source_sha256(task,model);
            let operator_stop=stopped.load(std::sync::atomic::Ordering::Acquire);
            if blocked || operator_stop || source.as_ref().is_none_or(|source|!digest(source)) {
                row.as_object_mut().unwrap().extend(json!({"result":"paused","executed":false,"reason":if blocked{"earlier_owned_cleanup_unconfirmed"}else if operator_stop{"operator_stop"}else{"missing_production_rust_fixture"},"exit_code":null,"wall_seconds":null,"test_seconds":null,"artifact_paths":[],"artifacts":[]}).as_object().unwrap().clone());
                rows.push(row);
                checkpoint(&output,&plan,&rows,"paused")?;
                continue;
            }
            let rep = row["trial"].as_u64().unwrap() as u8;
            let name = format!("{model}-{}-{rep:02}",task.name());
            let directory=output.join(&name);
            std::fs::create_dir(&directory).and_then(|_|std::fs::set_permissions(&directory,std::fs::Permissions::from_mode(0o700)))
                .map_err(|_|BenchmarkError("matrix_trial_directory_failed"))?;
            let trial=MatrixTrial{id:uuid::Uuid::new_v4(),task,model:model.into(),model_id:row["model_id"].as_str().unwrap().into(),repetition:rep,directory};
            let started=Instant::now();let started_at=stamp();
            save(&trial.directory,"trial.json",&json!({"id":trial.id,"model":trial.model,"model_id":trial.model_id,"task":trial.task,"trial":trial.repetition,"source_sha256":source,"definition":definition(task)}))?;
            let outcome=tokio::select! {
                result=tokio::time::timeout(TRIAL_DEADLINE,qualifier.qualify(&trial))=>match result {Ok(value)=>value,Err(_)=>Err(BenchmarkError("matrix_trial_timeout"))},
                _=async {while !stopped.load(std::sync::atomic::Ordering::Acquire){tokio::time::sleep(Duration::from_millis(100)).await;}}=>Err(BenchmarkError("matrix_trial_operator_stop")),
            };
            let cleanup=tokio::time::timeout(CLEANUP_DEADLINE,qualifier.cleanup(&trial)).await;
            let cleanup_confirmed=matches!(cleanup,Ok(Ok(())));
            blocked = !cleanup_confirmed;
            let (result,reason,evidence)=if !cleanup_confirmed {("cleanup_unconfirmed",Some("exact_owned_cleanup_unconfirmed"),Value::Null)}else{match outcome {
                Ok(MatrixOutcome::Verified(evidence)) if verify_evidence(&evidence,&trial).is_ok()=>
                    (if evidence.oracle_passed{"pass"}else{"fail"},None,json!({"wire_sha256":evidence.wire_sha256,"rollout_sha256":evidence.rollout_sha256,"independent_oracle_sha256":evidence.independent_oracle_sha256})),
                Ok(MatrixOutcome::Verified(_))=>("fail",Some("matrix_trial_evidence_mismatch"),Value::Null),
                Ok(MatrixOutcome::Failed(code))=>("fail",Some(code),Value::Null),
                Ok(MatrixOutcome::Skipped(code))=>("skip",Some(code),Value::Null),
                Err(BenchmarkError("matrix_trial_timeout"))=>("timeout",Some("matrix_trial_timeout"),Value::Null),
                Err(BenchmarkError(code))=>("fail",Some(code),Value::Null),
            }};
            row.as_object_mut().unwrap().extend(json!({"result":result,"reason":reason,"executed":true,"trial_id":trial.id,"gate_source_sha256":source,"started_at":started_at,"finished_at":stamp(),"wall_seconds":started.elapsed().as_secs_f64(),"test_seconds":started.elapsed().as_secs_f64(),"exit_code":if result=="pass"{0}else{1},"owned_cleanup_confirmed":cleanup_confirmed,"evidence":evidence,"artifact_paths":[trial.directory],"artifacts":[{"home":trial.directory,"correlation":"exact_owned_trial_receipts"}]}).as_object().unwrap().clone());
            rows.push(row);
            checkpoint(&output,&plan,&rows,"running")?;
        }
        let state=if blocked{"cleanup_unconfirmed"}else if rows.iter().any(|row|row["result"]=="paused"){"paused"}else{"complete"};
        checkpoint(&output,&plan,&rows,state)
    }.await;
    signal.abort();
    operation
}

#[cfg(test)]
mod tests {
    use super::*;
    fn options(output: PathBuf) -> MatrixRunOptions {
        MatrixRunOptions {
            output,
            models: "4b".into(),
            tasks: "status,semantic".into(),
            repetitions: 2,
            dry_run: false,
        }
    }
    #[test]
    fn defaults_are_canonical_and_never_enable_optional_27b_or_interrupt() {
        let plan = computer_matrix_plan("all", "all", 3).unwrap();
        assert_eq!(plan["total_trials"], 24);
        assert!(computer_matrix_plan("4b", "chrome", 1).is_err());
        assert_eq!(plan["models"], json!(["4b", "9b"]));
        assert!(
            !plan["tasks"]
                .as_array()
                .unwrap()
                .contains(&json!("interrupt"))
        );
        let explicit = computer_matrix_plan("27b,4b,27b", "interrupt,status", 1).unwrap();
        assert_eq!(explicit["models"], json!(["4b", "27b"]));
        assert_eq!(explicit["tasks"], json!(["status", "interrupt"]));
        for invalid in ["", "4b,", "unknown", "4b, 9b"] {
            assert!(computer_matrix_plan(invalid, "status", 1).is_err());
        }
        assert!(computer_matrix_plan("4b", "all", 0).is_err());
        assert!(computer_matrix_plan("4b", "all", 21).is_err());
    }
    #[tokio::test]
    async fn current_missing_live_gates_pause_without_running_or_substituting_direct_fixtures() {
        let root = tempfile::tempdir().unwrap();
        std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let summary = run_computer_matrix(&options(root.path().into()))
            .await
            .unwrap();
        assert_eq!(summary["state"], "paused");
        assert_eq!(summary["executed_trials"], 0);
        assert_eq!(summary["totals"]["paused"], 4);
        assert_eq!(summary["totals"]["pass"], 0);
        assert_eq!(std::fs::read_dir(root.path()).unwrap().count(), 3);
        assert!(
            summary["trials"]
                .as_array()
                .unwrap()
                .iter()
                .all(|row| row["reason"] == "missing_production_rust_fixture")
        );
    }
    struct RecordedSyntheticDriver {
        clean: bool,
        wrong_identity: bool,
        attempts: std::sync::Mutex<Vec<String>>,
    }
    impl MatrixQualifier for RecordedSyntheticDriver {
        fn source_sha256(&self, _: MatrixTask, _: &str) -> Option<String> {
            Some(hash(
                "synthetic runner test, never production qualification",
            ))
        }
        fn qualify<'a>(&'a self, trial: &'a MatrixTrial) -> MatrixFuture<'a, MatrixOutcome> {
            Box::pin(async move {
                self.attempts.lock().unwrap().push(format!(
                    "{}-{}-{}",
                    trial.model,
                    trial.task.name(),
                    trial.repetition
                ));
                Ok(MatrixOutcome::Verified(MatrixEvidence {
                    trial_id: if self.wrong_identity {
                        uuid::Uuid::new_v4()
                    } else {
                        trial.id
                    },
                    task: trial.task,
                    model_id: trial.model_id.clone(),
                    wire_sha256: hash("synthetic wire"),
                    rollout_sha256: hash("synthetic rollout"),
                    independent_oracle_sha256: hash("synthetic oracle"),
                    oracle_passed: true,
                }))
            })
        }
        fn cleanup<'a>(&'a self, _: &'a MatrixTrial) -> MatrixFuture<'a, ()> {
            Box::pin(async move { ensure(self.clean, "synthetic_cleanup_unconfirmed") })
        }
    }
    #[tokio::test]
    async fn serial_engine_rejects_wrong_receipt_and_stops_after_uncertain_owned_cleanup() {
        for (clean, wrong, expected, attempts) in [
            (true, false, "complete", 4),
            (true, true, "complete", 4),
            (false, false, "cleanup_unconfirmed", 1),
        ] {
            let root = tempfile::tempdir().unwrap();
            std::fs::set_permissions(root.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
            let driver = RecordedSyntheticDriver {
                clean,
                wrong_identity: wrong,
                attempts: Default::default(),
            };
            let summary = run_computer_matrix_with_qualifier(&options(root.path().into()), &driver)
                .await
                .unwrap();
            assert_eq!(summary["state"], expected);
            assert_eq!(
                summary["port_state"],
                "explicit_driver_available_for_selected_gates"
            );
            assert_eq!(driver.attempts.lock().unwrap().len(), attempts);
            if wrong {
                assert_eq!(summary["totals"]["pass"], 0);
                assert_eq!(summary["totals"]["fail"], 4);
            }
            if !clean {
                assert_eq!(summary["totals"]["paused"], 3);
                assert_eq!(summary["totals"]["pass"], 0);
            }
            if clean && !wrong {
                assert_eq!(
                    *driver.attempts.lock().unwrap(),
                    [
                        "4b-status-1",
                        "4b-status-2",
                        "4b-semantic-1",
                        "4b-semantic-2"
                    ]
                );
            }
        }
    }
}
