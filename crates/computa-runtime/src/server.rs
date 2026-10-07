//! Authenticated loopback Responses API. Only the native runtime authorizes task leases.
use crate::{browser::BrowserInference, codec};
use axum::{
    Json, Router,
    body::{Body, Bytes, to_bytes},
    extract::{DefaultBodyLimit, Request, State},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::post,
};
use computa_contracts::Identifier;
use serde_json::json;
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
struct HttpState {
    inference: Arc<BrowserInference>,
    bearer: String,
    capacity: Arc<Semaphore>,
}
pub struct WebModelServer {
    pub base_url: String,
    pub bearer_token: String,
    stop: CancellationToken,
    worker: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
    pub inference: Arc<BrowserInference>,
}
impl WebModelServer {
    pub async fn start(inference: Arc<BrowserInference>) -> std::io::Result<Self> {
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        let port = listener.local_addr()?.port();
        let bearer_token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let state = Arc::new(HttpState {
            inference: inference.clone(),
            bearer: bearer_token.clone(),
            capacity: Arc::new(Semaphore::new(8)),
        });
        let app = Router::new()
            .route("/v1/responses", post(responses))
            .layer(DefaultBodyLimit::max(2_000_000))
            .layer(middleware::from_fn_with_state(state.clone(), admit))
            .with_state(state);
        let stop = CancellationToken::new();
        let cancel = stop.clone();
        let worker = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(cancel.cancelled_owned())
                .await
        });
        Ok(Self {
            base_url: format!("http://127.0.0.1:{port}/v1"),
            bearer_token,
            stop,
            worker: Some(worker),
            inference,
        })
    }
    pub async fn shutdown(&mut self) -> Vec<String> {
        self.stop.cancel();
        let mut errors = self.inference.shutdown().await;
        if let Some(worker) = self.worker.take() {
            match tokio::time::timeout(std::time::Duration::from_secs(35), worker).await {
                Ok(Ok(Ok(()))) => {}
                _ => {
                    errors.push("The browser inference listener did not shut down cleanly.".into())
                }
            }
        }
        errors
    }
}
impl Drop for WebModelServer {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
async fn admit(State(state): State<Arc<HttpState>>, request: Request, next: Next) -> Response {
    if request.uri().path() != "/v1/responses" || request.uri().query().is_some() {
        return error(
            StatusCode::NOT_FOUND,
            "The local model path is unavailable.",
        );
    }
    let headers = request.headers();
    let bytes: usize = headers
        .iter()
        .map(|(k, v)| k.as_str().len() + v.as_bytes().len() + 4)
        .sum();
    if bytes > 16 * 1024 || headers.len() > 128 {
        return error(
            StatusCode::REQUEST_HEADER_FIELDS_TOO_LARGE,
            "The local model headers exceed their byte limit.",
        );
    }
    if headers.contains_key(header::ORIGIN)
        || headers.get_all(header::AUTHORIZATION).iter().count() != 1
        || headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            != Some(format!("Bearer {}", state.bearer).as_str())
    {
        return error(
            StatusCode::UNAUTHORIZED,
            "The local model request is unauthorized.",
        );
    }
    let _permit = match state.capacity.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return error(
                StatusCode::TOO_MANY_REQUESTS,
                "The local model connection capacity has been reached.",
            );
        }
    };
    let (parts, body) = request.into_parts();
    let bytes = match tokio::time::timeout(
        std::time::Duration::from_secs(15),
        to_bytes(body, 2_000_000),
    )
    .await
    {
        Ok(Ok(v)) => v,
        Ok(Err(_)) => {
            return error(
                StatusCode::PAYLOAD_TOO_LARGE,
                "The local model body exceeds its byte limit.",
            );
        }
        Err(_) => {
            return error(
                StatusCode::REQUEST_TIMEOUT,
                "The local model body read timed out.",
            );
        }
    };
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}
async fn responses(
    State(state): State<Arc<HttpState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    if headers.contains_key(header::ORIGIN)
        || headers.get_all(header::AUTHORIZATION).iter().count() != 1
        || headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            != Some(format!("Bearer {}", state.bearer).as_str())
    {
        return error(
            StatusCode::UNAUTHORIZED,
            "The local model request is unauthorized.",
        );
    }
    if headers.get_all("X-Computa-Task-ID").iter().count() != 1 {
        return error(
            StatusCode::BAD_REQUEST,
            "An exact task identity is required.",
        );
    }
    let task = match headers
        .get("X-Computa-Task-ID")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| Identifier::new(s).ok())
    {
        Some(v) => v,
        None => {
            return error(
                StatusCode::BAD_REQUEST,
                "An exact task identity is required.",
            );
        }
    };

    let request = match codec::prepare_request(&body) {
        Ok(v) => v,
        Err(e) => return error(StatusCode::BAD_REQUEST, &e.to_string()),
    };
    let reply = match state.inference.infer(&task, &request).await {
        Ok(v) => v,
        Err(e) => return error(StatusCode::BAD_GATEWAY, &e.to_string()),
    };
    let id = codec::new_response_id();
    let created = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    if request.stream {
        (
            [
                (header::CONTENT_TYPE, "text/event-stream"),
                (header::CACHE_CONTROL, "no-store"),
            ],
            codec::sse(&reply, &request, &id, created),
        )
            .into_response()
    } else {
        (
            [(header::CACHE_CONTROL, "no-store")],
            Json(codec::completed_response(&reply, &request, &id, created)),
        )
            .into_response()
    }
}
fn error(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(json!({"error":{"type":"computa_web_model_error","message":message}})),
    )
        .into_response()
}
#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use computa_contracts::{models::WebProvider, responses::*};
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Website {
        token: uuid::Uuid,
        calls: AtomicUsize,
        sequence: AtomicUsize,
    }
    #[async_trait]
    impl BrowserTransport for Website {
        async fn request(
            &self,
            op: BrowserOperation,
        ) -> Result<BrowserSnapshot, BrowserTransportError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let (state, text, cleanup) = match op {
                BrowserOperation::Start { .. } => (BrowserState::Ready, String::new(), None),
                BrowserOperation::Send { .. } => (
                    BrowserState::Complete,
                    r#"{"type":"message","text":"Hello"}"#.into(),
                    None,
                ),
                BrowserOperation::Finish { .. } | BrowserOperation::Cancel { .. } => (
                    BrowserState::Finished,
                    String::new(),
                    Some(BrowserCleanup {
                        closed: true,
                        error: None,
                    }),
                ),
                _ => return Err(BrowserTransportError::InvalidResponse),
            };
            Ok(BrowserSnapshot {
                session_token: self.token,
                provider: WebProvider::Claude,
                state,
                sequence: self.sequence.fetch_add(1, Ordering::SeqCst) as u64,
                text,
                cleanup,
                error: None,
            })
        }
    }
    #[tokio::test]
    async fn loopback_rejects_browser_origins_wrong_bearer_duplicate_task_and_wrong_model() {
        let website = Arc::new(Website {
            token: uuid::Uuid::new_v4(),
            calls: AtomicUsize::new(0),
            sequence: AtomicUsize::new(0),
        });
        let inference = Arc::new(BrowserInference::new(website.clone()));
        let task = Identifier::new("task").unwrap();
        inference
            .authorize_task(task.clone(), WebProvider::Claude)
            .await
            .unwrap();
        let mut server = WebModelServer::start(inference).await.unwrap();
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let url = format!("{}/responses", server.base_url);
        let body = json!({"model":"browser/claude","input":"hello","stream":true});
        let signed = || {
            client
                .post(&url)
                .bearer_auth(&server.bearer_token)
                .header("X-Computa-Task-ID", "task")
                .json(&body)
        };
        assert_eq!(
            client.post(&url).json(&body).send().await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            signed()
                .header("Origin", "https://claude.ai")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            signed()
                .header("X-Computa-Task-ID", "other")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::BAD_REQUEST
        );
        let wrong = json!({"model":"browser/chatgpt","input":"hello"});
        assert_eq!(
            client
                .post(&url)
                .bearer_auth(&server.bearer_token)
                .header("X-Computa-Task-ID", "task")
                .json(&wrong)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::BAD_GATEWAY
        );
        assert_eq!(website.calls.load(Ordering::SeqCst), 0);
        let response = signed().send().await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "text/event-stream"
        );
        assert!(
            response
                .text()
                .await
                .unwrap()
                .contains("response.completed")
        );
        assert_eq!(website.calls.load(Ordering::SeqCst), 2);
        assert!(server.shutdown().await.is_empty());
    }
}
