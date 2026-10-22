//! Browser model session orchestration; authority and cleanup remain native-owned.
use crate::codec;
use computa_contracts::{Identifier, models::WebProvider, responses::*};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
#[derive(Debug, thiserror::Error)]
pub enum InferenceError {
    #[error("{0}")]
    Transport(#[from] BrowserTransportError),
    #[error("{0}")]
    Codec(#[from] codec::CodecError),
    #[error("The website model request is not authorized for this active task.")]
    UnauthorizedTask,
    #[error("Sign in to this website in the built-in browser, then retry the task.")]
    SignInRequired,
    #[error("{0}")]
    Website(BrowserFailureCode),
    #[error("Browser inference was cancelled.")]
    Cancelled,
}
#[derive(Clone, Debug)]
pub struct BrowserTiming {
    pub ready_timeout: Duration,
    pub response_timeout: Duration,
    pub poll_interval: Duration,
    pub operation_timeout: Duration,
}
impl Default for BrowserTiming {
    fn default() -> Self {
        Self {
            ready_timeout: Duration::from_secs(45),
            response_timeout: Duration::from_secs(300),
            poll_interval: Duration::from_millis(500),
            operation_timeout: Duration::from_secs(30),
        }
    }
}
struct Session {
    token: uuid::Uuid,
    provider: WebProvider,
    sequence: u64,
}
struct TaskLease {
    provider: WebProvider,
    transport: Arc<dyn BrowserTransport>,
    cancel: CancellationToken,
    session: Mutex<Option<Session>>,
    serial: Mutex<()>,
}
struct Connection {
    generation: uuid::Uuid,
    transport: Arc<dyn BrowserTransport>,
}
/// Initial launch can bind a stable HTTP endpoint before a website model transport is available.
pub struct DisconnectedBrowserTransport;
#[async_trait::async_trait]
impl BrowserTransport for DisconnectedBrowserTransport {
    async fn request(&self, _: BrowserOperation) -> Result<BrowserSnapshot, BrowserTransportError> {
        Err(BrowserTransportError::Disconnected)
    }
}
pub struct BrowserInference {
    connection: Mutex<Connection>,
    tasks: Mutex<HashMap<Identifier, Arc<TaskLease>>>,
    timing: BrowserTiming,
}
impl BrowserInference {
    pub fn new(transport: Arc<dyn BrowserTransport>) -> Self {
        Self::with_timing(transport, BrowserTiming::default())
    }
    pub fn with_timing(transport: Arc<dyn BrowserTransport>, timing: BrowserTiming) -> Self {
        Self {
            connection: Mutex::new(Connection {
                generation: uuid::Uuid::new_v4(),
                transport,
            }),
            tasks: Mutex::new(HashMap::new()),
            timing,
        }
    }
    pub async fn authorize_task(
        &self,
        task: Identifier,
        provider: WebProvider,
    ) -> Result<(), InferenceError> {
        let connection = self.connection.lock().await;
        let mut tasks = self.tasks.lock().await;
        if let Some(old) = tasks.get(&task) {
            if old.cancel.is_cancelled() || old.provider != provider {
                return Err(InferenceError::UnauthorizedTask);
            }
            return Ok(());
        }
        tasks.insert(
            task,
            Arc::new(TaskLease {
                provider,
                transport: connection.transport.clone(),
                cancel: CancellationToken::new(),
                session: Mutex::new(None),
                serial: Mutex::new(()),
            }),
        );
        Ok(())
    }
    async fn operation(
        &self,
        transport: &dyn BrowserTransport,
        op: BrowserOperation,
        cancel: &CancellationToken,
    ) -> Result<BrowserSnapshot, InferenceError> {
        tokio::select! {biased;_ = cancel.cancelled()=>Err(InferenceError::Cancelled),v=tokio::time::timeout(self.timing.operation_timeout,transport.request(op))=>v.map_err(|_|BrowserTransportError::Timeout)?.map_err(InferenceError::from)}
    }
    fn check(snapshot: &BrowserSnapshot, session: &Session) -> Result<(), InferenceError> {
        if snapshot.session_token != session.token
            || snapshot.provider != session.provider
            || snapshot.sequence < session.sequence
        {
            return Err(BrowserTransportError::InvalidResponse.into());
        }
        if snapshot.state == BrowserState::NeedsSignIn {
            return Err(InferenceError::SignInRequired);
        }
        if snapshot.state == BrowserState::Failed {
            return Err(InferenceError::Website(
                snapshot
                    .error
                    .as_ref()
                    .map_or(BrowserFailureCode::Unknown, |e| e.code),
            ));
        }
        Ok(())
    }
    pub async fn infer(
        &self,
        task: &Identifier,
        request: &codec::Request,
    ) -> Result<codec::Reply, InferenceError> {
        let lease = self
            .tasks
            .lock()
            .await
            .get(task)
            .cloned()
            .ok_or(InferenceError::UnauthorizedTask)?;
        if request.model != lease.provider.model_id() {
            return Err(InferenceError::UnauthorizedTask);
        }
        let _serial = lease.serial.lock().await;
        if lease.cancel.is_cancelled() {
            return Err(InferenceError::Cancelled);
        }
        let mut session_guard = lease.session.lock().await;
        if session_guard.is_none() {
            // A start cannot be abandoned by cancellation: retain its exact token
            // before noticing cancellation so cleanup cannot leak an owned tab.
            let s = tokio::time::timeout(
                self.timing.operation_timeout,
                lease.transport.request(BrowserOperation::Start {
                    provider: lease.provider,
                }),
            )
            .await
            .map_err(|_| BrowserTransportError::Timeout)??;
            *session_guard = Some(Session {
                token: s.session_token,
                provider: lease.provider,
                sequence: s.sequence,
            });
            let session = session_guard
                .as_mut()
                .ok_or(InferenceError::UnauthorizedTask)?;
            Self::check(&s, session)?;
            let deadline = tokio::time::Instant::now() + self.timing.ready_timeout;
            let mut state = s.state;
            while state == BrowserState::Loading {
                if tokio::time::Instant::now() >= deadline {
                    return Err(InferenceError::Website(BrowserFailureCode::ReadyTimeout));
                }
                tokio::select! {_ = lease.cancel.cancelled()=>return Err(InferenceError::Cancelled),_ = tokio::time::sleep(self.timing.poll_interval)=>{}}
                let s = self
                    .operation(
                        lease.transport.as_ref(),
                        BrowserOperation::Poll {
                            session_token: session.token,
                        },
                        &lease.cancel,
                    )
                    .await?;
                Self::check(&s, session)?;
                session.sequence = s.sequence;
                state = s.state;
            }
            if state != BrowserState::Ready {
                return Err(InferenceError::Website(BrowserFailureCode::NotReady));
            }
        }
        let session = session_guard
            .as_mut()
            .ok_or(InferenceError::UnauthorizedTask)?;
        let mut snapshot = self
            .operation(
                lease.transport.as_ref(),
                BrowserOperation::Send {
                    session_token: session.token,
                    prompt: request.prompt.clone(),
                },
                &lease.cancel,
            )
            .await?;
        Self::check(&snapshot, session)?;
        session.sequence = snapshot.sequence;
        let deadline = tokio::time::Instant::now() + self.timing.response_timeout;
        while matches!(
            snapshot.state,
            BrowserState::Running | BrowserState::Loading
        ) {
            if tokio::time::Instant::now() >= deadline {
                return Err(InferenceError::Website(BrowserFailureCode::ResponseTimeout));
            }
            tokio::select! {_ = lease.cancel.cancelled()=>return Err(InferenceError::Cancelled),_ = tokio::time::sleep(self.timing.poll_interval)=>{}}
            snapshot = self
                .operation(
                    lease.transport.as_ref(),
                    BrowserOperation::Poll {
                        session_token: session.token,
                    },
                    &lease.cancel,
                )
                .await?;
            Self::check(&snapshot, session)?;
            session.sequence = snapshot.sequence;
        }
        if snapshot.state != BrowserState::Complete {
            return Err(InferenceError::Website(
                BrowserFailureCode::ResponseInterrupted,
            ));
        }
        if snapshot.text.len() > 512 * 1024 {
            return Err(InferenceError::Website(
                BrowserFailureCode::ResponseTooLarge,
            ));
        }
        codec::parse_reply(&snapshot.text, request).map_err(InferenceError::from)
    }
    /// A failed cleanup keeps the exact session and transport available for retry.
    pub async fn finish_task(
        &self,
        task: &Identifier,
        cancelled: bool,
    ) -> Result<(), InferenceError> {
        let lease = match self.tasks.lock().await.get(task).cloned() {
            Some(v) => v,
            None => return Ok(()),
        };
        lease.cancel.cancel();
        let _serial = lease.serial.lock().await;
        let mut guard = lease.session.lock().await;
        if let Some(session) = guard.as_ref() {
            let op = if cancelled {
                BrowserOperation::Cancel {
                    session_token: session.token,
                }
            } else {
                BrowserOperation::Finish {
                    session_token: session.token,
                }
            };
            let s =
                tokio::time::timeout(self.timing.operation_timeout, lease.transport.request(op))
                    .await
                    .map_err(|_| BrowserTransportError::Timeout)??;
            if s.session_token != session.token || s.provider != session.provider {
                return Err(BrowserTransportError::InvalidResponse.into());
            }
            if !s.cleanup.as_ref().is_some_and(|c| c.closed) {
                return Err(InferenceError::Website(
                    s.cleanup
                        .as_ref()
                        .and_then(|c| c.error.as_ref())
                        .or(s.error.as_ref())
                        .map_or(BrowserFailureCode::CleanupUnverified, |e| e.code),
                ));
            }
            *guard = None;
        }
        let mut tasks = self.tasks.lock().await;
        if tasks.get(task).is_some_and(|v| Arc::ptr_eq(v, &lease)) {
            tasks.remove(task);
        }
        Ok(())
    }
    pub async fn shutdown(&self) -> Vec<String> {
        let tasks: Vec<_> = self.tasks.lock().await.keys().cloned().collect();
        let mut failures = vec![];
        for task in tasks {
            if let Err(e) = self.finish_task(&task, true).await {
                failures.push(e.to_string());
            }
        }
        failures
    }
    pub async fn connection_generation(&self) -> uuid::Uuid {
        self.connection.lock().await.generation
    }
    /// Revoke the exact generation immediately. Retained sessions keep their
    /// original transport for cleanup; no token is adopted by a later connection.
    pub async fn revoke_transport(
        &self,
        expected_generation: uuid::Uuid,
    ) -> Result<uuid::Uuid, InferenceError> {
        let mut connection = self.connection.lock().await;
        if connection.generation != expected_generation {
            return Err(InferenceError::UnauthorizedTask);
        }
        for lease in self.tasks.lock().await.values() {
            lease.cancel.cancel();
        }
        connection.transport = Arc::new(DisconnectedBrowserTransport);
        connection.generation = uuid::Uuid::new_v4();
        Ok(connection.generation)
    }
    /// Native connection replacement only. The old connection stays retained
    /// until every owned session has verified cleanup; its tokens never migrate.
    /// Holding this gate prevents a new authorization during cleanup/replacement.
    pub async fn replace_transport(
        &self,
        expected_generation: uuid::Uuid,
        transport: Arc<dyn BrowserTransport>,
    ) -> Result<uuid::Uuid, InferenceError> {
        let mut connection = self.connection.lock().await;
        if connection.generation != expected_generation {
            return Err(InferenceError::UnauthorizedTask);
        }
        let errors = self.shutdown().await;
        if !errors.is_empty() || !self.tasks.lock().await.is_empty() {
            return Err(InferenceError::Website(
                BrowserFailureCode::CleanupUnverified,
            ));
        }
        connection.transport = transport;
        connection.generation = uuid::Uuid::new_v4();
        Ok(connection.generation)
    }
    pub async fn retained_session_count(&self) -> usize {
        self.tasks.lock().await.len()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::collections::VecDeque;
    struct Fake {
        replies: Mutex<VecDeque<BrowserSnapshot>>,
        ops: Mutex<Vec<BrowserOperation>>,
    }
    #[async_trait]
    impl BrowserTransport for Fake {
        async fn request(
            &self,
            op: BrowserOperation,
        ) -> Result<BrowserSnapshot, BrowserTransportError> {
            self.ops.lock().await.push(op);
            self.replies
                .lock()
                .await
                .pop_front()
                .ok_or(BrowserTransportError::InvalidResponse)
        }
    }
    fn snapshot(
        token: uuid::Uuid,
        state: BrowserState,
        text: &str,
        sequence: u64,
    ) -> BrowserSnapshot {
        BrowserSnapshot {
            session_token: token,
            provider: WebProvider::Claude,
            state,
            sequence,
            text: text.into(),
            error: None,
            cleanup: None,
        }
    }
    #[tokio::test]
    async fn waits_for_ready_and_retains_cleanup_failure() {
        let id = uuid::Uuid::new_v4();
        let mut failed = snapshot(id, BrowserState::Finished, "", 4);
        failed.cleanup = Some(BrowserCleanup {
            closed: false,
            error: Some(BrowserFailure {
                code: BrowserFailureCode::CleanupFailed,
            }),
        });
        let mut closed = failed.clone();
        closed.cleanup = Some(BrowserCleanup {
            closed: true,
            error: None,
        });
        let transport = Arc::new(Fake {
            replies: Mutex::new(VecDeque::from(vec![
                snapshot(id, BrowserState::Loading, "", 0),
                snapshot(id, BrowserState::Ready, "", 1),
                snapshot(id, BrowserState::Running, "", 2),
                snapshot(
                    id,
                    BrowserState::Complete,
                    r#"{"type":"message","text":"Hello"}"#,
                    3,
                ),
                failed,
                closed,
            ])),
            ops: Mutex::new(vec![]),
        });
        let inference = BrowserInference::with_timing(
            transport.clone(),
            BrowserTiming {
                poll_interval: Duration::from_millis(1),
                ..BrowserTiming::default()
            },
        );
        let task = Identifier::new("task").unwrap();
        inference
            .authorize_task(task.clone(), WebProvider::Claude)
            .await
            .unwrap();
        let r = codec::prepare_request(br#"{"model":"browser/claude","input":"Hi"}"#).unwrap();
        assert_eq!(
            inference.infer(&task, &r).await.unwrap(),
            codec::Reply::Message("Hello".into())
        );
        assert!(matches!(
            transport.ops.lock().await[1],
            BrowserOperation::Poll { .. }
        ));
        assert!(inference.finish_task(&task, false).await.is_err());
        assert_eq!(inference.retained_session_count().await, 1);
        inference.finish_task(&task, false).await.unwrap();
        assert_eq!(inference.retained_session_count().await, 0);
    }
    #[tokio::test]
    async fn failed_snapshot_preserves_finite_reason_and_omits_partial_text() {
        let id = uuid::Uuid::new_v4();
        let mut failed = snapshot(id, BrowserState::Failed, "private partial output", 1);
        failed.error = Some(BrowserFailure {
            code: BrowserFailureCode::ConversationChanged,
        });
        let transport = Arc::new(Fake {
            replies: Mutex::new(VecDeque::from(vec![
                snapshot(id, BrowserState::Ready, "", 0),
                failed,
            ])),
            ops: Mutex::new(vec![]),
        });
        let i = BrowserInference::new(transport);
        let t = Identifier::new("task").unwrap();
        i.authorize_task(t.clone(), WebProvider::Claude)
            .await
            .unwrap();
        let r = codec::prepare_request(br#"{"model":"browser/claude","input":"Hi"}"#).unwrap();
        let e = i.infer(&t, &r).await.unwrap_err();
        assert!(matches!(
            e,
            InferenceError::Website(BrowserFailureCode::ConversationChanged)
        ));
        assert!(!e.to_string().contains("private"));
    }
    #[tokio::test]
    async fn replacement_retains_old_transport_until_exact_cleanup_is_verified() {
        let id = uuid::Uuid::new_v4();
        let mut failed = snapshot(id, BrowserState::Finished, "", 2);
        failed.cleanup = Some(BrowserCleanup {
            closed: false,
            error: Some(BrowserFailure {
                code: BrowserFailureCode::CleanupUnverified,
            }),
        });
        let mut closed = failed.clone();
        closed.cleanup = Some(BrowserCleanup {
            closed: true,
            error: None,
        });
        let old = Arc::new(Fake {
            replies: Mutex::new(VecDeque::from(vec![
                snapshot(id, BrowserState::Ready, "", 0),
                snapshot(id, BrowserState::Complete, "old", 1),
                failed,
                closed,
            ])),
            ops: Mutex::new(vec![]),
        });
        let new_id = uuid::Uuid::new_v4();
        let new = Arc::new(Fake {
            replies: Mutex::new(VecDeque::from(vec![
                snapshot(new_id, BrowserState::Ready, "", 0),
                snapshot(new_id, BrowserState::Complete, "new", 1),
            ])),
            ops: Mutex::new(vec![]),
        });
        let inference = BrowserInference::new(old.clone());
        let task = Identifier::new("task").unwrap();
        let request =
            codec::prepare_request(br#"{"model":"browser/claude","input":"hi"}"#).unwrap();
        inference
            .authorize_task(task.clone(), WebProvider::Claude)
            .await
            .unwrap();
        inference.infer(&task, &request).await.unwrap();
        let generation = inference.connection_generation().await;
        assert!(
            inference
                .replace_transport(generation, new.clone())
                .await
                .is_err()
        );
        assert_eq!(inference.connection_generation().await, generation);
        assert!(new.ops.lock().await.is_empty());
        assert_eq!(inference.retained_session_count().await, 1);
        let next = inference
            .replace_transport(generation, new.clone())
            .await
            .unwrap();
        assert_ne!(next, generation);
        assert_eq!(inference.retained_session_count().await, 0);
        assert!(
            matches!(old.ops.lock().await.last(), Some(BrowserOperation::Cancel { session_token }) if *session_token == id)
        );
        inference
            .authorize_task(task.clone(), WebProvider::Claude)
            .await
            .unwrap();
        assert_eq!(
            inference.infer(&task, &request).await.unwrap(),
            codec::Reply::Message("new".into())
        );
        assert!(
            inference
                .replace_transport(generation, old.clone())
                .await
                .is_err()
        );
        assert_eq!(new.ops.lock().await.len(), 2);
    }
    #[tokio::test]
    async fn exact_disconnect_revokes_lease_and_stale_callback_cannot_change_generation() {
        let inference = BrowserInference::new(Arc::new(DisconnectedBrowserTransport));
        let task = Identifier::new("task").unwrap();
        inference
            .authorize_task(task.clone(), WebProvider::Claude)
            .await
            .unwrap();
        let first = inference.connection_generation().await;
        let second = inference.revoke_transport(first).await.unwrap();
        assert_ne!(first, second);
        assert!(inference.revoke_transport(first).await.is_err());
        assert_eq!(inference.connection_generation().await, second);
        let request =
            codec::prepare_request(br#"{"model":"browser/claude","input":"hi"}"#).unwrap();
        assert!(matches!(
            inference.infer(&task, &request).await,
            Err(InferenceError::Cancelled)
        ));
        inference.finish_task(&task, true).await.unwrap();
        assert_eq!(inference.retained_session_count().await, 0);
    }
}
