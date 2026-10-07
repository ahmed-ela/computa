//! Explicit installed-weights qualification; never downloads a model or touches
//! the installed app, its inference listener, Chrome, or persistent chat state.
#![cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::models::LocalModel;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    process::{Child, Command, Stdio},
    time::Duration,
};
struct OwnedWorker(Child);
impl Drop for OwnedWorker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn events(stream: &str) -> Vec<Value> {
    stream
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .map(|data| serde_json::from_str(data).unwrap())
        .collect()
}
#[tokio::test]
#[ignore = "requires explicitly selected installed catalog weights"]
async fn installed_native_model_text_image_context_and_disconnect() {
    let root = PathBuf::from(
        std::env::var_os("COMPUTA_QUAL_MODEL_ROOT")
            .expect("Set COMPUTA_QUAL_MODEL_ROOT to installed model directory"),
    );
    let model = LocalModel::Qwen35_4b;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let instance = uuid::Uuid::new_v4();
    // Production workers require direct, immutable colocated resources. Cargo's
    // generated resource directory is verified before preparing this owned copy.
    let built = PathBuf::from(env!("CARGO_BIN_EXE_computa-inference-worker"));
    let metal = built.parent().unwrap().join("NativeInferenceResources");
    computa_inference::metal_resources::verify_directory(&metal).unwrap();
    let stage = tempfile::tempdir().unwrap();
    let worker_path = stage.path().join("computa-inference-worker");
    std::fs::copy(&built, &worker_path).unwrap();
    for file in ["mlx.metallib", "manifest.json"] {
        std::fs::copy(metal.join(file), stage.path().join(file)).unwrap();
    }
    computa_inference::metal_resources::verify_directory(stage.path()).unwrap();
    let mut command = Command::new(&worker_path);
    command
        .args([
            "--model-root",
            root.to_str().unwrap(),
            "--model-id",
            model.model_id(),
            "--port",
            &port.to_string(),
            "--parent-pid",
            &std::process::id().to_string(),
        ])
        .env("HEYDASH_MLX_INSTANCE", instance.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    let _child = OwnedWorker(command.spawn().unwrap());
    let base = format!("http://127.0.0.1:{port}");
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(120))
        .build()
        .unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        if let Ok(response) = client.get(format!("{base}/health")).send().await
            && response.status().is_success()
        {
            let health: Value = response.json().await.unwrap();
            assert_eq!(health["heydash_instance"], instance.to_string());
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "owned native worker failed health startup"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let mut request = json!({"model":model.model_id(),"stream":true,"store":false,"max_output_tokens":128,"thinking_budget":48,"input":[{"role":"user","content":[{"type":"input_text","text":"Reply with exactly RUST_INFERENCE_770CE53A. Do not use tools."}]}]});
    let response = client
        .post(format!("{base}/v1/responses"))
        .json(&request)
        .send()
        .await
        .unwrap();
    assert!(response.status().is_success());
    let stream = response.text().await.unwrap();
    let parsed = events(&stream);
    let terminal = parsed.last().expect("native stream events");
    assert_eq!(
        terminal["type"], "response.completed",
        "Synthetic qualification stream: {stream}"
    );
    assert!(
        terminal["response"]["output_text"]
            .as_str()
            .unwrap()
            .contains("RUST_INFERENCE_770CE53A")
    );
    let public: String = parsed
        .iter()
        .filter(|event| event["type"] == "response.output_text.delta")
        .map(|event| event["delta"].as_str().unwrap())
        .collect();
    assert_eq!(terminal["response"]["output_text"], public);
    assert!(
        terminal["response"]["usage"]["input_tokens"]
            .as_u64()
            .unwrap()
            > 0
    );
    let image = image::RgbImage::from_pixel(64, 64, image::Rgb([255, 0, 0]));
    let mut png = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(image)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    request["input"] = json!([{"role":"user","content":[{"type":"input_text","text":"Which single color fills this image? Answer only with the color name."},{"type":"input_image","image_url":format!("data:image/png;base64,{}",STANDARD.encode(png.into_inner()))}]}]);
    let stream = client
        .post(format!("{base}/v1/responses"))
        .json(&request)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let parsed = events(&stream);
    let terminal = parsed.last().unwrap();
    assert_eq!(terminal["type"], "response.completed", "{terminal}");
    assert!(
        terminal["response"]["output_text"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("red"),
        "{terminal}"
    );
    request["input"] = json!(
        "Call fixture.marker with marker equal RUST_TOOL_770C and confirmed true. This function is offered below. Do not answer with ordinary text."
    );
    request["tools"] = json!([{"type":"namespace","name":"fixture","tools":[{"type":"function","name":"marker","description":"Return the supplied marker to the fixture","parameters":{"type":"object","properties":{"marker":{"type":"string"},"confirmed":{"type":"boolean"}},"required":["marker","confirmed"]}}]}]);
    request["tool_choice"] = json!("required");
    request["max_output_tokens"] = json!(256);
    request["thinking_budget"] = json!(64);
    let stream = client
        .post(format!("{base}/v1/responses"))
        .json(&request)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let parsed = events(&stream);
    let terminal = parsed.last().unwrap();
    assert_eq!(
        terminal["type"], "response.completed",
        "Synthetic namespaced-tool qualification stream: {stream}"
    );
    let calls: Vec<_> = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["type"] == "function_call")
        .collect();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0]["namespace"], "fixture");
    assert_eq!(calls[0]["name"], "marker");
    let arguments: Value = serde_json::from_str(calls[0]["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["marker"], "RUST_TOOL_770C");
    assert_eq!(arguments["confirmed"], true);
    assert_eq!(terminal["response"]["end_turn"], false);
    request.as_object_mut().unwrap().remove("tools");
    request.as_object_mut().unwrap().remove("tool_choice");
    request["max_output_tokens"] = json!(128);
    request["input"] = json!("token ".repeat(20000));
    let stream = client
        .post(format!("{base}/v1/responses"))
        .json(&request)
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    let parsed = events(&stream);
    let terminal = parsed.last().unwrap();
    assert_eq!(terminal["type"], "response.failed");
    assert_eq!(
        terminal["response"]["error"]["code"],
        "context_length_exceeded"
    );
    let budget = &terminal["response"]["context_budget"];
    assert_eq!(budget["max_output_tokens"], 128);
    assert_eq!(
        budget["required_tokens"].as_u64().unwrap(),
        budget["input_tokens"].as_u64().unwrap() + 128
    );
    use futures::StreamExt;
    request["input"] = json!("Explain every step of a long proof in detail.");
    request["max_output_tokens"] = json!(4096);
    let response = client
        .post(format!("{base}/v1/responses"))
        .json(&request)
        .send()
        .await
        .unwrap();
    let mut body = response.bytes_stream();
    assert!(body.next().await.unwrap().is_ok());
    drop(body);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let health: Value = client
            .get(format!("{base}/health"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if health["busy"] == false {
            assert_eq!(health["selected_model"], model.model_id());
            assert!(health["memory"]["cache_bytes"].as_u64().unwrap() <= 256 * 1024 * 1024);
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "disconnect did not release generation"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
