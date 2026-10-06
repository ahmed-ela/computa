//! Native-only loopback server. A single owned thread retains MLX allocations;
//! requests are never queued, adopted from other listeners, or replayed.
use crate::{
    generation::{InferenceError, Memory, Reply, Usage},
    live::Delta,
    request::{self, Request as ModelRequest},
};
use axum::{
    Json, Router,
    body::{Body, Bytes, to_bytes},
    extract::{Request, State},
    http::{StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use computa_contracts::models::LocalModel;
use futures::Stream;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    convert::Infallible,
    path::PathBuf,
    sync::{Arc, Mutex, mpsc as sync_mpsc},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub trait Backend {
    fn generate(
        &mut self,
        request: ModelRequest,
        alive: &mut dyn FnMut() -> bool,
        emit: &mut dyn FnMut(Delta) -> bool,
    ) -> Result<Reply, InferenceError>;
    fn memory(&self) -> Memory;
}
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
impl Backend for crate::mlx::OwnedModel {
    fn generate(
        &mut self,
        request: ModelRequest,
        alive: &mut dyn FnMut() -> bool,
        emit: &mut dyn FnMut(Delta) -> bool,
    ) -> Result<Reply, InferenceError> {
        let reply = self.generate_stream(request, alive, emit);
        crate::mlx::release_request_memory()?;
        reply
    }
    fn memory(&self) -> Memory {
        crate::mlx::memory().unwrap_or_default()
    }
}
#[derive(Default)]
struct Status {
    ready: bool,
    selected: Option<LocalModel>,
    memory: Memory,
}
struct Job {
    request: ModelRequest,
    events: mpsc::Sender<Result<Bytes, Infallible>>,
    cancel: CancellationToken,
    _permit: OwnedSemaphorePermit,
}
pub struct Worker {
    models: HashMap<LocalModel, PathBuf>,
    instance: Uuid,
    status: Arc<Mutex<Status>>,
    capacity: Arc<Semaphore>,
    jobs: sync_mpsc::SyncSender<Job>,
    stop: CancellationToken,
}
impl Worker {
    pub async fn spawn(
        models: HashMap<LocalModel, PathBuf>,
        instance: Uuid,
        factory: impl FnOnce() -> Result<Box<dyn Backend>, InferenceError> + Send + 'static,
    ) -> Result<Arc<Self>, InferenceError> {
        let status = Arc::new(Mutex::new(Status::default()));
        let thread_status = status.clone();
        let stop = CancellationToken::new();
        let thread_stop = stop.clone();
        let (jobs, receive) = sync_mpsc::sync_channel::<Job>(1);
        let (ready, started) = tokio::sync::oneshot::channel();
        std::thread::Builder::new()
            .name("computa-native-mlx".into())
            .spawn(move || {
                let mut backend = match factory() {
                    Ok(backend) => backend,
                    Err(error) => {
                        let _ = ready.send(Err(error));
                        return;
                    }
                };
                {
                    let mut state = thread_status.lock().unwrap_or_else(|p| p.into_inner());
                    state.ready = true;
                    state.memory = backend.memory();
                }
                let _ = ready.send(Ok(()));
                while !thread_stop.is_cancelled() {
                    let job = match receive.recv_timeout(Duration::from_millis(100)) {
                        Ok(job) => job,
                        Err(sync_mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(_) => break,
                    };
                    let alive = || {
                        !job.cancel.is_cancelled()
                            && !thread_stop.is_cancelled()
                            && !job.events.is_closed()
                    };
                    if !alive() {
                        continue;
                    }
                    let selected = {
                        let mut state = thread_status.lock().unwrap_or_else(|p| p.into_inner());
                        match state.selected {
                            Some(selected) => selected,
                            None => {
                                state.selected = Some(job.request.model);
                                job.request.model
                            }
                        }
                    };
                    let mut protocol =
                        Protocol::new(job.request.model, job.request.max_output_tokens);
                    if selected != job.request.model {
                        let _ =
                            protocol.fail(&InferenceError::RestartRequired, &job.events, &alive);
                        continue;
                    }
                    if !protocol.start(&job.events, &alive) {
                        continue;
                    }
                    let mut emit = |delta| protocol.delta(delta, &job.events, &alive);
                    let reply = backend.generate(job.request, &mut || alive(), &mut emit);
                    if alive() {
                        match reply {
                            Ok(reply) => {
                                if !protocol.finish(reply, &job.events, &alive) {
                                    let _ = protocol.fail(
                                        &InferenceError::Generation,
                                        &job.events,
                                        &alive,
                                    );
                                }
                            }
                            Err(error) => {
                                let _ = protocol.fail(&error, &job.events, &alive);
                            }
                        }
                    }
                    thread_status
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .memory = backend.memory();
                    // Dropping the job, including its permit, occurs only after all
                    // generation/synchronization has ended, even on disconnect.
                }
                thread_status
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .ready = false;
            })
            .map_err(|_| InferenceError::Unavailable)?;
        started.await.map_err(|_| InferenceError::Unavailable)??;
        Ok(Arc::new(Self {
            models,
            instance,
            status,
            capacity: Arc::new(Semaphore::new(1)),
            jobs,
            stop,
        }))
    }
    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/health", get(health))
            .route("/v1/models", get(models))
            .route("/v1/responses", post(responses))
            .fallback(|| async { error(StatusCode::NOT_FOUND, "Endpoint is not enabled.") })
            .layer(middleware::from_fn(native_only))
            .with_state(self.clone())
    }
    pub fn shutdown(&self) {
        self.stop.cancel();
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
async fn native_only(request: Request, next: Next) -> Response {
    if request.headers().contains_key(header::ORIGIN) || request.uri().query().is_some() {
        return error(StatusCode::FORBIDDEN, "Native local clients only.");
    }
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        header::HeaderValue::from_static("no-store"),
    );
    response
}
async fn health(State(worker): State<Arc<Worker>>) -> Response {
    let state = worker.status.lock().unwrap_or_else(|p| p.into_inner());
    (if state.ready{StatusCode::OK}else{StatusCode::SERVICE_UNAVAILABLE},Json(json!({"status":if state.ready{"healthy"}else{"stopped"},"heydash_instance":worker.instance,"backend":"computa-rust-mlx","version":"mlex-0.1.3","busy":worker.capacity.available_permits()==0,"context_limit":request::CONTEXT_LIMIT,"selected_model":state.selected.map(LocalModel::model_id),"memory":state.memory}))).into_response()
}
async fn models(State(worker): State<Arc<Worker>>) -> Json<Value> {
    let mut models: Vec<_> = worker.models.keys().map(|m| m.model_id()).collect();
    models.sort();
    Json(
        json!({"object":"list","data":models.into_iter().map(|id|json!({"id":id,"object":"model","owned_by":"local"})).collect::<Vec<_>>()}),
    )
}
async fn responses(State(worker): State<Arc<Worker>>, request: Request) -> Response {
    if worker.stop.is_cancelled() {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The owned local worker is stopping.",
        );
    }
    let headers = request.headers();
    if headers.get_all(header::CONTENT_TYPE).iter().count() != 1
        || headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(';').next())
            .map(str::trim)
            != Some("application/json")
    {
        return error(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "application/json is required.",
        );
    }
    let permit = match worker.capacity.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            return error(
                StatusCode::TOO_MANY_REQUESTS,
                "Local model is busy; no request was queued.",
            );
        }
    };
    let body = match tokio::time::timeout(
        Duration::from_secs(10),
        to_bytes(request.into_body(), request::MAX_BODY),
    )
    .await
    {
        Ok(Ok(body)) => body,
        Ok(Err(_)) => {
            return error(
                StatusCode::PAYLOAD_TOO_LARGE,
                "Request size limit exceeded.",
            );
        }
        Err(_) => return error(StatusCode::REQUEST_TIMEOUT, "Request upload timed out."),
    };
    let request = match request::parse(&body, &worker.models) {
        Ok(request) => request,
        Err(_) => return error(StatusCode::BAD_REQUEST, "Invalid local inference request."),
    };
    {
        let state = worker.status.lock().unwrap_or_else(|p| p.into_inner());
        if state
            .selected
            .is_some_and(|selected| selected != request.model)
        {
            return (StatusCode::CONFLICT,Json(json!({"error":{"code":"owned_restart_required","message":InferenceError::RestartRequired.to_string()}}))).into_response();
        }
    }
    let (events, receive) = mpsc::channel(64);
    let cancel = CancellationToken::new();
    if worker
        .jobs
        .try_send(Job {
            request,
            events,
            cancel: cancel.clone(),
            _permit: permit,
        })
        .is_err()
    {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The owned local worker is unavailable.",
        );
    }
    (
        [
            (header::CONTENT_TYPE, "text/event-stream; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        Body::from_stream(ResponseStream { receive, cancel }),
    )
        .into_response()
}
fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({"error":{"message":message}}))).into_response()
}
struct ResponseStream {
    receive: mpsc::Receiver<Result<Bytes, Infallible>>,
    cancel: CancellationToken,
}
impl Stream for ResponseStream {
    type Item = Result<Bytes, Infallible>;
    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        context: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.receive.poll_recv(context)
    }
}
impl Drop for ResponseStream {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

struct Item {
    id: String,
    index: usize,
    text: String,
    reasoning: bool,
    done: bool,
}
struct Protocol {
    id: String,
    model: LocalModel,
    max_output: usize,
    created: u64,
    sequence: u64,
    bytes: usize,
    reasoning: Option<Item>,
    message: Option<Item>,
    output: Vec<Value>,
    terminal: bool,
}
impl Protocol {
    fn new(model: LocalModel, max_output: usize) -> Self {
        Self {
            id: format!("resp_{}", Uuid::new_v4().simple()),
            model,
            max_output,
            created: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |t| t.as_secs()),
            sequence: 0,
            bytes: 0,
            reasoning: None,
            message: None,
            output: Vec::new(),
            terminal: false,
        }
    }
    fn response(&self, status: &str, output: Value, usage: Value, end_turn: bool) -> Value {
        json!({"id":self.id,"object":"response","created_at":self.created,"model":self.model.model_id(),"status":status,"output":output,"output_text":self.message.as_ref().map_or("",|m|m.text.as_str()),"error":null,"incomplete_details":null,"usage":usage,"store":false,"end_turn":end_turn})
    }
    fn send(
        &mut self,
        mut event: Value,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        if self.terminal || !alive() {
            return false;
        }
        event["sequence_number"] = json!(self.sequence);
        let body = format!(
            "event: {}\ndata: {}\n\n",
            event["type"].as_str().unwrap_or("response.failed"),
            event
        );
        let bytes = body.len();
        let limit = if matches!(
            event["type"].as_str(),
            Some("response.failed" | "response.incomplete")
        ) {
            crate::live::MAX_CAPTURE
        } else {
            crate::live::MAX_CAPTURE - 65536
        };
        if self.bytes.saturating_add(bytes) > limit {
            return false;
        }
        let mut item = Ok(Bytes::from(body));
        loop {
            if !alive() {
                return false;
            }
            match events.try_send(item) {
                Ok(()) => {
                    self.sequence += 1;
                    self.bytes += bytes;
                    return true;
                }
                Err(mpsc::error::TrySendError::Closed(_)) => return false,
                Err(mpsc::error::TrySendError::Full(returned)) => {
                    item = returned;
                    std::thread::sleep(Duration::from_millis(2));
                }
            }
        }
    }
    fn start(
        &mut self,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        let response = self.response("in_progress", json!([]), Value::Null, false);
        self.send(
            json!({"type":"response.created","response":response}),
            events,
            alive,
        ) && self.send(
            json!({"type":"response.in_progress","response":response}),
            events,
            alive,
        )
    }
    fn delta(
        &mut self,
        delta: Delta,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        let (reasoning, text) = match delta {
            Delta::Text(text) => (false, text),
            Delta::Reasoning(text) => (true, text),
        };
        if text.is_empty() {
            return true;
        }
        if reasoning && self.message.is_some() {
            return false;
        }
        if !reasoning && !self.close_reasoning(events, alive) {
            return false;
        }
        let exists = if reasoning {
            self.reasoning.is_some()
        } else {
            self.message.is_some()
        };
        if !exists {
            let index = self.output.len();
            let id = format!(
                "{}_{}",
                if reasoning { "rs" } else { "msg" },
                Uuid::new_v4().simple()
            );
            let item = if reasoning {
                json!({"id":id,"type":"reasoning","summary":[],"status":"in_progress"})
            } else {
                json!({"id":id,"type":"message","role":"assistant","content":[],"status":"in_progress"})
            };
            if !self.send(
                json!({"type":"response.output_item.added","output_index":index,"item":item}),
                events,
                alive,
            ) {
                return false;
            }
            if !reasoning&&!self.send(json!({"type":"response.content_part.added","item_id":id,"output_index":index,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}),events,alive){return false;}
            let item = Item {
                id,
                index,
                text: String::new(),
                reasoning,
                done: false,
            };
            if reasoning {
                self.reasoning = Some(item);
            } else {
                self.message = Some(item);
            }
        }
        let item = if reasoning {
            self.reasoning.as_mut().unwrap()
        } else {
            self.message.as_mut().unwrap()
        };
        if item.done {
            return false;
        }
        item.text.push_str(&text);
        let event = json!({"type":if reasoning{"response.reasoning_text.delta"}else{"response.output_text.delta"},"item_id":item.id,"output_index":item.index,"content_index":0,"delta":text});
        self.send(event, events, alive)
    }
    fn close_reasoning(
        &mut self,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        self.close_item(true, "completed", events, alive)
    }
    fn close_item(
        &mut self,
        reasoning: bool,
        status: &str,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        let item = if reasoning {
            self.reasoning.as_mut()
        } else {
            self.message.as_mut()
        };
        let Some(item) = item else {
            return true;
        };
        if item.done {
            return true;
        }
        item.done = true;
        let done = json!({"type":if item.reasoning{"response.reasoning_text.done"}else{"response.output_text.done"},"item_id":item.id,"output_index":item.index,"content_index":0,"text":item.text});
        let output = if reasoning {
            json!({"id":item.id,"type":"reasoning","summary":[{"type":"summary_text","text":item.text}],"status":status})
        } else {
            json!({"id":item.id,"type":"message","role":"assistant","content":[{"type":"output_text","text":item.text,"annotations":[]}],"status":status})
        };
        let index = item.index;
        let id = item.id.clone();
        if !self.send(done, events, alive) {
            return false;
        }
        if !reasoning&&!self.send(json!({"type":"response.content_part.done","item_id":id,"output_index":index,"content_index":0,"part":output["content"][0]}),events,alive){return false;}
        if !self.send(
            json!({"type":"response.output_item.done","output_index":index,"item":output}),
            events,
            alive,
        ) {
            return false;
        }
        if index != self.output.len() {
            return false;
        }
        self.output.push(output);
        true
    }
    fn finish(
        &mut self,
        reply: Reply,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        if reply.text != self.message.as_ref().map_or("", |m| m.text.as_str())
            || reply.reasoning.as_deref().unwrap_or("")
                != self.reasoning.as_ref().map_or("", |r| r.text.as_str())
            || !self.valid_usage(&reply.usage)
            || reply.calls.len() > 32
        {
            return false;
        }
        if !self.close_reasoning(events, alive)
            || !self.close_item(false, "completed", events, alive)
        {
            return false;
        }
        for call in &reply.calls {
            let index = self.output.len();
            let id = format!("fc_{}", Uuid::new_v4().simple());
            let call_id = format!("call_{}", Uuid::new_v4().simple());
            let mut item = json!({"id":id,"type":"function_call","call_id":call_id,"name":call.name,"arguments":call.arguments,"status":"completed"});
            if let Some(namespace) = &call.namespace {
                item["namespace"] = json!(namespace);
            }
            let mut pending = item.clone();
            pending["arguments"] = json!("");
            pending["status"] = json!("in_progress");
            for event in [
                json!({"type":"response.output_item.added","output_index":index,"item":pending}),
                json!({"type":"response.function_call_arguments.delta","item_id":id,"output_index":index,"call_id":call_id,"name":call.name,"delta":call.arguments}),
                json!({"type":"response.function_call_arguments.done","item_id":id,"output_index":index,"call_id":call_id,"name":call.name,"arguments":call.arguments}),
                json!({"type":"response.output_item.done","output_index":index,"item":item}),
            ] {
                if !self.send(event, events, alive) {
                    return false;
                }
            }
            self.output.push(item);
        }
        let response = self.response(
            "completed",
            json!(self.output),
            json!(reply.usage),
            reply.calls.is_empty(),
        );
        let sent = self.send(
            json!({"type":"response.completed","response":response}),
            events,
            alive,
        );
        self.terminal = sent;
        sent
    }
    fn valid_usage(&self, usage: &Usage) -> bool {
        usage.input_tokens <= request::CONTEXT_LIMIT
            && usage.output_tokens <= self.max_output
            && usage.input_tokens.checked_add(usage.output_tokens) == Some(usage.total_tokens)
    }
    fn incomplete(
        &mut self,
        usage: &Usage,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        // Only spans already emitted by LiveOutput can appear here. Complete or
        // unfinished tool bundles remain private until a clean generation stop.
        if !self.valid_usage(usage)
            || !self.close_item(true, "incomplete", events, alive)
            || !self.close_item(false, "incomplete", events, alive)
        {
            return self.fail(&InferenceError::Generation, events, alive);
        }
        let mut response = self.response("incomplete", json!(self.output), json!(usage), false);
        response["incomplete_details"] = json!({"reason":"max_output_tokens"});
        let sent = self.send(
            json!({"type":"response.incomplete","response":response}),
            events,
            alive,
        );
        self.terminal = sent;
        if sent {
            true
        } else {
            self.fail(&InferenceError::Generation, events, alive)
        }
    }
    fn fail(
        &mut self,
        error: &InferenceError,
        events: &mpsc::Sender<Result<Bytes, Infallible>>,
        alive: &dyn Fn() -> bool,
    ) -> bool {
        if let InferenceError::Length(usage) = error {
            return self.incomplete(usage, events, alive);
        }
        let mut response = self.response("failed", json!([]), Value::Null, false);
        response["error"] = json!({"code":"invalid_prompt","message":error.to_string()});
        if let InferenceError::Context(budget) = error {
            response["error"]["code"] = json!("context_length_exceeded");
            response["context_budget"] = json!(budget);
        }
        let sent = self.send(
            json!({"type":"response.failed","response":response}),
            events,
            alive,
        );
        self.terminal = sent;
        sent
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live::LiveOutput;
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Fake {
        release: Arc<AtomicUsize>,
        slow: bool,
        mismatch: bool,
    }
    impl Backend for Fake {
        fn generate(
            &mut self,
            _request: ModelRequest,
            alive: &mut dyn FnMut() -> bool,
            emit: &mut dyn FnMut(Delta) -> bool,
        ) -> Result<Reply, InferenceError> {
            if !emit(Delta::Reasoning("private reasoning".into()))
                || !emit(Delta::Text("MARKER_🦀".into()))
            {
                self.release.fetch_add(1, Ordering::SeqCst);
                return Err(InferenceError::Cancelled);
            }
            if self.slow {
                while alive() {
                    std::thread::sleep(Duration::from_millis(5));
                }
                std::thread::sleep(Duration::from_millis(120));
                self.release.fetch_add(1, Ordering::SeqCst);
                return Err(InferenceError::Cancelled);
            }
            self.release.fetch_add(1, Ordering::SeqCst);
            Ok(Reply {
                text: if self.mismatch {
                    "invented"
                } else {
                    "MARKER_🦀"
                }
                .into(),
                reasoning: Some("private reasoning".into()),
                calls: vec![],
                usage: Usage {
                    input_tokens: 20,
                    output_tokens: 8,
                    total_tokens: 28,
                },
            })
        }
        fn memory(&self) -> Memory {
            Memory::default()
        }
    }
    async fn fixture(
        slow: bool,
        mismatch: bool,
    ) -> (
        Arc<Worker>,
        String,
        tokio::task::JoinHandle<std::io::Result<()>>,
        Arc<AtomicUsize>,
    ) {
        let release = Arc::new(AtomicUsize::new(0));
        let fake_release = release.clone();
        let worker = Worker::spawn(
            HashMap::from([
                (LocalModel::Qwen35_4b, PathBuf::from("/fixed")),
                (LocalModel::Qwen35_9b, PathBuf::from("/fixed9")),
            ]),
            Uuid::new_v4(),
            move || {
                Ok(Box::new(Fake {
                    release: fake_release,
                    slow,
                    mismatch,
                }))
            },
        )
        .await
        .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let app = worker.router();
        let task = tokio::spawn(async move { axum::serve(listener, app).await });
        (worker, base, task, release)
    }
    fn request(model: LocalModel) -> Value {
        json!({"model":model.model_id(),"stream":true,"store":false,"input":"Read marker"})
    }
    #[tokio::test]
    async fn native_gate_exact_identity_and_terminal_match_live_unicode() {
        let (worker, base, task, _) = fixture(false, false).await;
        let client = reqwest::Client::new();
        for suffix in ["/health?x=1", "/v1/models?x=1"] {
            assert_eq!(
                client
                    .get(format!("{base}{suffix}"))
                    .send()
                    .await
                    .unwrap()
                    .status(),
                StatusCode::FORBIDDEN
            );
        }
        assert_eq!(
            client
                .get(format!("{base}/health"))
                .header("Origin", "https://example.test")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN
        );
        let health: Value = client
            .get(format!("{base}/health"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(health["heydash_instance"], worker.instance.to_string());
        assert_eq!(health["backend"], "computa-rust-mlx");
        assert!(health["selected_model"].is_null());
        let stream = client
            .post(format!("{base}/v1/responses"))
            .json(&request(LocalModel::Qwen35_4b))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        let events: Vec<Value> = stream
            .lines()
            .filter_map(|line| line.strip_prefix("data: "))
            .map(|json| serde_json::from_str(json).unwrap())
            .collect();
        for (index, event) in events.iter().enumerate() {
            assert_eq!(event["sequence_number"], index);
        }
        let terminal = events.last().unwrap();
        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(
            terminal["response"]["output"][1]["content"][0]["text"],
            "MARKER_🦀"
        );
        assert_eq!(terminal["response"]["usage"]["total_tokens"], 28);
        assert_eq!(terminal["response"]["end_turn"], true);
        assert_eq!(
            client
                .post(format!("{base}/v1/responses"))
                .json(&request(LocalModel::Qwen35_9b))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::CONFLICT
        );
        worker.shutdown();
        task.abort();
    }
    #[tokio::test]
    async fn disconnect_cancels_generation_and_keeps_busy_until_native_release() {
        use futures::StreamExt;
        let (worker, base, task, release) = fixture(true, false).await;
        let client = reqwest::Client::new();
        let response = client
            .post(format!("{base}/v1/responses"))
            .json(&request(LocalModel::Qwen35_4b))
            .send()
            .await
            .unwrap();
        let mut body = response.bytes_stream();
        assert!(body.next().await.unwrap().is_ok());
        assert_eq!(
            client
                .post(format!("{base}/v1/responses"))
                .json(&request(LocalModel::Qwen35_4b))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::TOO_MANY_REQUESTS
        );
        drop(body);
        assert_eq!(worker.capacity.available_permits(), 0);
        tokio::time::timeout(Duration::from_secs(3), async {
            while worker.capacity.available_permits() == 0 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(release.load(Ordering::SeqCst), 1);
        let state = worker.status.lock().unwrap();
        assert_eq!(state.selected, Some(LocalModel::Qwen35_4b));
        drop(state);
        worker.shutdown();
        task.abort();
    }
    #[tokio::test]
    async fn final_text_mismatch_fails_without_completed_event() {
        let (worker, base, task, _) = fixture(false, true).await;
        let stream = reqwest::Client::new()
            .post(format!("{base}/v1/responses"))
            .json(&request(LocalModel::Qwen35_4b))
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(stream.contains("event: response.failed\n"));
        assert!(!stream.contains("event: response.completed\n"));
        assert!(!stream.contains("invented"));
        worker.shutdown();
        task.abort();
    }
    struct BudgetBackend;
    impl Backend for BudgetBackend {
        fn generate(
            &mut self,
            request: ModelRequest,
            _: &mut dyn FnMut() -> bool,
            emit: &mut dyn FnMut(Delta) -> bool,
        ) -> Result<Reply, InferenceError> {
            let scenario = request.raw["input"].as_str().unwrap();
            if scenario == "context" {
                return Err(InferenceError::Context(
                    request::context_budget(request::CONTEXT_LIMIT, 1).unwrap(),
                ));
            }
            if scenario == "following" {
                assert!(emit(Delta::Text("RECOVERED_🦀".into())));
                return Ok(Reply {
                    text: "RECOVERED_🦀".into(),
                    reasoning: None,
                    calls: vec![],
                    usage: Usage {
                        input_tokens: 20,
                        output_tokens: 3,
                        total_tokens: 23,
                    },
                });
            }
            let raw = match scenario {
                "text" => "Partial 🦀",
                "reasoning" => "<think>unfinished reasoning",
                "tool-unfinished" => "<tool_call>{\"name\":\"click\",\"arguments\":{\"x\":",
                "tool-complete-exhausted" => {
                    "<tool_call>{\"name\":\"click\",\"arguments\":{}}</tool_call>"
                }
                "invalid-usage" => "Partial 🦀",
                _ => panic!("unexpected synthetic scenario"),
            };
            let mut parser = LiveOutput::new(false);
            for delta in parser.feed(raw).unwrap() {
                assert!(emit(delta));
            }
            Err(InferenceError::Length(Usage {
                input_tokens: 20,
                output_tokens: 1,
                total_tokens: if scenario == "invalid-usage" {
                    usize::MAX
                } else {
                    21
                },
            }))
        }
        fn memory(&self) -> Memory {
            Memory::default()
        }
    }
    fn decoded_events(stream: &str) -> Vec<Value> {
        stream
            .lines()
            .filter_map(|s| s.strip_prefix("data: "))
            .map(|s| serde_json::from_str(s).unwrap())
            .collect()
    }
    async fn wait_idle(worker: &Worker) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while worker.capacity.available_permits() == 0 {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn exhausted_text_reasoning_and_tool_bundles_are_incomplete_and_next_request_recovers() {
        let worker = Worker::spawn(
            HashMap::from([(LocalModel::Qwen35_4b, PathBuf::from("/fixed"))]),
            Uuid::new_v4(),
            || Ok(Box::new(BudgetBackend)),
        )
        .await
        .unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!(
            "http://127.0.0.1:{}/v1/responses",
            listener.local_addr().unwrap().port()
        );
        let app = worker.router();
        let task = tokio::spawn(async move { axum::serve(listener, app).await });
        let client = reqwest::Client::new();
        for scenario in [
            "text",
            "reasoning",
            "tool-unfinished",
            "tool-complete-exhausted",
        ] {
            let mut input = request(LocalModel::Qwen35_4b);
            input["input"] = json!(scenario);
            input["max_output_tokens"] = json!(1);
            let stream = client
                .post(&endpoint)
                .json(&input)
                .send()
                .await
                .unwrap()
                .text()
                .await
                .unwrap();
            let events = decoded_events(&stream);
            for (index, event) in events.iter().enumerate() {
                assert_eq!(event["sequence_number"], index);
            }
            let terminals: Vec<_> = events
                .iter()
                .filter(|e| {
                    matches!(
                        e["type"].as_str(),
                        Some("response.incomplete" | "response.failed" | "response.completed")
                    )
                })
                .collect();
            assert_eq!(terminals.len(), 1);
            let terminal = terminals[0];
            let response = &terminal["response"];
            assert_eq!(terminal["type"], "response.incomplete");
            assert_eq!(response["id"], events[0]["response"]["id"]);
            assert_eq!(response["status"], "incomplete");
            assert_eq!(
                response["incomplete_details"]["reason"],
                "max_output_tokens"
            );
            assert_eq!(
                response["usage"],
                json!({"input_tokens":20,"output_tokens":1,"total_tokens":21})
            );
            assert!(response["error"].is_null());
            assert_eq!(response["end_turn"], false);
            assert!(!events.iter().any(|e| {
                e["type"]
                    .as_str()
                    .is_some_and(|s| s.starts_with("response.function_call"))
                    || e["item"]["type"] == "function_call"
            }));
            let public: String = events
                .iter()
                .filter(|e| e["type"] == "response.output_text.delta")
                .filter_map(|e| e["delta"].as_str())
                .collect();
            assert_eq!(response["output_text"], public);
            assert_eq!(
                public,
                if scenario == "text" {
                    "Partial 🦀"
                } else {
                    ""
                }
            );
            for output in response["output"].as_array().unwrap() {
                let done = events
                    .iter()
                    .find(|e| {
                        e["type"] == "response.output_item.done" && e["item"]["id"] == output["id"]
                    })
                    .unwrap();
                assert_eq!(&done["item"], output);
                assert_eq!(output["status"], "incomplete");
            }
            wait_idle(&worker).await;
            input["input"] = json!("following");
            input["max_output_tokens"] = json!(64);
            let following = decoded_events(
                &client
                    .post(&endpoint)
                    .json(&input)
                    .send()
                    .await
                    .unwrap()
                    .text()
                    .await
                    .unwrap(),
            );
            assert_eq!(following.last().unwrap()["type"], "response.completed");
            assert_eq!(
                following.last().unwrap()["response"]["output_text"],
                "RECOVERED_🦀"
            );
            wait_idle(&worker).await;
        }
        for (scenario, code) in [
            ("context", "context_length_exceeded"),
            ("invalid-usage", "invalid_prompt"),
        ] {
            let mut input = request(LocalModel::Qwen35_4b);
            input["input"] = json!(scenario);
            input["max_output_tokens"] = json!(1);
            let events = decoded_events(
                &client
                    .post(&endpoint)
                    .json(&input)
                    .send()
                    .await
                    .unwrap()
                    .text()
                    .await
                    .unwrap(),
            );
            let terminal = events.last().unwrap();
            assert_eq!(terminal["type"], "response.failed");
            assert_eq!(terminal["response"]["error"]["code"], code);
            assert!(!events.iter().any(|e| e["type"] == "response.incomplete"));
            wait_idle(&worker).await;
        }
        worker.shutdown();
        task.abort();
    }
}
