//! Replay the retained 91 synthetic screenshots through the actual Rust worker.
//! This is an offline model-cascade diagnostic; it sends no native input and
//! never captures a desktop, downloads weights or executes Python.
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::grounding::{
    self as wire, CaptureBinding, PixelPoint, RefusalCode, Request, Response,
};
use computa_runtime::process::ObservedExit;
use computa_runtime::process::{OwnedProcess, isolated_environment};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    os::unix::fs::MetadataExt,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{ChildStdin, ChildStdout},
    sync::watch,
};
use uuid::Uuid;

const EXPECTED_REFUSAL: [&str; 4] = ["heldout", "zoom90", "preferences", "workspace-name"];

fn worker_hash(path: &Path) -> Result<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| BenchmarkError("grounding_native_worker_invalid"))?;
    let before = file
        .metadata()
        .map_err(|_| BenchmarkError("grounding_native_worker_invalid"))?;
    ensure(
        before.is_file() && (1..=512 * 1024 * 1024).contains(&before.len()),
        "grounding_native_worker_bound_exceeded",
    )?;
    let mut digest = Sha256::new();
    let mut count = 0u64;
    let mut buffer = vec![0; 1024 * 1024];
    loop {
        let length = file
            .read(&mut buffer)
            .map_err(|_| BenchmarkError("grounding_worker_hash_failed"))?;
        if length == 0 {
            break;
        }
        count += length as u64;
        ensure(
            count <= before.len(),
            "grounding_worker_changed_during_hash",
        )?;
        digest.update(&buffer[..length]);
    }
    let after = file
        .metadata()
        .map_err(|_| BenchmarkError("grounding_worker_hash_failed"))?;
    ensure(
        count == before.len()
            && before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.len() == after.len()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec(),
        "grounding_worker_changed_during_hash",
    )?;
    Ok(hex::encode(digest.finalize()))
}

#[derive(Clone, Debug)]
pub struct GroundingCascadeOptions {
    pub corpus: PathBuf,
    /// Absolute trusted native `computa-grounding-worker` executable.
    pub worker: PathBuf,
    pub model_root: PathBuf,
    /// Existing empty private output directory outside the repository.
    pub output: PathBuf,
    pub expected_hits: usize,
    pub expected_refusals: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct TargetBox {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
impl TargetBox {
    fn validate(&self, width: u32, height: u32) -> Result<()> {
        ensure(
            [self.x, self.y, self.width, self.height]
                .iter()
                .all(|v| v.is_finite())
                && self.x >= 0.
                && self.y >= 0.
                && self.width > 0.
                && self.height > 0.
                && self.x + self.width <= f64::from(width)
                && self.y + self.height <= f64::from(height),
            "grounding_corpus_box_invalid",
        )
    }
    fn contains(&self, point: PixelPoint) -> bool {
        point.x.is_finite()
            && point.y.is_finite()
            && self.x <= point.x
            && point.x <= self.x + self.width
            && self.y <= point.y
            && point.y <= self.y + self.height
    }
}
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SourceCase {
    variant: String,
    screen: String,
    target: String,
    instruction: String,
    image: String,
    target_box: TargetBox,
    width: u32,
    height: u32,
}
struct Case {
    cohort: &'static str,
    source: SourceCase,
    image: PathBuf,
}
fn source_cases(value: Value) -> Result<Vec<SourceCase>> {
    let cases: Vec<SourceCase> = serde_json::from_value(value)
        .map_err(|_| BenchmarkError("grounding_corpus_schema_invalid"))?;
    ensure(
        !cases.is_empty() && cases.len() <= 91,
        "grounding_corpus_size_invalid",
    )?;
    for case in &cases {
        ensure(
            [&case.variant, &case.screen, &case.target]
                .iter()
                .all(|text| {
                    !text.is_empty() && text.len() <= 200 && !text.chars().any(char::is_control)
                })
                && !case.instruction.is_empty()
                && case.instruction.trim() == case.instruction
                && case.instruction.chars().count() <= 512
                && case.instruction.len() <= 4096
                && !case.instruction.chars().any(char::is_control)
                && (1..=8192).contains(&case.width)
                && (1..=8192).contains(&case.height)
                && u64::from(case.width) * u64::from(case.height) <= wire::MAX_PIXELS,
            "grounding_corpus_case_invalid",
        )?;
        ensure(
            Path::new(&case.image).components().count() == 1
                && Path::new(&case.image)
                    .file_name()
                    .is_some_and(|name| name == case.image.as_str())
                && case.image.ends_with(".png"),
            "grounding_corpus_image_name_invalid",
        )?;
        case.target_box.validate(case.width, case.height)?;
    }
    Ok(cases)
}
fn load_corpus(path: &Path) -> Result<(Vec<Case>, Value)> {
    ensure(path.is_absolute(), "grounding_absolute_corpus_required")?;
    let mut cases = vec![];
    let mut provenance = vec![];
    let mut ids = HashSet::new();
    for cohort in ["development", "heldout"] {
        let directory = path.join(cohort);
        let manifest = read(&directory.join("manifest.source.json"))?;
        ensure(
            manifest.len() <= 256 * 1024,
            "grounding_corpus_manifest_bound_exceeded",
        )?;
        for source in source_cases(parse(&manifest)?)? {
            ensure(
                ids.insert((
                    cohort,
                    source.variant.clone(),
                    source.screen.clone(),
                    source.target.clone(),
                )),
                "grounding_corpus_duplicate_case",
            )?;
            let image = directory.join(&source.image);
            let png = read(&image)?;
            validate_png(&source, &png)?;
            cases.push(Case {
                cohort,
                source,
                image,
            });
        }
        provenance.push(json!({"cohort":cohort,"manifestSHA256":hash(manifest)}));
    }
    ensure(
        cases.len() == 91
            && cases
                .iter()
                .filter(|case| {
                    [
                        case.cohort,
                        case.source.variant.as_str(),
                        case.source.screen.as_str(),
                        case.source.target.as_str(),
                    ] == EXPECTED_REFUSAL
                })
                .count()
                == 1,
        "grounding_retained_91_case_corpus_required",
    )?;
    Ok((cases, json!(provenance)))
}
fn validate_png(case: &SourceCase, png: &[u8]) -> Result<()> {
    ensure(
        png.len() >= 33
            && png.len() <= wire::MAX_PNG_BYTES
            && &png[..8] == b"\x89PNG\r\n\x1a\n"
            && &png[12..16] == b"IHDR"
            && u32::from_be_bytes(png[16..20].try_into().unwrap()) == case.width
            && u32::from_be_bytes(png[20..24].try_into().unwrap()) == case.height,
        "grounding_corpus_png_dimensions_invalid",
    )
}
fn percentile(values: &[f64], fraction: f64) -> Option<f64> {
    if values.is_empty()
        || !fraction.is_finite()
        || !(0.0..=1.0).contains(&fraction)
        || values.iter().any(|v| !v.is_finite() || *v < 0.)
    {
        return None;
    }
    let mut values = values.to_vec();
    values.sort_by(f64::total_cmp);
    let index = (values.len() - 1) as f64 * fraction;
    let low = index.floor() as usize;
    let high = index.ceil() as usize;
    Some(if low == high {
        values[low]
    } else {
        values[low] * (high as f64 - index) + values[high] * (index - low as f64)
    })
}
async fn write_frame(input: &mut ChildStdin, request: &Request) -> Result<()> {
    request
        .validate()
        .map_err(|_| BenchmarkError("grounding_request_invalid"))?;
    let bytes = wire::encode(request, wire::MAX_REQUEST_FRAME)
        .map_err(|_| BenchmarkError("grounding_request_bound_exceeded"))?;
    input
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await
        .map_err(|_| BenchmarkError("grounding_worker_write_failed"))?;
    input
        .write_all(&bytes)
        .await
        .map_err(|_| BenchmarkError("grounding_worker_write_failed"))?;
    input
        .flush()
        .await
        .map_err(|_| BenchmarkError("grounding_worker_write_failed"))
}
async fn read_frame(output: &mut ChildStdout) -> Result<Response> {
    let mut header = [0; 4];
    output
        .read_exact(&mut header)
        .await
        .map_err(|_| BenchmarkError("grounding_worker_frame_missing"))?;
    let length = u32::from_be_bytes(header) as usize;
    ensure(
        (1..=wire::MAX_RESPONSE_FRAME).contains(&length),
        "grounding_worker_frame_bound_exceeded",
    )?;
    let mut bytes = vec![0; length];
    output
        .read_exact(&mut bytes)
        .await
        .map_err(|_| BenchmarkError("grounding_worker_frame_incomplete"))?;
    wire::decode(&bytes, wire::MAX_RESPONSE_FRAME)
        .map_err(|_| BenchmarkError("grounding_worker_response_invalid"))
}
async fn bounded<T>(
    cancel: &mut watch::Receiver<bool>,
    seconds: u64,
    future: impl std::future::Future<Output = Result<T>>,
) -> Result<T> {
    if *cancel.borrow() {
        return Err(BenchmarkError("grounding_cascade_cancelled"));
    }
    tokio::select! {
        _=cancel.changed()=>Err(BenchmarkError("grounding_cascade_cancelled")),
        result=tokio::time::timeout(Duration::from_secs(seconds),future)=>result.map_err(|_|BenchmarkError("grounding_worker_deadline_exceeded"))?,
    }
}
fn grade_response(
    case: &Case,
    binding: &CaptureBinding,
    response: Response,
    elapsed: f64,
) -> Result<Value> {
    let mut row = json!({"cohort":case.cohort,"variant":case.source.variant,"screen":case.source.screen,"target":case.source.target,"instruction":case.source.instruction,
        "target_box":case.source.target_box,"captureID":binding.capture_id,"imageSHA256":binding.png_sha256,"targetSHA256":binding.target_sha256,"point":null,"hit":false,"safe_refusal":false,
        "error_code":null,"used_showui":null,"selected_pair":null,"worker_latency_ms":null,"request_latency_ms":elapsed});
    match response {
        Response::Unagreed {
            binding: returned,
            elapsed_seconds,
        } if returned == *binding
            && elapsed_seconds.is_finite()
            && (0.0..=60.0).contains(&elapsed_seconds) =>
        {
            row["safe_refusal"] = json!(true);
            row["error_code"] = json!("no_pair_agreement");
            row["error"] = json!(RefusalCode::NoAgreement.message());
            row["used_showui"] = json!(true);
            row["worker_latency_ms"] = json!(elapsed_seconds * 1000.);
        }
        Response::Grounded {
            binding: returned,
            result,
        } if returned == *binding => {
            result
                .validate(binding)
                .map_err(|_| BenchmarkError("grounding_cascade_evidence_invalid"))?;
            row["point"] = json!(result.point);
            row["hit"] = json!(case.source.target_box.contains(result.point));
            row["used_showui"] = json!(result.used_showui);
            row["selected_pair"] = json!(result.selected_pair);
            row["worker_latency_ms"] = json!(result.elapsed_seconds * 1000.);
            row["model_points"] = json!(result.model_points);
            row["model_seconds"] = json!(result.model_seconds);
        }
        Response::Refused {
            instance,
            binding: Some(returned),
            code,
        } if instance == binding.instance && returned == *binding => {
            row["safe_refusal"] = json!(code == RefusalCode::NoAgreement);
            row["error_code"] = if code == RefusalCode::NoAgreement {
                json!("no_pair_agreement")
            } else {
                json!(code)
            };
            row["error"] = json!(code.message());
        }
        _ => {
            return Err(BenchmarkError(
                "grounding_cascade_response_identity_mismatch",
            ));
        }
    }
    Ok(row)
}
struct Timings {
    ready: Option<f64>,
    load: Option<f64>,
    warmup: Option<f64>,
    wall: f64,
}
fn report(
    options: &GroundingCascadeOptions,
    rows: &[Value],
    aborted: Option<&str>,
    timings: Timings,
    provenance: &Value,
) -> Value {
    let hits = rows.iter().filter(|row| row["hit"] == true).count();
    let safe_refusals = rows
        .iter()
        .filter(|row| row["safe_refusal"] == true)
        .collect::<Vec<_>>();
    let correct_refusals = safe_refusals.len() == 1
        && safe_refusals.iter().all(|row| {
            [
                row["cohort"].as_str().unwrap(),
                row["variant"].as_str().unwrap(),
                row["screen"].as_str().unwrap(),
                row["target"].as_str().unwrap(),
            ] == EXPECTED_REFUSAL
        });
    let request = rows
        .iter()
        .filter_map(|row| row["request_latency_ms"].as_f64())
        .collect::<Vec<_>>();
    let worker = rows
        .iter()
        .filter_map(|row| row["worker_latency_ms"].as_f64())
        .collect::<Vec<_>>();
    let complete = aborted.is_none() && rows.len() == 91;
    json!({"schema_version":2,"method_version":wire::METHOD_VERSION,"protocol_version":wire::PROTOCOL_VERSION,"tasks":rows.len(),"complete":complete,"aborted":aborted,
        "passed":complete && hits==options.expected_hits && safe_refusals.len()==options.expected_refusals && correct_refusals && rows.iter().all(|row|row["hit"]==true || row["safe_refusal"]==true),
        "hits":hits,"safe_refusals":safe_refusals.len(),"expected_hits":options.expected_hits,"expected_refusals":options.expected_refusals,
        "showui_calls":rows.iter().filter(|row|row["used_showui"]==true).count(),"request_latency_p50_ms":percentile(&request,0.5),"request_latency_p95_ms":percentile(&request,0.95),
        "worker_latency_p50_ms":percentile(&worker,0.5),"worker_latency_p95_ms":percentile(&worker,0.95),"ready_wall_seconds":timings.ready,"worker_load_seconds":timings.load,"worker_warmup_seconds":timings.warmup,"wall_seconds":timings.wall,
        "provenance":provenance,"noDesktopCapture":true,"noNativeInput":true,"noDownloads":true,"limitations":"One correlated synthetic corpus pass; not real-world reliability or native action completion evidence.","rows":rows})
}

struct CancelOnDrop(watch::Sender<bool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        let _ = self.0.send(true);
    }
}

/// An owned task completes exact process-group cleanup even if the CLI caller
/// drops its pending future while the Tokio runtime remains alive.
pub async fn grounding_cascade(options: &GroundingCascadeOptions) -> Result<Value> {
    let options = options.clone();
    let (tx, rx) = watch::channel(false);
    let _cancel = CancelOnDrop(tx);
    tokio::spawn(async move { run(options, rx).await })
        .await
        .map_err(|_| BenchmarkError("grounding_cascade_owned_task_failed"))?
}
async fn run(options: GroundingCascadeOptions, mut cancel: watch::Receiver<bool>) -> Result<Value> {
    ensure(
        options.expected_hits <= 91 && options.expected_refusals <= 91,
        "grounding_expected_counts_invalid",
    )?;
    let output = private_output(&options.output)?;
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .map_err(|_| BenchmarkError("grounding_repository_path_invalid"))?;
    ensure(
        !output.starts_with(repository)
            && std::fs::read_dir(&output)
                .map_err(|_| BenchmarkError("grounding_output_invalid"))?
                .next()
                .is_none(),
        "grounding_empty_private_output_outside_repo_required",
    )?;
    let (cases, corpus_provenance) = load_corpus(&options.corpus)?;
    ensure(
        options.worker.is_absolute() && options.model_root.is_absolute(),
        "grounding_absolute_worker_model_paths_required",
    )?;
    let metadata = std::fs::symlink_metadata(&options.worker)
        .map_err(|_| BenchmarkError("grounding_native_worker_missing"))?;
    ensure(
        metadata.is_file()
            && !metadata.file_type().is_symlink()
            && metadata.permissions().mode() & 0o111 != 0,
        "grounding_native_worker_invalid",
    )?;
    let resources = options
        .worker
        .parent()
        .ok_or(BenchmarkError("grounding_worker_resources_missing"))?;
    computa_inference::metal_resources::verify_directory(resources)
        .map_err(|_| BenchmarkError("grounding_colocated_metal_resources_invalid"))?;
    let executable_hash = worker_hash(&options.worker)?;
    let provenance = json!({"runnerSHA256":hash(include_str!("grounding_cascade.rs")),"workerSHA256":executable_hash,"corpus":corpus_provenance,"modelNames":wire::MODELS,"frozenMethodVersion":wire::METHOD_VERSION});
    let private = tempfile::Builder::new()
        .prefix("computa-grounding-cascade-")
        .tempdir()
        .map_err(|_| BenchmarkError("grounding_private_process_home_failed"))?;
    std::fs::set_permissions(private.path(), std::fs::Permissions::from_mode(0o700))
        .map_err(|_| BenchmarkError("grounding_private_process_home_failed"))?;
    let instance = Uuid::new_v4();
    let generation = Uuid::new_v4();
    let mut environment = isolated_environment(private.path(), private.path());
    environment.insert("COMPUTA_GROUNDING_INSTANCE".into(), instance.to_string());
    let args = vec![
        "--model-root".into(),
        options.model_root.to_string_lossy().into_owned(),
        "--parent-pid".into(),
        std::process::id().to_string(),
    ];
    let started = Instant::now();
    ensure(!*cancel.borrow(), "grounding_cascade_cancelled")?;
    let (process, mut input, mut stdout) =
        OwnedProcess::spawn(&options.worker, &args, private.path(), &environment)
            .map_err(|_| BenchmarkError("grounding_worker_spawn_failed"))?;
    let mut rows = vec![];
    let mut ready_seconds = None;
    let mut load_seconds = None;
    let mut warmup_seconds = None;
    let outcome: Result<()> = async {
        let response = bounded(&mut cancel, 30, read_frame(&mut stdout)).await?;
        match response {
            Response::Ready {
                protocol_version,
                method_version,
                instance: returned,
                parent_pid,
                model_names,
            } if protocol_version == wire::PROTOCOL_VERSION
                && method_version == wire::METHOD_VERSION
                && returned == instance
                && parent_pid == std::process::id()
                && model_names == wire::MODELS => {}
            Response::Refused {
                instance: returned,
                binding: None,
                code,
            } if returned == instance => {
                return Err(BenchmarkError(match code {
                    RefusalCode::MissingModels => "grounding_pinned_models_not_installed",
                    RefusalCode::Installation => "grounding_pinned_installation_rejected",
                    _ => "grounding_worker_startup_refused",
                }));
            }
            _ => return Err(BenchmarkError("grounding_worker_ready_identity_mismatch")),
        }
        load_seconds = Some(started.elapsed().as_secs_f64());
        let warm_case = cases
            .iter()
            .find(|case| {
                case.cohort == "development"
                    && case.source.variant == "base"
                    && case.source.screen == "dashboard"
                    && case.source.target == "search"
            })
            .ok_or(BenchmarkError("grounding_fixed_warmup_fixture_missing"))?;
        let png = read(&warm_case.image)?;
        validate_png(&warm_case.source, &png)?;
        let warm_binding = CaptureBinding {
            instance,
            request_id: Uuid::new_v4(),
            generation,
            capture_id: Uuid::new_v4(),
            png_sha256: wire::Sha256::new(hash(&png)).unwrap(),
            target_sha256: wire::Sha256::new(hash(wire::WARMUP_TARGET)).unwrap(),
            width: warm_case.source.width,
            height: warm_case.source.height,
        };
        let warm_request = Request::Warmup {
            binding: warm_binding.clone(),
            png_base64: STANDARD.encode(png),
        };
        let warm_started = Instant::now();
        let response = bounded(&mut cancel, 60, async {
            write_frame(&mut input, &warm_request).await?;
            read_frame(&mut stdout).await
        })
        .await?;
        match response {
            Response::Warmed {
                binding,
                elapsed_seconds,
            } if binding == warm_binding
                && elapsed_seconds.is_finite()
                && (0.0..=60.0).contains(&elapsed_seconds) =>
            {
                warmup_seconds = Some(warm_started.elapsed().as_secs_f64())
            }
            Response::Refused {
                instance: returned,
                binding: Some(binding),
                ..
            } if returned == instance && binding == warm_binding => {
                return Err(BenchmarkError("grounding_all_model_warmup_refused"));
            }
            _ => {
                return Err(BenchmarkError(
                    "grounding_warmup_response_identity_mismatch",
                ));
            }
        }
        ready_seconds = Some(started.elapsed().as_secs_f64());
        for case in &cases {
            let png = read(&case.image)?;
            validate_png(&case.source, &png)?;
            let binding = CaptureBinding {
                instance,
                request_id: Uuid::new_v4(),
                generation,
                capture_id: Uuid::new_v4(),
                png_sha256: wire::Sha256::new(hash(&png)).unwrap(),
                target_sha256: wire::Sha256::new(hash(&case.source.instruction)).unwrap(),
                width: case.source.width,
                height: case.source.height,
            };
            let request = Request::Ground {
                binding: binding.clone(),
                png_base64: STANDARD.encode(png),
                target: case.source.instruction.clone(),
            };
            let request_started = Instant::now();
            let response = bounded(&mut cancel, 60, async {
                write_frame(&mut input, &request).await?;
                read_frame(&mut stdout).await
            })
            .await?;
            rows.push(grade_response(
                case,
                &binding,
                response,
                request_started.elapsed().as_secs_f64() * 1000.,
            )?);
            save(
                &output,
                "cascade.json",
                &report(
                    &options,
                    &rows,
                    None,
                    Timings {
                        ready: ready_seconds,
                        load: load_seconds,
                        warmup: warmup_seconds,
                        wall: started.elapsed().as_secs_f64(),
                    },
                    &provenance,
                ),
            )?;
        }
        let shutdown = Request::Shutdown { instance };
        let response = bounded(&mut cancel, 20, async {
            write_frame(&mut input, &shutdown).await?;
            read_frame(&mut stdout).await
        })
        .await?;
        ensure(
            matches!(response,Response::Stopped{instance:returned} if returned==instance),
            "grounding_worker_shutdown_identity_mismatch",
        )?;
        bounded(&mut cancel, 20, async {
            loop {
                match process
                    .observed_exit()
                    .map_err(|_| BenchmarkError("grounding_worker_terminal_state_unavailable"))?
                {
                    Some(ObservedExit::Exited(0)) => return Ok(()),
                    Some(_) => return Err(BenchmarkError("grounding_worker_unclean_exit")),
                    None => tokio::time::sleep(Duration::from_millis(25)).await,
                }
            }
        })
        .await
    }
    .await;
    let stopped = process.stop().await;
    let aborted = if stopped.is_err() {
        Some("grounding_owned_cleanup_unconfirmed")
    } else {
        outcome.as_ref().err().map(|error| error.0)
    };
    let result = report(
        &options,
        &rows,
        aborted,
        Timings {
            ready: ready_seconds,
            load: load_seconds,
            warmup: warmup_seconds,
            wall: started.elapsed().as_secs_f64(),
        },
        &provenance,
    );
    save(&output, "cascade.json", &result)?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_corpus_has_exact_expected_safe_refusal_and_valid_geometry() {
        let development = source_cases(
            parse(include_bytes!(
                "../../../../Benchmarks/VisualGrounding/development/manifest.source.json"
            ))
            .unwrap(),
        )
        .unwrap();
        let heldout = source_cases(
            parse(include_bytes!(
                "../../../../Benchmarks/VisualGrounding/heldout/manifest.source.json"
            ))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(development.len() + heldout.len(), 91);
        assert_eq!(
            heldout
                .iter()
                .filter(|case| [
                    "heldout",
                    case.variant.as_str(),
                    case.screen.as_str(),
                    case.target.as_str()
                ] == EXPECTED_REFUSAL)
                .count(),
            1
        );
    }
    #[test]
    fn corpus_rejects_unbounded_instruction_escape_and_impossible_boxes() {
        let mut value = parse(include_bytes!(
            "../../../../Benchmarks/VisualGrounding/heldout/manifest.source.json"
        ))
        .unwrap();
        value[0]["image"] = json!("../outside.png");
        assert!(source_cases(value.clone()).is_err());
        value[0]["image"] = json!("fixture.png");
        value[0]["target_box"]["width"] = json!(99999);
        assert!(source_cases(value.clone()).is_err());
        value[0]["target_box"]["width"] = json!(1);
        value[0]["instruction"] = json!("x".repeat(513));
        assert!(source_cases(value).is_err());
    }
    #[test]
    fn exact_source_refusal_does_not_fabricate_points_or_count_missing_models_as_safe() {
        let source = source_cases(
            parse(include_bytes!(
                "../../../../Benchmarks/VisualGrounding/heldout/manifest.source.json"
            ))
            .unwrap(),
        )
        .unwrap()
        .remove(0);
        let case = Case {
            cohort: "heldout",
            source,
            image: PathBuf::new(),
        };
        let binding = CaptureBinding {
            instance: Uuid::new_v4(),
            request_id: Uuid::new_v4(),
            generation: Uuid::new_v4(),
            capture_id: Uuid::new_v4(),
            png_sha256: wire::Sha256::new("a".repeat(64)).unwrap(),
            target_sha256: wire::Sha256::new("b".repeat(64)).unwrap(),
            width: case.source.width,
            height: case.source.height,
        };
        let response = |code| Response::Refused {
            instance: binding.instance,
            binding: Some(binding.clone()),
            code,
        };
        let row = grade_response(&case, &binding, response(RefusalCode::NoAgreement), 2.).unwrap();
        assert_eq!(row["safe_refusal"], true);
        assert!(row["point"].is_null());
        assert_eq!(row["hit"], false);
        assert_eq!(
            grade_response(&case, &binding, response(RefusalCode::MissingModels), 2.).unwrap()["safe_refusal"],
            false
        );
        let unagreed = grade_response(
            &case,
            &binding,
            Response::Unagreed {
                binding: binding.clone(),
                elapsed_seconds: 2.3,
            },
            2.4,
        )
        .unwrap();
        assert_eq!(unagreed["safe_refusal"], true);
        assert_eq!(unagreed["used_showui"], true);
        assert_eq!(unagreed["worker_latency_ms"], 2300.0);
        assert_eq!(unagreed["error_code"], "no_pair_agreement");
        assert!(unagreed["point"].is_null());
        assert!(
            grade_response(
                &case,
                &binding,
                Response::Unagreed {
                    binding: binding.clone(),
                    elapsed_seconds: f64::INFINITY
                },
                2.4
            )
            .is_err()
        );
        let mut wrong = binding.clone();
        wrong.capture_id = Uuid::new_v4();
        assert!(
            grade_response(
                &case,
                &binding,
                Response::Refused {
                    instance: binding.instance,
                    binding: Some(wrong),
                    code: RefusalCode::NoAgreement
                },
                2.
            )
            .is_err()
        );
    }
    #[test]
    fn box_edges_and_percentiles_match_original_correlated_corpus_oracle() {
        let box_ = TargetBox {
            x: 1.,
            y: 2.,
            width: 3.,
            height: 4.,
        };
        assert!(box_.contains(PixelPoint { x: 4., y: 6. }));
        assert!(!box_.contains(PixelPoint { x: 4.1, y: 6. }));
        assert_eq!(percentile(&[1., 2., 3., 4.], 0.5), Some(2.5));
        assert!((percentile(&[1., 2., 3., 4.], 0.95).unwrap() - 3.85).abs() < 1e-12);
        assert_eq!(percentile(&[], 0.5), None);
        assert_eq!(percentile(&[f64::NAN], 0.5), None);
    }
}
