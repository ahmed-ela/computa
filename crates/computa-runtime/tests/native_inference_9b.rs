//! Explicit reviewed 9B qualification through the production owned lifecycle.
//! Private process home, unused loopback port, no downloads or installed app.
use computa_contracts::models::{LocalModel, ModelId};
use computa_runtime::{InferenceLifecycle, NativeInferenceConfig, NativeInferenceLifecycle};
use futures::StreamExt;
use serde_json::{Value, json};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::{collections::HashMap, path::PathBuf, time::Duration};
const RED_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC";
fn require(condition: bool, error: &str) -> Result<(), String> {
    if condition { Ok(()) } else { Err(error.into()) }
}
fn record_synthetic_terminal(terminal: &Value) -> Result<(), String> {
    let Some(directory) = std::env::var_os("COMPUTA_TEST_MLX_EVIDENCE").map(PathBuf::from) else {
        return Ok(());
    };
    require(
        directory.is_absolute(),
        "Synthetic evidence directory is relative",
    )?;
    for parent in directory.ancestors() {
        if let Ok(m) = std::fs::symlink_metadata(parent) {
            require(
                m.is_dir() && !m.file_type().is_symlink(),
                "Synthetic evidence ancestor is nonregular",
            )?;
        }
    }
    std::fs::create_dir_all(&directory).map_err(|_| "Synthetic evidence directory failed")?;
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))
        .map_err(|_| "Synthetic evidence permissions failed")?;
    let bytes = serde_json::to_vec_pretty(terminal)
        .map_err(|_| "Synthetic evidence serialization failed")?;
    require(
        bytes.len() <= 1024 * 1024,
        "Synthetic terminal evidence exceeded its bound",
    )?;
    static SEQUENCE: AtomicUsize = AtomicUsize::new(0);
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(directory.join(format!("terminal-{sequence:02}.json")))
        .map_err(|_| "Synthetic evidence creation failed")?;
    std::io::Write::write_all(&mut file, &bytes).map_err(|_| "Synthetic evidence write failed")?;
    file.sync_all()
        .map_err(|_| "Synthetic evidence sync failed".to_owned())
}
async fn response(client: &reqwest::Client, base: &str, request: &Value) -> Result<Value, String> {
    let result = client
        .post(format!("{base}/responses"))
        .json(request)
        .send()
        .await
        .map_err(|_| "HTTP request failed")?;
    require(result.status().is_success(), "Native request refused HTTP")?;
    let text = result.text().await.map_err(|_| "SSE body failed")?;
    require(text.len() <= 4 * 1024 * 1024, "SSE evidence bound exceeded")?;
    let events = text
        .lines()
        .filter_map(|l| l.strip_prefix("data: "))
        .map(|l| computa_contracts::strict_json::parse(l.as_bytes()).map_err(|_| "Malformed SSE"))
        .collect::<Result<Vec<Value>, _>>()?;
    let terminal = events.last().ok_or("Missing SSE terminal")?.clone();
    // This ignored fixture sends only fresh synthetic input directly to its
    // owned worker. No existing chats, credentials or provider configuration
    // can enter these qualification-only records.
    record_synthetic_terminal(&terminal)?;
    if terminal["type"] == "response.completed" {
        let visible: String = events
            .iter()
            .filter(|e| e["type"] == "response.output_text.delta")
            .map(|e| e["delta"].as_str().unwrap_or(""))
            .collect();
        require(
            terminal["response"]["output_text"] == visible,
            "SSE delta/terminal mismatch",
        )?;
    }
    Ok(terminal)
}
fn request(model: LocalModel, text: &str) -> Value {
    json!({"model":model.model_id(),"stream":true,"store":false,"max_output_tokens":128,"thinking_budget":48,"input":[{"role":"user","content":[{"type":"input_text","text":text}]}]})
}
async fn qualify(lifecycle: &NativeInferenceLifecycle) -> Result<(), String> {
    let model = LocalModel::Qwen35_9b;
    eprintln!("NATIVE_9B_PHASE=owned_startup");
    lifecycle.prepare(&ModelId::Local(model)).await?;
    let original = lifecycle
        .worker_instance()
        .await
        .ok_or("Missing 9B instance")?;
    let base = lifecycle.local_base_url();
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(240))
        .build()
        .map_err(|_| "Client failed")?;
    let mut input = request(
        model,
        "Reply with exactly NATIVE_9B_READY. Do not use tools.",
    );
    let terminal = response(&client, &base, &input).await?;
    require(
        terminal["type"] == "response.completed",
        "9B generation failed",
    )?;
    require(
        terminal["response"]["output_text"].as_str() == Some("NATIVE_9B_READY"),
        "9B exact-answer oracle failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=exact_text_pass");
    let mut exhausted = request(model, "Explain a long mathematical proof in detail.");
    exhausted["max_output_tokens"] = json!(1);
    exhausted["thinking_budget"] = json!(0);
    let terminal = response(&client, &base, &exhausted).await?;
    require(
        terminal["type"] == "response.incomplete"
            && terminal["response"]["incomplete_details"]["reason"] == "max_output_tokens",
        "9B one-token exhaustion classification failed",
    )?;
    require(
        terminal["response"]["usage"]["output_tokens"] == 1,
        "9B one-token output accounting failed",
    )?;
    require(
        terminal["response"]["output"]
            .as_array()
            .is_some_and(|items| items.iter().all(|item| item["type"] != "function_call")),
        "Incomplete response published a completed function call",
    )?;
    let terminal = response(
        &client,
        &base,
        &request(
            model,
            "Reply with exactly NATIVE_9B_RECOVERED. Do not use tools.",
        ),
    )
    .await?;
    require(
        terminal["type"] == "response.completed"
            && terminal["response"]["output_text"].as_str() == Some("NATIVE_9B_RECOVERED"),
        "9B exhaustion recovery failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=exhaustion_recovery_pass");
    input["input"] = json!([{"role":"user","content":[{"type":"input_text","text":"Which single color fills this image? Answer only with the color name."},{"type":"input_image","image_url":format!("data:image/png;base64,{RED_PNG}")}]}]);
    let terminal = response(&client, &base, &input).await?;
    require(
        terminal["type"] == "response.completed",
        "9B vision generation failed",
    )?;
    require(
        terminal["response"]["output_text"]
            .as_str()
            .is_some_and(|s| s.trim().trim_matches('.').eq_ignore_ascii_case("red")),
        "9B red-image oracle failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=image_pass");
    input["input"] = json!("token ".repeat(20000));
    let terminal = response(&client, &base, &input).await?;
    require(
        terminal["type"] == "response.failed"
            && terminal["response"]["error"]["code"] == "context_length_exceeded",
        "9B overflow classification failed",
    )?;
    let budget = &terminal["response"]["context_budget"];
    require(
        budget["max_output_tokens"] == 128
            && budget["required_tokens"].as_u64()
                == budget["input_tokens"].as_u64().map(|n| n + 128),
        "9B context accounting failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=context_overflow_pass");
    input["input"] = json!("Explain every step of a long proof in detail.");
    input["max_output_tokens"] = json!(4096);
    let stream = client
        .post(format!("{base}/responses"))
        .json(&input)
        .send()
        .await
        .map_err(|_| "Cancellation request failed")?;
    require(stream.status().is_success(), "Cancellation HTTP refused")?;
    let mut body = stream.bytes_stream();
    body.next()
        .await
        .ok_or("Cancellation stream empty")?
        .map_err(|_| "Cancellation first event failed")?;
    require(
        lifecycle.health_snapshot().await?["busy"] == true,
        "Cancellation never observed an active generation",
    )?;
    require(
        lifecycle
            .prepare(&ModelId::Local(LocalModel::Qwen35_4b))
            .await
            .is_err(),
        "Busy model switch was accepted",
    )?;
    require(
        lifecycle.worker_instance().await == Some(original),
        "Busy switch replaced owned worker",
    )?;
    drop(body);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let health = lifecycle.health_snapshot().await?;
        if health["busy"] == false {
            require(
                health["selected_model"] == model.model_id(),
                "Cancellation selected a different model",
            )?;
            require(
                health["memory"]["cache_bytes"]
                    .as_u64()
                    .is_some_and(|n| n <= 256 * 1024 * 1024),
                "Cancellation cache cap failed",
            )?;
            break;
        }
        require(
            tokio::time::Instant::now() < deadline,
            "Cancellation failed to become idle",
        )?;
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let terminal = response(
        &client,
        &base,
        &request(
            model,
            "Reply with exactly CANCEL_RECOVERED. Do not use tools.",
        ),
    )
    .await?;
    require(
        terminal["type"] == "response.completed"
            && terminal["response"]["output_text"].as_str() == Some("CANCEL_RECOVERED"),
        "9B cancellation recovery failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=cancellation_recovery_pass");
    lifecycle
        .prepare(&ModelId::Local(LocalModel::Qwen35_4b))
        .await?;
    let four = lifecycle
        .worker_instance()
        .await
        .ok_or("Missing 4B switch instance")?;
    require(four != original, "Idle switch did not restart worker")?;
    let terminal = response(
        &client,
        &base,
        &request(
            LocalModel::Qwen35_4b,
            "Reply with exactly SWITCH_4B_READY. Do not use tools.",
        ),
    )
    .await?;
    require(
        terminal["type"] == "response.completed"
            && terminal["response"]["output_text"].as_str() == Some("SWITCH_4B_READY"),
        "4B switch answer failed",
    )?;
    eprintln!("NATIVE_9B_PHASE=idle_switch_4b_pass");
    lifecycle.prepare(&ModelId::Local(model)).await?;
    require(
        lifecycle
            .worker_instance()
            .await
            .is_some_and(|i| i != four && i != original),
        "9B return switch reused stale ownership",
    )?;
    let terminal = response(
        &client,
        &base,
        &request(
            model,
            "Reply with exactly SWITCH_9B_READY. Do not use tools.",
        ),
    )
    .await?;
    require(
        terminal["type"] == "response.completed"
            && terminal["response"]["output_text"].as_str() == Some("SWITCH_9B_READY"),
        "9B return switch answer failed",
    )?;
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "explicit reviewed 4B/9B roots and trusted colocated native worker required"]
async fn reviewed_nine_b_text_image_context_cancel_and_owned_model_switch() {
    let path = |key| {
        PathBuf::from(std::env::var_os(key).unwrap_or_else(|| panic!("Explicit {key} required")))
    };
    let worker = path("COMPUTA_TEST_MLX_WORKER");
    let four = path("COMPUTA_TEST_MLX_4B_ROOT");
    let nine = path("COMPUTA_TEST_MLX_9B_ROOT");
    let port = std::env::var("COMPUTA_TEST_MLX_PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|p| *p >= 1024 && *p != 1237)
        .expect("Explicit unused fixture port required");
    let home = tempfile::tempdir().unwrap();
    let private = computa_state::PrivateHome::at(home.path().join("home")).unwrap();
    let lifecycle = NativeInferenceLifecycle::new(NativeInferenceConfig {
        worker_executable: worker,
        model_roots: HashMap::from([(LocalModel::Qwen35_4b, four), (LocalModel::Qwen35_9b, nine)]),
        fallback_model_root: None,
        port,
        private_process_home: private.process_home,
        codex_home: private.codex_home,
        external_base_url: None,
    })
    .unwrap();
    let result = tokio::time::timeout(Duration::from_secs(900), qualify(&lifecycle)).await;
    let cleanup = tokio::time::timeout(Duration::from_secs(8), lifecycle.shutdown()).await;
    assert!(
        cleanup.is_ok_and(|r| r.is_ok()),
        "Owned worker cleanup unverified"
    );
    assert!(
        tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .is_err(),
        "Owned fixture listener remains"
    );
    assert!(
        matches!(result, Ok(Ok(()))),
        "Actual native9B qualification failed: {result:?}"
    );
}
