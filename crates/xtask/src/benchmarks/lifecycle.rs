//! Opt-in native worker parent-crash qualification. No desktop/model tool dispatch.
use super::*;
use computa_runtime::process::OwnedProcess;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub parent: u32,
    pub started: String,
    pub command: String,
}
pub fn parse_process_identity(value: &str) -> Option<ProcessIdentity> {
    if value.len() > 16384 {
        return None;
    }
    let pattern = regex::Regex::new(
        r"^(\d+)\s+(\d+)\s+([A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+)$",
    )
    .ok()?;
    let capture = pattern.captures(value.trim())?;
    let pid = capture[1].parse::<u32>().ok()?;
    let parent = capture[2].parse::<u32>().ok()?;
    if pid <= 1 || parent == 0 || capture[4].contains('\n') {
        return None;
    }
    Some(ProcessIdentity {
        pid,
        parent,
        started: capture[3].split_whitespace().collect::<Vec<_>>().join(" "),
        command: capture[4].into(),
    })
}
pub fn same_process_identity(a: Option<&ProcessIdentity>, b: Option<&ProcessIdentity>) -> bool {
    a.zip(b)
        .is_some_and(|(a, b)| a.pid == b.pid && a.started == b.started && a.command == b.command)
}
fn environment() -> Result<BTreeMap<String, String>> {
    let account = computa_state::account::user_home()
        .map_err(|_| BenchmarkError("native_account_home_unavailable"))?;
    Ok(BTreeMap::from([
        (
            "HOME".into(),
            account
                .to_str()
                .ok_or(BenchmarkError("native_account_home_invalid"))?
                .into(),
        ),
        ("PATH".into(), "/usr/bin:/bin:/usr/sbin:/sbin".into()),
        ("LC_ALL".into(), "C".into()),
        ("HF_HUB_OFFLINE".into(), "1".into()),
        ("TRANSFORMERS_OFFLINE".into(), "1".into()),
        ("HF_HUB_DISABLE_TELEMETRY".into(), "1".into()),
    ]))
}
async fn command(
    executable: &str,
    args: &[String],
    maximum: usize,
    seconds: u64,
) -> Result<(i32, String)> {
    let mut command = tokio::process::Command::new(executable);
    command
        .args(args)
        .env_clear()
        .envs(environment()?)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| BenchmarkError("lifecycle_diagnostic_spawn_failed"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or(BenchmarkError("lifecycle_diagnostic_pipe_failed"))?;
    tokio::time::timeout(Duration::from_secs(seconds), async {
        let mut bytes = vec![];
        stdout
            .take((maximum + 1) as u64)
            .read_to_end(&mut bytes)
            .await
            .map_err(|_| BenchmarkError("lifecycle_diagnostic_read_failed"))?;
        ensure(bytes.len() <= maximum, "lifecycle_diagnostic_bound")?;
        let status = child
            .wait()
            .await
            .map_err(|_| BenchmarkError("lifecycle_diagnostic_wait_failed"))?;
        Ok((
            status.code().unwrap_or(-1),
            String::from_utf8(bytes).map_err(|_| BenchmarkError("lifecycle_diagnostic_utf8"))?,
        ))
    })
    .await
    .map_err(|_| BenchmarkError("lifecycle_diagnostic_timeout"))?
}
async fn identity(pid: u32) -> Result<Option<ProcessIdentity>> {
    ensure(pid > 1, "invalid_owned_pid")?;
    let (code, text) = command(
        "/bin/ps",
        &[
            "-p".into(),
            pid.to_string(),
            "-o".into(),
            "pid=,ppid=,lstart=,command=".into(),
        ],
        16384,
        5,
    )
    .await?;
    if code != 0 && text.trim().is_empty() {
        return Ok(None);
    }
    ensure(code == 0, "owned_pid_diagnostic_failed")?;
    let identity =
        parse_process_identity(&text).ok_or(BenchmarkError("owned_pid_identity_invalid"))?;
    ensure(identity.pid == pid, "owned_pid_identity_mismatch")?;
    Ok(Some(identity))
}
async fn port_free(port: u16) -> bool {
    tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .await
        .is_ok()
}
async fn verify_listener(pid: u32, port: u16) -> Result<()> {
    let (code, text) = command(
        "/usr/sbin/lsof",
        &[
            "-nP".into(),
            "-a".into(),
            "-p".into(),
            pid.to_string(),
            format!("-iTCP:{port}"),
            "-sTCP:LISTEN".into(),
            "-Fpn".into(),
        ],
        4096,
        5,
    )
    .await?;
    ensure(
        code == 0
            && text.lines().any(|line| line == format!("p{pid}"))
            && text
                .lines()
                .any(|line| line == format!("n127.0.0.1:{port}"))
            && text
                .lines()
                .filter(|line| line.starts_with('n'))
                .all(|line| line == format!("n127.0.0.1:{port}")),
        "owned_worker_listener_mismatch",
    )
}
async fn footprint(pid: u32) -> Result<Value> {
    let (code, text) = command(
        "/usr/bin/vmmap",
        &["-summary".into(), pid.to_string()],
        2 * 1024 * 1024,
        8,
    )
    .await?;
    let line = |prefix: &str| {
        text.lines()
            .find_map(|line| line.strip_prefix(prefix))
            .map(str::trim)
            .filter(|value| value.len() <= 128)
            .map(str::to_owned)
    };
    Ok(
        json!({"commandExit":code,"physicalFootprint":line("Physical footprint:"),"peakPhysicalFootprint":line("Physical footprint (peak):")}),
    )
}
fn verify_paths(worker: &Path, model_root: &Path) -> Result<(PathBuf, PathBuf)> {
    ensure(
        worker.is_absolute()
            && model_root.is_absolute()
            && worker.file_name().and_then(|s| s.to_str()) == Some("computa-inference-worker"),
        "exact_native_worker_path_required",
    )?;
    let metadata = std::fs::symlink_metadata(worker)
        .map_err(|_| BenchmarkError("native_worker_unavailable"))?;
    ensure(
        metadata.is_file()
            && !metadata.file_type().is_symlink()
            && metadata.permissions().mode() & 0o111 != 0,
        "native_worker_unavailable",
    )?;
    let model = model_root
        .canonicalize()
        .map_err(|_| BenchmarkError("model_root_unavailable"))?;
    ensure(
        model.is_dir() && model.join("config.json").is_file(),
        "explicit_local_four_b_model_required",
    )?;
    let pin = crate::models::reviewed_manifest()
        .map_err(|_| BenchmarkError("reviewed_four_b_pin_unavailable"))?;
    let config_pin = pin
        .files
        .iter()
        .find(|file| file.path == "config.json")
        .ok_or(BenchmarkError("reviewed_four_b_pin_invalid"))?;
    let config = crate::models::read_regular(&model.join("config.json"), 256 * 1024)
        .map_err(|_| BenchmarkError("four_b_configuration_unavailable"))?;
    let matches = if let Some(expected) = &config_pin.sha256 {
        hash(&config) == *expected
    } else if let Some(expected) = &config_pin.git_blob_sha1 {
        use sha1::{Digest, Sha1};
        let mut digest = Sha1::new();
        digest.update(format!("blob {}\0", config.len()));
        digest.update(&config);
        hex::encode(digest.finalize()) == *expected
    } else {
        false
    };
    ensure(
        config.len() as u64 == config_pin.size && matches,
        "reviewed_four_b_configuration_mismatch",
    )?;
    let worker = worker
        .canonicalize()
        .map_err(|_| BenchmarkError("native_worker_unavailable"))?;
    Ok((worker, model))
}
/// Internal exact child supervisor entrypoint; emits one bounded ownership handshake.
pub async fn parent_death_supervisor(
    worker: &Path,
    model_root: &Path,
    port: u16,
    instance: uuid::Uuid,
) -> Result<()> {
    ensure(
        port >= 1024 && port != 1234,
        "private_lifecycle_port_required",
    )?;
    let (worker, model_root) = verify_paths(worker, model_root)?;
    let mut env = environment()?;
    env.insert("HEYDASH_MLX_INSTANCE".into(), instance.to_string());
    let args = vec![
        "--model-root".into(),
        model_root
            .to_str()
            .ok_or(BenchmarkError("invalid_model_root"))?
            .into(),
        "--model-id".into(),
        MODEL.into(),
        "--port".into(),
        port.to_string(),
        "--parent-pid".into(),
        std::process::id().to_string(),
    ];
    let supervisor_parent = identity(std::process::id())
        .await?
        .ok_or(BenchmarkError("supervisor_os_identity_missing"))?
        .parent;
    ensure(
        supervisor_parent > 1,
        "supervisor_requires_live_owned_parent",
    )?;
    let worker_hash = hash(read_bounded(&worker, 64 * 1024 * 1024)?);
    let (process, stdin, mut stdout) = OwnedProcess::spawn(&worker, &args, &model_root, &env)
        .map_err(|_| BenchmarkError("owned_worker_spawn_failed"))?;
    drop(stdin);
    let drain = tokio::spawn(async move {
        let _ = tokio::io::copy(&mut stdout, &mut tokio::io::sink()).await;
    });
    let result = async {
        let handshake = json!({"supervisorPID":std::process::id(),"childPID":process.pid(),"nonce":instance,"workerSHA256":worker_hash}).to_string()+"\n";
        tokio::io::stdout().write_all(handshake.as_bytes()).await.map_err(|_|BenchmarkError("supervisor_handshake_write_failed"))?;
        tokio::io::stdout().flush().await.map_err(|_|BenchmarkError("supervisor_handshake_write_failed"))?;
        let observed = async {
            loop {
                if process.observed_exit().map_err(|_|BenchmarkError("owned_worker_exit_unverified"))?.is_some() {return Ok::<_,BenchmarkError>(());}
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        };
        // The whole owned chain closes if the benchmark runner disappears.
        let parent_watch = async {
            loop {
                if identity(std::process::id()).await?.is_none_or(|id|id.parent != supervisor_parent) {return Ok::<_,BenchmarkError>(());}
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        };
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).map_err(|_|BenchmarkError("supervisor_signal_unavailable"))?;
        tokio::select! {result=observed=>result,result=parent_watch=>result,_=tokio::signal::ctrl_c()=>Ok(()),_=term.recv()=>Ok(())}
    }.await;
    let cleanup = process
        .stop()
        .await
        .map_err(|_| BenchmarkError("owned_worker_cleanup_unverified"));
    drain.abort();
    result?;
    cleanup
}

#[derive(Clone, Debug)]
pub struct ParentDeathOptions {
    pub output: PathBuf,
    pub worker: PathBuf,
    pub model_root: PathBuf,
    pub policy: PathBuf,
    pub port: u16,
    pub load_4b: bool,
}
async fn health(client: &reqwest::Client, endpoint: &str, instance: uuid::Uuid) -> Result<Value> {
    let mut response = client
        .get(format!("{endpoint}/health"))
        .timeout(Duration::from_secs(1))
        .send()
        .await
        .map_err(|_| BenchmarkError("lifecycle_health_transport"))?;
    ensure(response.status().is_success(), "lifecycle_health_http")?;
    let mut bytes = vec![];
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| BenchmarkError("lifecycle_health_body"))?
    {
        ensure(bytes.len() + chunk.len() <= 32000, "lifecycle_health_bound")?;
        bytes.extend_from_slice(&chunk);
    }
    let value = parse(&bytes)?;
    let observation = ObservationMode::RustBoundary {
        instance: instance.to_string(),
    }
    .inspect(&value, MODEL)?;
    Ok(
        json!({"busy":!observation["idle"].as_bool().unwrap(),"memory":value["memory"],"selected_model":value["selected_model"]}),
    )
}
async fn loaded_marker(
    client: &reqwest::Client,
    endpoint: &str,
    instance: uuid::Uuid,
    policy: &Path,
) -> Result<Value> {
    let before = health(client, endpoint, instance).await?;
    ensure(before["busy"] == false, "owned_worker_unexpectedly_busy")?;
    let policy = read_text(policy)?;
    ensure(
        !policy.trim().is_empty() && policy.len() <= 64 * 1024,
        "complete_bounded_policy_required",
    )?;
    let marker = "HEYDASH_PARENT_DEATH_MEMORY_OK";
    let request = json!({"model":MODEL,"instructions":"You are Computa. This is a read-only local memory-lifecycle test. No tools are available.","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":policy}]},{"type":"message","role":"user","content":[{"type":"input_text","text":format!("Reply only {marker}. Do not use tools.")}]}],"tools":[],"stream":true,"store":false,"reasoning":{"effort":"none"},"temperature":0.1,"max_output_tokens":1024});
    let started = Instant::now();
    let (events, bytes) = tokio::time::timeout(Duration::from_secs(120), async {
        let mut response = client
            .post(format!("{endpoint}/v1/responses"))
            .json(&request)
            .send()
            .await
            .map_err(|_| BenchmarkError("lifecycle_marker_transport"))?;
        ensure(
            response.status().is_success()
                && response
                    .headers()
                    .get("content-type")
                    .and_then(|h| h.to_str().ok())
                    .is_some_and(|h| h.contains("text/event-stream")),
            "lifecycle_marker_http_content_type",
        )?;
        let mut bytes = vec![];
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| BenchmarkError("lifecycle_marker_body"))?
        {
            ensure(
                bytes.len() + chunk.len() <= 4 * 1024 * 1024,
                "lifecycle_marker_stream_bound",
            )?;
            bytes.extend_from_slice(&chunk);
        }
        let text =
            std::str::from_utf8(&bytes).map_err(|_| BenchmarkError("lifecycle_marker_utf8"))?;
        let mut decoder = SseDecoder::default();
        let events = decoder.push(text)?;
        decoder.finish()?;
        Ok::<_, BenchmarkError>((events, bytes.len()))
    })
    .await
    .map_err(|_| BenchmarkError("lifecycle_marker_timeout"))??;
    let final_response = stream_completed(&events, MODEL)?;
    exact_text(&events, final_response, marker)?;
    let after = health(client, endpoint, instance).await?;
    ensure(
        after["busy"] == false
            && after["memory"]["active_bytes"]
                .as_u64()
                .is_some_and(|bytes| bytes > 0)
            && after["selected_model"] == MODEL,
        "loaded_model_idle_memory_unconfirmed",
    )?;
    Ok(
        json!({"exactMarker":true,"noTools":true,"elapsedMS":started.elapsed().as_secs_f64()*1000.0,"requestSHA256":hash(request.to_string()),"inheritedPolicySHA256":hash(policy),"eventsSHA256":hash(json!(events).to_string()),"eventCount":events.len(),"bytes":bytes,"usage":final_response["usage"],"after":after}),
    )
}
/// Default is an unloaded worker lifetime test. Loading 4B requires the explicit flag.
pub async fn parent_death_probe(options: &ParentDeathOptions) -> Result<Value> {
    ensure(
        options.port >= 1024 && options.port != 1234,
        "private_lifecycle_port_required",
    )?;
    let output = private_output(&options.output)?;
    let repository = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .map_err(|_| BenchmarkError("repository_identity_failed"))?;
    ensure(
        !output.starts_with(repository)
            && std::fs::read_dir(&output)
                .map_err(|_| BenchmarkError("output_unreadable"))?
                .next()
                .is_none(),
        "fresh_external_private_output_required",
    )?;
    let (worker, model_root) = verify_paths(&options.worker, &options.model_root)?;
    let model_pin = crate::models::reviewed_manifest()
        .map_err(|_| BenchmarkError("reviewed_four_b_pin_unavailable"))?;
    crate::models::verify_model(&model_root, &model_pin)
        .map_err(|_| BenchmarkError("reviewed_four_b_weights_mismatch"))?;
    let nonce = uuid::Uuid::new_v4();
    let endpoint = format!("http://127.0.0.1:{}", options.port);
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| BenchmarkError("http_client_unavailable"))?;
    let mut summary = json!({"state":"preflight","load4BExplicitlyRequested":options.load_4b,"model":MODEL,"endpoint":endpoint,"nonce":nonce,"inferenceLaneRequirement":"Run only when Computa and all other inference producers are idle/stopped.","limitations":"Process disappearance releases its allocations; this is not a matched RAM A/B or whole-system free-memory measurement.","sourceHashes":{"worker":hash(read_bounded(&worker,64*1024*1024)?),"runner":hash(include_bytes!("lifecycle.rs"))},"protocol":"computa-rust-parent-death-v1"});
    let mut supervisor = None;
    let mut child_identity = None;
    let mut descendant = None;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|_| BenchmarkError("lifecycle_signal_unavailable"))?;
    let operation = async {
        save(&output, "summary.json", &summary)?;
        ensure(
            port_free(options.port).await,
            "private_port_occupied_nothing_launched",
        )?;
        summary["state"] = json!("starting_owned_supervisor");
        save(&output, "summary.json", &summary)?;
        let executable = std::env::current_exe()
            .map_err(|_| BenchmarkError("supervisor_executable_unavailable"))?;
        let args = vec![
            "benchmark-parent-death-supervisor".into(),
            "--worker".into(),
            worker
                .to_str()
                .ok_or(BenchmarkError("invalid_worker_path"))?
                .into(),
            "--model-root".into(),
            model_root
                .to_str()
                .ok_or(BenchmarkError("invalid_model_root"))?
                .into(),
            "--port".into(),
            options.port.to_string(),
            "--instance".into(),
            nonce.to_string(),
        ];
        let (process, stdin, mut stdout) =
            OwnedProcess::spawn(&executable, &args, &output, &environment()?)
                .map_err(|_| BenchmarkError("owned_supervisor_spawn_failed"))?;
        drop(stdin);
        supervisor = Some(process);
        let process = supervisor.as_ref().unwrap();
        let mut handshake = vec![];
        tokio::time::timeout(Duration::from_secs(10), async {
            let mut byte = [0u8; 1];
            loop {
                ensure(handshake.len() < 1024, "supervisor_handshake_bound")?;
                ensure(
                    stdout
                        .read(&mut byte)
                        .await
                        .map_err(|_| BenchmarkError("supervisor_handshake_read_failed"))?
                        == 1,
                    "supervisor_exited_before_handshake",
                )?;
                if byte[0] == b'\n' {
                    break;
                }
                handshake.push(byte[0]);
            }
            Ok::<_, BenchmarkError>(())
        })
        .await
        .map_err(|_| BenchmarkError("supervisor_handshake_timeout"))??;
        let report = parse(&handshake)?;
        ensure(
            report["supervisorPID"].as_i64() == Some(process.pid() as i64)
                && report["nonce"] == nonce.to_string()
                && report["workerSHA256"] == summary["sourceHashes"]["worker"],
            "supervisor_ownership_mismatch",
        )?;
        let pid = report["childPID"]
            .as_u64()
            .and_then(|pid| u32::try_from(pid).ok())
            .filter(|pid| *pid > 1)
            .ok_or(BenchmarkError("supervisor_child_pid_invalid"))?;
        let observed = identity(pid)
            .await?
            .ok_or(BenchmarkError("owned_worker_not_running"))?;
        ensure(
            observed.parent == process.pid() as u32
                && observed.command.starts_with(worker.to_str().unwrap())
                && observed
                    .command
                    .contains(&format!("--parent-pid {}", process.pid())),
            "worker_os_identity_mismatch",
        )?;
        child_identity = Some(observed.clone());
        let worker_arguments = vec![
            "--model-root".into(),
            model_root.to_str().unwrap().into(),
            "--model-id".into(),
            MODEL.into(),
            "--port".into(),
            options.port.to_string(),
            "--parent-pid".into(),
            process.pid().to_string(),
        ];
        let proof = process
            .capture_descendant_for_lifecycle_probe(pid as i32, &worker, &worker_arguments)
            .await
            .map_err(|_| BenchmarkError("owned_descendant_identity_unconfirmed"))?;
        summary["childKernelBirth"] = json!(proof.start_time());
        descendant = Some(proof);
        summary["supervisorPID"] = json!(process.pid());
        summary["child"] = json!(observed);
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            ensure(
                process
                    .observed_exit()
                    .map_err(|_| BenchmarkError("supervisor_exit_unverified"))?
                    .is_none(),
                "supervisor_exited_during_startup",
            )?;
            match health(&client, &endpoint, nonce).await {
                Ok(value) => {
                    ensure(value["busy"] == false, "owned_worker_busy_at_ready")?;
                    verify_listener(pid, options.port).await?;
                    summary["ready"] = value;
                    break;
                }
                Err(error)
                    if ["lifecycle_health_transport", "lifecycle_health_http"]
                        .contains(&error.0) =>
                {
                    ensure(Instant::now() < deadline, "owned_worker_readiness_timeout")?;
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                Err(error) => return Err(error),
            }
        }
        summary["preLoadFootprint"] = footprint(pid).await?;
        if options.load_4b {
            summary["state"] = json!("running_opt_in_marker");
            save(&output, "summary.json", &summary)?;
            summary["loadedMarker"] =
                loaded_marker(&client, &endpoint, nonce, &options.policy).await?;
            summary["loadedFootprint"] = footprint(pid).await?;
        }
        let current = identity(pid).await?;
        ensure(
            same_process_identity(child_identity.as_ref(), current.as_ref())
                && current
                    .as_ref()
                    .is_some_and(|id| id.parent == process.pid() as u32)
                && process
                    .observed_exit()
                    .map_err(|_| BenchmarkError("supervisor_exit_unverified"))?
                    .is_none(),
            "ownership_changed_no_crash_signal",
        )?;
        health(&client, &endpoint, nonce).await?;
        verify_listener(pid, options.port).await?;
        ensure(
            descendant
                .as_ref()
                .unwrap()
                .matches_current()
                .map_err(|_| BenchmarkError("owned_descendant_identity_unconfirmed"))?,
            "descendant_changed_no_crash_signal",
        )?;
        summary["state"] = json!("crashing_owned_supervisor");
        save(&output, "summary.json", &summary)?;
        let killed = Instant::now();
        summary["supervisorExit"] = json!(
            process
                .crash_for_lifecycle_probe()
                .await
                .map_err(|_| BenchmarkError("owned_supervisor_crash_unverified"))?
                .to_string()
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if !descendant
                .as_ref()
                .unwrap()
                .matches_current()
                .map_err(|_| BenchmarkError("owned_descendant_identity_unconfirmed"))?
            {
                // A changed identity cannot yield a terminal receipt or a signal.
                descendant
                    .as_ref()
                    .unwrap()
                    .stop_for_lifecycle_probe()
                    .await
                    .map_err(|_| BenchmarkError("worker_pid_replaced_cleanup_unconfirmed"))?;
                break;
            }
            ensure(
                Instant::now() < deadline,
                "worker_outlived_parent_watch_deadline",
            )?;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        summary["childExitAfterParentDeathMS"] = json!(killed.elapsed().as_secs_f64() * 1000.0);
        let free = port_free(options.port).await;
        summary["portFreeAfterParentDeath"] = json!(free);
        ensure(free, "port_not_free_after_parent_death")?;
        summary["parentWatchPass"] = json!(true);
        summary["state"] = json!(if options.load_4b {
            "passed_loaded_model_parent_death"
        } else {
            "passed_unloaded_parent_death_only"
        });
        Ok::<_, BenchmarkError>(())
    };
    let operation = tokio::select! {result=operation=>result,_=tokio::signal::ctrl_c()=>Err(BenchmarkError("operator_interrupted_lifecycle")),_=terminate.recv()=>Err(BenchmarkError("operator_interrupted_lifecycle"))};
    if let Err(error) = operation {
        summary["failurePhase"] = summary["state"].clone();
        summary["state"] = json!("failed");
        summary["failure"] = json!(error.0);
    }
    if let Some(process) = &supervisor {
        let cleaned = process.stop().await.is_ok();
        summary["supervisorCleanupVerified"] = json!(cleaned);
        if !cleaned {
            summary["state"] = json!("owned_supervisor_cleanup_unconfirmed");
            summary["cleanupUnconfirmed"] = json!(true);
        }
    }
    if let Some(proof) = &descendant {
        let living = proof.matches_current();
        if matches!(living, Ok(true)) {
            summary["fallbackOwnedChildCleanupRequired"] = json!(true);
        }
        let cleaned = proof.stop_for_lifecycle_probe().await.is_ok();
        summary["childAbsentAtCleanup"] = json!(cleaned);
        summary["childCleanupVerified"] = json!(cleaned);
        if !cleaned {
            summary["cleanupUnconfirmed"] = json!(true);
            summary["state"] = json!("owned_worker_cleanup_unconfirmed");
        }
    } else if let Some(child) = &child_identity {
        let current = identity(child.pid).await;
        summary["childAbsentAtCleanup"] = json!(matches!(&current, Ok(None)));
        if !matches!(&current, Ok(None)) {
            summary["cleanupUnconfirmed"] = json!(true);
            summary["state"] = json!("owned_worker_cleanup_unconfirmed");
            summary["cleanupNotice"] = json!(
                "The observed descendant is not a retained direct-child handle. No bare-PID cleanup signal was sent."
            );
        }
    }
    save(&output, "summary.json", &summary)?;
    Ok(summary)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn process_identity_requires_pid_start_and_complete_command() {
        let a = parse_process_identity(
            "1234 567 Fri Sep 25 17:35:12 2026 /owned/computa-inference-worker --parent-pid 567\n",
        )
        .unwrap();
        let mut b = a.clone();
        b.parent = 1;
        assert!(same_process_identity(Some(&a), Some(&b)));
        b.pid = 999;
        assert!(!same_process_identity(Some(&a), Some(&b)));
        b = a.clone();
        b.started = "changed".into();
        assert!(!same_process_identity(Some(&a), Some(&b)));
        b = a.clone();
        b.command = "unrelated".into();
        assert!(!same_process_identity(Some(&a), Some(&b)));
        assert!(!same_process_identity(Some(&a), None));
        assert!(parse_process_identity("invalid").is_none());
    }
    #[test]
    fn private_port_and_exact_native_worker_path_fail_before_launch() {
        let root = tempfile::tempdir().unwrap();
        assert!(verify_paths(&root.path().join("other-worker"), root.path()).is_err());
        assert!(parse_process_identity("1 0 Fri Sep 25 17:35:12 2026 launchd").is_none());
    }
}
