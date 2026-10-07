//! Lazy, app-owned native MLX worker lifecycle and explicit external preflight.
use crate::{
    agent::InferenceLifecycle,
    process::{OwnedProcess, diagnostic_phase, isolated_environment},
};
use async_trait::async_trait;
use computa_contracts::{
    models::{LocalModel, ModelId},
    strict_json,
};
use futures::StreamExt;
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;
#[derive(Clone, Debug)]
pub struct NativeInferenceConfig {
    /// Trusted executable selected by the signed app's resource resolver, never PATH.
    pub worker_executable: PathBuf,
    pub model_roots: HashMap<LocalModel, PathBuf>,
    pub fallback_model_root: Option<PathBuf>,
    pub port: u16,
    pub private_process_home: PathBuf,
    pub codex_home: PathBuf,
    /// Explicit opt-in only. Missing means external models fail without fallback.
    pub external_base_url: Option<Url>,
}
impl NativeInferenceConfig {
    pub fn bundled(
        resources: PathBuf,
        model_roots: HashMap<LocalModel, PathBuf>,
        home: &computa_state::PrivateHome,
    ) -> Self {
        Self {
            worker_executable: resources.join("InferenceRuntime/computa-inference-worker"),
            model_roots,
            fallback_model_root: None,
            port: 1237,
            private_process_home: home.process_home.clone(),
            codex_home: home.codex_home.clone(),
            external_base_url: None,
        }
    }
}
struct Worker {
    process: Arc<OwnedProcess>,
    instance: Uuid,
    model: LocalModel,
    ready: bool,
}
struct Supervisor {
    worker: Option<Worker>,
    stopped: bool,
}
pub struct NativeInferenceLifecycle {
    config: NativeInferenceConfig,
    client: reqwest::Client,
    state: Mutex<Supervisor>,
}
impl NativeInferenceLifecycle {
    pub fn new(config: NativeInferenceConfig) -> Result<Arc<Self>, String> {
        if config.port == 0 {
            return Err("The native inference port is invalid.".into());
        }
        if let Some(url) = &config.external_base_url {
            validate_endpoint(url)?;
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(|_| "Could not create the local inference client.".to_owned())?;
        Ok(Arc::new(Self {
            config,
            client,
            state: Mutex::new(Supervisor {
                worker: None,
                stopped: false,
            }),
        }))
    }
    pub fn local_base_url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.config.port)
    }
    async fn health(&self, instance: Uuid) -> Result<Value, String> {
        let url = format!("http://127.0.0.1:{}/health", self.config.port);
        let response = self
            .client
            .get(url)
            .timeout(Duration::from_secs(1))
            .send()
            .await
            .map_err(|_| "The owned MLX worker is not healthy.".to_owned())?;
        let health = bounded_json(response, 4096).await?;
        if health["status"] != "healthy"
            || health["heydash_instance"].as_str() != Some(instance.to_string().as_str())
            || health["backend"] != "computa-rust-mlx"
            || health["version"] != "mlex-0.1.3"
            || !health["busy"].is_boolean()
            || health["context_limit"].as_u64() != Some(16384)
        {
            return Err(
                "The local inference listener does not match this app-owned worker.".into(),
            );
        }
        Ok(health)
    }
    async fn start_worker(&self, state: &mut Supervisor, model: LocalModel) -> Result<(), String> {
        diagnostic_phase("native worker preparation entered");
        let root = self.config.model_roots.get(&model).ok_or_else(|| {
            "The selected 4B/9B model is not installed. No model was downloaded.".to_owned()
        })?;
        if !root.is_dir() {
            return Err(
                "The selected model directory is unavailable. No model was downloaded.".into(),
            );
        }
        let metadata = std::fs::symlink_metadata(&self.config.worker_executable)
            .map_err(|_| "Computa's native MLX worker is missing from its bundle.".to_owned())?;
        use std::os::unix::fs::PermissionsExt;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || metadata.permissions().mode() & 0o111 == 0
        {
            return Err("Computa's native MLX worker is not a regular executable.".into());
        }
        // A discovered listener is never adopted, stopped, or treated as ours.
        let probe =
            tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, self.config.port))
                .await
                .map_err(|_| {
                    "Port 1237 is occupied by another listener. Computa will not adopt or stop it."
                        .to_owned()
                })?;
        drop(probe);
        let instance = Uuid::new_v4();
        let mut args = vec![
            "--model-root".into(),
            root.to_string_lossy().into_owned(),
            "--model-id".into(),
            model.model_id().into(),
            "--port".into(),
            self.config.port.to_string(),
            "--parent-pid".into(),
            std::process::id().to_string(),
        ];
        if let Some(fallback) = &self.config.fallback_model_root {
            args.extend([
                "--fallback-model-root".into(),
                fallback.to_string_lossy().into_owned(),
            ]);
        }
        let mut environment: BTreeMap<_, _> =
            isolated_environment(&self.config.private_process_home, &self.config.codex_home);
        environment.insert("HEYDASH_MLX_INSTANCE".into(), instance.to_string());
        let (process, input, output) = OwnedProcess::spawn(
            &self.config.worker_executable,
            &args,
            &self.config.private_process_home,
            &environment,
        )
        .map_err(|e| e.to_string())?;
        drop(input);
        let mut output = output;
        tokio::spawn(async move {
            let _ = tokio::io::copy(&mut output, &mut tokio::io::sink()).await;
        });
        state.worker = Some(Worker {
            process: Arc::new(process),
            instance,
            model,
            ready: false,
        });
        diagnostic_phase("native worker health wait entered");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        loop {
            if let Some(exit) = state
                .worker
                .as_ref()
                .unwrap()
                .process
                .observed_exit()
                .map_err(|_| {
                    "The native MLX worker's exit status could not be observed safely.".to_owned()
                })?
            {
                diagnostic_phase("native worker exited before health");
                let error = format!(
                    "The owned native MLX worker stopped before becoming ready ({exit}). No fallback was started."
                );
                if state.worker.as_ref().unwrap().process.stop().await.is_ok() {
                    state.worker = None;
                }
                return Err(error);
            }
            if self.health(instance).await.is_ok() {
                diagnostic_phase("native worker owned health ready");
                break;
            }
            if tokio::time::Instant::now() >= deadline {
                let worker = state.worker.as_ref().unwrap();
                if worker.process.stop().await.is_ok() {
                    state.worker = None;
                }
                return Err("The native MLX worker did not become ready within 60 seconds. No fallback was started.".into());
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.validate_models(
            &Url::parse(&self.local_base_url())
                .map_err(|_| "Invalid native inference endpoint.".to_owned())?,
            model.model_id(),
        )
        .await?;
        state.worker.as_mut().unwrap().ready = true;
        Ok(())
    }
    pub async fn validate_models(&self, endpoint: &Url, model_id: &str) -> Result<(), String> {
        validate_endpoint(endpoint)?;
        let url = format!("{}/models", endpoint.as_str().trim_end_matches('/'));
        let response = self
            .client
            .get(url)
            .timeout(Duration::from_secs(2))
            .send()
            .await
            .map_err(|_| "The selected local model provider is unavailable.".to_owned())?;
        let value = bounded_json(response, 1024 * 1024).await?;
        let data = value["data"]
            .as_array()
            .filter(|a| !a.is_empty() && a.len() <= 4096)
            .ok_or_else(|| "The local provider returned an invalid model list.".to_owned())?;
        if !data.iter().all(|v| {
            v["id"]
                .as_str()
                .is_some_and(|s| !s.is_empty() && s.len() <= 1024)
        }) {
            return Err("The local provider returned an invalid model list.".into());
        }
        if !data.iter().any(|v| v["id"].as_str() == Some(model_id)) {
            return Err("The selected model is not advertised by the configured local provider. No model was switched or downloaded.".into());
        }
        Ok(())
    }
    pub async fn worker_instance(&self) -> Option<Uuid> {
        self.state.lock().await.worker.as_ref().map(|w| w.instance)
    }
    pub async fn health_snapshot(&self) -> Result<Value, String> {
        let state = self.state.lock().await;
        let worker = state
            .worker
            .as_ref()
            .ok_or_else(|| "Native MLX has not been started.".to_owned())?;
        self.health(worker.instance).await
    }
}
#[async_trait]
impl InferenceLifecycle for NativeInferenceLifecycle {
    async fn prepare(&self, model: &ModelId) -> Result<(), String> {
        diagnostic_phase("inference prepare entered");
        if matches!(model, ModelId::Browser(_)) {
            return Ok(());
        }
        let mut state = self.state.lock().await;
        if state.stopped {
            return Err("Native inference is shutting down.".into());
        }
        if let ModelId::Local(local) = model
            && local.supports_headless_mlx()
        {
            if let Some(worker) = state.worker.as_ref() {
                let health = self.health(worker.instance).await?;
                if health["busy"] == true {
                    return Err(
                        "Wait for the owned MLX worker to finish before changing its model.".into(),
                    );
                }
                if worker.model == *local && worker.ready {
                    if health["selected_model"]
                        .as_str()
                        .is_some_and(|m| m != local.model_id())
                    {
                        return Err("The owned MLX worker selected an unexpected model.".into());
                    }
                    return Ok(());
                }
                worker.process.stop().await.map_err(|e| e.to_string())?;
                state.worker = None;
            }
            return self.start_worker(&mut state, *local).await;
        }
        let external=self.config.external_base_url.as_ref().ok_or_else(||"This model requires an explicitly configured external local provider. Computa will not switch to one automatically.".to_owned())?;
        if let Some(worker) = state.worker.as_ref() {
            let h = self.health(worker.instance).await?;
            if h["busy"] == true {
                return Err("The native MLX worker is busy.".into());
            }
            worker.process.stop().await.map_err(|e| e.to_string())?;
            state.worker = None;
        }
        drop(state);
        self.validate_models(external, model.as_str()).await
    }
    async fn endpoint(&self, model: &ModelId) -> Result<Option<String>, String> {
        match model {
            ModelId::Browser(_) => Ok(None),
            ModelId::Local(local) if local.supports_headless_mlx() => {
                Ok(Some(self.local_base_url()))
            }
            _ => self
                .config
                .external_base_url
                .as_ref()
                .map(|u| Some(u.to_string()))
                .ok_or_else(|| "No external local inference provider is configured.".into()),
        }
    }
    async fn shutdown(&self) -> Result<(), String> {
        let mut state = self.state.lock().await;
        state.stopped = true;
        if let Some(worker) = state.worker.as_ref() {
            worker.process.stop().await.map_err(|e| e.to_string())?;
            state.worker = None;
        }
        Ok(())
    }
}
fn validate_endpoint(url: &Url) -> Result<(), String> {
    let loopback = match url.host() {
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        Some(url::Host::Domain(d)) => d == "localhost",
        _ => false,
    };
    if url.scheme() != "http"
        || !loopback
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.port_or_known_default().is_none()
    {
        Err("A local provider must use an explicit HTTP loopback URL without credentials, query, or fragment.".into())
    } else {
        Ok(())
    }
}
async fn bounded_json(response: reqwest::Response, maximum: usize) -> Result<Value, String> {
    if !response.status().is_success() {
        return Err("The local inference provider returned an unsuccessful response.".into());
    }
    if response
        .content_length()
        .is_some_and(|n| n > maximum as u64)
    {
        return Err("The local inference response exceeds its byte limit.".into());
    }
    let mut chunks = response.bytes_stream();
    let mut bytes = vec![];
    while let Some(chunk) = chunks.next().await {
        let chunk = chunk.map_err(|_| "Could not read the local inference response.".to_owned())?;
        if bytes.len() + chunk.len() > maximum {
            return Err("The local inference response exceeds its byte limit.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    strict_json::parse(&bytes)
        .map_err(|_| "The local inference provider returned malformed JSON.".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn external_endpoint_cannot_leave_loopback_or_carry_credentials() {
        for url in [
            "https://127.0.0.1/v1",
            "http://example.com/v1",
            "http://user:secret@127.0.0.1/v1",
            "http://127.0.0.1/v1?key=x",
            "http://127.0.0.1/v1#fragment",
        ] {
            assert!(validate_endpoint(&Url::parse(url).unwrap()).is_err());
        }
        assert!(validate_endpoint(&Url::parse("http://[::1]:1234/v1").unwrap()).is_ok());
    }
    #[tokio::test]
    async fn explicit_external_models_are_checked_exactly() {
        use axum::{Json, Router, routing::get};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().route(
            "/v1/models",
            get(|| async { Json(serde_json::json!({"data":[{"id":"installed-model"}]})) }),
        );
        let worker = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let temp = tempfile::tempdir().unwrap();
        let config = NativeInferenceConfig {
            worker_executable: PathBuf::from("not-used"),
            model_roots: HashMap::new(),
            fallback_model_root: None,
            port: 1237,
            private_process_home: temp.path().into(),
            codex_home: temp.path().into(),
            external_base_url: Some(Url::parse(&format!("http://127.0.0.1:{port}/v1")).unwrap()),
        };
        let lifecycle = NativeInferenceLifecycle::new(config).unwrap();
        assert!(
            lifecycle
                .prepare(&ModelId::parse("installed-model").unwrap())
                .await
                .is_ok()
        );
        assert!(
            lifecycle
                .prepare(&ModelId::parse("missing-model").unwrap())
                .await
                .is_err()
        );
        assert!(lifecycle.worker_instance().await.is_none());
        worker.abort();
    }
}
