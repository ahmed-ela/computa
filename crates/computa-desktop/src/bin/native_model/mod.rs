mod audit;
mod backend;
use audit::{Audit, hash};
use backend::{Effects, RestrictedBackend};
use computa_contracts::{
    Identifier,
    appserver::{ContentItem, DispatchError, ExecutionScope, ToolOutput, TurnConclusion},
    models::ModelId,
    tools::InteractionPolicy,
    ui::{EntryKind, NativeAction},
};
use computa_desktop::grounder::{NativeGroundingConfig, NativeGroundingService};
use computa_harness::{
    ApprovalGate, BrowserToolLane, Harness, HarnessError, LocalFuture, NativeApproval,
    browser::RoutingBrowserLane,
};
use computa_macos::{
    MacosBackend, NativeBackend, PermissionGrant, TreeLimits,
    qualification_fixture::{
        self as fixture, BUNDLE_ID, DIGIT_ID, DISPLAY_ID, OwnedQualificationFixture,
    },
};
use computa_runtime::{
    ApprovalDecision, ChannelToolDispatcher, NativeCommand, NativeInferenceConfig,
    NativeInferenceLifecycle, Runtime, RuntimeConfig, RuntimeEvent,
};
use computa_state::PrivateHome;
use futures::{executor::LocalPool, task::LocalSpawnExt};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    fs::OpenOptions,
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    trial_id: Uuid,
    task: String,
    model_id: ModelId,
    resources: PathBuf,
    worker: PathBuf,
    model_root: PathBuf,
    port: u16,
    fixture_executable: Option<PathBuf>,
    grounding_resources: PathBuf,
    grounding_model_root: PathBuf,
    directory: PathBuf,
    parent_pid: i32,
}
#[derive(Clone)]
struct Call {
    id: Identifier,
    name: String,
    args: Value,
    output: ToolOutput,
}
#[derive(Default)]
struct AuditState {
    calls: Vec<Call>,
    approved: Vec<String>,
    unexpected: Vec<String>,
    oracle: Option<Value>,
    cleanup: Vec<String>,
}
struct Gate {
    state: Rc<RefCell<AuditState>>,
    allowed: String,
    call_id: Identifier,
    scope: ExecutionScope,
}
impl ApprovalGate for Gate {
    fn approve<'a>(
        &'a mut self,
        r: NativeApproval,
    ) -> LocalFuture<'a, std::result::Result<bool, HarnessError>> {
        Box::pin(async move {
            let expected = format!(
                "computer:{}:{}",
                self.scope.generation,
                self.call_id.as_str()
            );
            let title = match self.allowed.as_str() {
                "open" => "Application action",
                "chrome" => "Isolated browser action",
                "press" => "Computer action",
                "click" => "Computer pointer action",
                _ => "never",
            };
            let okay = r.id == expected && r.task_id == self.scope.task_id && r.title == title;
            if okay {
                self.state.borrow_mut().approved.push(self.allowed.clone())
            } else {
                self.state
                    .borrow_mut()
                    .unexpected
                    .push("unexpected_native_approval".into())
            }
            Ok(okay)
        })
    }
}
struct Slot {
    scope: ExecutionScope,
    harness: Harness<RestrictedBackend>,
    browser: RoutingBrowserLane,
    cancel: CancellationToken,
}
fn text(output: &ToolOutput) -> String {
    output
        .content
        .iter()
        .filter_map(|p| match p {
            ContentItem::Text { text } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}
/// Mirrored by the portable matrix adapter. A stale gate executable cannot
/// qualify under the source digest of a newly compiled benchmark definition.
fn gate_source(task: &str) -> String {
    hash(format!(
        "native-matrix-v1:{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        task,
        include_str!("../computa-native-model-qualification.rs"),
        include_str!("mod.rs"),
        include_str!("audit.rs"),
        include_str!("backend.rs"),
        include_str!("../../../../computa-macos/src/bin/computa-native-qualification-fixture.rs"),
        include_str!("../../../../computa-macos/src/qualification_fixture.rs"),
        include_str!("../../../../computa-browser/src/qualification.rs")
    ))
}
fn regular(path: &Path, max: u64) -> Result<Vec<u8>> {
    if !path.is_absolute() {
        return Err("absolute path required".into());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let m = file.metadata()?;
    if !m.is_file() || m.len() > max {
        return Err("bounded regular file required".into());
    }
    let mut out = vec![];
    file.take(max + 1).read_to_end(&mut out)?;
    if out.len() as u64 > max {
        return Err("file grew beyond bound".into());
    }
    Ok(out)
}
fn save(directory: &Path, name: &str, v: &Value) -> Result<String> {
    let bytes = serde_json::to_vec_pretty(v)?;
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("audit bound".into());
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.join(name))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    Ok(hash(bytes))
}
fn expected(task: &str) -> &'static [&'static str] {
    match task {
        "status" => &["computer_v2_status"],
        "semantic" => &[
            "computer_v2_open",
            "computer_v2_read_page",
            "computer_v2_press",
            "computer_v2_read_page",
        ],
        "combined" => &[
            "computer_v2_open",
            "computer_v2_capture",
            "computer_v2_press",
            "computer_v2_read_page",
        ],
        "visual" => &[
            "computer_v2_open",
            "computer_v2_capture",
            "computer_v2_ground_click",
            "computer_v2_verify",
        ],
        _ => &[],
    }
}
fn allowed(
    config: &Config,
    state: &AuditState,
    name: &str,
    args: &Value,
    chrome: Option<&computa_browser::qualification::ChromeFixture>,
) -> bool {
    if state.calls.len() >= 8 {
        return false;
    }
    if let Some(f) = chrome {
        return if state.calls.is_empty() {
            name == "computer_v2_open" && *args == f.open_arguments
        } else {
            state.calls.len() <= 3
                && name == "computer_v2_read_page"
                && *args == json!({"query":f.heading})
        };
    }
    if expected(&config.task).get(state.calls.len()).copied() != Some(name) {
        return false;
    }
    match name {
        "computer_v2_status" => *args == json!({}),
        "computer_v2_open" => {
            *args
                == json!({"bundle_id":BUNDLE_ID,"activation":if config.task=="visual"{"foreground"}else{"none"}})
        }
        "computer_v2_read_page" => {
            *args
                == if state.calls.len() == 1 {
                    json!({})
                } else {
                    json!({"query":"Qualification display"})
                }
        }
        "computer_v2_capture" => *args == json!({"include_accessibility":true}),
        "computer_v2_press" => {
            args["action_ref"].is_string()
                && args["postcondition"] == json!({"kind":"selection","expected":"true"})
                && args.as_object().is_some_and(|o| o.len() == 2)
        }
        "computer_v2_ground_click" => {
            args["capture_id"].is_string()
                && args["target"] == "Click the button labeled 1."
                && args.as_object().is_some_and(|o| o.len() == 2)
        }
        "computer_v2_verify" => {
            args["operation_id"].is_string()
                && args["snapshot_id"].is_string()
                && args["property"] == "value"
                && args["expected"] == "1"
                && args["element_index"].is_u64()
                && args.as_object().is_some_and(|o| o.len() == 5)
        }
        _ => false,
    }
}
fn prompt(
    config: &Config,
    marker: &str,
    chrome: Option<&computa_browser::qualification::ChromeFixture>,
) -> String {
    if let Some(f) = chrome {
        return f.prompt.clone();
    }
    let open = json!({"bundle_id":BUNDLE_ID,"activation":if config.task=="visual"{"foreground"}else{"none"}});
    match config.task.as_str() {
        "status" => format!(
            "Call computer_v2_status exactly once with empty arguments {{}}. After its real result, reply with exactly {marker}. Use that tool and no other tool."
        ),
        "interrupt" => {
            "Write every integer from 1 to 10000, one per line. Do not use tools.".into()
        }
        "semantic" | "combined" => format!(
            "Use exactly four tools in order: computer_v2_open with {open}; {}; computer_v2_press with the observed action_ref for the unique button titled 1 and postcondition {{\"kind\":\"selection\",\"expected\":\"true\"}}; then computer_v2_read_page with {{\"query\":\"Qualification display\"}}. The button is initially selected=false and the display initially 0; pressing it once selects it and changes its display to 1. Verify the fresh display is 1 and the press receipt verified selection=true, then reply with exactly {marker}. Use no other tools, no coordinates, no CLI, and do not repeat input.",
            if config.task == "combined" {
                "computer_v2_capture with {\"include_accessibility\":true}"
            } else {
                "computer_v2_read_page with empty arguments {}"
            }
        ),
        "visual" => format!(
            "Use exactly four tools in order: computer_v2_open with {open}; computer_v2_capture with {{\"include_accessibility\":true}}; computer_v2_ground_click with the exact capture_id and target \"Click the button labeled 1.\"; computer_v2_verify with the returned operation_id and fresh returned snapshot_id, element_index for Qualification display, property \"value\", expected \"1\". Ground_click's post-action image is observation-only and cannot authorize another click. Verify the receipt and independently rendered display changed from 0 to 1; reply with exactly {marker}. Use no other tools, no direct coordinates, no CLI, and never repeat input."
        ),
        _ => String::new(),
    }
}
async fn background(
    config: Config,
    dispatcher: Arc<ChannelToolDispatcher>,
    audit: Arc<Audit>,
    cancel: Arc<AtomicBool>,
    marker: String,
    prompt: String,
) -> std::result::Result<Value, String> {
    let home = PrivateHome::at(config.directory.join("CodexHome")).map_err(|_| "private_home")?;
    let local = match config.model_id {
        ModelId::Local(local) => local,
        _ => return Err("local_model_required".into()),
    };
    let inference = NativeInferenceLifecycle::new(NativeInferenceConfig {
        worker_executable: config.worker.clone(),
        model_roots: HashMap::from([(local, config.model_root.clone())]),
        fallback_model_root: None,
        port: config.port,
        private_process_home: home.process_home.clone(),
        codex_home: home.codex_home.clone(),
        external_base_url: None,
    })
    .map_err(|_| "inference_configuration")?;
    let mut rc = RuntimeConfig::new(config.resources.clone(), home.clone());
    rc.initial_model = config.model_id.clone();
    rc.local_base_url = Some(format!("http://127.0.0.1:{}/v1", config.port));
    rc.policy = if matches!(config.task.as_str(), "visual" | "chrome") {
        InteractionPolicy::Foreground
    } else {
        InteractionPolicy::BackgroundOnly
    };
    rc.qualification_no_cli = true;
    let runtime =
        Runtime::launch_with_observer(rc, dispatcher.clone(), inference, None, audit.clone())
            .await
            .map_err(|_| "runtime_launch")?;
    let mut events = runtime.subscribe();
    let outcome=async {
        runtime.handle_action(NativeAction::CreateTask).await.map_err(|_|"create_native_task")?;
        let task=runtime.snapshot().await.selected_task_id.ok_or("selected_task")?;
        runtime.handle_action(NativeAction::SetTaskModel{task_id:task.clone(),model_id:config.model_id.clone()}).await.map_err(|_|"native_model_selection")?;
        runtime.handle_action(NativeAction::SubmitPrompt{request_id:Identifier::new(format!("request-{}",config.trial_id)).map_err(|_|"request_id")?,task_id:task.clone(),prompt}).await.map_err(|_|"native_prompt_submit")?;
        let started=Instant::now();let mut interrupted=false;let mut followed=false;
        loop {
            while let Ok(event)=events.try_recv(){if let RuntimeEvent::ApprovalRequested(request)=event {let _=runtime.resolve_approval(&request.id,ApprovalDecision::Decline).await;return Err("unexpected_runtime_approval")}}
            if cancel.load(Ordering::Acquire){let _=runtime.handle_action(NativeAction::InterruptTask{task_id:task.clone()}).await;return Err("trial_cancelled")}
            let snapshot=runtime.snapshot().await;let view=snapshot.tasks.iter().find(|t|t.id==task).ok_or("task_disappeared")?;
            if config.task=="interrupt"&&!interrupted&&view.is_busy&&audit.state.lock().map_err(|_|"wire_lock")?.first_delta.is_some(){runtime.handle_action(NativeAction::InterruptTask{task_id:task.clone()}).await.map_err(|_|"native_interrupt")?;interrupted=true;}
            if config.task=="interrupt"&&interrupted&&!followed&&!view.is_busy&&view.status=="Waiting" {
                if !audit.state.lock().map_err(|_|"wire_lock")?.completed.iter().any(|row|row.2=="interrupted"){return Err("uncorrelated_interrupt")}
                runtime.handle_action(NativeAction::SubmitPrompt{request_id:Identifier::new(format!("follow-{}",config.trial_id)).map_err(|_|"request_id")?,task_id:task.clone(),prompt:format!("The previous request was cancelled. Reply with exactly {marker} and do not use tools.")}).await.map_err(|_|"post_interrupt_submit")?;followed=true;
            }else if !view.is_busy {
                if view.status!="Completed"{return Err("native_terminal_not_completed")}
                let assistant=view.entries.iter().rev().find(|e|e.kind==EntryKind::Assistant).map(|e|e.body.trim()).unwrap_or("");
                if assistant!=marker||view.model!=config.model_id||snapshot.tasks.len()!=1{return Err("exact_terminal_marker_or_model")}
                if config.task=="interrupt"&&!followed{return Err("interrupt_not_observed")}
                return Ok(json!({"task_id":task,"model_id":view.model,"status":view.status,"assistant_sha256":hash(assistant),"prompt_receipts":snapshot.prompt_receipts,"interrupt_followup":followed,"entry_kinds":view.entries.iter().map(|e|e.kind).collect::<Vec<_>>() }));
            }
            if started.elapsed()>Duration::from_secs(820){let _=runtime.handle_action(NativeAction::InterruptTask{task_id:task.clone()}).await;return Err("native_trial_deadline")}
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    }.await;
    let cleanup = runtime.shutdown().await;
    if !cleanup.is_empty() {
        return Err("runtime_cleanup_unconfirmed".into());
    }
    if tokio::net::TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, config.port))
        .await
        .is_ok()
    {
        return Err("owned_listener_remained".into());
    }
    outcome.map_err(str::to_owned)
}
fn native_oracle(
    pid: i32,
    effects: &Effects,
    task: &str,
    foreground: Option<i32>,
) -> Result<Value> {
    let mut backend = NativeBackend::new()?;
    let binding = backend.bind_exact_process(pid, BUNDLE_ID)?;
    let fresh = backend.observe(&binding, TreeLimits::default())?;
    let displays = fresh
        .elements
        .iter()
        .filter(|n| n.identifier.as_deref() == Some(DISPLAY_ID))
        .collect::<Vec<_>>();
    let digits = fresh
        .elements
        .iter()
        .filter(|n| n.identifier.as_deref() == Some(DIGIT_ID))
        .collect::<Vec<_>>();
    if displays.len() != 1
        || digits.len() != 1
        || displays[0].value.as_deref() != Some("1")
        || effects.displays.first().map(String::as_str) != Some("0")
        || effects.mutations + effects.inputs != 1
        || digits[0].is_selected != Some(true)
        || (matches!(task, "semantic" | "combined")
            && (!effects.foreground_preserved
                || backend.foreground_process_identifier()? != foreground))
    {
        return Err("independent_exact_native_transition".into());
    }
    Ok(
        json!({"exact_pid":pid,"bundle_id":BUNDLE_ID,"window_id":fresh.window.window_id,"baseline":"0","final":"1","mutations":effects.mutations,"inputs":effects.inputs,"foreground_preserved":effects.foreground_preserved,"observation_sha256":hash(serde_json::to_vec(&fresh)?)}),
    )
}
fn rollout(home: &Path, audit: &Audit) -> Result<(String, String)> {
    let thread = audit
        .state
        .lock()
        .map_err(|_| "wire lock")?
        .thread
        .clone()
        .ok_or("wire_thread_missing")?;
    let sessions = home.join("sessions");
    let mut pending = vec![(sessions, 0)];
    let mut paths = vec![];
    while let Some((p, depth)) = pending.pop() {
        if depth > 4 {
            return Err("rollout traversal bound".into());
        }
        for entry in std::fs::read_dir(p)? {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_symlink() {
                return Err("rollout symlink".into());
            }
            if kind.is_dir() {
                pending.push((entry.path(), depth + 1))
            } else if kind.is_file() && entry.file_name().to_string_lossy().ends_with(".jsonl") {
                paths.push(entry.path())
            }
            if paths.len() + pending.len() > 64 {
                return Err("rollout inventory bound".into());
            }
        }
    }
    let mut matched = vec![];
    for p in paths {
        let bytes = regular(&p, 32 * 1024 * 1024)?;
        let first = bytes.split(|b| *b == b'\n').next().ok_or("rollout empty")?;
        let v = computa_contracts::strict_json::parse(first)?;
        if v["payload"]["id"] == thread {
            matched.push((p, bytes))
        }
    }
    if matched.len() != 1 {
        return Err("exact rollout required".into());
    }
    let (path, bytes) = matched.pop().unwrap();
    let mut calls = HashSet::new();
    for line in bytes.split(|b| *b == b'\n').filter(|l| !l.is_empty()) {
        let v = computa_contracts::strict_json::parse(line)?;
        if v["type"] == "response_item" && v["payload"]["type"] == "function_call" {
            let name = v["payload"]["name"].as_str().ok_or("rollout tool")?;
            if !name.starts_with("computer_v2_") {
                return Err("rollout unexpected tool".into());
            }
            calls.insert(
                v["payload"]["call_id"]
                    .as_str()
                    .ok_or("rollout call id")?
                    .to_owned(),
            );
        }
    }
    let wire = audit.state.lock().map_err(|_| "wire lock")?;
    if calls != wire.calls.iter().map(|r| r.2.clone()).collect() {
        return Err("rollout/wire call mismatch".into());
    }
    let relative = path
        .strip_prefix(home)?
        .to_str()
        .ok_or("rollout UTF8")?
        .to_owned();
    Ok((hash(bytes), relative))
}
pub fn run() -> Result<()> {
    let mut args = std::env::args_os().skip(1);
    let path = PathBuf::from(args.next().ok_or("private config required")?);
    if args.next().is_some() {
        return Err("unexpected option".into());
    }
    let config: Config = serde_json::from_value(computa_contracts::strict_json::parse(&regular(
        &path, 16384,
    )?)?)?;
    if config.trial_id.is_nil()
        || !matches!(
            config.task.as_str(),
            "status" | "semantic" | "combined" | "visual" | "interrupt" | "chrome"
        )
        || config.port < 1024
        || config.port == 1237
    {
        return Err("invalid closed trial configuration".into());
    }
    // SAFETY: getppid reads only this test host's real OS parent.
    if unsafe { libc::getppid() } != config.parent_pid {
        return Err("exact supervisor mismatch".into());
    }
    let m = std::fs::symlink_metadata(&config.directory)?;
    if !config.directory.is_absolute()
        || !m.is_dir()
        || m.file_type().is_symlink()
        || m.permissions().mode() & 0o077 != 0
    {
        return Err("private trial directory required".into());
    }
    let initial = NativeBackend::new()?;
    let permissions = initial.permissions();
    if !matches!(config.task.as_str(), "status" | "interrupt")
        && permissions.accessibility != PermissionGrant::Granted
    {
        return Err("accessibility_not_granted_no_prompt".into());
    }
    if matches!(config.task.as_str(), "combined" | "visual")
        && permissions.screen_recording != PermissionGrant::Granted
    {
        return Err("screen_recording_not_granted_no_prompt".into());
    }
    let foreground = initial.foreground_process_identifier()?;
    let child = if matches!(config.task.as_str(), "semantic" | "combined" | "visual") {
        Some(OwnedQualificationFixture::launch(
            config
                .fixture_executable
                .as_deref()
                .ok_or("disposable_fixture_required")?,
        )?)
    } else {
        None
    };
    let chrome = if config.task == "chrome" {
        Some(computa_browser::qualification::prepare(
            &config.directory,
            config.trial_id,
        )?)
    } else {
        None
    };
    let marker = chrome
        .as_ref()
        .map(|f| f.completion_token.clone())
        .unwrap_or_else(|| {
            format!(
                "COMPUTA_MATRIX_{}_OK_{}",
                config.task.to_ascii_uppercase(),
                config.trial_id.simple()
            )
        });
    let prompt = prompt(&config, &marker, chrome.as_ref());
    let home = PrivateHome::at(config.directory.join("CodexHome"))?;
    let grounder = NativeGroundingService::new(NativeGroundingConfig::bundled(
        config.grounding_resources.clone(),
        config.grounding_model_root.clone(),
        &home,
    ));
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()?;
    let (dispatcher, mut commands) = ChannelToolDispatcher::channel();
    let audit = Arc::new(Audit::create(
        &config.directory.join("wire-metadata.jsonl"),
    )?);
    let cancel = Arc::new(AtomicBool::new(false));
    let watch = cancel.clone();
    let owner = config.parent_pid;
    let done = Arc::new(AtomicBool::new(false));
    let finished = done.clone();
    let watcher = std::thread::spawn(move || {
        while !finished.load(Ordering::Acquire) {
            // SAFETY: read-only exact parent identity check; no foreign process is signalled.
            if unsafe { libc::getppid() } != owner {
                watch.store(true, Ordering::Release);
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    });
    let job = runtime.spawn(background(
        config.clone(),
        dispatcher.clone(),
        audit.clone(),
        cancel.clone(),
        marker.clone(),
        prompt,
    ));
    let mut pool = LocalPool::new();
    let active = Rc::new(Cell::new(false));
    let slots = Rc::new(RefCell::new(HashMap::<Identifier, Slot>::new()));
    let state = Rc::new(RefCell::new(AuditState::default()));
    let effects = Rc::new(RefCell::new(Effects {
        foreground_preserved: true,
        ..Effects::default()
    }));
    let started = Instant::now();
    while !job.is_finished() {
        let _entered = runtime.enter();
        pool.run_until_stalled();
        if started.elapsed() > Duration::from_secs(920) {
            cancel.store(true, Ordering::Release);
            dispatcher.revoke_all();
        }
        if !active.get()
            && let Ok(command) = commands.try_recv()
        {
            match command {
                NativeCommand::Begin {
                    scope,
                    cancellation,
                    reply,
                } => {
                    let result = (|| {
                        let native =
                            NativeBackend::new().map_err(|_| DispatchError::Unavailable)?;
                        let backend = RestrictedBackend {
                            native,
                            pid: child
                                .as_ref()
                                .map(OwnedQualificationFixture::process_identifier),
                            executable: child.as_ref().map(|c| c.executable().to_owned()),
                            effects: effects.clone(),
                            allow_chrome: config.task == "chrome",
                            chrome_pid: None,
                            initial_foreground: foreground,
                        };
                        let mut harness = Harness::new(backend, scope.policy);
                        harness
                            .begin_turn(scope.clone())
                            .map_err(|_| DispatchError::StaleScope)?;
                        let mut browser =
                            RoutingBrowserLane::new(None, config.directory.join("BrowserProfiles"));
                        browser.set_turn_authority(harness.authority());
                        slots.borrow_mut().insert(
                            scope.task_id.clone(),
                            Slot {
                                scope,
                                harness,
                                browser,
                                cancel: cancellation,
                            },
                        );
                        Ok(())
                    })();
                    let _ = reply.send(result);
                }
                NativeCommand::Execute {
                    scope,
                    call_id,
                    name,
                    arguments,
                    cancellation,
                    reply,
                } => {
                    let Some(mut slot) = slots
                        .borrow_mut()
                        .remove(&scope.task_id)
                        .filter(|s| s.scope == scope)
                    else {
                        let _ = reply.send(Err(DispatchError::StaleScope));
                        continue;
                    };
                    if cancellation.is_cancelled()
                        || !allowed(&config, &state.borrow(), &name, &arguments, chrome.as_ref())
                    {
                        state
                            .borrow_mut()
                            .unexpected
                            .push("unexpected_or_cancelled_tool".into());
                        slots.borrow_mut().insert(scope.task_id.clone(), slot);
                        let _=reply.send(Ok(ToolOutput::text("Qualification rejects this unauthorized tool or argument; no input occurred.",false)));
                        continue;
                    }
                    active.set(true);
                    let slots = slots.clone();
                    let active = active.clone();
                    let state = state.clone();
                    let grounder = grounder.clone();
                    let chrome = chrome.clone();
                    let task = config.task.clone();
                    let effects = effects.clone();
                    let pid = child
                        .as_ref()
                        .map(OwnedQualificationFixture::process_identifier);
                    pool.spawner().spawn_local(async move {
                        let action = match name.as_str() {
                            "computer_v2_open" => {
                                if task == "chrome" {
                                    "chrome"
                                } else {
                                    "open"
                                }
                            }
                            "computer_v2_press" => "press",
                            "computer_v2_ground_click" => "click",
                            _ => "none",
                        };
                        let mut gate = Gate {
                            state: state.clone(),
                            allowed: action.into(),
                            call_id: call_id.clone(),
                            scope: scope.clone(),
                        };
                        let mut visual =
                            grounder.for_turn(scope.generation, slot.harness.authority());
                        let output = slot
                            .harness
                            .execute(
                                &scope,
                                &call_id,
                                &name,
                                arguments.clone(),
                                &cancellation,
                                &mut gate,
                                &mut slot.browser,
                                &mut visual,
                            )
                            .await;
                        state.borrow_mut().calls.push(Call {
                            id: call_id,
                            name: name.clone(),
                            args: arguments,
                            output: output.clone(),
                        });
                        if let Some(f) = chrome.as_ref()
                            && name == "computer_v2_read_page"
                            && let Some((controller, attachment)) =
                                slot.browser.owned_qualification_receipt()
                            && let Ok(oracle) = computa_browser::qualification::independent_heading(
                                &*controller,
                                &attachment,
                                f,
                            )
                            .await
                        {
                            state.borrow_mut().oracle = Some(oracle)
                        }
                        if matches!(task.as_str(), "semantic" | "combined" | "visual")
                            && matches!(name.as_str(), "computer_v2_press" | "computer_v2_verify")
                            && let Some(pid) = pid
                            && let Ok(oracle) =
                                native_oracle(pid, &effects.borrow(), &task, foreground)
                        {
                            state.borrow_mut().oracle = Some(oracle)
                        }
                        slots.borrow_mut().insert(scope.task_id.clone(), slot);
                        active.set(false);
                        let _ = reply.send(Ok(output));
                    })?;
                }
                NativeCommand::End { scope, reply } => {
                    if let Some(mut slot) = slots
                        .borrow_mut()
                        .remove(&scope.task_id)
                        .filter(|s| s.scope == scope)
                    {
                        active.set(true);
                        let state = state.clone();
                        let active = active.clone();
                        pool.spawner().spawn_local(async move {
                            let a = slot.harness.outcome_counts();
                            let b = slot.browser.outcome_counts();
                            let issues = slot.harness.end_turn(&mut slot.browser).await;
                            slot.cancel.cancel();
                            state.borrow_mut().cleanup.extend(issues);
                            active.set(false);
                            let _ = reply.send(TurnConclusion {
                                unresolved_operations: a.0 + b.0,
                                failed_operations: a.1 + b.1,
                            });
                        })?;
                    } else {
                        let _ = reply.send(TurnConclusion {
                            unresolved_operations: 1,
                            failed_operations: 0,
                        });
                    }
                }
            }
        }
        fixture::pump();
    }
    let outcome = runtime
        .block_on(job)
        .map_err(|_| "native_background_failed")?;
    let ground_cleanup = runtime.block_on(grounder.shutdown());
    done.store(true, Ordering::Release);
    watcher.join().map_err(|_| "parent_watch_failed")?;
    let fixture_cleanup = child
        .as_ref()
        .map(OwnedQualificationFixture::close)
        .transpose();
    let cleanup_ok = ground_cleanup.is_ok()
        && fixture_cleanup.is_ok()
        && state.borrow().cleanup.is_empty()
        && slots.borrow().is_empty();
    audit.sync()?;
    let wire_sha = hash(regular(
        &config.directory.join("wire-metadata.jsonl"),
        8 * 1024 * 1024,
    )?);
    let rollout_sha = rollout(&home.codex_home, &audit);
    let s = state.borrow();
    let wire = audit.state.lock().map_err(|_| "wire lock")?;
    let calls_ok = if let Some(f) = &chrome {
        let calls = s
            .calls
            .iter()
            .map(|c| computa_browser::qualification::QualificationCall {
                name: c.name.clone(),
                arguments: c.args.clone(),
                output: c.output.clone(),
            })
            .collect::<Vec<_>>();
        computa_browser::qualification::verify_tools(
            f,
            &calls,
            &marker,
            s.approved.iter().filter(|a| a.as_str() == "chrome").count(),
            s.unexpected.len(),
        )
        .is_ok()
    } else {
        s.calls.iter().map(|c| c.name.as_str()).collect::<Vec<_>>() == expected(&config.task)
            && s.calls.iter().all(|c| {
                c.output.success
                    || (config.task == "visual"
                        && c.name == "computer_v2_ground_click"
                        && text(&c.output).contains("ACTION_EVIDENCE"))
            })
    };
    let correlated = s.calls.len() == wire.calls.len()
        && s.calls
            .iter()
            .zip(&wire.calls)
            .all(|(call, seen)| call.id.as_str() == seen.2 && call.name == seen.3)
        && wire
            .rows
            .iter()
            .any(|r| r["thread_start_model"] == config.model_id.as_str());
    let correlated = correlated
        && wire
            .final_agents
            .last()
            .is_some_and(|r| r.2 == hash(&marker))
        && wire
            .calls
            .iter()
            .zip(&s.calls)
            .all(|(call, actual)| tool_lifecycle(&wire, call, actual));
    let oracle = if config.task == "status" {
        let okay = s.calls.len() == 1
            && s.calls[0].args == json!({})
            && effects.borrow().inputs + effects.borrow().mutations == 0
            && serde_json::from_str::<Value>(&text(&s.calls[0].output))
                .ok()
                .is_some_and(|v| {
                    v["bound"] == false
                        && v["interaction_policy"] == "background_only"
                        && v["permissions"]
                            == serde_json::to_value(permissions).unwrap_or(Value::Null)
                });
        Some(
            json!({"real_native_status":okay,"permissions":permissions,"effects":effects.borrow().inputs+effects.borrow().mutations}),
        )
    } else if config.task == "interrupt" {
        Some(interrupt_oracle(&wire, &marker))
    } else {
        s.oracle.clone()
    };
    let oracle_passed = oracle.as_ref().is_some_and(|o| {
        if config.task == "status" {
            o["real_native_status"] == true
        } else if config.task == "interrupt" {
            o["passed"] == true
        } else {
            true
        }
    });
    let oracle_sha = save(
        &config.directory,
        "independent-oracle.json",
        &oracle.unwrap_or(json!({"passed":false,"reason":"independent_native_proof_missing"})),
    )?;
    let passed = outcome.is_ok()
        && calls_ok
        && correlated
        && oracle_passed
        && cleanup_ok
        && rollout_sha.is_ok()
        && s.unexpected.is_empty()
        && !wire.unexpected;
    let projections=s.calls.iter().map(|c|json!({"call_id":c.id,"name":c.name,"arguments_sha256":hash(serde_json::to_vec(&c.args).unwrap_or_default()),"success":c.output.success,"text_sha256":hash(text(&c.output)),"image_sha256":c.output.content.iter().filter_map(|p|match p{ContentItem::Image{image_url}=>Some(hash(image_url)),_=>None}).collect::<Vec<_>>() })).collect::<Vec<_>>();
    save(
        &config.directory,
        "tool-projections.json",
        &json!(projections),
    )?;
    let result = json!({"protocol":"computa-rust-native-model-qualification-v1","trial_id":config.trial_id,"task":config.task,"model_id":config.model_id,"passed":passed,"cleanup_confirmed":cleanup_ok,"wire_sha256":wire_sha,"rollout_sha256":rollout_sha.as_ref().ok().map(|r|&r.0),"rollout_relative_path":rollout_sha.as_ref().ok().map(|r|&r.1),"independent_oracle_sha256":oracle_sha,"oracle_passed":oracle_passed,"native_action_result":outcome.as_ref().ok(),"failure_code":outcome.err(),"calls_valid":calls_ok,"wire_correlated":correlated,"unexpected_tools_or_approvals":s.unexpected,"variant":"exact owned disposable fixture; canonical opaque tools; explicit global outcome verification; no CLI"});
    let mut result = result;
    result["gate_source_sha256"] = json!(gate_source(&config.task));
    save(&config.directory, "native-result.json", &result)?;
    println!("{}", serde_json::to_string(&result)?);
    if passed {
        Ok(())
    } else {
        Err("model_driven_gate_failed_see_private_audit".into())
    }
}
fn interrupt_oracle(w: &audit::State, marker: &str) -> Value {
    let passed = w.calls.is_empty()
        && w.first_delta.as_ref().is_some_and(|(thread, turn, seq)| {
            let interrupted = w
                .completed
                .iter()
                .find(|r| r.0 == *thread && r.1 == *turn && r.2 == "interrupted" && r.3 > *seq);
            let request = w.rows.iter().find(|r| {
                r["method"] == "turn/interrupt"
                    && r["thread_id"] == thread.as_str()
                    && r["turn_id"] == turn.as_str()
                    && r["sequence"].as_u64().is_some_and(|s| s > *seq)
            });
            if let (Some(terminal), Some(request)) = (interrupted, request) {
                let request_seq = request["sequence"].as_u64().unwrap_or(u64::MAX);
                let ack = w.rows.iter().any(|r| {
                    r["direction"] == "inbound"
                        && r["method"] == "reply"
                        && r["rpc_error"] == false
                        && r["rpc_id"] == request["rpc_id"]
                        && r["sequence"].as_u64().is_some_and(|s| s > request_seq)
                });
                ack && terminal.3 > request_seq
                    && w.completed.iter().any(|r| {
                        r.0 == *thread
                            && r.1 != *turn
                            && r.2 == "completed"
                            && r.3 > terminal.3
                            && w.public_hashes
                                .get(&(r.0.clone(), r.1.clone()))
                                .is_some_and(|d| {
                                    hex::encode(sha2::Digest::finalize(d.clone())) == hash(marker)
                                })
                    })
            } else {
                false
            }
        });
    json!({"passed":passed,"streamed_delta_before_native_interrupt":w.first_delta,"terminal_turns":w.completed,"same_thread_distinct_followup":passed})
}
fn tool_lifecycle(
    w: &audit::State,
    seen: &(String, String, String, String, u64),
    actual: &Call,
) -> bool {
    let Some(request) = w
        .rows
        .iter()
        .find(|r| r["method"] == "item/tool/call" && r["call_id"] == seen.2)
    else {
        return false;
    };
    // The observer hashes parsed JSON Values; canonicalize typed content in the
    // same way rather than comparing struct/tag serialization field order.
    let expected_content =
        audit::hash_value(&serde_json::to_value(&actual.output.content).unwrap_or(Value::Null));
    let expected_arguments = audit::hash_value(&actual.args);
    let started = w.rows.iter().any(|r| {
        r["direction"] == "inbound"
            && r["method"] == "item/started"
            && r["item_type"] == "dynamicToolCall"
            && r["item_id"] == seen.2
            && r["tool"] == seen.3
            && r["arguments_sha256"] == expected_arguments
            && r["thread_id"] == seen.0
            && r["turn_id"] == seen.1
            && r["sequence"].as_u64().is_some_and(|s| s < seen.4)
    });
    let reply = w.rows.iter().find(|r| {
        r["direction"] == "outbound"
            && r["method"] == "reply"
            && r["rpc_id"] == request["rpc_id"]
            && r["reply_success"] == actual.output.success
            && r["reply_content_sha256"] == expected_content
            && r["sequence"].as_u64().is_some_and(|s| s > seen.4)
    });
    let completed = w.rows.iter().find(|r| {
        r["direction"] == "inbound"
            && r["method"] == "item/completed"
            && r["item_type"] == "dynamicToolCall"
            && r["item_id"] == seen.2
            && r["tool"] == seen.3
            && r["arguments_sha256"] == expected_arguments
            && r["content_sha256"] == expected_content
            && r["thread_id"] == seen.0
            && r["turn_id"] == seen.1
            && r["item_success"] == actual.output.success
            && r["sequence"].as_u64().is_some_and(|s| s > seen.4)
    });
    started
        && reply.is_some()
        && completed.is_some_and(|r| {
            w.completed.iter().any(|turn| {
                turn.0 == seen.0
                    && turn.1 == seen.1
                    && turn.2 == "completed"
                    && turn.3 > r["sequence"].as_u64().unwrap_or(u64::MAX)
            })
        })
        && request["arguments_sha256"] == expected_arguments
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn partial_tool_delivery_never_qualifies_a_completed_lifecycle() {
        use computa_runtime::rpc::{WireDirection, WireObserver};
        let dir = tempfile::tempdir().unwrap();
        let audit = Audit::create(&dir.path().join("audit.jsonl")).unwrap();
        let actual = Call {
            id: Identifier::new("call-1").unwrap(),
            name: "computer_v2_status".into(),
            args: json!({}),
            output: ToolOutput::text("status", true),
        };
        let seen = (
            "thread-1".into(),
            "turn-1".into(),
            "call-1".into(),
            actual.name.clone(),
            2,
        );
        audit.observe(WireDirection::Inbound,1,&json!({"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"dynamicToolCall","id":"call-1","tool":actual.name,"arguments":actual.args,"status":"inProgress"}}})).unwrap();
        audit.observe(WireDirection::Inbound,2,&json!({"id":4,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":actual.name,"arguments":actual.args}})).unwrap();
        audit
            .observe(
                WireDirection::Outbound,
                3,
                &json!({"id":4,"result":actual.output}),
            )
            .unwrap();
        assert!(!tool_lifecycle(
            &audit.state.lock().unwrap(),
            &seen,
            &actual
        ));
        audit.observe(WireDirection::Inbound,4,&json!({"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"dynamicToolCall","id":"call-1","tool":actual.name,"arguments":actual.args,"status":"completed","success":true,"contentItems":actual.output.content}}})).unwrap();
        audit.observe(WireDirection::Inbound,5,&json!({"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}})).unwrap();
        let mut w = audit.state.lock().unwrap();
        assert!(tool_lifecycle(&w, &seen, &actual));
        w.rows[3]["content_sha256"] = json!(hash("different completed content"));
        assert!(!tool_lifecycle(&w, &seen, &actual));
        w.rows[3]["content_sha256"] = w.rows[2]["reply_content_sha256"].clone();
        w.rows[2]["reply_content_sha256"] = json!(hash("different response"));
        assert!(!tool_lifecycle(&w, &seen, &actual));
    }
    #[test]
    fn interruption_requires_real_delta_ack_terminal_and_distinct_followup() {
        let marker = "QUALIFIED";
        let mut w = audit::State {
            first_delta: Some(("thread-1".into(), "turn-1".into(), 2)),
            rows: vec![
                json!({"direction":"outbound","method":"turn/interrupt","thread_id":"thread-1","turn_id":"turn-1","rpc_id":9,"sequence":3}),
            ],
            completed: vec![
                ("thread-1".into(), "turn-1".into(), "interrupted".into(), 5),
                ("thread-1".into(), "turn-2".into(), "completed".into(), 8),
            ],
            ..Default::default()
        };
        let mut digest = sha2::Sha256::default();
        sha2::Digest::update(&mut digest, marker);
        w.public_hashes
            .insert(("thread-1".into(), "turn-2".into()), digest);
        assert_eq!(interrupt_oracle(&w, marker)["passed"], false);
        w.rows
            .push(json!({"direction":"inbound","method":"reply","rpc_id":9,"sequence":4,"rpc_error":true}));
        assert_eq!(interrupt_oracle(&w, marker)["passed"], false);
        w.rows.last_mut().unwrap()["rpc_error"] = json!(false);
        assert_eq!(interrupt_oracle(&w, marker)["passed"], true);
        w.completed[1].1 = "turn-1".into();
        assert_eq!(interrupt_oracle(&w, marker)["passed"], false);
    }
}
