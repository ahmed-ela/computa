//! A foreground Chrome process owned by this task. Never discovers a user's Chrome endpoint.
use crate::{
    ApplePeerVerifier, BrowserError, PeerVerifier, identity,
    leases::{Attachment, BrowserControl, BrowserOwnership, Candidate},
};
use computa_contracts::chrome::{MAX_FRAME, policy};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::Read,
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::TcpStream,
    process::{Child, Command},
    sync::Mutex,
    time::{Instant, timeout},
};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream,
    tungstenite::{Message, protocol::WebSocketConfig},
};
use uuid::Uuid;

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct Cdp {
    socket: Socket,
    next: u64,
}
struct Bound {
    attachment: Attachment,
    session: String,
    frame: Option<Value>,
    contexts: HashSet<u64>,
    objects: HashMap<String, String>,
}
pub struct OwnedBrowserController {
    generation: Uuid,
    epoch: Uuid,
    pid: u32,
    executable: PathBuf,
    profile: PathBuf,
    child: Mutex<Option<Child>>,
    cdp: Mutex<Cdp>,
    attachments: Mutex<HashMap<String, Bound>>,
    valid: AtomicBool,
}
struct RequestGuard<'a> {
    valid: &'a AtomicBool,
    armed: bool,
}
struct StartupProfile {
    path: PathBuf,
    identity: (u64, u64),
    armed: bool,
}
impl Drop for StartupProfile {
    fn drop(&mut self) {
        if self.armed
            && std::fs::symlink_metadata(&self.path)
                .is_ok_and(|info| info.is_dir() && (info.dev(), info.ino()) == self.identity)
        {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}
impl Drop for RequestGuard<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.valid.store(false, Ordering::SeqCst);
        }
    }
}

impl OwnedBrowserController {
    pub async fn launch(
        executable: PathBuf,
        profile_parent: PathBuf,
        initial_url: &str,
        generation: Uuid,
    ) -> Result<Arc<Self>, BrowserError> {
        if !policy::eligible_owned(initial_url)
            || !executable.is_absolute()
            || !profile_parent.is_absolute()
        {
            return Err(BrowserError::Configuration);
        }
        let executable =
            std::fs::canonicalize(executable).map_err(|_| BrowserError::Unavailable)?;
        if executable
            .file_name()
            .is_none_or(|name| name != "Google Chrome")
            || !executable
                .to_string_lossy()
                .contains(".app/Contents/MacOS/")
        {
            return Err(BrowserError::Identity);
        }
        identity::prepare_directory(&profile_parent)?;
        let profile = profile_parent.join(format!("isolated-{}", Uuid::new_v4()));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&profile)
            .map_err(|_| BrowserError::Configuration)?;
        let profile_info =
            std::fs::symlink_metadata(&profile).map_err(|_| BrowserError::Identity)?;
        let mut startup_profile = StartupProfile {
            path: profile.clone(),
            identity: (profile_info.dev(), profile_info.ino()),
            armed: true,
        };
        let mut command = Command::new(&executable);
        command
            .args([
                "--remote-debugging-port=0",
                "--remote-debugging-address=127.0.0.1",
                "--no-first-run",
                "--no-default-browser-check",
            ])
            .arg(format!("--user-data-dir={}", profile.display()))
            .arg(initial_url)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        // A private process group lets shutdown reap this browser and its own subprocesses only.
        command.as_std_mut().process_group(0);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(_) => {
                let _ = std::fs::remove_dir(&profile);
                return Err(BrowserError::Unavailable);
            }
        };
        let pid = child.id().ok_or(BrowserError::Unavailable)?;
        let connection = Self::startup(&mut child, pid, &profile).await;
        let socket = match connection {
            Ok(socket) => socket,
            Err(error) => {
                terminate(&mut child, pid).await;
                let _ = std::fs::remove_dir_all(&profile);
                return Err(error);
            }
        };
        startup_profile.armed = false;
        Ok(Arc::new(Self {
            generation,
            epoch: Uuid::new_v4(),
            pid,
            executable,
            profile,
            child: Mutex::new(Some(child)),
            cdp: Mutex::new(Cdp { socket, next: 0 }),
            attachments: Mutex::new(HashMap::new()),
            valid: AtomicBool::new(true),
        }))
    }
    async fn startup(child: &mut Child, pid: u32, profile: &Path) -> Result<Socket, BrowserError> {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if child
                .try_wait()
                .map_err(|_| BrowserError::Unavailable)?
                .is_some()
            {
                return Err(BrowserError::Unavailable);
            }
            if let Ok((port, path)) = read_endpoint(profile) {
                ApplePeerVerifier.verify_chrome(pid as i32)?;
                verify_listener(pid, port).await?;
                let address = format!("ws://127.0.0.1:{port}{path}");
                let config = WebSocketConfig::default()
                    .max_message_size(Some(16 * 1024 * 1024))
                    .max_frame_size(Some(16 * 1024 * 1024));
                let (socket, _) = timeout(
                    Duration::from_secs(5),
                    tokio_tungstenite::connect_async_with_config(address, Some(config), false),
                )
                .await
                .map_err(|_| BrowserError::Deadline)?
                .map_err(|_| BrowserError::Unavailable)?;
                // Recheck the exact process after connection; no endpoint from a recycled PID is admitted.
                if child
                    .try_wait()
                    .map_err(|_| BrowserError::Unavailable)?
                    .is_some()
                {
                    return Err(BrowserError::Identity);
                }
                ApplePeerVerifier.verify_chrome(pid as i32)?;
                return Ok(socket);
            }
            if Instant::now() >= deadline {
                return Err(BrowserError::Deadline);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    pub fn pid(&self) -> u32 {
        self.pid
    }
    pub fn profile_path(&self) -> &Path {
        &self.profile
    }
    pub fn executable_path(&self) -> &Path {
        &self.executable
    }
    async fn rpc(
        &self,
        method: &str,
        params: Value,
        session: Option<&str>,
    ) -> Result<Value, BrowserError> {
        let mut cdp = self.cdp.lock().await;
        if !self.valid.load(Ordering::SeqCst) {
            return Err(BrowserError::Closed);
        }
        if self
            .child
            .lock()
            .await
            .as_mut()
            .is_none_or(|child| child.try_wait().ok().flatten().is_some())
        {
            self.valid.store(false, Ordering::SeqCst);
            return Err(BrowserError::Closed);
        }
        ApplePeerVerifier.verify_chrome(self.pid as i32)?;
        let mut guard = RequestGuard {
            valid: &self.valid,
            armed: true,
        };
        cdp.next += 1;
        let id = cdp.next;
        let mut request = json!({"id":id,"method":method,"params":params});
        if let Some(session) = session {
            request["sessionId"] = json!(session);
        }
        let result = timeout(Duration::from_secs(15), async {
            cdp.socket
                .send(Message::Text(request.to_string().into()))
                .await
                .map_err(|_| BrowserError::Closed)?;
            for _ in 0..4096 {
                let message = cdp
                    .socket
                    .next()
                    .await
                    .ok_or(BrowserError::Closed)?
                    .map_err(|_| BrowserError::Closed)?;
                let Message::Text(text) = message else {
                    if matches!(message, Message::Close(_)) {
                        return Err(BrowserError::Closed);
                    }
                    continue;
                };
                if text.len() > 16 * 1024 * 1024 {
                    return Err(BrowserError::InvalidFrame);
                }
                let value: Value =
                    serde_json::from_str(&text).map_err(|_| BrowserError::InvalidFrame)?;
                if value.get("id").is_none() {
                    continue;
                }
                if value["id"] != id || value.get("sessionId").and_then(Value::as_str) != session {
                    return Err(BrowserError::InvalidFrame);
                }
                if value.get("error").is_some() {
                    return Err(BrowserError::Rejected("chrome_operation_failed".into()));
                }
                return value
                    .get("result")
                    .cloned()
                    .filter(Value::is_object)
                    .ok_or(BrowserError::InvalidFrame);
            }
            Err(BrowserError::InvalidFrame)
        })
        .await
        .map_err(|_| BrowserError::Deadline)?;
        if result.is_ok() || matches!(result, Err(BrowserError::Rejected(_))) {
            guard.armed = false;
        }
        result
    }
    async fn targets(&self) -> Result<Vec<Value>, BrowserError> {
        let result = self.rpc("Target.getTargets", json!({}), None).await?;
        let targets = result["targetInfos"]
            .as_array()
            .ok_or(BrowserError::InvalidFrame)?;
        if targets.len() > 2048 {
            return Err(BrowserError::InvalidFrame);
        }
        let mut unique = HashSet::new();
        let mut out = vec![];
        for target in targets {
            let id = target["targetId"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 256)
                .ok_or(BrowserError::InvalidFrame)?;
            if !unique.insert(id) {
                return Err(BrowserError::InvalidFrame);
            }
            if target["type"] == "page"
                && target["url"].as_str().is_some_and(policy::eligible_owned)
            {
                out.push(target.clone());
            }
        }
        Ok(out)
    }
    async fn current(&self, target: &str) -> Result<Value, BrowserError> {
        self.targets()
            .await?
            .into_iter()
            .find(|v| v["targetId"] == target)
            .ok_or(BrowserError::Rejected("target_unavailable".into()))
    }
    pub async fn inventory(&self) -> Result<Vec<Candidate>, BrowserError> {
        Ok(self
            .targets()
            .await?
            .iter()
            .map(|t| Candidate {
                target_id: t["targetId"].as_str().unwrap().into(),
                title: t["title"]
                    .as_str()
                    .unwrap_or("")
                    .chars()
                    .take(4096)
                    .collect(),
                url: t["url"].as_str().unwrap().into(),
                availability: if t["attached"] == false {
                    "available"
                } else {
                    "busy"
                }
                .into(),
            })
            .collect())
    }
    pub async fn attach(&self, target: &str) -> Result<Attachment, BrowserError> {
        let mut attachments = self.attachments.lock().await;
        if attachments.len() >= 16 {
            return Err(BrowserError::Rejected("capacity_exceeded".into()));
        }
        if attachments
            .values()
            .any(|a| a.attachment.target_id == target)
        {
            return Err(BrowserError::Rejected("already_attached".into()));
        }
        let observed = self.current(target).await?;
        if observed["attached"] != false {
            return Err(BrowserError::Rejected("target_busy".into()));
        }
        let result = self
            .rpc(
                "Target.attachToTarget",
                json!({"targetId":target,"flatten":true}),
                None,
            )
            .await?;
        let session = result["sessionId"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or(BrowserError::InvalidFrame)?
            .to_owned();
        let current = self.current(target).await?;
        let attachment = Attachment {
            attachment_token: Uuid::new_v4().to_string(),
            target_id: target.into(),
            title: current["title"]
                .as_str()
                .unwrap_or("")
                .chars()
                .take(4096)
                .collect(),
            url: current["url"]
                .as_str()
                .ok_or(BrowserError::InvalidFrame)?
                .into(),
        };
        attachments.insert(
            attachment.attachment_token.clone(),
            Bound {
                attachment: attachment.clone(),
                session,
                frame: None,
                contexts: HashSet::new(),
                objects: HashMap::new(),
            },
        );
        Ok(attachment)
    }
    pub async fn command(
        &self,
        token: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError> {
        policy::validate_owned(method, &params).map_err(BrowserError::Rejected)?;
        let mut attachments = self.attachments.lock().await;
        let bound = attachments
            .get_mut(token)
            .ok_or(BrowserError::Rejected("stale_attachment".into()))?;
        self.current(&bound.attachment.target_id).await?;
        check_capability(bound, method, &params)?;
        let value = self
            .rpc(method, params.clone(), Some(&bound.session))
            .await?;
        record_result(bound, method, &params, value)
    }
    pub async fn navigate(&self, token: &str, url: &str) -> Result<Value, BrowserError> {
        if !policy::eligible_owned(url) {
            return Err(BrowserError::Rejected("invalid_request".into()));
        }
        let mut attachments = self.attachments.lock().await;
        let bound = attachments
            .get_mut(token)
            .ok_or(BrowserError::Rejected("stale_attachment".into()))?;
        self.current(&bound.attachment.target_id).await?;
        // Retire references before navigation, including when its result is lost.
        bound.frame = None;
        bound.contexts.clear();
        bound.objects.clear();
        let result = self
            .rpc("Page.navigate", json!({"url":url}), Some(&bound.session))
            .await?;
        if result.get("errorText").is_some() {
            return Err(BrowserError::Rejected("navigation_failed".into()));
        }
        Ok(result)
    }
    pub async fn detach(&self, token: &str) -> Result<(), BrowserError> {
        let mut attachments = self.attachments.lock().await;
        let bound = attachments
            .get(token)
            .ok_or(BrowserError::Rejected("stale_attachment".into()))?;
        self.rpc(
            "Target.detachFromTarget",
            json!({"sessionId":bound.session}),
            None,
        )
        .await?;
        attachments.remove(token);
        Ok(())
    }
    pub async fn shutdown(&self) -> Vec<Value> {
        self.valid.store(false, Ordering::SeqCst);
        let mut warnings = vec![];
        if let Some(mut child) = self.child.lock().await.take() {
            terminate(&mut child, self.pid).await;
            if child.try_wait().ok().flatten().is_none() {
                warnings.push(json!({"pid":self.pid,"closed":false}));
                return warnings;
            }
        }
        if group_exists(self.pid) {
            warnings.push(json!({"pid":self.pid,"closed":false}));
            return warnings;
        }
        self.attachments.lock().await.clear();
        if std::fs::remove_dir_all(&self.profile).is_err() && self.profile.exists() {
            warnings.push(json!({"profileRemoved":false}));
        }
        warnings
    }
}
#[async_trait::async_trait]
impl BrowserControl for OwnedBrowserController {
    fn generation(&self) -> Uuid {
        self.generation
    }
    fn bridge_epoch(&self) -> Uuid {
        self.epoch
    }
    fn ownership(&self) -> BrowserOwnership {
        BrowserOwnership::Owned
    }
    async fn inventory(&self) -> Result<Vec<Candidate>, BrowserError> {
        OwnedBrowserController::inventory(self).await
    }
    async fn attach(&self, target: &str) -> Result<Attachment, BrowserError> {
        OwnedBrowserController::attach(self, target).await
    }
    async fn command(
        &self,
        token: &str,
        method: &str,
        params: Value,
    ) -> Result<Value, BrowserError> {
        OwnedBrowserController::command(self, token, method, params).await
    }
    async fn detach(&self, token: &str) -> Result<(), BrowserError> {
        OwnedBrowserController::detach(self, token).await
    }
    async fn navigate(&self, token: &str, url: &str) -> Result<Value, BrowserError> {
        OwnedBrowserController::navigate(self, token, url).await
    }
    async fn shutdown(&self) -> Vec<Value> {
        OwnedBrowserController::shutdown(self).await
    }
}
fn check_capability(bound: &Bound, method: &str, p: &Value) -> Result<(), BrowserError> {
    let code = match method {
        "DOMSnapshot.captureSnapshot" if bound.frame.is_none() => Some("stale_frame"),
        "Page.createIsolatedWorld"
            if bound.frame.as_ref().map(|f| &f["id"]) != Some(&p["frameId"]) =>
        {
            Some("stale_frame")
        }
        "DOM.resolveNode"
            if !p["executionContextId"]
                .as_u64()
                .is_some_and(|id| bound.contexts.contains(&id)) =>
        {
            Some("stale_context")
        }
        "Runtime.callFunctionOn"
            if !p["objectId"]
                .as_str()
                .is_some_and(|id| bound.objects.contains_key(id))
                || bound.frame.as_ref().map(|f| &f["url"]) != Some(&p["arguments"][0]["value"]) =>
        {
            Some("stale_object")
        }
        _ => None,
    };
    code.map_or(Ok(()), |code| Err(BrowserError::Rejected(code.into())))
}
fn record_result(
    bound: &mut Bound,
    method: &str,
    p: &Value,
    value: Value,
) -> Result<Value, BrowserError> {
    let invalid = || BrowserError::InvalidFrame;
    match method {
        "Page.getFrameTree" => {
            let f = &value["frameTree"]["frame"];
            if f["id"].as_str().is_none_or(|s| s.is_empty())
                || f["loaderId"].as_str().is_none_or(|s| s.is_empty())
                || !f["url"].as_str().is_some_and(policy::eligible_owned)
            {
                return Err(invalid());
            }
            let url = format!(
                "{}{}",
                f["url"].as_str().unwrap(),
                f["urlFragment"].as_str().unwrap_or("")
            );
            let frame = json!({"id":f["id"],"loaderId":f["loaderId"],"url":url});
            if bound.frame.as_ref() != Some(&frame) {
                bound.contexts.clear();
                bound.objects.clear();
            }
            bound.frame = Some(frame);
        }
        "Page.createIsolatedWorld" => {
            let id = value["executionContextId"]
                .as_u64()
                .filter(|id| *id > 0)
                .ok_or_else(invalid)?;
            if bound.contexts.len() >= 64 {
                return Err(invalid());
            }
            bound.contexts.insert(id);
        }
        "DOM.resolveNode" => {
            let id = value["object"]["objectId"]
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 2048)
                .ok_or_else(invalid)?;
            if bound.objects.len() >= 256 {
                return Err(invalid());
            }
            bound.objects.insert(
                id.into(),
                p["objectGroup"].as_str().ok_or_else(invalid)?.into(),
            );
        }
        "Runtime.releaseObjectGroup" => bound
            .objects
            .retain(|_, group| Some(group.as_str()) != p["objectGroup"].as_str()),
        "Accessibility.getFullAXTree" => {
            return policy::project_ax(&value, MAX_FRAME - 4096).map_err(BrowserError::Rejected);
        }
        "DOMSnapshot.captureSnapshot" => {
            return policy::project_clickability_owned(
                &value,
                MAX_FRAME - 4096,
                bound.frame.as_ref().ok_or_else(invalid)?,
            )
            .map_err(BrowserError::Rejected);
        }
        _ => {}
    }
    if serde_json::to_vec(&value).map_err(|_| invalid())?.len() > MAX_FRAME - 4096 {
        return Err(invalid());
    }
    Ok(value)
}
fn parse_endpoint(text: &str) -> Result<(u16, String), BrowserError> {
    let lines: Vec<_> = text.lines().collect();
    if lines.len() != 2 {
        return Err(BrowserError::Identity);
    }
    let port = lines[0]
        .parse::<u16>()
        .map_err(|_| BrowserError::Identity)?;
    let Some(id) = lines[1].strip_prefix("/devtools/browser/") else {
        return Err(BrowserError::Identity);
    };
    if port == 0 || Uuid::parse_str(id).is_err() {
        return Err(BrowserError::Identity);
    }
    Ok((port, lines[1].into()))
}
fn read_endpoint(profile: &Path) -> Result<(u16, String), BrowserError> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(profile.join("DevToolsActivePort"))
        .map_err(|_| BrowserError::Unavailable)?;
    let info = file.metadata().map_err(|_| BrowserError::Identity)?;
    // SAFETY: getuid is a process identity query with no pointer arguments.
    if !info.is_file() || info.len() > 1024 || info.uid() != unsafe { libc::getuid() } {
        return Err(BrowserError::Identity);
    }
    let mut text = String::new();
    file.take(1025)
        .read_to_string(&mut text)
        .map_err(|_| BrowserError::Identity)?;
    parse_endpoint(&text)
}
async fn verify_listener(pid: u32, port: u16) -> Result<(), BrowserError> {
    let output = timeout(
        Duration::from_secs(3),
        Command::new("/usr/sbin/lsof")
            .args([
                "-nP",
                "-a",
                "-p",
                &pid.to_string(),
                &format!("-iTCP:{port}"),
                "-sTCP:LISTEN",
                "-Fpn",
            ])
            .output(),
    )
    .await
    .map_err(|_| BrowserError::Deadline)?
    .map_err(|_| BrowserError::Unavailable)?;
    let text = std::str::from_utf8(&output.stdout).map_err(|_| BrowserError::Identity)?;
    let expected_pid = format!("p{pid}");
    let expected_address = format!("n127.0.0.1:{port}");
    if !output.status.success()
        || text.len() > 4096
        || !text.lines().any(|line| line == expected_pid)
        || !text.lines().any(|line| line == expected_address)
        || text
            .lines()
            .filter(|line| line.starts_with('n'))
            .any(|line| line != expected_address)
    {
        return Err(BrowserError::Identity);
    }
    Ok(())
}
async fn terminate(child: &mut Child, pid: u32) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    // SAFETY: while the Child is unreaped its PID cannot be reused. We established this exact process group at spawn.
    unsafe {
        libc::kill(-(pid as i32), libc::SIGTERM);
    }
    if timeout(Duration::from_secs(3), child.wait()).await.is_err() {
        // SAFETY: the Child is still unreaped, and this process group belongs only to the owned browser.
        unsafe {
            libc::kill(-(pid as i32), libc::SIGKILL);
        }
        let _ = timeout(Duration::from_secs(3), child.wait()).await;
    }
}
fn group_exists(pid: u32) -> bool {
    // SAFETY: signal zero performs a liveness query only, and never changes the process group.
    unsafe { libc::kill(-(pid as i32), 0) == 0 }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn bound() -> Bound {
        Bound {
            attachment: Attachment {
                attachment_token: Uuid::new_v4().to_string(),
                target_id: "owned".into(),
                title: String::new(),
                url: "https://example.test".into(),
            },
            session: "session".into(),
            frame: Some(json!({"id":"f","loaderId":"l","url":"https://example.test/"})),
            contexts: HashSet::from([9]),
            objects: HashMap::from([("object".into(), "group".into())]),
        }
    }
    #[test]
    fn only_exact_local_browser_endpoint_is_admitted() {
        let id = Uuid::new_v4();
        assert_eq!(
            parse_endpoint(&format!("32123\n/devtools/browser/{id}\n"))
                .unwrap()
                .0,
            32123
        );
        for text in [
            "0\n/devtools/browser/x",
            "80\nws://example.test",
            "80\n/devtools/page/abc",
            "80\n/devtools/browser/../../evil",
            "80\n/devtools/browser/79e4505e-e068-4c75-87ca-309c060a8c41\nextra",
        ] {
            assert!(parse_endpoint(text).is_err());
        }
    }
    #[test]
    fn endpoint_file_cannot_follow_a_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let other = dir.path().join("other");
        std::fs::write(
            &other,
            format!("32123\n/devtools/browser/{}", Uuid::new_v4()),
        )
        .unwrap();
        std::os::unix::fs::symlink(other, dir.path().join("DevToolsActivePort")).unwrap();
        assert!(read_endpoint(dir.path()).is_err());
    }
    #[test]
    fn document_replacement_retires_context_and_object_authority() {
        let mut b = bound();
        record_result(&mut b,"Page.getFrameTree",&json!({}),json!({"frameTree":{"frame":{"id":"f","loaderId":"replacement","url":"https://example.test/"}}})).unwrap();
        assert!(b.contexts.is_empty());
        assert!(b.objects.is_empty());
        assert_eq!(
            check_capability(&b, "DOM.resolveNode", &json!({"executionContextId":9})),
            Err(BrowserError::Rejected("stale_context".into()))
        );
    }
    #[test]
    fn mutation_requires_exact_observed_object_and_url() {
        let b = bound();
        assert!(
            check_capability(
                &b,
                "Runtime.callFunctionOn",
                &json!({"objectId":"object","arguments":[{"value":"https://example.test/"}]})
            )
            .is_ok()
        );
        assert!(
            check_capability(
                &b,
                "Runtime.callFunctionOn",
                &json!({"objectId":"object","arguments":[{"value":"https://replacement.test/"}]})
            )
            .is_err()
        );
        assert!(
            check_capability(
                &b,
                "Runtime.callFunctionOn",
                &json!({"objectId":"forged","arguments":[{"value":"https://example.test/"}]})
            )
            .is_err()
        );
    }
    #[test]
    fn canceled_wire_request_retires_connection_authority() {
        let valid = AtomicBool::new(true);
        {
            let _guard = RequestGuard {
                valid: &valid,
                armed: true,
            };
        }
        assert!(!valid.load(Ordering::SeqCst));
    }
    #[test]
    fn owned_file_navigation_does_not_expand_borrowed_authority() {
        let path = "file:///tmp/computa-fixture.html";
        assert!(policy::eligible_owned(path));
        assert!(!policy::eligible(path));
        let params = json!({"objectId":"object","functionDeclaration":computa_contracts::chrome::PRESS_FUNCTION,"arguments":[{"value":path}],"returnByValue":true,"awaitPromise":true,"userGesture":true});
        assert!(policy::validate_owned("Runtime.callFunctionOn", &params).is_ok());
        assert!(policy::validate("Runtime.callFunctionOn", &params).is_err());
        assert!(!policy::eligible_owned(
            "file://remote.example/fixture.html"
        ));
    }
    #[test]
    fn canceled_startup_removes_only_its_exact_private_profile() {
        let parent = tempfile::tempdir().unwrap();
        let path = parent.path().join("owned");
        std::fs::create_dir(&path).unwrap();
        let info = std::fs::symlink_metadata(&path).unwrap();
        {
            let _guard = StartupProfile {
                path: path.clone(),
                identity: (info.dev(), info.ino()),
                armed: true,
            };
            std::fs::write(path.join("partial"), b"fixture").unwrap();
        }
        assert!(!path.exists());
        std::fs::create_dir(&path).unwrap();
        let info = std::fs::symlink_metadata(&path).unwrap();
        let moved = parent.path().join("moved");
        let guard = StartupProfile {
            path: path.clone(),
            identity: (info.dev(), info.ino()),
            armed: true,
        };
        std::fs::rename(&path, &moved).unwrap();
        std::fs::create_dir(&path).unwrap();
        drop(guard);
        assert!(path.exists());
        assert!(moved.exists());
    }
}
