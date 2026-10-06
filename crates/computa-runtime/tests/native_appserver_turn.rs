//! Exact pinned App Server + owned native worker, isolated from installed state.
use async_trait::async_trait;
use computa_contracts::{
    Identifier,
    appserver::{DispatchError, ExecutionScope, ToolDispatcher, ToolOutput, TurnConclusion},
    models::{LocalModel, ModelId},
    ui::{EntryKind, NativeAction},
};
use computa_runtime::{
    InferenceLifecycle, NativeInferenceConfig, NativeInferenceLifecycle, Runtime, RuntimeConfig,
};
use computa_state::PrivateHome;
use serde_json::{Value, json};
use std::{collections::HashMap, path::PathBuf, sync::Arc, time::Duration};
struct NoTools;
struct RecordingInference {
    native: Arc<NativeInferenceLifecycle>,
    endpoint: String,
}
#[async_trait]
impl InferenceLifecycle for RecordingInference {
    async fn prepare(&self, model: &ModelId) -> Result<(), String> {
        self.native.prepare(model).await
    }
    async fn endpoint(&self, _: &ModelId) -> Result<Option<String>, String> {
        Ok(Some(self.endpoint.clone()))
    }
    async fn shutdown(&self) -> Result<(), String> {
        self.native.shutdown().await
    }
}
#[derive(Clone)]
struct ProxyState {
    target: String,
    client: reqwest::Client,
    shapes: Arc<tokio::sync::Mutex<Vec<Value>>>,
}
fn type_label(value: &Value) -> &'static str {
    match value.as_str() {
        Some("message") => "message",
        Some("input_text") => "input_text",
        Some("output_text") => "output_text",
        Some("input_image") => "input_image",
        Some("function_call") => "function_call",
        Some("function_call_output") => "function_call_output",
        Some("reasoning") => "reasoning",
        Some("function") => "function",
        Some("namespace") => "namespace",
        Some("custom") => "custom",
        None => "absent",
        _ => "other",
    }
}
fn finite_shape(raw: &Value) -> Value {
    let input=raw["input"].as_array().map(|items|items.iter().map(|item|json!({"type":type_label(&item["type"]),"role":match item["role"].as_str(){Some("system")=>"system",Some("developer")=>"developer",Some("user")=>"user",Some("assistant")=>"assistant",None=>"absent",_=>"other"},"content":item["content"].as_array().map(|parts|parts.iter().map(|part|type_label(&part["type"])).collect::<Vec<_>>())})).collect::<Vec<_>>());
    json!({"instructions_string":raw["instructions"].is_string(),"input":input,"tools":raw["tools"].as_array().map(|tools|tools.iter().map(|tool|json!({"type":type_label(&tool["type"]),"children":tool["tools"].as_array().map(|children|children.iter().map(|child|type_label(&child["type"])).collect::<Vec<_>>())})).collect::<Vec<_>>()),"temperature_present":raw.get("temperature").is_some(),"tool_choice_present":raw.get("tool_choice").is_some()})
}
async fn proxy_response(
    axum::extract::State(state): axum::extract::State<ProxyState>,
    body: axum::body::Bytes,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    use futures::StreamExt;
    if let Ok(raw) = computa_contracts::strict_json::parse(&body) {
        state.shapes.lock().await.push(finite_shape(&raw));
    }
    let response = match state
        .client
        .post(&state.target)
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
    {
        Ok(response) => response,
        Err(_) => return axum::http::StatusCode::BAD_GATEWAY.into_response(),
    };
    let status = response.status();
    let content_type = response.headers().get("Content-Type").cloned();
    let stream = response
        .bytes_stream()
        .map(|chunk| chunk.map_err(std::io::Error::other));
    let mut result = axum::http::Response::new(axum::body::Body::from_stream(stream));
    *result.status_mut() = status;
    if let Some(content_type) = content_type {
        result.headers_mut().insert("Content-Type", content_type);
    }
    result
}
#[async_trait]
impl ToolDispatcher for NoTools {
    async fn begin_turn(&self, _: ExecutionScope) -> Result<(), DispatchError> {
        Ok(())
    }
    async fn execute(
        &self,
        _: ExecutionScope,
        _: Identifier,
        _: String,
        _: Value,
    ) -> Result<ToolOutput, DispatchError> {
        Ok(ToolOutput::text(
            "This qualification prompt does not authorize computer actions.",
            false,
        ))
    }
    async fn end_turn(&self, _: ExecutionScope) -> TurnConclusion {
        TurnConclusion::default()
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "Requires explicit trusted App Server resources/native worker/installed4B and unused qualification port; no downloads"]
async fn native_action_uses_custom_provider_finishes_real_turn_and_keeps_upstream_history() {
    let resources = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_APP_RESOURCES")
            .expect("Explicit trusted resources required"),
    );
    let worker = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_MLX_WORKER").expect("Explicit native worker required"),
    );
    let weights = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_MLX_MODEL_ROOT")
            .expect("Explicit installed4B root required"),
    );
    let port = std::env::var("COMPUTA_TEST_MLX_PORT")
        .unwrap()
        .parse::<u16>()
        .unwrap();
    assert!(port >= 1024 && port != 1237);
    let temporary = tempfile::tempdir().unwrap();
    let home = PrivateHome::at(temporary.path().join("CodexHome")).unwrap();
    let inference = NativeInferenceLifecycle::new(NativeInferenceConfig {
        worker_executable: worker,
        model_roots: HashMap::from([(LocalModel::Qwen35_4b, weights)]),
        fallback_model_root: None,
        port,
        private_process_home: home.process_home.clone(),
        codex_home: home.codex_home.clone(),
        external_base_url: None,
    })
    .unwrap();
    let shapes = Arc::new(tokio::sync::Mutex::new(Vec::new()));
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .unwrap();
    let address = listener.local_addr().unwrap();
    let proxy = ProxyState {
        target: format!("http://127.0.0.1:{port}/v1/responses"),
        client: reqwest::Client::builder().no_proxy().build().unwrap(),
        shapes: shapes.clone(),
    };
    let router = axum::Router::new()
        .route("/v1/responses", axum::routing::post(proxy_response))
        .layer(axum::extract::DefaultBodyLimit::max(32 * 1024 * 1024))
        .with_state(proxy);
    let (stop_proxy, stopping) = tokio::sync::oneshot::channel::<()>();
    let proxy_task = tokio::spawn(async move {
        axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                let _ = stopping.await;
            })
            .await
            .unwrap();
    });
    let inference = Arc::new(RecordingInference {
        native: inference,
        endpoint: format!("http://{address}/v1"),
    });
    let mut config = RuntimeConfig::new(resources, home.clone());
    config.local_base_url = Some(format!("http://127.0.0.1:{port}/v1"));
    assert_eq!(config.model_provider, "computa_local");
    let runtime = Runtime::launch(config.clone(), Arc::new(NoTools), inference.clone(), None)
        .await
        .unwrap();
    let task = runtime.create_task().await;
    let request = Identifier::new("native-turn-request").unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(75),
        runtime.handle_action(NativeAction::SubmitPrompt {
            request_id: request.clone(),
            task_id: task.clone(),
            prompt: "Reply with only the word READY. Do not use tools.".into(),
        }),
    )
    .await;
    let mut outcome = Err("The native turn did not complete".to_owned());
    if matches!(result, Ok(Ok(()))) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(150);
        loop {
            let snapshot = runtime.snapshot().await;
            let view = snapshot.tasks.iter().find(|t| t.id == task).unwrap();
            if !view.is_busy {
                outcome = if view.status == "Completed"
                    && view
                        .entries
                        .iter()
                        .any(|e| e.kind == EntryKind::Assistant && e.body.trim() == "READY")
                    && snapshot
                        .prompt_receipts
                        .iter()
                        .any(|r| r.id == request && r.task_id == task && r.accepted)
                {
                    Ok(())
                } else {
                    Err(format!(
                        "Native task terminal status={}, receipt={:?}",
                        view.status, snapshot.prompt_receipts
                    ))
                };
                break;
            }
            if tokio::time::Instant::now() >= deadline {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
    let history = if outcome.is_ok() {
        runtime.load_history(&task).await
    } else {
        Ok(())
    };
    let saved = runtime.snapshot().await;
    let stopped = runtime.shutdown().await;
    let mut cold_outcome = Err("Cold native chat was not recovered".to_owned());
    if outcome.is_ok() {
        let cold = Runtime::launch(config, Arc::new(NoTools), inference, None)
            .await
            .unwrap();
        if cold.load_threads().await.is_ok() {
            let listing = cold.snapshot().await;
            let recovered = listing
                .tasks
                .iter()
                .find(|t| {
                    t.model == ModelId::Local(LocalModel::Qwen35_4b)
                        && t.title == "Reply with only the word READY. Do not use tools."
                })
                .map(|t| t.id.clone());
            if let Some(recovered) = recovered
                && cold.load_history(&recovered).await.is_ok()
            {
                let history = cold.snapshot().await;
                if history
                    .tasks
                    .iter()
                    .find(|t| t.id == recovered)
                    .is_some_and(|t| {
                        t.entries.iter().any(|e| {
                            e.kind == EntryKind::User
                                && e.body == "Reply with only the word READY. Do not use tools."
                        }) && t
                            .entries
                            .iter()
                            .any(|e| e.kind == EntryKind::Assistant && e.body.trim() == "READY")
                    })
                {
                    cold_outcome = Ok(());
                }
            }
        }
        let cleanup = cold.shutdown().await;
        assert!(cleanup.is_empty(), "Cold owned cleanup failed");
    }
    let _ = stop_proxy.send(());
    tokio::time::timeout(Duration::from_secs(3), proxy_task)
        .await
        .unwrap()
        .unwrap();
    let captured = shapes.lock().await;
    eprintln!(
        "Finite AppServer request shape: {}",
        serde_json::to_string(&*captured).unwrap()
    );
    assert!(
        captured.iter().any(|shape| shape["input"]
            .as_array()
            .is_some_and(|items| items.iter().any(|item| item["role"] == "developer"))),
        "Real AppServer developer instructions must be represented in the adapter fixture"
    );
    assert!(stopped.is_empty(), "Owned cleanup failed: {stopped:?}");
    assert!(
        matches!(result, Ok(Ok(()))),
        "NativeAction submit failed: {result:?}"
    );
    assert!(
        outcome.is_ok(),
        "Native actual model turn failed: {outcome:?}"
    );
    assert!(
        cold_outcome.is_ok(),
        "Cold provider/model/history recovery failed"
    );
    history.unwrap();
    assert!(home.upstream_database().exists());
    assert!(
        saved
            .tasks
            .iter()
            .find(|t| t.id == task)
            .unwrap()
            .entries
            .iter()
            .any(|e| e.kind == EntryKind::User)
    );
    assert!(
        tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .is_err(),
        "Owned listener must be gone"
    );
}
