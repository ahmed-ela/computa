//! Explicit local qualification, isolated from the installed app and port1237.
use computa_contracts::models::{LocalModel, ModelId};
use computa_runtime::{
    agent::InferenceLifecycle,
    inference::{NativeInferenceConfig, NativeInferenceLifecycle},
};
use std::{collections::HashMap, path::PathBuf, time::Duration};
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "Requires explicit trusted Rust worker and installed 4B paths; never downloads a model"]
async fn owned_native_worker_starts_with_private_home_exact_instance_and_bounded_shutdown() {
    let executable = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_MLX_WORKER").expect("Explicit trusted worker required"),
    );
    let model_root = PathBuf::from(
        std::env::var_os("COMPUTA_TEST_MLX_MODEL_ROOT")
            .expect("Explicit installed 4B root required"),
    );
    let port = std::env::var("COMPUTA_TEST_MLX_PORT")
        .ok()
        .and_then(|s| s.parse::<u16>().ok())
        .filter(|p| *p >= 1024 && *p != 1237)
        .expect("Explicit unused qualification port required");
    let private = tempfile::tempdir().unwrap();
    let process_home = private.path().join("process-home");
    let codex_home = private.path().join("codex-home");
    std::fs::create_dir(&process_home).unwrap();
    std::fs::create_dir(&codex_home).unwrap();
    let model = LocalModel::Qwen35_4b;
    assert!(model.supports_headless_mlx());
    let lifecycle = NativeInferenceLifecycle::new(NativeInferenceConfig {
        worker_executable: executable,
        model_roots: HashMap::from([(model, model_root)]),
        fallback_model_root: None,
        port,
        private_process_home: process_home,
        codex_home,
        external_base_url: None,
    })
    .unwrap();
    let prepared = tokio::time::timeout(
        Duration::from_secs(75),
        lifecycle.prepare(&ModelId::Local(model)),
    )
    .await;
    let instance = lifecycle.worker_instance().await;
    let health = if matches!(prepared, Ok(Ok(()))) {
        Some(lifecycle.health_snapshot().await)
    } else {
        None
    };
    // Cleanup runs before asserting readiness, including failed/timed-out starts.
    let stopped = tokio::time::timeout(Duration::from_secs(8), lifecycle.shutdown()).await;
    assert!(
        stopped.is_ok_and(|result| result.is_ok()),
        "Owned worker shutdown must complete"
    );
    assert!(lifecycle.worker_instance().await.is_none());
    assert!(
        matches!(prepared, Ok(Ok(()))),
        "Owned subprocess readiness failed: {prepared:?}"
    );
    let instance = instance.expect("Ready worker instance");
    let health = health.unwrap().expect("Owned listener health");
    assert_eq!(health["status"], "healthy");
    assert_eq!(health["heydash_instance"], instance.to_string());
    assert_eq!(health["backend"], "computa-rust-mlx");
    assert_eq!(health["version"], "mlex-0.1.3");
    assert!(!health["busy"].as_bool().unwrap());
    assert!(
        tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port))
            .await
            .is_err(),
        "The exact owned listener must be absent after shutdown"
    );
}
