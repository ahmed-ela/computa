use crate::{
    BrowserError, PeerVerifier, VerifiedPeer, framing, identity::prepare_directory,
    revokes_connection,
};
use computa_contracts::{
    chrome::{Hello, MAX_FRAME, MAX_PENDING, Request, Response, uuid_text},
    responses::{
        BrowserFailureCode, BrowserOperation, BrowserSnapshot, BrowserTransport,
        BrowserTransportError,
    },
};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    os::{
        fd::AsRawFd,
        unix::fs::{FileTypeExt, MetadataExt},
    },
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::{UnixListener, UnixStream, unix::OwnedWriteHalf},
    sync::{Mutex as AsyncMutex, broadcast, oneshot},
};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub enum LinkEvent {
    Hello(Hello),
    Detached(String),
    CleanupFailed,
    Disconnected,
}
type Completion = oneshot::Sender<Result<Value, BrowserError>>;
pub struct ChromeLink {
    pub id: Uuid,
    pub peer: VerifiedPeer,
    verifier: Arc<dyn PeerVerifier>,
    fd: std::os::fd::RawFd,
    writer: AsyncMutex<OwnedWriteHalf>,
    pending: Mutex<HashMap<String, (String, Completion)>>,
    closed: AtomicBool,
    hello: Mutex<Option<Hello>>,
    detached: Mutex<HashSet<String>>,
    events: broadcast::Sender<LinkEvent>,
}
impl ChromeLink {
    pub fn from_verified(
        stream: UnixStream,
        verifier: Arc<dyn PeerVerifier>,
    ) -> Result<Arc<Self>, BrowserError> {
        let fd = stream.as_raw_fd();
        let peer = verifier.verify_host(fd)?;
        let (mut reader, writer) = stream.into_split();
        let (events, _) = broadcast::channel(128);
        let link = Arc::new(Self {
            id: Uuid::new_v4(),
            peer,
            verifier,
            fd,
            writer: AsyncMutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
            hello: Mutex::new(None),
            detached: Mutex::new(HashSet::new()),
            events,
        });
        let weak = Arc::downgrade(&link);
        tokio::spawn(async move {
            loop {
                let payload = match framing::read_async(&mut reader).await {
                    Ok(Some(bytes)) => bytes,
                    _ => break,
                };
                let Some(link) = weak.upgrade() else { break };
                if link.receive(&payload).is_err() {
                    link.close(BrowserError::InvalidFrame);
                    break;
                }
            }
            if let Some(link) = weak.upgrade() {
                link.close(BrowserError::Closed);
            }
        });
        Ok(link)
    }
    pub fn events(&self) -> broadcast::Receiver<LinkEvent> {
        self.events.subscribe()
    }
    pub fn hello(&self) -> Option<Hello> {
        self.hello.lock().unwrap().clone()
    }
    pub fn check(&self) -> Result<(), BrowserError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(BrowserError::Closed);
        }
        self.verifier.verify_chrome(self.peer.chrome_pid)
    }
    pub fn check_attachment(&self, token: &str) -> Result<(), BrowserError> {
        self.check()?;
        if self.detached.lock().unwrap().contains(token) {
            Err(BrowserError::Closed)
        } else {
            Ok(())
        }
    }
    pub async fn request(
        self: &Arc<Self>,
        operation: &str,
        params: Value,
        generation: Uuid,
    ) -> Result<Value, BrowserError> {
        self.check()?;
        let id = Uuid::new_v4().to_string();
        let generation = generation.to_string();
        let request = Request {
            version: 1,
            id: id.clone(),
            operation: operation.into(),
            params,
            generation: generation.clone(),
        };
        if !request.valid() {
            return Err(BrowserError::InvalidFrame);
        }
        let payload = serde_json::to_vec(&request).map_err(|_| BrowserError::InvalidFrame)?;
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending.lock().unwrap();
            if pending.len() >= MAX_PENDING {
                return Err(BrowserError::InvalidFrame);
            }
            pending.insert(id.clone(), (generation, tx));
        }
        struct InFlight<'a> {
            link: &'a ChromeLink,
            armed: bool,
        }
        impl Drop for InFlight<'_> {
            fn drop(&mut self) {
                if self.armed {
                    self.link.close(BrowserError::Closed);
                }
            }
        }
        let mut guard = InFlight {
            link: self,
            armed: true,
        };
        let submitted = tokio::time::timeout(Duration::from_secs(3), async {
            let mut writer = self.writer.lock().await;
            self.check()?;
            framing::write_async(&mut *writer, &payload).await
        })
        .await;
        match submitted {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                self.close(error.clone());
                guard.armed = false;
                return Err(error);
            }
            Err(_) => {
                self.close(BrowserError::Deadline);
                guard.armed = false;
                return Err(BrowserError::Deadline);
            }
        }
        let result = match tokio::time::timeout(Duration::from_secs(15), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(BrowserError::Closed),
            Err(_) => {
                self.close(BrowserError::Deadline);
                Err(BrowserError::Deadline)
            }
        };
        guard.armed = false;
        result
    }
    fn receive(&self, payload: &[u8]) -> Result<(), BrowserError> {
        if payload.is_empty() || payload.len() > MAX_FRAME || self.closed.load(Ordering::Acquire) {
            return Err(BrowserError::InvalidFrame);
        }
        let value: Value =
            serde_json::from_slice(payload).map_err(|_| BrowserError::InvalidFrame)?;
        if value["version"] != 1 {
            return Err(BrowserError::InvalidFrame);
        }
        if let Some(event) = value["event"].as_str() {
            match event {
                "hello" | "pairRequested" => {
                    let incoming: Hello =
                        serde_json::from_value(value).map_err(|_| BrowserError::InvalidFrame)?;
                    if !incoming.valid() {
                        return Err(BrowserError::Identity);
                    }
                    let mut hello = self.hello.lock().unwrap();
                    if hello.as_ref().is_some_and(|old| {
                        old.installation_id != incoming.installation_id
                            || old.bridge_epoch != incoming.bridge_epoch
                    }) {
                        return Err(BrowserError::Identity);
                    }
                    *hello = Some(incoming.clone());
                    let _ = self.events.send(LinkEvent::Hello(incoming));
                }
                "detached" => {
                    let token = value["attachmentToken"]
                        .as_str()
                        .filter(|t| uuid_text(t))
                        .ok_or(BrowserError::InvalidFrame)?;
                    let mut detached = self.detached.lock().unwrap();
                    if detached.len() >= 4096 {
                        return Err(BrowserError::InvalidFrame);
                    }
                    detached.insert(token.into());
                    let _ = self.events.send(LinkEvent::Detached(token.into()));
                }
                "webProviderCleanupFailed" => {
                    if !matches!(
                        value["provider"].as_str(),
                        Some("chatgpt" | "gemini" | "claude")
                    ) || !value["sessionToken"].as_str().is_some_and(uuid_text)
                    {
                        return Err(BrowserError::InvalidFrame);
                    }
                    let _ = self.events.send(LinkEvent::CleanupFailed);
                }
                _ => return Err(BrowserError::InvalidFrame),
            }
            return Ok(());
        }
        let response: Response =
            serde_json::from_value(value).map_err(|_| BrowserError::InvalidFrame)?;
        let mut pending = self.pending.lock().unwrap();
        let Some((generation, _)) = pending.get(&response.id) else {
            return Err(BrowserError::InvalidFrame);
        };
        if response.generation != *generation {
            return Err(BrowserError::Identity);
        }
        let (_, tx) = pending.remove(&response.id).unwrap();
        drop(pending);
        if response.ok {
            let result = response
                .result
                .filter(|result| result.is_object() || result.is_array())
                .ok_or(BrowserError::InvalidFrame)?;
            let _ = tx.send(Ok(result));
        } else {
            let code = response.error.as_ref().map(|error| error.code.as_str());
            let _ = tx.send(Err(BrowserError::from_code(code)));
            if revokes_connection(code) {
                self.close(BrowserError::Closed);
            }
        }
        Ok(())
    }
    pub fn close(&self, error: BrowserError) {
        if self.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        for (_, (_, tx)) in self.pending.lock().unwrap().drain() {
            let _ = tx.send(Err(error.clone()));
        }
        let _ = self.events.send(LinkEvent::Disconnected);
        // SAFETY: both owned socket halves remain members of this live link/read task. Shutdown neither closes nor transfers the descriptor.
        unsafe { libc::shutdown(self.fd, libc::SHUT_RDWR) };
    }
}
pub struct BridgeServer {
    listener: UnixListener,
    path: PathBuf,
    identity: (u64, u64),
    verifier: Arc<dyn PeerVerifier>,
}
impl BridgeServer {
    pub fn bind(directory: &Path, verifier: Arc<dyn PeerVerifier>) -> Result<Self, BrowserError> {
        prepare_directory(directory)?;
        let path = directory.join("bridge.sock");
        if let Ok(info) = std::fs::symlink_metadata(&path) {
            // SAFETY: getuid returns the effective owner's real UID without pointer arguments.
            if !info.file_type().is_socket() || info.uid() != unsafe { libc::getuid() } {
                return Err(BrowserError::Identity);
            }
            if std::os::unix::net::UnixStream::connect(&path).is_ok() {
                return Err(BrowserError::Unavailable);
            }
            std::fs::remove_file(&path).map_err(|_| BrowserError::Configuration)?;
        }
        let listener = UnixListener::bind(&path).map_err(|_| BrowserError::Unavailable)?;
        let info = std::fs::symlink_metadata(&path).map_err(|_| BrowserError::Identity)?;
        Ok(Self {
            listener,
            path,
            identity: (info.dev(), info.ino()),
            verifier,
        })
    }
    pub async fn accept(&self) -> Result<Arc<ChromeLink>, BrowserError> {
        let (stream, _) = self
            .listener
            .accept()
            .await
            .map_err(|_| BrowserError::Unavailable)?;
        ChromeLink::from_verified(stream, self.verifier.clone())
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
}
impl Drop for BridgeServer {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.path)
            .is_ok_and(|info| (info.dev(), info.ino()) == self.identity)
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}
pub struct ExtensionBrowserTransport {
    pub link: Arc<ChromeLink>,
    pub generation: Uuid,
    pub cleanup_proofs: Arc<crate::CleanupProofStore>,
}
#[async_trait::async_trait]
impl BrowserTransport for ExtensionBrowserTransport {
    async fn request(
        &self,
        operation: BrowserOperation,
    ) -> Result<BrowserSnapshot, BrowserTransportError> {
        let cleanup_token = match &operation {
            BrowserOperation::Finish { session_token }
            | BrowserOperation::Cancel { session_token } => Some(*session_token),
            _ => None,
        };
        if let Some(token) = cleanup_token
            && let Some(snapshot) = self.cleanup_proofs.finished(self.generation, token)
        {
            return Ok(snapshot);
        }
        let start_provider = if let BrowserOperation::Start { provider } = &operation {
            Some(*provider)
        } else {
            None
        };
        let reservation = if start_provider.is_some() {
            Some(
                self.cleanup_proofs
                    .reserve()
                    .map_err(|_| BrowserTransportError::Rejected)?,
            )
        } else {
            None
        };
        let source_hello = if start_provider.is_some() {
            Some(
                self.link
                    .hello()
                    .ok_or(BrowserTransportError::InvalidResponse)?,
            )
        } else {
            None
        };
        let expected_token = match &operation {
            BrowserOperation::Start { .. } => None,
            BrowserOperation::Poll { session_token }
            | BrowserOperation::Send { session_token, .. }
            | BrowserOperation::Finish { session_token }
            | BrowserOperation::Cancel { session_token } => Some(*session_token),
        };
        let (name, params) = match operation {
            BrowserOperation::Start { provider } => {
                ("webProviderStart", json!({"provider":provider}))
            }
            BrowserOperation::Poll { session_token } => {
                ("webProviderPoll", json!({"sessionToken":session_token}))
            }
            BrowserOperation::Send {
                session_token,
                prompt,
            } => (
                "webProviderSend",
                json!({"sessionToken":session_token,"prompt":prompt}),
            ),
            BrowserOperation::Finish { session_token } => {
                ("webProviderFinish", json!({"sessionToken":session_token}))
            }
            BrowserOperation::Cancel { session_token } => {
                ("webProviderCancel", json!({"sessionToken":session_token}))
            }
        };
        let mut value = self
            .link
            .request(name, params, self.generation)
            .await
            .map_err(|error| match error {
                BrowserError::Deadline => BrowserTransportError::Timeout,
                BrowserError::Closed | BrowserError::Unavailable => {
                    BrowserTransportError::Disconnected
                }
                BrowserError::ReloadRequired => BrowserTransportError::ReloadRequired,
                BrowserError::Rejected(code) if code == "web_sign_in_required" => {
                    BrowserTransportError::SignInRequired
                }
                BrowserError::Rejected(code) if code.starts_with("web_") => {
                    BrowserTransportError::Website(
                        serde_json::from_value::<BrowserFailureCode>(json!(code))
                            .unwrap_or(BrowserFailureCode::Unknown),
                    )
                }
                _ => BrowserTransportError::Rejected,
            })?;
        if let Some(cleanup) = value["cleanup"].as_str() {
            let normalized = json!({"closed":matches!(cleanup,"not_created"|"deleted"|"temporary_closed")&&value["state"]=="finished","error":if cleanup=="failed"{value.get("error").cloned()}else{None}});
            value["cleanup"] = normalized;
        }
        let snapshot: BrowserSnapshot =
            serde_json::from_value(value).map_err(|_| BrowserTransportError::InvalidResponse)?;
        if expected_token.is_some_and(|token| token != snapshot.session_token)
            || start_provider.is_some_and(|provider| provider != snapshot.provider)
        {
            self.link.close(BrowserError::Identity);
            return Err(BrowserTransportError::InvalidResponse);
        }
        let evidence = if let (Some(reservation), Some(hello)) = (reservation, source_hello) {
            self.cleanup_proofs
                .register(reservation, &hello, self.generation, &snapshot)
        } else {
            self.cleanup_proofs.update(self.generation, &snapshot)
        };
        evidence.map_err(|_| BrowserTransportError::InvalidResponse)?;
        Ok(snapshot)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct TestVerifier;
    impl PeerVerifier for TestVerifier {
        fn verify_host(&self, _: i32) -> Result<VerifiedPeer, BrowserError> {
            Ok(VerifiedPeer {
                helper_pid: 1,
                chrome_pid: 2,
            })
        }
        fn verify_chrome(&self, _: i32) -> Result<(), BrowserError> {
            Ok(())
        }
    }
    #[tokio::test]
    async fn exact_request_response_and_unknown_message_fail_closed() {
        let (a, mut b) = UnixStream::pair().unwrap();
        let link = ChromeLink::from_verified(a, Arc::new(TestVerifier)).unwrap();
        let owner = link.clone();
        let task =
            tokio::spawn(
                async move { owner.request("inventory", json!({}), Uuid::new_v4()).await },
            );
        let bytes = framing::read_async(&mut b).await.unwrap().unwrap();
        let request: Request = serde_json::from_slice(&bytes).unwrap();
        framing::write_async(&mut b,&serde_json::to_vec(&json!({"version":1,"id":request.id,"generation":request.generation,"ok":true,"result":{"candidates":[]}})).unwrap()).await.unwrap();
        assert_eq!(task.await.unwrap().unwrap(), json!({"candidates":[]}));
        assert!(link.receive(br#"{"version":1,"event":"unknown"}"#).is_err());
    }
    #[tokio::test]
    async fn cancelling_potentially_delivered_request_revokes_all_old_authority() {
        let (a, mut b) = UnixStream::pair().unwrap();
        let link = ChromeLink::from_verified(a, Arc::new(TestVerifier)).unwrap();
        let owner = link.clone();
        let task =
            tokio::spawn(
                async move { owner.request("inventory", json!({}), Uuid::new_v4()).await },
            );
        let _ = framing::read_async(&mut b).await.unwrap();
        task.abort();
        let _ = task.await;
        assert_eq!(link.check(), Err(BrowserError::Closed));
    }
}
