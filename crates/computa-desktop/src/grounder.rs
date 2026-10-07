//! App-owned visual worker supervision. No native/AX handles enter the worker;
//! no coordinate escapes until its frozen cascade and exact capture are checked.
use base64::{Engine, engine::general_purpose::STANDARD};
use computa_contracts::grounding::{self as wire, CaptureBinding, RefusalCode, Request, Response};
use computa_harness::executor::{
    GroundingMethod, HarnessError, LocalFuture, QualifiedGrounding, TurnAuthority, VisualGrounder,
    validate_grounding,
};
use computa_macos::{CapturedImage, Point};
use computa_runtime::process::{OwnedProcess, isolated_environment};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::{ChildStdin, ChildStdout},
    sync::Mutex,
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

pub struct NativeGroundingConfig {
    resources: PathBuf,
    model_root: PathBuf,
    process_home: PathBuf,
    codex_home: PathBuf,
}
impl NativeGroundingConfig {
    /// Called only by the native resource resolver. Model paths cannot be
    /// selected or replaced by page IPC, tool arguments or worker requests.
    pub fn bundled(
        resources: PathBuf,
        model_root: PathBuf,
        home: &computa_state::PrivateHome,
    ) -> Self {
        Self {
            resources,
            model_root,
            process_home: home.process_home.clone(),
            codex_home: home.codex_home.clone(),
        }
    }
}
struct Worker {
    process: Arc<OwnedProcess>,
    input: ChildStdin,
    output: ChildStdout,
    instance: Uuid,
    ready: bool,
}
#[derive(Default)]
struct Supervisor {
    worker: Option<Worker>,
    stopped: bool,
}
pub struct NativeGroundingService {
    config: NativeGroundingConfig,
    state: Mutex<Supervisor>,
    shutdown: CancellationToken,
}
pub struct TurnVisualGrounder {
    service: Arc<NativeGroundingService>,
    generation: Uuid,
    authority: TurnAuthority,
}
struct RequestLifetime(CancellationToken);
/// Owned pixels and target frozen at the trusted capture boundary. This is not
/// a worker response or an action capability; generation is checked again by
/// the caller's turn authority before a returned coordinate can be published.
struct FrozenRequest {
    generation: Uuid,
    capture_id: Uuid,
    png: Vec<u8>,
    width: u32,
    height: u32,
    target: String,
}
impl Drop for RequestLifetime {
    fn drop(&mut self) {
        self.0.cancel();
    }
}
impl NativeGroundingService {
    pub fn new(config: NativeGroundingConfig) -> Arc<Self> {
        Arc::new(Self {
            config,
            state: Mutex::new(Supervisor::default()),
            shutdown: CancellationToken::new(),
        })
    }
    pub fn for_turn(
        self: &Arc<Self>,
        generation: Uuid,
        authority: TurnAuthority,
    ) -> TurnVisualGrounder {
        TurnVisualGrounder {
            service: self.clone(),
            generation,
            authority,
        }
    }
    pub async fn shutdown(&self) -> Result<(), String> {
        self.shutdown.cancel();
        let mut state = self.state.lock().await;
        state.stopped = true;
        stop_worker(&mut state).await
    }
    /// Execute in an owned Tokio task so dropping a main-thread future cancels
    /// I/O and still completes exact child-group cleanup, including startup.
    async fn locate(
        self: &Arc<Self>,
        request: FrozenRequest,
        cancellation: &CancellationToken,
    ) -> Result<QualifiedGrounding, String> {
        let request_cancel = cancellation.child_token();
        let _lifetime = RequestLifetime(request_cancel.clone());
        let service = self.clone();
        let owned_cancel = request_cancel.clone();
        let job = tokio::spawn(async move { service.request(request, &owned_cancel).await });
        // The task itself must remain alive after receiver cancellation to reap
        // its child. Awaiting it during ordinary cancellation verifies cleanup.
        job.await.map_err(|_| {
            "The visual worker supervisor failed; no coordinate was authorized.".to_owned()
        })?
    }
    async fn request(
        &self,
        request: FrozenRequest,
        cancel: &CancellationToken,
    ) -> Result<QualifiedGrounding, String> {
        let FrozenRequest {
            generation,
            capture_id,
            png,
            width,
            height,
            target,
        } = request;
        if png.is_empty() || png.len() > wire::MAX_PNG_BYTES {
            return Err(RefusalCode::InvalidImage.message().into());
        }
        let mut state = tokio::select! {
            _=cancel.cancelled()=>return Err(RefusalCode::Cancelled.message().into()),
            _=self.shutdown.cancelled()=>return Err(RefusalCode::Cancelled.message().into()),
            state=self.state.lock()=>state,
        };
        if state.stopped || self.shutdown.is_cancelled() || cancel.is_cancelled() {
            return Err(RefusalCode::Cancelled.message().into());
        }
        if state.worker.as_ref().is_some_and(|w| !w.ready) {
            stop_worker(&mut state).await?;
        }
        if state.worker.is_none() {
            let startup = self.start(&mut state, cancel).await;
            if let Err(error) = startup {
                return fail_and_stop(&mut state, error).await;
            }
        }
        // The captured bytes and target are frozen before any request is sent.
        let binding = CaptureBinding {
            instance: state.worker.as_ref().unwrap().instance,
            request_id: Uuid::new_v4(),
            generation,
            capture_id,
            png_sha256: wire::Sha256::new(hex::encode(Sha256::digest(&png)))
                .map_err(|e| e.to_string())?,
            target_sha256: wire::Sha256::new(hex::encode(Sha256::digest(target.as_bytes())))
                .map_err(|e| e.to_string())?,
            width,
            height,
        };
        let request = Request::Ground {
            binding: binding.clone(),
            png_base64: STANDARD.encode(&png),
            target,
        };
        if request.validate().is_err() {
            return Err(RefusalCode::InvalidRequest.message().into());
        }
        let worker = state.worker.as_mut().unwrap();
        let exchange = async {
            send(&mut worker.input, &request).await?;
            receive(&mut worker.output).await
        };
        let response = tokio::select! {
            _=cancel.cancelled()=>Err(RefusalCode::Cancelled.message().to_owned()),
            _=self.shutdown.cancelled()=>Err(RefusalCode::Cancelled.message().to_owned()),
            result=tokio::time::timeout(Duration::from_secs(60),exchange)=>result.map_err(|_|"Visual grounding exceeded 60 seconds; its owned worker was stopped.".to_owned()).and_then(|r|r),
        };
        let response = match response {
            Ok(r) => r,
            Err(error) => return fail_and_stop(&mut state, error).await,
        };
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return fail_and_stop(&mut state, RefusalCode::Cancelled.message().into()).await;
        }
        match response {
            Response::Unagreed {
                binding: returned,
                elapsed_seconds,
            } if returned == binding
                && elapsed_seconds.is_finite()
                && (0.0..=60.0).contains(&elapsed_seconds) =>
            {
                Err(RefusalCode::NoAgreement.message().into())
            }
            Response::Grounded {
                binding: returned,
                result,
            } => match qualify(&binding, &returned, &result) {
                Ok(result) => Ok(result),
                Err(error) => fail_and_stop(&mut state, error.to_string()).await,
            },
            Response::Refused {
                instance,
                binding: Some(returned),
                code,
            } if instance == binding.instance && returned == binding => {
                // Inference refusal does not authorize action. Reuse only after
                // a complete, matched response; cancel/model failure restarts.
                if matches!(
                    code,
                    RefusalCode::NoAgreement
                        | RefusalCode::InvalidTarget
                        | RefusalCode::InvalidImage
                ) {
                    Err(code.message().into())
                } else {
                    fail_and_stop(&mut state, code.message().into()).await
                }
            }
            _ => fail_and_stop(&mut state, wire::WireError.to_string()).await,
        }
    }
    async fn start(
        &self,
        state: &mut Supervisor,
        cancel: &CancellationToken,
    ) -> Result<(), String> {
        // Early cancellation never creates a worker or mutates supervisor state.
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Err(RefusalCode::Cancelled.message().into());
        }
        let root = &self.config.model_root;
        if !root.exists() {
            return Err(RefusalCode::MissingModels.message().into());
        }
        let executable = verify_worker(&self.config.resources)?;
        let metadata = fs::symlink_metadata(root)
            .map_err(|_| RefusalCode::Installation.message().to_owned())?;
        if !root.is_absolute()
            || root.canonicalize().ok().as_ref() != Some(root)
            || !metadata.is_dir()
            || metadata.file_type().is_symlink()
        {
            return Err(RefusalCode::Installation.message().into());
        }
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Err(RefusalCode::Cancelled.message().into());
        }
        let instance = Uuid::new_v4();
        let args = vec![
            "--model-root".into(),
            root.to_string_lossy().into_owned(),
            "--parent-pid".into(),
            std::process::id().to_string(),
        ];
        let mut environment =
            isolated_environment(&self.config.process_home, &self.config.codex_home);
        environment.insert("COMPUTA_GROUNDING_INSTANCE".into(), instance.to_string());
        let (process, input, output) =
            OwnedProcess::spawn(&executable, &args, &self.config.process_home, &environment)
                .map_err(|_| "Computa's bundled visual worker could not be started.".to_owned())?;
        state.worker = Some(Worker {
            process: Arc::new(process),
            input,
            output,
            instance,
            ready: false,
        });
        let worker = state.worker.as_mut().unwrap();
        let response = tokio::select! {
            _=cancel.cancelled()=>return Err(RefusalCode::Cancelled.message().into()),
            _=self.shutdown.cancelled()=>return Err(RefusalCode::Cancelled.message().into()),
            result=tokio::time::timeout(Duration::from_secs(30),receive(&mut worker.output))=>result.map_err(|_|"Computa's owned visual worker did not become ready within 30 seconds.".to_owned())??,
        };
        if cancel.is_cancelled() || self.shutdown.is_cancelled() {
            return Err(RefusalCode::Cancelled.message().into());
        }
        match response {
            Response::Ready {
                protocol_version,
                method_version,
                instance: returned,
                parent_pid,
                model_names,
            } if protocol_version == wire::PROTOCOL_VERSION
                && method_version == wire::METHOD_VERSION
                && returned == instance
                && parent_pid == std::process::id()
                && model_names == wire::MODELS =>
            {
                worker.ready = true;
                Ok(())
            }
            Response::Refused {
                instance: returned,
                binding: None,
                code,
            } if returned == instance => Err(code.message().into()),
            _ => Err(wire::WireError.to_string()),
        }
    }
}
impl VisualGrounder for TurnVisualGrounder {
    fn locate<'a>(
        &'a mut self,
        capture: &'a CapturedImage,
        target: &'a str,
        cancellation: &'a CancellationToken,
    ) -> LocalFuture<'a, Result<QualifiedGrounding, HarnessError>> {
        Box::pin(async move {
            self.authority.check()?;
            if cancellation.is_cancelled() {
                return Err(HarnessError::Cancelled);
            }
            let width = u32::try_from(capture.width)
                .map_err(|_| HarnessError::Invalid("capture width".into()))?;
            let height = u32::try_from(capture.height)
                .map_err(|_| HarnessError::Invalid("capture height".into()))?;
            let result = self
                .service
                .locate(
                    FrozenRequest {
                        generation: self.generation,
                        capture_id: capture.id,
                        png: capture.png.clone(),
                        width,
                        height,
                        target: target.to_owned(),
                    },
                    cancellation,
                )
                .await
                .map_err(HarnessError::Capability)?;
            self.authority.check()?;
            if cancellation.is_cancelled() {
                return Err(HarnessError::Cancelled);
            }
            validate_grounding(&result, capture)?;
            Ok(result)
        })
    }
}
fn qualify(
    expected: &CaptureBinding,
    returned: &CaptureBinding,
    result: &wire::GroundingResult,
) -> Result<QualifiedGrounding, wire::WireError> {
    if returned != expected {
        return Err(wire::WireError);
    }
    result.validate(expected)?;
    Ok(QualifiedGrounding {
        capture_id: expected.capture_id,
        point: Point {
            x: result.point.x,
            y: result.point.y,
        },
        model_points: wire::MODELS
            .into_iter()
            .filter_map(|name| {
                result.model_points[&name]
                    .map(|p| (name.as_str().to_owned(), Point { x: p.x, y: p.y }))
            })
            .collect(),
        method: if result.used_showui {
            GroundingMethod::ShowUiDisambiguated
        } else {
            GroundingMethod::GoClickGuiOwlAgreement
        },
    })
}
async fn fail_and_stop<T>(state: &mut Supervisor, error: String) -> Result<T, String> {
    match stop_worker(state).await {
        Ok(()) => Err(error),
        Err(cleanup) => Err(format!("{error} {cleanup}")),
    }
}
async fn stop_worker(state: &mut Supervisor) -> Result<(), String> {
    if let Some(worker) = state.worker.as_mut() {
        worker.ready = false;
        worker.process.stop().await.map_err(|_|"The owned visual worker's process group could not be verified stopped. Further visual requests are blocked.".to_owned())?;
        state.worker = None;
    }
    Ok(())
}
async fn send(input: &mut ChildStdin, request: &Request) -> Result<(), String> {
    let bytes = wire::encode(request, wire::MAX_REQUEST_FRAME).map_err(|e| e.to_string())?;
    input
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .await
        .map_err(|_| "The owned visual worker input closed.".to_owned())?;
    input
        .write_all(&bytes)
        .await
        .map_err(|_| "The owned visual worker input closed.".to_owned())?;
    input
        .flush()
        .await
        .map_err(|_| "The owned visual worker input closed.".to_owned())
}
async fn receive(output: &mut ChildStdout) -> Result<Response, String> {
    let length = output
        .read_u32()
        .await
        .map_err(|_| "The owned visual worker output closed.".to_owned())?
        as usize;
    if length == 0 || length > wire::MAX_RESPONSE_FRAME {
        return Err(wire::WireError.to_string());
    }
    let mut bytes = vec![0; length];
    output
        .read_exact(&mut bytes)
        .await
        .map_err(|_| "The owned visual worker response was incomplete.".to_owned())?;
    wire::decode(&bytes, wire::MAX_RESPONSE_FRAME).map_err(|e| e.to_string())
}
fn verify_worker(resources: &Path) -> Result<PathBuf, String> {
    let invalid = || "Computa's bundled visual worker is missing, changed or unsafe.".to_owned();
    let root = resources.canonicalize().map_err(|_| invalid())?;
    if !resources.is_absolute()
        || root != resources
        || fs::symlink_metadata(resources)
            .map_err(|_| invalid())?
            .file_type()
            .is_symlink()
    {
        return Err(invalid());
    }
    let directory = root.join("InferenceRuntime");
    let dir = fs::symlink_metadata(&directory).map_err(|_| invalid())?;
    if !dir.is_dir() || dir.file_type().is_symlink() {
        return Err(invalid());
    }
    let executable = directory.join("computa-grounding-worker");
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&executable)
        .map_err(|_| invalid())?;
    let before = file.metadata().map_err(|_| invalid())?;
    if !before.is_file()
        || before.mode() & 0o111 == 0
        || before.len() < 32
        || before.len() > 512 * 1024 * 1024
    {
        return Err(invalid());
    }
    let mut header = [0u8; 32];
    file.read_exact(&mut header).map_err(|_| invalid())?;
    let word = |offset| u32::from_le_bytes(header[offset..offset + 4].try_into().unwrap());
    if word(0) != 0xfeedfacf
        || word(4) != 0x0100000c
        || word(12) != 2
        || word(16) == 0
        || u64::from(word(20)) > before.len() - 32
    {
        return Err(invalid());
    }
    let current = fs::symlink_metadata(&executable).map_err(|_| invalid())?;
    if current.file_type().is_symlink()
        || !same_file(&before, &current)
        || !same_file(&before, &file.metadata().map_err(|_| invalid())?)
        || executable.canonicalize().map_err(|_| invalid())? != executable
    {
        return Err(invalid());
    }
    Ok(executable)
}
fn same_file(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.len() == b.len()
        && a.mode() == b.mode()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
#[cfg(test)]
mod tests {
    use super::*;
    fn frozen_fixture() -> FrozenRequest {
        FrozenRequest {
            generation: Uuid::new_v4(),
            capture_id: Uuid::new_v4(),
            png: vec![1],
            width: 1,
            height: 1,
            target: "Click button".into(),
        }
    }
    use std::os::unix::fs::{PermissionsExt, symlink};
    #[test]
    fn bundle_resolver_rejects_symlinks_non_native_executables_and_wrong_resource_roots() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        fs::create_dir(root.join("InferenceRuntime")).unwrap();
        let file = root.join("InferenceRuntime/computa-grounding-worker");
        fs::write(&file, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(verify_worker(&root).is_err());
        fs::remove_file(&file).unwrap();
        symlink("/usr/bin/true", &file).unwrap();
        assert!(verify_worker(&root).is_err());
        let alias = root.join("alias");
        symlink(&root, &alias).unwrap();
        assert!(verify_worker(&alias).is_err());
    }
    #[tokio::test]
    async fn already_cancelled_startup_never_spawns_or_replaces_an_owned_worker() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let service = NativeGroundingService::new(NativeGroundingConfig {
            resources: root.clone(),
            model_root: root.clone(),
            process_home: root.clone(),
            codex_home: root,
        });
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(service.request(frozen_fixture(), &cancel).await.is_err());
        assert!(service.state.lock().await.worker.is_none());
        service.shutdown().await.unwrap();
    }
    async fn owned_waiting_worker() -> (tempfile::TempDir, Arc<NativeGroundingService>, i32) {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let service = NativeGroundingService::new(NativeGroundingConfig {
            resources: root.clone(),
            model_root: root.clone(),
            process_home: root.clone(),
            codex_home: root.clone(),
        });
        // This test child contains no model/desktop code and creates no foreign
        // state. Its silent pipe exercises cancellation during an exact owned
        // request, including cleanup after the caller's future is dropped.
        let (process, input, output) = OwnedProcess::spawn(
            Path::new("/bin/sleep"),
            &["60".into()],
            &root,
            &isolated_environment(&root, &root),
        )
        .unwrap();
        let pid = process.pid();
        service.state.lock().await.worker = Some(Worker {
            process: Arc::new(process),
            input,
            output,
            instance: Uuid::new_v4(),
            ready: true,
        });
        (directory, service, pid)
    }
    async fn wait_for_exchange(service: &NativeGroundingService) {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if service.state.try_lock().is_err() {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    fn exact_group_absent(pid: i32) -> bool {
        // SAFETY: signal zero only probes this test's spawned process group.
        (unsafe { libc::kill(-pid, 0) }) != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }
    #[tokio::test]
    async fn cancellation_reaps_the_owned_child_before_returning_and_allows_restart() {
        let (_directory, service, pid) = owned_waiting_worker().await;
        let cancel = CancellationToken::new();
        let running = service.clone();
        let token = cancel.clone();
        let job = tokio::spawn(async move { running.locate(frozen_fixture(), &token).await });
        wait_for_exchange(&service).await;
        cancel.cancel();
        let error = tokio::time::timeout(Duration::from_secs(5), job)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert!(error.contains("cancelled"));
        assert!(service.state.lock().await.worker.is_none());
        assert!(exact_group_absent(pid));
        assert!(!service.state.lock().await.stopped);
        service.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn dropped_main_thread_request_still_cancels_and_reaps_its_worker() {
        let (_directory, service, pid) = owned_waiting_worker().await;
        let running = service.clone();
        let token = CancellationToken::new();
        let job = tokio::spawn(async move { running.locate(frozen_fixture(), &token).await });
        wait_for_exchange(&service).await;
        job.abort();
        assert!(job.await.unwrap_err().is_cancelled());
        tokio::time::timeout(Duration::from_secs(5), async {
            let state = service.state.lock().await;
            assert!(state.worker.is_none());
        })
        .await
        .unwrap();
        assert!(exact_group_absent(pid));
        service.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn host_shutdown_interrupts_an_inflight_request_and_does_not_restart() {
        let (_directory, service, pid) = owned_waiting_worker().await;
        let running = service.clone();
        let token = CancellationToken::new();
        let job = tokio::spawn(async move { running.locate(frozen_fixture(), &token).await });
        wait_for_exchange(&service).await;
        tokio::time::timeout(Duration::from_secs(5), service.shutdown())
            .await
            .unwrap()
            .unwrap();
        assert!(job.await.unwrap().is_err());
        assert!(exact_group_absent(pid));
        let state = service.state.lock().await;
        assert!(state.stopped && state.worker.is_none());
    }
    #[test]
    fn qualified_coordinates_require_exact_capture_target_dimensions_generation_and_frozen_midpoint()
     {
        use std::collections::BTreeMap;
        use wire::{ModelName, PixelPoint};
        let binding = CaptureBinding {
            instance: Uuid::new_v4(),
            request_id: Uuid::new_v4(),
            generation: Uuid::new_v4(),
            capture_id: Uuid::new_v4(),
            png_sha256: wire::Sha256::new("a".repeat(64)).unwrap(),
            target_sha256: wire::Sha256::new("b".repeat(64)).unwrap(),
            width: 100,
            height: 100,
        };
        let mut result = wire::GroundingResult {
            point: PixelPoint { x: 11.0, y: 10.0 },
            used_showui: false,
            selected_pair: [ModelName::GoClick, ModelName::GuiOwl],
            initial_distance_normalized_diagonal: Some(2.0 / 100.0f64.hypot(100.0)),
            selected_distance_normalized_diagonal: 2.0 / 100.0f64.hypot(100.0),
            model_points: BTreeMap::from([
                (ModelName::GoClick, Some(PixelPoint { x: 10.0, y: 10.0 })),
                (ModelName::GuiOwl, Some(PixelPoint { x: 12.0, y: 10.0 })),
                (ModelName::ShowUi, None),
            ]),
            model_seconds: BTreeMap::from([(ModelName::GoClick, 0.1), (ModelName::GuiOwl, 0.2)]),
            elapsed_seconds: 0.4,
        };
        let qualified = qualify(&binding, &binding, &result).unwrap();
        assert_eq!(qualified.capture_id, binding.capture_id);
        assert_eq!(qualified.point, Point { x: 11.0, y: 10.0 });
        for field in 0..8 {
            let mut foreign = binding.clone();
            match field {
                0 => foreign.instance = Uuid::new_v4(),
                1 => foreign.request_id = Uuid::new_v4(),
                2 => foreign.generation = Uuid::new_v4(),
                3 => foreign.capture_id = Uuid::new_v4(),
                4 => foreign.png_sha256 = wire::Sha256::new("c".repeat(64)).unwrap(),
                5 => foreign.target_sha256 = wire::Sha256::new("d".repeat(64)).unwrap(),
                6 => foreign.width += 1,
                _ => foreign.height += 1,
            }
            assert!(qualify(&binding, &foreign, &result).is_err());
        }
        result.point.x += 0.0001;
        assert!(qualify(&binding, &binding, &result).is_err());
    }
}
