//! Native shell: one privileged resource view, native approval controls, and
//! independent human browser views. AX handles remain on this event-loop thread.
use crate::{
    assets::{Assets, UI_CSP, UI_DOCUMENT, accepts_ipc},
    chrome::{ChromeCoordinator, ChromeEvent},
    executor::Executor,
    grounder::{NativeGroundingConfig, NativeGroundingService},
    human::{HumanBrowser, HumanEvent},
    menus::{MenuEvent, NativeMenus},
};
use computa_browser::{identity, leases::BrowserController};
use computa_contracts::{Identifier, models::*, ui::*};
use computa_harness::NativeApproval;
use computa_macos::{
    MacosBackend, NativeBackend, PermissionGrant,
    browser_controls::{
        NATIVE_BROWSER_TOOLBAR_HEIGHT, NativeBrowserEvent, TrustedNativeBrowserControls,
    },
    controls::{NativeAccessMode, NativeControlEvent, TrustedNativeControls},
};
use computa_runtime::{
    ApprovalDecision, ApprovalRequest, ChannelToolDispatcher, NativeCommand, NativeInferenceConfig,
    NativeInferenceLifecycle, Runtime, RuntimeConfig, RuntimeEvent,
};
use computa_state::{
    PrivateHome,
    preferences::{Preferences, PreferencesStore},
};
use objc2_app_kit::{NSView, NSWindow};
use objc2_foundation::{NSPoint, NSRect, NSSize};
use std::{borrow::Cow, cell::Cell, collections::VecDeque, io, path::PathBuf, rc::Rc, sync::Arc};
use tao::{
    dpi::{LogicalPosition, LogicalSize},
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy},
    platform::macos::WindowExtMacOS,
    window::{Window, WindowBuilder},
};
use tokio::sync::oneshot;
use uuid::Uuid;
use wry::{Rect, WebView, WebViewBuilder, http::Response};

pub enum DesktopEvent {
    Ipc {
        origin: String,
        body: String,
    },
    Native(NativeControlEvent),
    Menu(MenuEvent),
    Browser(NativeBrowserEvent),
    Human(HumanEvent),
    OpenHumanUrl(String),
    RuntimeReady(Result<Arc<Runtime>, String>),
    Runtime(RuntimeEvent),
    RuntimeResync {
        snapshot: AppSnapshot,
        approvals: Vec<ApprovalRequest>,
    },
    Command(NativeCommand),
    HarnessApproval {
        request: NativeApproval,
        reply: oneshot::Sender<bool>,
    },
    ApprovalExpired(String),
    ChromeReady(Result<Arc<ChromeCoordinator>, String>),
    Chrome(ChromeEvent),
    ChromeResync(crate::chrome::ChromeSnapshot),
    ChromeAttached {
        controller: Arc<BrowserController>,
        result: Result<Uuid, String>,
    },
    ChromeDetached {
        generation: Uuid,
    },
    ChromeTransition(Result<(Uuid, Arc<BrowserController>), String>),
    Status(String),
    ShutdownDone(Vec<String>),
    Wake,
}
#[derive(Debug)]
pub struct Options {
    pub resources: PathBuf,
    pub private_home: Option<PathBuf>,
    pub fixture: bool,
    pub inference_port: Option<u16>,
}
impl Options {
    pub fn parse(args: impl IntoIterator<Item = String>) -> io::Result<Self> {
        let mut resources = None;
        let mut private_home = None;
        let mut fixture = false;
        let mut inference_port = None;
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--resources" if resources.is_none() => {
                    resources = Some(PathBuf::from(
                        args.next()
                            .ok_or_else(|| invalid("Missing resources directory"))?,
                    ))
                }
                "--private-home" if private_home.is_none() => {
                    private_home = Some(PathBuf::from(
                        args.next().ok_or_else(|| invalid("Missing private home"))?,
                    ))
                }
                "--ui-fixture" if !fixture => fixture = true,
                "--inference-port" if inference_port.is_none() => {
                    let port = args
                        .next()
                        .ok_or_else(|| invalid("Missing inference port"))?
                        .parse::<u16>()
                        .map_err(|_| invalid("Invalid inference port"))?;
                    if port < 1024 {
                        return Err(invalid("Invalid inference port"));
                    }
                    inference_port = Some(port);
                }
                _ => return Err(invalid("Unknown or duplicate desktop option")),
            }
        }
        if fixture && private_home.is_none() {
            return Err(invalid(
                "UI qualification requires an explicit private home",
            ));
        }
        if inference_port.is_some() && private_home.is_none() {
            return Err(invalid(
                "A qualification inference port requires a private home",
            ));
        }
        let resources = match resources {
            Some(p) => p,
            None => {
                let executable = std::env::current_exe()?;
                let macos = executable
                    .parent()
                    .ok_or_else(|| invalid("Missing bundle"))?;
                if macos.file_name().is_none_or(|s| s != "MacOS") {
                    return Err(invalid("Launch the bundled app or supply --resources"));
                }
                macos
                    .parent()
                    .ok_or_else(|| invalid("Missing bundle Contents"))?
                    .join("Resources")
            }
        };
        Ok(Self {
            resources,
            private_home,
            fixture,
            inference_port,
        })
    }
}
enum Prompt {
    Harness {
        request: NativeApproval,
        reply: oneshot::Sender<bool>,
    },
    Runtime(ApprovalRequest),
    Pair {
        id: Uuid,
        installation: String,
        extension: String,
    },
    Temporary {
        generation: Uuid,
    },
}
enum BrowserChange {
    Pair(Uuid),
    Temporary(Uuid),
}
impl Prompt {
    fn id(&self) -> String {
        match self {
            Self::Harness { request, .. } => request.id.clone(),
            Self::Runtime(r) => r.id.as_str().into(),
            Self::Pair { id, .. } => id.to_string(),
            Self::Temporary { generation } => format!("temporary-{generation}"),
        }
    }
}
struct Host {
    window: Window,
    ui: WebView,
    controls: TrustedNativeControls,
    menus: NativeMenus,
    browser_controls: TrustedNativeBrowserControls,
    human: HumanBrowser,
    rt: tokio::runtime::Runtime,
    runtime: Option<Arc<Runtime>>,
    dispatcher: Arc<ChannelToolDispatcher>,
    executor: Executor,
    grounder: Arc<NativeGroundingService>,
    mode: Rc<Cell<AccessMode>>,
    snapshot: AppSnapshot,
    last_runtime_revision: Option<u64>,
    revision: u64,
    ready: bool,
    prompts: VecDeque<Prompt>,
    pending: Option<Prompt>,
    proxy: EventLoopProxy<DesktopEvent>,
    chrome: Option<Arc<ChromeCoordinator>>,
    proposal: Option<(Uuid, String, String)>,
    candidate: Option<Arc<BrowserController>>,
    browser_generation: Option<Uuid>,
    chrome_generation: Option<Uuid>,
    attaching: bool,
    closing: bool,
    runtime_starting: bool,
    chrome_starting: bool,
    shutdown_started: bool,
    shutdown_done: bool,
    status: Option<String>,
    fixture: bool,
}
pub fn run() -> io::Result<()> {
    let options = Options::parse(std::env::args().skip(1))?;
    run_with_options(options)
}
pub fn run_with_options(options: Options) -> io::Result<()> {
    let private = options.private_home.is_some();
    let user_home = identity::user_home().map_err(invalid)?;
    let home = match &options.private_home {
        Some(p) => PrivateHome::at(p.clone())?,
        None => PrivateHome::existing_or_create(&user_home)?,
    };
    let store = Arc::new(PreferencesStore::open(&home.codex_home).map_err(invalid)?);
    let preferences = match store.load().map_err(invalid)? {
        Some(p) => p,
        None => {
            let p = if private {
                Preferences::default()
            } else {
                Preferences::import_legacy(&crate::defaults::legacy_defaults()?)
            };
            store.initialize(&p).map_err(invalid)?
        }
    };
    let assets = Assets::open(options.resources.join("WebUI"))?;
    let event_loop = EventLoopBuilder::<DesktopEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    let window = WindowBuilder::new()
        .with_title(if options.fixture {
            "Computa Rust UI Qualification"
        } else {
            "Computa"
        })
        .with_inner_size(LogicalSize::new(1200., 800.))
        .with_min_inner_size(LogicalSize::new(800., 560.))
        .build(&event_loop)
        .map_err(invalid)?;
    let ui_proxy = proxy.clone();
    let link_proxy = proxy.clone();
    let ui = WebViewBuilder::new()
        .with_bounds(bounds(0., 0., 1200., 766.))
        .with_devtools(false)
        .with_incognito(true)
        .with_custom_protocol("computaui".into(), move |_, request| {
            let (mime, data, status) = match assets.read(&request.uri().to_string()) {
                Ok((mime, data)) => (mime, data, 200),
                Err(_) => ("text/plain", b"Resource unavailable".to_vec(), 404),
            };
            Response::builder()
                .status(status)
                .header("Content-Type", mime)
                .header("Content-Security-Policy", UI_CSP)
                .header("X-Content-Type-Options", "nosniff")
                .header("Cache-Control", "no-store")
                .body(Cow::Owned(data))
                .expect("fixed resource response")
        })
        .with_navigation_handler(|url| url == UI_DOCUMENT)
        .with_new_window_req_handler(move |url, _| {
            if computa_macos::browser_controls::ValidatedBrowserAddress::normalize(&url).is_ok() {
                let _ = link_proxy.send_event(DesktopEvent::OpenHumanUrl(url));
            }
            wry::NewWindowResponse::Deny
        })
        .with_ipc_handler(move |request| {
            let _ = ui_proxy.send_event(DesktopEvent::Ipc {
                origin: request.uri().to_string(),
                body: request.into_body(),
            });
        })
        .with_url(UI_DOCUMENT)
        .build_as_child(&window)
        .map_err(invalid)?;
    // SAFETY: the live privileged view belongs to this AppKit thread. This
    // prevents script popups; user-opened HTTP links go to unprivileged views.
    unsafe {
        use wry::WebViewExtMacOS;
        ui.webview()
            .configuration()
            .preferences()
            .setJavaScriptCanOpenWindowsAutomatically(false);
    }
    // SAFETY: Tao owns these live AppKit objects for this entire host lifetime;
    // references remain on the main thread and controls retain their parent.
    let (ns_window, ns_view) = unsafe {
        (
            &*(window.ns_window() as *const NSWindow),
            &*(window.ns_view() as *const NSView),
        )
    };
    let native_proxy = proxy.clone();
    let controls = TrustedNativeControls::new(
        ns_window,
        Rc::new(move |event| {
            let _ = native_proxy.send_event(DesktopEvent::Native(event));
        }),
    )
    .map_err(invalid)?;
    let menu_proxy = proxy.clone();
    let menus = NativeMenus::new(Rc::new(move |event| {
        let _ = menu_proxy.send_event(DesktopEvent::Menu(event));
    }))
    .map_err(invalid)?;
    let browser_proxy = proxy.clone();
    let browser_controls = TrustedNativeBrowserControls::new(
        ns_view,
        NSRect::new(
            NSPoint::new(800., 34.),
            NSSize::new(400., NATIVE_BROWSER_TOOLBAR_HEIGHT),
        ),
        Rc::new(move |event| {
            let _ = browser_proxy.send_event(DesktopEvent::Browser(event));
        }),
    )
    .map_err(invalid)?;
    browser_controls.set_hidden(true);
    let human_proxy = proxy.clone();
    let human = HumanBrowser::new(
        crate::defaults::browser_profile(private)?,
        private,
        bounds(800., NATIVE_BROWSER_TOOLBAR_HEIGHT, 400., 678.),
        Rc::new(move |event| {
            let _ = human_proxy.send_event(DesktopEvent::Human(event));
        }),
    );
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let (dispatcher, mut commands) = ChannelToolDispatcher::channel();
    let command_proxy = proxy.clone();
    rt.spawn(async move {
        while let Some(command) = commands.recv().await {
            if command_proxy
                .send_event(DesktopEvent::Command(command))
                .is_err()
            {
                break;
            }
        }
    });
    let mode = Rc::new(Cell::new(preferences.access_mode));
    let grounder = NativeGroundingService::new(NativeGroundingConfig::bundled(
        options.resources.clone(),
        user_home.join("Library/Application Support/LocalCodex/VisualGrounding"),
        &home,
    ));
    let executor = Executor::new(
        proxy.clone(),
        mode.clone(),
        home.evidence.clone(),
        home.codex_home.join("OwnedBrowserProfiles"),
        grounder.clone(),
    );
    let snapshot = initial_snapshot(&preferences, options.fixture);
    let mut host = Host {
        window,
        ui,
        controls,
        menus,
        browser_controls,
        human,
        rt,
        runtime: None,
        dispatcher,
        executor,
        grounder,
        mode,
        snapshot,
        last_runtime_revision: None,
        revision: 0,
        ready: false,
        prompts: VecDeque::new(),
        pending: None,
        proxy: proxy.clone(),
        chrome: None,
        proposal: None,
        candidate: None,
        browser_generation: None,
        chrome_generation: None,
        attaching: false,
        closing: false,
        runtime_starting: !options.fixture,
        chrome_starting: !options.fixture && !private,
        shutdown_started: false,
        shutdown_done: false,
        status: None,
        fixture: options.fixture,
    };
    if !options.fixture {
        let mut config = RuntimeConfig::new(options.resources.clone(), home.clone());
        config.initial_model = preferences.default_model.clone();
        config.preferences = preferences;
        if let Some(port) = options.inference_port {
            config.local_base_url = Some(format!("http://127.0.0.1:{port}/v1"));
        }
        let roots = [LocalModel::Qwen35_4b, LocalModel::Qwen35_9b]
            .into_iter()
            .filter_map(|model| {
                let canonical = user_home
                    .join("Library/Application Support/LocalCodex/MLX/models")
                    .join(model.model_id());
                let fallback = user_home.join(".lmstudio/models").join(model.model_id());
                if canonical.join("config.json").is_file() {
                    Some((model, canonical))
                } else if fallback.join("config.json").is_file() {
                    Some((model, fallback))
                } else {
                    None
                }
            })
            .collect();
        let mut inference_config = NativeInferenceConfig::bundled(options.resources, roots, &home);
        if let Some(port) = options.inference_port {
            inference_config.port = port;
        }
        let inference = NativeInferenceLifecycle::new(inference_config).map_err(invalid)?;
        let dispatcher = host.dispatcher.clone();
        let runtime_proxy = proxy.clone();
        host.rt.spawn(async move {
            match Runtime::launch(config, dispatcher, inference, None).await {
                Ok(runtime) => {
                    let mut events = runtime.subscribe();
                    let history = runtime.load_threads().await;
                    let _ =
                        runtime_proxy.send_event(DesktopEvent::RuntimeReady(Ok(runtime.clone())));
                    let _ = runtime_proxy.send_event(DesktopEvent::Runtime(
                        RuntimeEvent::Snapshot(runtime.snapshot().await),
                    ));
                    if history.is_err() {
                        let _ = runtime_proxy.send_event(DesktopEvent::Status(
                            "Saved chats could not be loaded. They remain in local storage.".into(),
                        ));
                    }
                    loop {
                        let event = match events.recv().await {
                            Ok(event) => DesktopEvent::Runtime(event),
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                                DesktopEvent::RuntimeResync {
                                    snapshot: runtime.snapshot().await,
                                    approvals: runtime.pending_approvals().await,
                                }
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                        };
                        if runtime_proxy.send_event(event).is_err() {
                            break;
                        }
                    }
                }
                Err(error) => {
                    let _ = runtime_proxy
                        .send_event(DesktopEvent::RuntimeReady(Err(error.to_string())));
                }
            }
        });
        if !private {
            let chrome_proxy = proxy.clone();
            host.rt.spawn(async move {
                match ChromeCoordinator::start(store) {
                    Ok(chrome) => {
                        let mut events = chrome.events();
                        let _ =
                            chrome_proxy.send_event(DesktopEvent::ChromeReady(Ok(chrome.clone())));
                        let snapshot = chrome.snapshot().await;
                        let _ =
                            chrome_proxy.send_event(DesktopEvent::Chrome(ChromeEvent::Status {
                                text: snapshot.status,
                            }));
                        if let Some(proposal) = snapshot.proposal {
                            let _ = chrome_proxy.send_event(DesktopEvent::Chrome(
                                ChromeEvent::Proposal {
                                    id: proposal.id,
                                    installation: proposal.installation,
                                    extension: proposal.extension,
                                },
                            ));
                        }
                        if let Some(controller) = snapshot.connected {
                            let generation = controller.generation;
                            let _ = chrome_proxy.send_event(DesktopEvent::Chrome(
                                ChromeEvent::Connected {
                                    controller,
                                    generation,
                                },
                            ));
                        }
                        loop {
                            let event = match events.recv().await {
                                Ok(event) => DesktopEvent::Chrome(event),
                                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                                    DesktopEvent::ChromeResync(chrome.snapshot().await)
                                }
                                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                            };
                            if chrome_proxy.send_event(event).is_err() {
                                break;
                            }
                        }
                    }
                    Err(error) => {
                        let _ = chrome_proxy
                            .send_event(DesktopEvent::ChromeReady(Err(error.to_string())));
                    }
                }
            });
        }
    }
    host.publish();
    event_loop.run(move |event, _, control| {
        *control = ControlFlow::Wait;
        match event {
            Event::UserEvent(event) => host.receive(event),
            Event::WindowEvent {
                event: WindowEvent::Resized(_),
                ..
            } => host.layout(),
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => host.shutdown(),
            Event::MainEventsCleared => {
                host.executor.pump(host.rt.handle());
                if host.shutdown_done && !host.executor.pending() {
                    host.human.shutdown();
                    *control = ControlFlow::Exit;
                }
            }
            _ => {}
        }
    });
}
impl Host {
    fn receive(&mut self, event: DesktopEvent) {
        match event {
            DesktopEvent::Menu(MenuEvent::Quit) => self.shutdown(),
            DesktopEvent::Menu(MenuEvent::Action(action)) => {
                if !self.controls.interaction_blocked() && !self.closing {
                    self.action(action);
                }
            }
            DesktopEvent::Ipc { origin, body } => {
                if !accepts_ipc(
                    &origin,
                    &body,
                    self.controls.interaction_blocked() || self.closing,
                ) {
                    return;
                }
                let Ok(value) = computa_contracts::strict_json::parse(body.as_bytes()) else {
                    return;
                };
                let Ok(action) = serde_json::from_value::<NativeAction>(value) else {
                    return;
                };
                self.action(action);
            }
            DesktopEvent::RuntimeReady(result) => {
                self.runtime_starting = false;
                match result {
                    Ok(runtime) => {
                        self.runtime = Some(runtime);
                        self.permissions(None);
                        self.try_attach();
                    }
                    Err(error) => {
                        self.status = Some(error);
                        self.snapshot.connection = ConnectionSnapshot {
                            state: ConnectionState::Failed,
                            label: "Runtime unavailable".into(),
                            tone: Tone::Red,
                        };
                        self.publish();
                    }
                }
                if self.closing {
                    self.start_shutdown();
                }
            }
            DesktopEvent::Runtime(event) => match event {
                RuntimeEvent::Snapshot(snapshot) => {
                    if self
                        .last_runtime_revision
                        .is_some_and(|last| snapshot.revision <= last)
                    {
                        return;
                    }
                    self.last_runtime_revision = Some(snapshot.revision);
                    self.snapshot = snapshot;
                    self.mode.set(self.snapshot.access_mode);
                    self.executor.set_models(
                        self.snapshot
                            .tasks
                            .iter()
                            .map(|t| (t.id.clone(), matches!(t.model, ModelId::Browser(_))))
                            .collect(),
                    );
                    self.layout();
                    self.publish();
                    self.try_attach();
                }
                RuntimeEvent::ApprovalRequested(request) => {
                    if self.closing {
                        self.resolve_runtime(request.id, false);
                    } else if self
                        .pending
                        .as_ref()
                        .is_some_and(|p| p.id() == request.id.as_str())
                        || self.prompts.iter().any(|p| p.id() == request.id.as_str())
                    {
                        // The same approval is already visible or queued.
                    } else if self.mode.get() == AccessMode::FullAccess {
                        self.resolve_runtime(request.id, true);
                    } else {
                        self.prompts.push_back(Prompt::Runtime(request));
                        self.next_prompt();
                    }
                }
                RuntimeEvent::ApprovalResolved(id) => self.expire_prompt(id.as_str()),
                RuntimeEvent::Failure { message, .. } => {
                    self.status = Some(message);
                    self.publish();
                }
                RuntimeEvent::Disconnected => {
                    self.snapshot.connection = ConnectionSnapshot {
                        state: ConnectionState::Disconnected,
                        label: "Runtime disconnected".into(),
                        tone: Tone::Red,
                    };
                    self.publish();
                }
            },
            DesktopEvent::RuntimeResync {
                snapshot,
                approvals,
            } => {
                self.receive(DesktopEvent::Runtime(RuntimeEvent::Snapshot(snapshot)));
                let live: std::collections::HashSet<_> =
                    approvals.iter().map(|a| a.id.as_str()).collect();
                self.prompts
                    .retain(|p| !matches!(p,Prompt::Runtime(r) if !live.contains(r.id.as_str())));
                if let Some(Prompt::Runtime(request)) = self.pending.as_ref()
                    && !live.contains(request.id.as_str())
                {
                    let id = request.id.as_str().to_owned();
                    self.expire_prompt(&id);
                }
                for approval in approvals {
                    self.receive(DesktopEvent::Runtime(RuntimeEvent::ApprovalRequested(
                        approval,
                    )));
                }
                self.next_prompt();
            }
            DesktopEvent::Command(command) => {
                self.executor.push(command);
            }
            DesktopEvent::HarnessApproval { request, reply } => {
                if self.closing || reply.is_closed() {
                    let _ = reply.send(false);
                } else {
                    self.prompts.push_back(Prompt::Harness { request, reply });
                    self.next_prompt();
                }
            }
            DesktopEvent::ApprovalExpired(id) => self.expire_prompt(&id),
            DesktopEvent::Native(event) => self.native_event(event),
            DesktopEvent::Browser(event) => {
                let hidden = matches!(event, NativeBrowserEvent::HidePane);
                if let Err(error) = self.human.handle(
                    event,
                    &self.window,
                    self.controls.interaction_blocked() || self.closing,
                ) {
                    self.status = Some(error);
                }
                if hidden {
                    if self.snapshot.is_browser_presented {
                        self.action(NativeAction::ToggleBrowser);
                    }
                    self.snapshot.is_browser_presented = false;
                }
                self.layout();
                self.publish();
            }
            DesktopEvent::Human(event) => {
                if let Err(error) = self.human.receive(
                    event,
                    &self.window,
                    self.controls.interaction_blocked() || self.closing,
                ) {
                    self.status = Some(error);
                }
                self.layout();
            }
            DesktopEvent::OpenHumanUrl(url) => {
                if !self.closing
                    && !self.controls.interaction_blocked()
                    && let Ok(address) =
                        computa_macos::browser_controls::ValidatedBrowserAddress::normalize(&url)
                {
                    match self.human.create(&self.window, Some(address), true) {
                        Ok(_) => self.snapshot.is_browser_presented = true,
                        Err(error) => self.status = Some(error),
                    }
                    self.publish();
                }
            }
            DesktopEvent::ChromeReady(result) => {
                self.chrome_starting = false;
                match result {
                    Ok(chrome) => {
                        self.chrome = Some(chrome);
                        self.status = Some("Chrome bridge ready".into());
                        self.publish();
                    }
                    Err(error) => {
                        self.status = Some(error);
                        self.publish();
                    }
                }
                if self.closing {
                    self.start_shutdown();
                }
            }
            DesktopEvent::Chrome(event) => self.chrome_event(event),
            DesktopEvent::ChromeResync(snapshot) => {
                if snapshot.connected.is_none() {
                    if let Some(generation) = self.chrome_generation {
                        self.chrome_event(ChromeEvent::Disconnected { generation });
                    }
                    self.candidate = None;
                }
                if let Some(controller) = snapshot.connected {
                    let generation = controller.generation;
                    self.chrome_event(ChromeEvent::Connected {
                        controller,
                        generation,
                    });
                }
                self.proposal = snapshot
                    .proposal
                    .map(|p| (p.id, p.installation, p.extension));
                self.status = Some(snapshot.status);
                self.publish();
            }
            DesktopEvent::ChromeAttached { controller, result } => {
                self.attaching = false;
                match result {
                    Ok(generation) => {
                        if !self.closing
                            && self
                                .candidate
                                .as_ref()
                                .is_some_and(|c| c.generation == controller.generation)
                            && controller.link.check().is_ok()
                        {
                            self.browser_generation = Some(generation);
                            self.chrome_generation = Some(controller.generation);
                            self.executor.set_browser(Some(controller));
                            self.status = Some("Chrome connected".into());
                        } else if let Some(runtime) = self.runtime.clone() {
                            self.rt.spawn(async move {
                                let _ = runtime.detach_browser(generation).await;
                            });
                        }
                    }
                    Err(error) => self.status = Some(error),
                }
                self.publish();
            }
            DesktopEvent::ChromeDetached { generation } => {
                if self.chrome_generation == Some(generation) {
                    self.executor.set_browser(None);
                    self.chrome_generation = None;
                    self.browser_generation = None;
                    self.publish();
                }
            }
            DesktopEvent::ChromeTransition(result) => {
                self.attaching = false;
                match result {
                    Ok((generation, controller))
                        if !self.closing && controller.link.check().is_ok() =>
                    {
                        self.browser_generation = Some(generation);
                        self.chrome_generation = Some(controller.generation);
                        self.candidate = Some(controller.clone());
                        self.executor.set_browser(Some(controller));
                        self.proposal = None;
                        self.status = Some("Chrome connected".into());
                    }
                    Ok((generation, _)) => {
                        self.executor.set_browser(None);
                        if let Some(runtime) = self.runtime.clone() {
                            self.rt.spawn(async move {
                                let _ = runtime.detach_browser(generation).await;
                            });
                        }
                    }
                    Err(error) => {
                        self.executor.set_browser(None);
                        self.browser_generation = None;
                        self.chrome_generation = None;
                        self.candidate = None;
                        self.status = Some(error);
                    }
                }
                self.publish();
            }
            DesktopEvent::Status(status) => {
                self.status = Some(status);
                self.controls
                    .set_access_mode(native_mode(self.snapshot.access_mode));
                self.publish();
            }
            DesktopEvent::ShutdownDone(issues) => {
                if !issues.is_empty() {
                    eprintln!("Computa shutdown: {}", issues.join("; "));
                }
                self.shutdown_done = true;
            }
            DesktopEvent::Wake => {}
        }
    }
    fn permissions(&mut self, request: Option<bool>) {
        let Ok(backend) = NativeBackend::new() else {
            return;
        };
        let p = match request {
            Some(true) => backend.request_accessibility(),
            Some(false) => backend.request_screen_recording(),
            None => backend.permissions(),
        };
        let permissions = PermissionSnapshot {
            accessibility: grant(p.accessibility),
            screen_recording: grant(p.screen_recording),
        };
        self.snapshot.permissions = permissions.clone();
        if let Some(runtime) = self.runtime.clone() {
            self.rt.spawn(async move {
                runtime.update_permissions(permissions).await;
            });
        }
        self.publish();
    }
    fn publish(&mut self) {
        self.menus
            .set_actions_enabled(!self.controls.interaction_blocked() && !self.closing);
        self.revision = self.revision.saturating_add(1);
        let mut snapshot = self.snapshot.clone();
        snapshot.revision = self.revision;
        let native_count = usize::from(
            self.pending
                .as_ref()
                .is_some_and(|p| !matches!(p, Prompt::Runtime(_))),
        ) + self
            .prompts
            .iter()
            .filter(|p| !matches!(p, Prompt::Runtime(_)))
            .count();
        snapshot.pending_approval_count =
            snapshot.pending_approval_count.saturating_add(native_count);
        self.controls
            .set_access_mode(native_mode(snapshot.access_mode));
        self.controls
            .update_status(self.status.as_deref().unwrap_or(&snapshot.connection.label));
        if self.ready
            && let Ok(json) = serde_json::to_string(&snapshot)
        {
            let json = json
                .replace('\u{2028}', "\\u2028")
                .replace('\u{2029}', "\\u2029");
            let _ = self
                .ui
                .evaluate_script(&format!("window.__localCodexReceiveState?.({json});"));
        }
        self.layout();
    }
    fn layout(&mut self) {
        let size = self
            .window
            .inner_size()
            .to_logical::<f64>(self.window.scale_factor());
        let height = (size.height - 34.).max(1.);
        let presented = self.snapshot.is_browser_presented;
        let browser_width = if presented {
            (size.width * 0.4).clamp(320., 640.)
        } else {
            0.
        };
        let ui_width = (size.width - browser_width).max(1.);
        let _ = self.ui.set_bounds(bounds(0., 0., ui_width, height));
        self.controls.resize(size.width);
        self.human.set_bounds(bounds(
            ui_width,
            NATIVE_BROWSER_TOOLBAR_HEIGHT,
            browser_width.max(1.),
            (height - NATIVE_BROWSER_TOOLBAR_HEIGHT).max(1.),
        ));
        self.human.set_visible(presented);
        self.browser_controls.resize(NSRect::new(
            NSPoint::new(ui_width, 34. + height - NATIVE_BROWSER_TOOLBAR_HEIGHT),
            NSSize::new(browser_width.max(1.), NATIVE_BROWSER_TOOLBAR_HEIGHT),
        ));
        self.browser_controls.set_hidden(!presented);
        let _ = self.browser_controls.update(
            &self.human.metadata(),
            self.human.selected(),
            self.controls.interaction_blocked() || self.closing,
        );
    }
    fn next_prompt(&mut self) {
        if self.pending.is_some() || self.closing {
            return;
        }
        while let Some(prompt) = self.prompts.pop_front() {
            if matches!(&prompt,Prompt::Harness{reply,..}if reply.is_closed()) {
                continue;
            }
            let id = prompt.id();
            let result = match &prompt {
                Prompt::Harness { request, .. } => self.controls.present_approval(
                    &id,
                    &request.title,
                    &request.summary,
                    &request.details,
                ),
                Prompt::Runtime(request) => self.controls.present_approval(
                    &id,
                    "Approve agent action",
                    &request.method,
                    &request.details.to_string(),
                ),
                Prompt::Pair {
                    installation,
                    extension,
                    ..
                } => self.controls.present_pairing(&id, extension, installation),
                Prompt::Temporary { .. } => self.controls.present_temporary_tab_grant(&id),
            };
            if result.is_ok() {
                self.pending = Some(prompt);
                break;
            }
            if let Prompt::Harness { reply, .. } = prompt {
                let _ = reply.send(false);
            }
        }
        self.publish();
    }
    fn expire_prompt(&mut self, id: &str) {
        self.prompts.retain(|p| p.id() != id);
        if self.pending.as_ref().is_some_and(|p| p.id() == id) {
            self.controls.dismiss_prompt(id);
            self.pending = None;
            self.next_prompt();
        }
        self.publish();
    }
    fn resolve_runtime(&self, id: Identifier, approved: bool) {
        if let Some(runtime) = self.runtime.clone() {
            let proxy = self.proxy.clone();
            self.rt.spawn(async move {
                if let Err(error) = runtime
                    .resolve_approval(
                        &id,
                        if approved {
                            ApprovalDecision::Accept
                        } else {
                            ApprovalDecision::Decline
                        },
                    )
                    .await
                {
                    let _ = proxy.send_event(DesktopEvent::Status(error.to_string()));
                }
            });
        }
    }
    fn native_event(&mut self, event: NativeControlEvent) {
        match event {
            NativeControlEvent::AccessModeChanged(mode) => {
                if self.controls.interaction_blocked() || self.closing {
                    return;
                }
                let mode = match mode {
                    NativeAccessMode::AskEveryTime => AccessMode::AskEveryTime,
                    NativeAccessMode::FullAccess => AccessMode::FullAccess,
                };
                if let Some(runtime) = self.runtime.clone() {
                    let proxy = self.proxy.clone();
                    self.rt.spawn(async move {
                        if let Err(error) = runtime.set_access_mode(mode).await {
                            let _ = proxy.send_event(DesktopEvent::Status(error.to_string()));
                        }
                    });
                } else if self.fixture {
                    self.snapshot.access_mode = mode;
                    self.mode.set(mode);
                    self.publish();
                }
            }
            NativeControlEvent::ApprovalResolved { id, approved } => {
                if self.pending.as_ref().is_none_or(|p| p.id() != id) {
                    return;
                }
                match self.pending.take() {
                    Some(Prompt::Harness { reply, .. }) => {
                        let _ = reply.send(approved);
                    }
                    Some(Prompt::Runtime(request)) => self.resolve_runtime(request.id, approved),
                    _ => {}
                }
                self.next_prompt();
            }
            NativeControlEvent::RequestPairingUi => {
                if let Some((id, installation, extension)) = self.proposal.clone() {
                    self.prompts.push_back(Prompt::Pair {
                        id,
                        installation,
                        extension,
                    });
                    self.next_prompt();
                } else {
                    self.status =
                        Some("Open the Computa extension in Chrome and choose Pair.".into());
                    self.publish();
                }
            }
            NativeControlEvent::PairingResolved { id, remember } => {
                if self.pending.as_ref().is_none_or(|p| p.id() != id) {
                    return;
                }
                if let Some(Prompt::Pair { id, .. }) = self.pending.take()
                    && remember
                {
                    self.change_browser(BrowserChange::Pair(id));
                }
                self.next_prompt();
            }
            NativeControlEvent::RequestTemporaryTabGrant => {
                if let Some(generation) = self.chrome_generation {
                    self.prompts.push_back(Prompt::Temporary { generation });
                    self.next_prompt();
                } else {
                    self.status = Some("Connect Chrome before allowing temporary tabs.".into());
                    self.publish();
                }
            }
            NativeControlEvent::TemporaryTabGrantResolved { id, approved } => {
                if self.pending.as_ref().is_none_or(|p| p.id() != id) {
                    return;
                }
                if let Some(Prompt::Temporary { generation }) = self.pending.take()
                    && approved
                    && self.chrome_generation == Some(generation)
                {
                    self.change_browser(BrowserChange::Temporary(generation));
                }
                self.next_prompt();
            }
            NativeControlEvent::DisconnectChrome => {
                if let (Some(chrome), Some(generation)) =
                    (self.chrome.clone(), self.chrome_generation)
                {
                    self.executor.set_browser(None);
                    self.candidate = None;
                    let runtime = self.runtime.clone();
                    let runtime_generation = self.browser_generation;
                    let proxy = self.proxy.clone();
                    self.rt.spawn(async move {
                        if let (Some(runtime), Some(runtime_generation)) =
                            (runtime, runtime_generation)
                            && let Err(error) = runtime.detach_browser(runtime_generation).await
                        {
                            let _ = proxy.send_event(DesktopEvent::Status(error.to_string()));
                        }
                        if let Err(error) = chrome.disconnect(generation).await {
                            let _ = proxy.send_event(DesktopEvent::Status(error.to_string()));
                        }
                    });
                }
            }
            NativeControlEvent::RequestAccessibility => self.permissions(Some(true)),
            NativeControlEvent::RequestScreenRecording => self.permissions(Some(false)),
        }
    }
    fn chrome_event(&mut self, event: ChromeEvent) {
        match event {
            ChromeEvent::Proposal {
                id,
                installation,
                extension,
            } => {
                self.proposal = Some((id, installation, extension));
                self.status =
                    Some("Chrome pairing is available in the native connection menu.".into());
            }
            ChromeEvent::Connected { controller, .. } => {
                self.candidate = Some(controller);
                self.try_attach();
            }
            ChromeEvent::Disconnected { generation } => {
                if self
                    .candidate
                    .as_ref()
                    .is_some_and(|c| c.generation == generation)
                {
                    self.candidate = None;
                }
                if self.chrome_generation == Some(generation) {
                    self.executor.set_browser(None);
                    if let (Some(runtime), Some(runtime_generation)) =
                        (self.runtime.clone(), self.browser_generation)
                    {
                        let proxy = self.proxy.clone();
                        self.rt.spawn(async move {
                            let _ = runtime.detach_browser(runtime_generation).await;
                            let _ = proxy.send_event(DesktopEvent::ChromeDetached { generation });
                        });
                    }
                }
            }
            ChromeEvent::Status { text } => self.status = Some(text),
            ChromeEvent::PreferencesChanged(_) => {}
        }
        self.publish();
    }
    fn try_attach(&mut self) {
        if self.attaching
            || self.closing
            || self.snapshot.tasks.iter().any(|t| t.is_busy)
            || self.snapshot.pending_approval_count > 0
        {
            return;
        }
        let (Some(runtime), Some(chrome), Some(controller)) = (
            self.runtime.clone(),
            self.chrome.clone(),
            self.candidate.clone(),
        ) else {
            return;
        };
        if self.chrome_generation == Some(controller.generation) {
            return;
        }
        self.attaching = true;
        let proxy = self.proxy.clone();
        self.rt.spawn(async move {
            let expected = runtime.browser_generation().await;
            let transport = chrome.transport(&controller);
            let result = runtime
                .attach_browser(expected, Arc::new(transport))
                .await
                .map_err(|e| e.to_string());
            let _ = proxy.send_event(DesktopEvent::ChromeAttached { controller, result });
        });
    }
    fn change_browser(&mut self, change: BrowserChange) {
        if self.attaching || self.closing {
            return;
        }
        let (Some(runtime), Some(chrome)) = (self.runtime.clone(), self.chrome.clone()) else {
            return;
        };
        self.attaching = true;
        let proxy = self.proxy.clone();
        self.rt.spawn(async move {
            let expected = runtime.browser_generation().await;
            let result = runtime
                .transition_browser(expected, move || async move {
                    let result = match change {
                        BrowserChange::Pair(id) => chrome.pair(id).await,
                        BrowserChange::Temporary(generation) => {
                            chrome.grant_temporary(generation).await
                        }
                    };
                    result.map_err(|error| {
                        computa_runtime::RuntimeError::Inference(error.to_string())
                    })?;
                    let controller = chrome
                        .snapshot()
                        .await
                        .connected
                        .ok_or(computa_runtime::RuntimeError::BrowserUnavailable)?;
                    let transport: Arc<dyn computa_contracts::responses::BrowserTransport> =
                        Arc::new(chrome.transport(&controller));
                    Ok((transport, controller))
                })
                .await
                .map_err(|error| error.to_string());
            let _ = proxy.send_event(DesktopEvent::ChromeTransition(result));
        });
        self.publish();
    }
    fn shutdown(&mut self) {
        if self.closing {
            return;
        }
        self.closing = true;
        self.dispatcher.revoke_all();
        self.executor.revoke_all();
        if let Some(prompt) = self.pending.take() {
            self.controls.dismiss_prompt(&prompt.id());
            if let Prompt::Harness { reply, .. } = prompt {
                let _ = reply.send(false);
            }
        }
        self.prompts.clear();
        self.start_shutdown();
        self.publish();
    }
    fn start_shutdown(&mut self) {
        if !self.closing || self.runtime_starting || self.chrome_starting || self.shutdown_started {
            return;
        }
        self.shutdown_started = true;
        let runtime = self.runtime.clone();
        let chrome = self.chrome.clone();
        let grounder = self.grounder.clone();
        let proxy = self.proxy.clone();
        self.rt.spawn(async move {
            let mut issues = if let Some(runtime) = runtime {
                runtime.shutdown().await
            } else {
                vec![]
            };
            if let Some(chrome) = chrome {
                for receipt in chrome.shutdown().await {
                    if receipt["status"] != "closed" && receipt["status"] != "detached" {
                        issues.push("Chrome cleanup was not confirmed.".into());
                    }
                }
            }
            if let Err(error) = grounder.shutdown().await {
                issues.push(error);
            }
            let _ = proxy.send_event(DesktopEvent::ShutdownDone(issues));
        });
    }
    fn action(&mut self, action: NativeAction) {
        match action {
            NativeAction::Ready => {
                self.ready = true;
                self.publish();
            }
            NativeAction::RefreshPermissions => self.permissions(None),
            NativeAction::RequestAccessibilityPermission => self.permissions(Some(true)),
            NativeAction::RequestScreenRecordingPermission => self.permissions(Some(false)),
            action => {
                if let Some(runtime) = self.runtime.clone() {
                    let proxy = self.proxy.clone();
                    self.rt.spawn(async move {
                        if let Err(error) = runtime.handle_action(action).await {
                            let _ = proxy.send_event(DesktopEvent::Status(error.to_string()));
                        }
                    });
                } else if self.fixture {
                    self.fixture_action(action);
                }
            }
        }
    }
    fn fixture_action(&mut self, action: NativeAction) {
        match action {
            NativeAction::SelectTask { id } if self.snapshot.tasks.iter().any(|t| t.id == id) => {
                self.snapshot.selected_task_id = Some(id)
            }
            NativeAction::SetTaskModel { task_id, model_id } => {
                if let Some(task) = self.snapshot.tasks.iter_mut().find(|t| t.id == task_id) {
                    task.model = model_id;
                }
            }
            NativeAction::SetDefaultModel { model_id } => self.snapshot.default_model = model_id,
            NativeAction::ToggleBrowser => {
                self.snapshot.is_browser_presented = !self.snapshot.is_browser_presented
            }
            NativeAction::ToggleInspector => {
                self.snapshot.is_inspector_presented = !self.snapshot.is_inspector_presented
            }
            NativeAction::ShowSettings => self.snapshot.is_settings_presented = true,
            NativeAction::DismissSettings => self.snapshot.is_settings_presented = false,
            NativeAction::SetAppearance { value } => self.snapshot.appearance = value,
            NativeAction::SetShowToolPayloads { value } => self.snapshot.show_tool_payloads = value,
            _ => {}
        }
        self.publish();
    }
}
fn bounds(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        position: LogicalPosition::new(x, y).into(),
        size: LogicalSize::new(width, height).into(),
    }
}
fn native_mode(mode: AccessMode) -> NativeAccessMode {
    match mode {
        AccessMode::AskEveryTime => NativeAccessMode::AskEveryTime,
        AccessMode::FullAccess => NativeAccessMode::FullAccess,
    }
}
fn grant(grant: PermissionGrant) -> PermissionStatus {
    match grant {
        PermissionGrant::Granted => PermissionStatus::Granted,
        PermissionGrant::NotGranted => PermissionStatus::NotGranted,
    }
}
fn invalid(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, error.to_string())
}
fn initial_snapshot(p: &Preferences, fixture: bool) -> AppSnapshot {
    let id = Identifier::new("rust-ui-fixture").expect("constant id");
    let tasks = if fixture {
        vec![TaskSnapshot {
            id: id.clone(),
            title: "New task".into(),
            summary: "Rust desktop qualification".into(),
            status: "Waiting".into(),
            status_tone: Tone::Neutral,
            updated_at: computa_macos::unix_time(),
            active_turn_started_at: None,
            active_activity_group_id: None,
            workspace: "Private qualification".into(),
            model: ModelId::Browser(WebProvider::Claude),
            model_selectable: true,
            branch: None,
            entries: vec![],
            queued_prompts: vec![],
            queue_paused: false,
            can_steer: false,
            is_busy: false,
        }]
    } else {
        vec![]
    };
    let model_options = [
        LocalModel::Qwen35_4b,
        LocalModel::Qwen35_9b,
        LocalModel::Qwen36_35bA3b,
        LocalModel::Qwen38_27b,
    ]
    .into_iter()
    .map(|model| ModelOption {
        id: ModelId::Local(model),
        label: model.model_id().split('/').next_back().unwrap().into(),
        detail: if model.supports_headless_mlx() {
            "Local MLX"
        } else {
            "External local server"
        }
        .into(),
        high_memory: model.high_memory(),
    })
    .chain(
        [
            WebProvider::Chatgpt,
            WebProvider::Gemini,
            WebProvider::Claude,
        ]
        .into_iter()
        .map(|provider| ModelOption {
            id: ModelId::Browser(provider),
            label: provider.label().into(),
            detail: "Browser session".into(),
            high_memory: false,
        }),
    )
    .collect();
    AppSnapshot {
        revision: 0,
        selected_task_id: fixture.then_some(id),
        selected_entry_id: None,
        tasks,
        prompt_receipts: vec![],
        pending_approval_count: 0,
        connection: ConnectionSnapshot {
            state: ConnectionState::Connecting,
            label: if fixture {
                "Private UI qualification"
            } else {
                "Starting runtime"
            }
            .into(),
            tone: Tone::Neutral,
        },
        permissions: PermissionSnapshot {
            accessibility: PermissionStatus::NotGranted,
            screen_recording: PermissionStatus::NotGranted,
        },
        appearance: p.appearance,
        access_mode: p.access_mode,
        default_model: p.default_model.clone(),
        model_options,
        show_tool_payloads: false,
        is_inspector_presented: false,
        is_browser_presented: false,
        is_settings_presented: false,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn qualification_port_is_explicit_private_and_unprivileged() {
        assert!(
            Options::parse(
                ["--resources", "/tmp/resources", "--inference-port", "32137"].map(String::from)
            )
            .is_err()
        );
        assert!(
            Options::parse(
                [
                    "--resources",
                    "/tmp/resources",
                    "--private-home",
                    "/tmp/private",
                    "--inference-port",
                    "0"
                ]
                .map(String::from)
            )
            .is_err()
        );
        assert!(
            Options::parse(
                [
                    "--resources",
                    "/tmp/resources",
                    "--private-home",
                    "/tmp/private",
                    "--inference-port",
                    "1023"
                ]
                .map(String::from)
            )
            .is_err()
        );
        let options = Options::parse(
            [
                "--resources",
                "/tmp/resources",
                "--private-home",
                "/tmp/private",
                "--inference-port",
                "32137",
            ]
            .map(String::from),
        )
        .unwrap();
        assert_eq!(options.inference_port, Some(32137));
    }
    #[test]
    fn fixture_requires_private_state_and_rejects_duplicate_flags() {
        assert!(
            Options::parse(["--resources", "/tmp/res", "--ui-fixture"].map(String::from)).is_err()
        );
        assert!(
            Options::parse(
                [
                    "--resources",
                    "/tmp/res",
                    "--private-home",
                    "/tmp/owned",
                    "--ui-fixture"
                ]
                .map(String::from)
            )
            .unwrap()
            .fixture
        );
        assert!(
            Options::parse(["--resources", "/tmp/a", "--resources", "/tmp/b"].map(String::from))
                .is_err()
        );
    }
}
