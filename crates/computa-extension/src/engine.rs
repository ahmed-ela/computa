use crate::{
    commands::{self, keys},
    providers::{self, Observation, Session},
    temporary::{Lease, TemporaryTabs, validate_targets},
};
use computa_contracts::{
    chrome::{CleanupReceipt, HOST_NAME, MAX_FRAME, Request, uuid_text},
    models::WebProvider,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use uuid::Uuid;
const LOCAL_KEY: &str = "macndashChromeBridgeV1";
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Event {
    Bootstrap {
        local: Value,
        session: Value,
        now: u64,
    },
    Native {
        message: Value,
        now: u64,
        #[serde(default)]
        connection: u64,
    },
    Popup {
        action: String,
        sender: Value,
        id: u64,
        now: u64,
    },
    ChromeReply {
        id: u64,
        result: Option<Value>,
        error: Option<String>,
        now: u64,
    },
    HostDisconnected {
        now: u64,
        #[serde(default)]
        connection: u64,
    },
    Timer {
        token: u64,
        now: u64,
    },
    Detached {
        source: Value,
        reason: String,
        now: u64,
    },
    Activated {
        tab_id: i64,
        now: u64,
    },
    Removed {
        tab_id: i64,
        now: u64,
    },
    Updated {
        tab_id: i64,
        change: Value,
        tab: Value,
        now: u64,
    },
    StorageFailed {
        now: u64,
    },
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum Effect {
    Chrome {
        id: u64,
        api: String,
        params: Value,
        timeout_ms: u64,
    },
    Emit {
        connection: u64,
        message: Value,
    },
    Store {
        area: String,
        value: Value,
    },
    Connect {
        id: u64,
        host: String,
    },
    Disconnect,
    Schedule {
        token: u64,
        after_ms: u64,
    },
    PopupReply {
        id: u64,
        value: Value,
    },
}
#[derive(Clone, Debug)]
struct Attachment {
    token: String,
    target: String,
    tab: Option<i64>,
    frame: Option<Value>,
    contexts: HashSet<u64>,
    objects: HashMap<String, String>,
}
#[derive(Clone, Debug, PartialEq)]
enum Step {
    Targets,
    Attach,
    Current,
    Command,
    Detach,
    CreateProvider,
    AttachProvider,
    RecoveryAttach,
    Frame,
    World,
    FrameAgain,
    Dom,
    PreInput,
    Input,
    RemovedProvider,
    DetachedProvider,
    TempSource,
    TempSourceTab,
    TempSourceAgain,
    TempCreate,
    TempSettleTab,
    TempSettleTargets,
    TempRetired,
    TempReleaseTab,
    TempReleaseTargets,
    TempRemove,
}
#[derive(Clone, Debug)]
struct Work {
    request: Request,
    revision: u64,
    step: Step,
    effect: u64,
    token: Option<String>,
    action: String,
    frame: Value,
    context: u64,
    raw: Value,
    observation: Option<Observation>,
    prompt: String,
    cleanup: bool,
    started: u64,
}
pub struct Engine {
    installation: String,
    extension: String,
    epoch: String,
    pairing: Option<String>,
    pairing_nonce: Option<String>,
    suspended: bool,
    generation: Option<String>,
    revision: u64,
    used_generations: HashSet<String>,
    request_ids: HashSet<String>,
    internal_ids: HashSet<String>,
    attachments: HashMap<String, Attachment>,
    pub sessions: HashMap<String, Session>,
    pub temporary: TemporaryTabs,
    queue: VecDeque<(Request, u64)>,
    work: Option<Work>,
    retired: HashMap<u64, Work>,
    next_effect: u64,
    live_effects: HashSet<u64>,
    background: HashMap<u64, (u64, String)>,
    now: u64,
    connected: bool,
    connection: u64,
    retry: u32,
    timer: Option<u64>,
    cleanup_failures: Vec<Value>,
    cleanup_receipts: VecDeque<CleanupReceipt>,
    effects: Vec<Effect>,
}
impl Engine {
    pub fn new(installation: String, extension: String, epoch: String) -> Self {
        Self {
            installation,
            extension,
            epoch,
            pairing: None,
            pairing_nonce: None,
            suspended: false,
            generation: None,
            revision: 0,
            used_generations: HashSet::new(),
            request_ids: HashSet::new(),
            internal_ids: HashSet::new(),
            attachments: HashMap::new(),
            sessions: HashMap::new(),
            temporary: TemporaryTabs::default(),
            queue: VecDeque::new(),
            work: None,
            retired: HashMap::new(),
            next_effect: 0,
            live_effects: HashSet::new(),
            background: HashMap::new(),
            now: 0,
            connected: false,
            connection: 0,
            retry: 0,
            timer: None,
            cleanup_failures: vec![],
            cleanup_receipts: VecDeque::new(),
            effects: vec![],
        }
    }
    pub fn permits(&self, id: u64) -> bool {
        self.live_effects.contains(&id)
    }
    pub fn accepts_popup(&self, sender: &Value) -> bool {
        sender["id"] == self.extension
            && sender["url"] == format!("chrome-extension://{}/popup.html", self.extension)
            && sender.get("tab").is_none()
    }
    fn id(&mut self) -> u64 {
        self.next_effect += 1;
        self.next_effect
    }
    fn emit(&mut self, message: Value) {
        self.effects.push(Effect::Emit {
            connection: self.connection,
            message,
        });
    }
    fn hello(&mut self) {
        self.emit(json!({"version":1,"event":"hello","installationId":self.installation,"extensionId":self.extension,"bridgeEpoch":self.epoch,"paired":self.pairing.is_some(),"suspended":self.suspended,"pairingToken":self.pairing,"capabilities":{"temporaryTabsVersion":1},"cleanupReceipts":self.cleanup_receipts}));
    }
    fn local_store(&mut self) {
        self.effects.push(Effect::Store{area:"local".into(),value:json!({LOCAL_KEY:{"installationId":self.installation,"pairingToken":self.pairing,"suspended":self.suspended}})});
    }
    fn ledger(&mut self) {
        self.effects.push(Effect::Store{area:"session".into(),value:json!({providers::LEDGER_KEY:self.sessions.values().map(Session::ledger).collect::<Vec<_>>(),providers::RECEIPTS_KEY:self.cleanup_receipts})});
    }
    pub fn status(&self) -> Value {
        let paired = self.pairing.is_some();
        let connected = self.generation.is_some();
        let status = if !paired {
            "Not paired"
        } else if self.suspended {
            "Access paused"
        } else if connected {
            "Connected to Computa"
        } else {
            "Paired · waiting for Computa"
        };
        json!({"paired":paired,"suspended":self.suspended,"connected":connected,"installationId":self.installation,"extensionId":self.extension,"attachmentCount":self.attachments.len(),"webProviderCleanupFailures":self.cleanup_failures,"view":{"status":{"textContent":status},"pair":{"hidden":paired},"resume":{"hidden":!paired||(connected&&!self.suspended)},"forget":{"hidden":!paired},"web-cleanup-warning":{"hidden":self.cleanup_failures.is_empty(),"textContent":if self.cleanup_failures.is_empty(){""}else{"Website history cleanup could not be verified. Local transcripts stay in Computa."}}}})
    }
    fn check(&self, generation: &str, revision: u64) -> Result<(), String> {
        if self.pairing.is_some()
            && !self.suspended
            && self.generation.as_deref() == Some(generation)
            && self.revision == revision
        {
            Ok(())
        } else {
            Err("unauthorized".into())
        }
    }
    pub fn dispatch(&mut self, event: Event) -> Vec<Effect> {
        self.effects.clear();
        match event {
            Event::Bootstrap {
                local,
                session,
                now,
            } => {
                self.now = now;
                if let Some(stored) = local.get(LOCAL_KEY).filter(|v| v.is_object())
                    && stored["installationId"].as_str().is_some_and(uuid_text)
                {
                    self.installation = stored["installationId"].as_str().unwrap().into();
                    self.pairing = stored["pairingToken"]
                        .as_str()
                        .filter(|s| !s.is_empty() && s.len() <= 256)
                        .map(str::to_owned);
                    self.suspended = stored["suspended"] == true;
                }
                self.local_store();
                self.restore(&session);
                if self.pairing.is_some() && !self.suspended {
                    self.connect();
                }
            }
            Event::Native {
                message,
                now,
                connection,
            } => {
                self.now = now;
                if connection == 0 || connection == self.connection {
                    self.native(message);
                }
            }
            Event::Popup {
                action,
                sender,
                id,
                now,
            } => {
                self.now = now;
                let expected = format!("chrome-extension://{}/popup.html", self.extension);
                if sender["id"] == self.extension
                    && sender["url"] == expected
                    && sender.get("tab").is_none()
                {
                    let result = self.popup(&action);
                    self.effects.push(Effect::PopupReply {
                        id,
                        value: match result {
                            Ok(v) => json!({"ok":true,"result":v}),
                            Err(code) => json!({"ok":false,"error":code}),
                        },
                    });
                }
            }
            Event::ChromeReply {
                id,
                result,
                error,
                now,
            } => {
                self.now = now;
                self.reply(id, result, error);
            }
            Event::HostDisconnected { now, connection } => {
                self.now = now;
                if connection != 0 && connection != self.connection {
                    return std::mem::take(&mut self.effects);
                }
                self.connected = false;
                self.revoke(false, false);
                if self.pairing.is_some() && !self.suspended {
                    let token = self.id();
                    // Reconnect the authenticated helper indefinitely, with one
                    // outstanding timer and a capped attempt rate. No request is replayed.
                    let after = (1000 * (1u64 << self.retry.min(5))).min(30_000);
                    self.retry = self.retry.saturating_add(1).min(5);
                    self.timer = Some(token);
                    self.effects.push(Effect::Schedule {
                        token,
                        after_ms: after,
                    });
                }
            }
            Event::Timer { token, now } => {
                self.now = now;
                if self.timer == Some(token) {
                    self.timer = None;
                    if !self.suspended && self.pairing.is_some() {
                        self.connect();
                    }
                } else if self
                    .work
                    .as_ref()
                    .is_some_and(|w| w.effect == token && w.step == Step::TempSettleTab)
                    && let Some(w) = self.work.take()
                {
                    let tab = self.temporary.leases[wtoken(&w)].tab;
                    self.chrome(w, Step::TempSettleTab, "tabs.get", json!([tab]), 1500);
                }
            }
            Event::Detached {
                source,
                reason,
                now,
            } => {
                self.now = now;
                self.detached(source, &reason);
            }
            Event::Activated { tab_id, now } => {
                self.now = now;
                self.temporary.note(tab_id, "activation", None);
                self.takeover(tab_id);
            }
            Event::Removed { tab_id, now } => {
                self.now = now;
                self.temporary.note(tab_id, "removal", None);
                self.takeover(tab_id);
                for l in self
                    .temporary
                    .leases
                    .values_mut()
                    .filter(|l| l.tab == Some(tab_id))
                {
                    l.status = "closed".into();
                }
                let tokens: Vec<_> = self
                    .sessions
                    .values()
                    .filter(|s| s.tab_id == tab_id)
                    .map(|s| s.token.clone())
                    .collect();
                for token in tokens {
                    if let Some(mut s) = self.sessions.remove(&token) {
                        s.revoked = true;
                        if (s.submitted || s.ownership_lost)
                            && !matches!(
                                s.cleanup.as_str(),
                                "not_created" | "deleted" | "temporary_closed"
                            )
                        {
                            s.cleanup = "failed".into();
                            self.cleanup_warning(&s, "web_tab_closed");
                        } else {
                            self.cleanup_failures.retain(|v| v["sessionToken"] != token);
                        }
                    }
                }
                self.ledger();
            }
            Event::Updated {
                tab_id,
                change,
                tab,
                now,
            } => {
                self.now = now;
                self.updated(tab_id, change, tab);
            }
            Event::StorageFailed { now } => {
                self.now = now;
                self.revoke(true, false);
                self.effects
                    .retain(|effect| !matches!(effect, Effect::Store { .. }));
                self.hello();
            }
        }
        self.start_next();
        std::mem::take(&mut self.effects)
    }
    fn connect(&mut self) {
        if !self.connected {
            self.connected = true;
            let id = self.id();
            self.connection = id;
            self.effects.push(Effect::Connect {
                id,
                host: HOST_NAME.into(),
            });
            self.hello();
        }
    }
    fn popup(&mut self, action: &str) -> Result<Value, String> {
        match action {
            "status" => {}
            "pair" => {
                if self.pairing.is_some() {
                    return Err("already_paired".into());
                }
                self.retry = 0;
                self.connect();
                self.pairing_nonce = Some(Uuid::new_v4().to_string());
                self.pair_proposal();
            }
            "resume" => {
                if self.pairing.is_none() {
                    return Err("not_paired".into());
                }
                self.retry = 0;
                self.suspended = false;
                self.local_store();
                self.connect();
                self.hello();
            }
            "forget" => {
                self.timer = None;
                self.revoke(true, true);
                self.effects.push(Effect::Disconnect);
                self.connected = false;
                self.hello();
            }
            _ => return Err("invalid_request".into()),
        }
        Ok(self.status())
    }
    fn pair_proposal(&mut self) {
        if self.pairing.is_none() && self.pairing_nonce.is_some() {
            self.emit(json!({"version":1,"event":"pairRequested","installationId":self.installation,"extensionId":self.extension,"bridgeEpoch":self.epoch,"paired":false,"suspended":self.suspended,"pairingNonce":self.pairing_nonce,"capabilities":{"temporaryTabsVersion":1}}));
        }
    }
    fn native(&mut self, value: Value) {
        if value["version"] == 1 && value["event"] == "requestHello" {
            self.hello();
            self.pair_proposal();
            return;
        }
        if value["version"] == 1 && value["event"] == "appDisconnected" {
            self.revoke(false, false);
            self.hello();
            return;
        }
        if !serde_json::to_vec(&value).is_ok_and(|v| v.len() <= MAX_FRAME)
            || self.queue.len() + usize::from(self.work.is_some()) >= 32
        {
            self.revoke(true, false);
            self.emit(json!({"version":1,"event":"bridgeError","code":"capacity_exceeded"}));
            return;
        }
        let Ok(request) = serde_json::from_value::<Request>(value) else {
            return;
        };
        if !request.valid() {
            self.fail(&request, "invalid_request");
            return;
        }
        if self.request_ids.contains(&request.id) {
            self.fail(&request, "duplicate_request");
            return;
        }
        if self.request_ids.len() >= 4096 {
            self.fail(&request, "capacity_exceeded");
            return;
        }
        self.request_ids.insert(request.id.clone());
        if matches!(request.operation.as_str(), "revokePair" | "disconnect") {
            self.admit(request, self.revision);
        } else {
            self.queue.push_back((request, self.revision));
        }
    }
    fn start_next(&mut self) {
        if self.work.is_some() {
            return;
        }
        while let Some((request, revision)) = self.queue.pop_front() {
            self.admit(request, revision);
            if self.work.is_some() {
                break;
            }
        }
    }
    fn fail(&mut self, r: &Request, code: &str) {
        if self.internal_ids.remove(&r.id) {
            return;
        }
        self.emit(json!({"version":1,"id":r.id,"generation":r.generation,"ok":false,"error":{"code":code,"message":"The bounded browser operation could not complete. No action was replayed."}}));
    }
    fn success(&mut self, r: &Request, result: Value) {
        if self.internal_ids.remove(&r.id) {
            return;
        }
        let value =
            json!({"version":1,"id":r.id,"generation":r.generation,"ok":true,"result":result});
        if serde_json::to_vec(&value).is_ok_and(|v| v.len() <= MAX_FRAME) {
            self.emit(value);
        } else {
            self.fail(r, "response_too_large");
        }
    }
    fn chrome(&mut self, mut w: Work, step: Step, api: &str, params: Value, timeout: u64) {
        let id = self.id();
        w.effect = id;
        w.step = step;
        self.live_effects.insert(id);
        self.effects.push(Effect::Chrome {
            id,
            api: api.into(),
            params,
            timeout_ms: timeout,
        });
        self.work = Some(w);
    }
    fn background_chrome(&mut self, api: &str, params: Value, timeout: u64) {
        let id = self.id();
        self.live_effects.insert(id);
        self.background.insert(id, (self.revision, api.into()));
        self.effects.push(Effect::Chrome {
            id,
            api: api.into(),
            params,
            timeout_ms: timeout,
        });
    }
    fn cdp(&mut self, w: Work, step: Step, method: &str, params: Value) {
        let target = if let Some(token) = &w.token {
            if let Some(session) = self.sessions.get(token) {
                json!({"tabId":session.tab_id})
            } else if let Some(a) = self.attachments.get(token) {
                json!({"targetId":a.target})
            } else {
                json!({})
            }
        } else {
            json!({})
        };
        self.chrome(
            w,
            step,
            "debugger.sendCommand",
            json!([target, method, params]),
            1500,
        );
    }
    fn new_work(&self, r: Request, revision: u64) -> Work {
        Work {
            request: r,
            revision,
            step: Step::Targets,
            effect: 0,
            token: None,
            action: String::new(),
            frame: Value::Null,
            context: 0,
            raw: Value::Null,
            observation: None,
            prompt: String::new(),
            cleanup: false,
            started: self.now,
        }
    }
    fn admit(&mut self, r: Request, revision: u64) {
        let result = if self.retired.len() >= 64
            && !self.internal_ids.contains(&r.id)
            && matches!(
                r.operation.as_str(),
                "attach" | "webProviderStart" | "createTemporary"
            ) {
            Err("capacity_exceeded".into())
        } else {
            self.admit_checked(r.clone(), revision)
        };
        if let Err(code) = result {
            self.fail(&r, &code);
        }
    }
    fn admit_checked(&mut self, r: Request, revision: u64) -> Result<(), String> {
        let p = &r.params;
        if revision != self.revision {
            return Err("revoked".into());
        }
        match r.operation.as_str() {
            "approvePair" => {
                if !keys(p, &["installationId", "pairingNonce", "pairingToken"])
                    || self.pairing.is_some()
                    || p["installationId"] != self.installation
                    || p["pairingNonce"].as_str() != self.pairing_nonce.as_deref()
                    || !p["pairingToken"]
                        .as_str()
                        .is_some_and(|s| s.len() >= 32 && s.len() <= 256)
                {
                    return Err("pairing_rejected".into());
                }
                self.pairing = p["pairingToken"].as_str().map(str::to_owned);
                self.pairing_nonce = None;
                self.suspended = false;
                self.local_store();
                self.hello();
                self.success(&r, json!({"paired":true}));
                return Ok(());
            }
            "authorizeSession" => {
                if !(keys(p, &["installationId", "pairingToken"])
                    || keys(
                        p,
                        &["installationId", "pairingToken", "temporaryTabsVersion"],
                    ) && p["temporaryTabsVersion"] == 1)
                    || self.pairing.is_none()
                    || self.suspended
                    || p["installationId"] != self.installation
                    || p["pairingToken"].as_str() != self.pairing.as_deref()
                {
                    return Err("unauthorized".into());
                }
                if self.used_generations.contains(&r.generation) {
                    return Err("duplicate_generation".into());
                }
                if self.used_generations.len() >= 4096 {
                    return Err("capacity_exceeded".into());
                }
                self.revoke(false, false);
                self.generation = Some(r.generation.clone());
                self.used_generations.insert(r.generation.clone());
                self.temporary.tasks.clear();
                self.temporary
                    .leases
                    .retain(|_, lease| lease.status != "closed");
                self.temporary.authorized = p["temporaryTabsVersion"] == 1;
                self.retry = 0;
                self.success(
                    &r,
                    json!({"generation":r.generation,"bridgeEpoch":self.epoch}),
                );
                return Ok(());
            }
            "revokePair" => {
                if !keys(p, &["installationId", "pairingToken"])
                    || p["installationId"] != self.installation
                    || p["pairingToken"].as_str() != self.pairing.as_deref()
                    || self.pairing.is_none()
                {
                    return Err("unauthorized".into());
                }
                self.revoke(true, true);
                self.hello();
                self.success(&r, json!({"paired":false,"disconnected":true}));
                return Ok(());
            }
            _ => {}
        }
        let internal = self.internal_ids.contains(&r.id);
        if !internal {
            self.check(&r.generation, revision)?;
        }
        let mut w = self.new_work(r.clone(), revision);
        match r.operation.as_str() {
            "ping" => {
                if !keys(p, &[]) {
                    return Err("invalid_request".into());
                }
                self.success(&r,json!({"generation":r.generation,"bridgeEpoch":self.epoch,"capabilities":{"temporaryTabsVersion":1}}));
            }
            "inventory" => {
                if !keys(p, &[]) {
                    return Err("invalid_request".into());
                }
                self.chrome(w, Step::Targets, "debugger.getTargets", json!([]), 15000);
            }
            "attach" => {
                if !keys(p, &["targetID"])
                    || p["targetID"].as_str().is_none_or(|s| s.is_empty())
                    || self.attachments.len() >= 16
                {
                    return Err("invalid_request".into());
                }
                if self.attachments.values().any(|a| a.target == p["targetID"]) {
                    return Err("already_attached".into());
                }
                self.chrome(w, Step::Targets, "debugger.getTargets", json!([]), 15000);
            }
            "detach" => {
                if !keys(p, &["attachmentToken"]) {
                    return Err("invalid_request".into());
                }
                let token = p["attachmentToken"].as_str().ok_or("invalid_request")?;
                let a = self.attachments.get(token).ok_or("stale_attachment")?;
                w.token = Some(token.into());
                let target = a.target.clone();
                self.chrome(
                    w,
                    Step::Detach,
                    "debugger.detach",
                    json!([{"targetId":target}]),
                    1500,
                );
            }
            "command" => {
                if !keys(p, &["attachmentToken", "method", "params"]) {
                    return Err("invalid_request".into());
                }
                commands::validate(p["method"].as_str().ok_or("invalid_request")?, &p["params"])?;
                let token = p["attachmentToken"].as_str().ok_or("invalid_request")?;
                if !self.attachments.contains_key(token) {
                    return Err("stale_attachment".into());
                }
                w.token = Some(token.into());
                self.chrome(w, Step::Current, "debugger.getTargets", json!([]), 15000);
            }
            "webProviderStart" => {
                if !keys(p, &["provider"]) {
                    return Err("invalid_request".into());
                }
                let provider: WebProvider =
                    serde_json::from_value(p["provider"].clone()).map_err(|_| "invalid_request")?;
                if self.sessions.len() >= 4 {
                    return Err("web_capacity_exceeded".into());
                }
                w.raw = json!({"eventSequence":self.temporary.sequence});
                self.chrome(
                    w,
                    Step::CreateProvider,
                    "tabs.create",
                    json!([{"url":provider.root_url(),"active":false}]),
                    3000,
                );
            }
            "webProviderPoll" | "webProviderSend" | "webProviderFinish" | "webProviderCancel" => {
                let send = r.operation == "webProviderSend";
                if !keys(
                    p,
                    if send {
                        &["sessionToken", "prompt"]
                    } else {
                        &["sessionToken"]
                    },
                ) {
                    return Err("invalid_request".into());
                }
                let token = p["sessionToken"].as_str().ok_or("invalid_request")?;
                let s = self.sessions.get(token).ok_or("web_stale_session")?;
                if !internal
                    && (s.generation != r.generation || s.revision != revision || s.revoked)
                {
                    return Err("web_stale_session".into());
                }
                w.token = Some(token.into());
                w.cleanup = internal
                    || matches!(
                        r.operation.as_str(),
                        "webProviderFinish" | "webProviderCancel"
                    );
                if send {
                    if !matches!(s.state.as_str(), "ready" | "complete") {
                        return Err("web_not_ready".into());
                    }
                    let prompt = p["prompt"]
                        .as_str()
                        .filter(|s| !s.is_empty() && s.len() <= 180_000)
                        .ok_or("invalid_request")?;
                    w.prompt = if s.provider == WebProvider::Claude && !s.submitted {
                        format!("Computa session marker: {}\n\n{prompt}", Uuid::new_v4())
                    } else {
                        prompt.into()
                    };
                    w.action = "prepare".into();
                } else if r.operation == "webProviderPoll" {
                    if !matches!(s.state.as_str(), "loading" | "running") {
                        self.success(&r, s.snapshot());
                        return Ok(());
                    }
                    w.action = "inspect".into();
                } else {
                    if s.ownership_lost
                        || s.provider == WebProvider::Claude
                            && (s.submitted || s.recovered)
                            && s.document_loader_id.is_none()
                    {
                        self.provider_error(w, "web_document_changed");
                        return Ok(());
                    }
                    w.action = if r.operation == "webProviderCancel" && s.state == "running" {
                        "stop"
                    } else {
                        "finish"
                    }
                    .into();
                    if !s.submitted && !s.recovered && s.provider != WebProvider::Claude {
                        self.close_provider(w);
                        return Ok(());
                    }
                }
                if s.recovered && w.cleanup {
                    let tab = s.tab_id;
                    self.chrome(
                        w,
                        Step::RecoveryAttach,
                        "debugger.attach",
                        json!([{"tabId":tab},"1.3"]),
                        1500,
                    );
                } else {
                    self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
                }
            }
            "createTemporary" => {
                if !self.temporary.authorized {
                    return Err("temporary_tabs_not_authorized".into());
                }
                if !keys(p, &["sourceTargetID", "expectedSourceURL", "taskNonce"])
                    || !p["taskNonce"].as_str().is_some_and(uuid_text)
                    || !p["expectedSourceURL"]
                        .as_str()
                        .is_some_and(commands::eligible)
                {
                    return Err("invalid_request".into());
                }
                if let Some(token) = self.temporary.tasks.get(p["taskNonce"].as_str().unwrap()) {
                    let l = &self.temporary.leases[token];
                    if l.status != "active"
                        || l.source_target != p["sourceTargetID"]
                        || l.source_url != p["expectedSourceURL"]
                    {
                        return Err("temporary_task_already_used".into());
                    }
                    w.token = Some(token.clone());
                } else if self.temporary.tasks.len() >= 128
                    || self.temporary.leases.len() >= 128
                    || self.temporary.active_count() >= 4
                {
                    return Err("capacity_exceeded".into());
                }
                self.chrome(w, Step::TempSource, "debugger.getTargets", json!([]), 15000);
            }
            "releaseTemporary" => {
                if !internal && !self.temporary.authorized {
                    return Err("temporary_tabs_not_authorized".into());
                }
                if !keys(p, &["leaseToken", "taskNonce"]) {
                    return Err("invalid_request".into());
                }
                let token = p["leaseToken"].as_str().ok_or("invalid_request")?;
                let l = self
                    .temporary
                    .leases
                    .get(token)
                    .ok_or("stale_temporary_lease")?;
                if l.task != p["taskNonce"]
                    || !internal && (l.generation != r.generation || l.revision != revision)
                {
                    return Err("stale_temporary_lease".into());
                }
                w.token = Some(token.into());
                w.cleanup = true;
                self.release_temp(w);
            }
            "disconnect" => {
                if !keys(p, &["forgetPairing"]) || !p["forgetPairing"].is_boolean() {
                    return Err("invalid_request".into());
                }
                self.revoke(true, p["forgetPairing"] == true);
                self.hello();
                self.success(&r, json!({"disconnected":true}));
            }
            _ => return Err("unsupported_operation".into()),
        }
        Ok(())
    }
    fn reply(&mut self, id: u64, result: Option<Value>, error: Option<String>) {
        self.live_effects.remove(&id);
        if let Some(old) = self.retired.remove(&id) {
            if let Some(value) = result {
                self.cleanup_late(&old, &value);
            }
            return;
        }
        if self.background.remove(&id).is_some() {
            return;
        }
        let Some(w) = self.work.take() else { return };
        if w.effect != id {
            self.work = Some(w);
            return;
        }
        if !w.cleanup && self.check(&w.request.generation, w.revision).is_err() {
            if let Some(value) = result {
                self.cleanup_late(&w, &value);
            }
            self.fail(&w.request, "revoked");
            return;
        }
        if let Some(code) = error {
            let uncertain = code == "timeout" && !w.cleanup;
            if matches!(
                w.step,
                Step::DetachedProvider | Step::TempRetired | Step::RecoveryAttach
            ) {
                let copy = w.clone();
                if let Err(code) = self.advance(w, json!({})) {
                    self.fail(&copy.request, &code);
                }
                return;
            }
            if code == "timeout"
                && matches!(
                    w.step,
                    Step::CreateProvider
                        | Step::AttachProvider
                        | Step::Attach
                        | Step::TempCreate
                        | Step::RemovedProvider
                )
            {
                self.retired.insert(id, w.clone());
            }
            if w.token
                .as_ref()
                .is_some_and(|t| self.sessions.contains_key(t))
            {
                self.provider_error(
                    w,
                    if code == "timeout" {
                        "chrome_timeout"
                    } else {
                        "web_operation_failed"
                    },
                );
            } else {
                self.fail(
                    &w.request,
                    if code == "timeout" {
                        "chrome_timeout"
                    } else {
                        "chrome_operation_failed"
                    },
                );
            }
            if uncertain {
                self.revoke(true, false);
                self.hello();
            }
            return;
        }
        let value = result.unwrap_or(Value::Null);
        let copy = w.clone();
        if let Err(code) = self.advance(w, value) {
            if copy
                .token
                .as_ref()
                .is_some_and(|t| self.sessions.contains_key(t))
            {
                self.provider_error(copy, &code);
            } else {
                self.fail(&copy.request, &code);
            }
        }
    }
    fn advance(&mut self, mut w: Work, value: Value) -> Result<(), String> {
        match w.step {
            Step::Targets => {
                let targets = validate_targets(value)?;
                if w.request.operation == "inventory" {
                    self.success(&w.request,json!({"generation":w.request.generation,"candidates":targets.iter().map(|t|json!({"targetID":t["id"],"title":t["title"].as_str().unwrap_or("").chars().take(4096).collect::<String>(),"url":t["url"],"availability":if t["attached"]==false{"available"}else if t["attached"]==true{"busy"}else{"unknown"}})).collect::<Vec<_>>()}));
                } else {
                    let target = targets
                        .into_iter()
                        .find(|t| t["id"] == w.request.params["targetID"])
                        .ok_or("target_unavailable")?;
                    if target["attached"] != false {
                        return Err("target_busy".into());
                    }
                    if !self
                        .temporary
                        .attachable(target["id"].as_str().ok_or("invalid_inventory")?)
                    {
                        return Err("stale_temporary_lease".into());
                    }
                    w.raw = target.clone();
                    self.chrome(
                        w,
                        Step::Attach,
                        "debugger.attach",
                        json!([{"targetId":target["id"]},"1.3"]),
                        15000,
                    );
                }
            }
            Step::Attach => {
                let token = Uuid::new_v4().to_string();
                let a = Attachment {
                    token: token.clone(),
                    target: w.raw["id"].as_str().ok_or("invalid_inventory")?.into(),
                    tab: w.raw["tabId"].as_i64(),
                    frame: None,
                    contexts: HashSet::new(),
                    objects: HashMap::new(),
                };
                self.attachments.insert(token.clone(), a);
                w.token = Some(token);
                self.chrome(w, Step::Current, "debugger.getTargets", json!([]), 15000);
            }
            Step::Current => {
                let targets = validate_targets(value)?;
                let a = self.attachments.get(wtoken(&w)).ok_or("stale_attachment")?;
                let target = targets
                    .iter()
                    .find(|t| t["id"] == a.target)
                    .ok_or("target_unavailable")?;
                if !self.temporary.attachable(&a.target) {
                    return Err("stale_temporary_lease".into());
                }
                if w.request.operation == "attach" {
                    self.success(&w.request,json!({"attachmentToken":a.token,"targetID":a.target,"title":target["title"],"url":target["url"]}));
                } else {
                    let method = w.request.params["method"]
                        .as_str()
                        .ok_or("invalid_request")?
                        .to_owned();
                    let p = w.request.params["params"].clone();
                    match method.as_str() {
                        "DOMSnapshot.captureSnapshot" if a.frame.is_none() => {
                            return Err("stale_frame".into());
                        }
                        "Page.createIsolatedWorld"
                            if a.frame.as_ref().map(|f| &f["id"]) != Some(&p["frameId"]) =>
                        {
                            return Err("stale_frame".into());
                        }
                        "DOM.resolveNode"
                            if !p["executionContextId"]
                                .as_u64()
                                .is_some_and(|id| a.contexts.contains(&id)) =>
                        {
                            return Err("stale_context".into());
                        }
                        "Runtime.callFunctionOn"
                            if !p["objectId"]
                                .as_str()
                                .is_some_and(|id| a.objects.contains_key(id))
                                || a.frame.as_ref().map(|f| &f["url"])
                                    != Some(&p["arguments"][0]["value"]) =>
                        {
                            return Err("stale_object".into());
                        }
                        _ => {}
                    }
                    for l in self
                        .temporary
                        .leases
                        .values_mut()
                        .filter(|l| l.target.as_deref() == Some(&a.target))
                    {
                        if method == "Runtime.callFunctionOn" {
                            l.mutation_deadline = self.now + 16500;
                        }
                    }
                    self.cdp(w, Step::Command, &method, p);
                }
            }
            Step::Command => {
                let a = self
                    .attachments
                    .get_mut(wtoken(&w))
                    .ok_or("stale_attachment")?;
                let method = w.request.params["method"]
                    .as_str()
                    .ok_or("invalid_request")?;
                let mut out = value.clone();
                match method {
                    "Page.getFrameTree" => {
                        let f = &value["frameTree"]["frame"];
                        if !valid_frame(f) {
                            return Err("invalid_document".into());
                        }
                        let identity =
                            json!({"id":f["id"],"loaderId":f["loaderId"],"url":frame_url(f)});
                        if a.frame.as_ref() != Some(&identity) {
                            a.contexts.clear();
                            a.objects.clear();
                        }
                        a.frame = Some(identity);
                    }
                    "Page.createIsolatedWorld" => {
                        let id = value["executionContextId"]
                            .as_u64()
                            .filter(|id| *id > 0)
                            .ok_or("invalid_context")?;
                        if a.contexts.len() >= 64 && !a.contexts.contains(&id) {
                            return Err("capacity_exceeded".into());
                        }
                        a.contexts.insert(id);
                    }
                    "DOM.resolveNode" => {
                        let id = value["object"]["objectId"]
                            .as_str()
                            .filter(|id| !id.is_empty() && id.len() <= 2048)
                            .ok_or("invalid_object")?;
                        if a.objects.len() >= 256 && !a.objects.contains_key(id) {
                            return Err("capacity_exceeded".into());
                        }
                        a.objects.insert(
                            id.into(),
                            w.request.params["params"]["objectGroup"]
                                .as_str()
                                .ok_or("invalid_request")?
                                .into(),
                        );
                    }
                    "Runtime.releaseObjectGroup" => {
                        a.objects.retain(|_, group| {
                            Some(group.as_str())
                                != w.request.params["params"]["objectGroup"].as_str()
                        });
                    }
                    "Accessibility.getFullAXTree" => {
                        out = commands::project_ax(&value, MAX_FRAME - 4096)?
                    }
                    "DOMSnapshot.captureSnapshot" => {
                        out = commands::project_clickability(
                            &value,
                            MAX_FRAME - 4096,
                            a.frame.as_ref().ok_or("stale_frame")?,
                        )?
                    }
                    _ => {}
                }
                self.success(&w.request, out);
            }
            Step::Detach => {
                self.attachments.remove(wtoken(&w));
                self.success(&w.request, json!({"detached":true}));
            }
            Step::CreateProvider => {
                let tab = value["id"]
                    .as_i64()
                    .filter(|n| *n >= 0)
                    .ok_or("web_tab_unavailable")?;
                let provider: WebProvider =
                    serde_json::from_value(w.request.params["provider"].clone())
                        .map_err(|_| "invalid_request")?;
                let token = Uuid::new_v4().to_string();
                self.sessions.insert(
                    token.clone(),
                    Session::new(
                        token.clone(),
                        tab,
                        provider,
                        w.request.generation.clone(),
                        w.revision,
                        self.now,
                    ),
                );
                self.sessions.get_mut(&token).unwrap().source_epoch = Some(self.epoch.clone());
                w.token = Some(token);
                w.raw = value.clone();
                self.ledger();
                self.chrome(
                    w,
                    Step::AttachProvider,
                    "debugger.attach",
                    json!([{"tabId":tab},"1.3"]),
                    3000,
                );
            }
            Step::AttachProvider => {
                self.ledger();
                self.success(&w.request, self.sessions[wtoken(&w)].snapshot());
            }
            Step::RecoveryAttach => self.cdp(w, Step::Frame, "Page.getFrameTree", json!({})),
            Step::Frame => {
                let frame = &value["frameTree"]["frame"];
                if !valid_frame_base(frame) {
                    return Err("web_invalid_document".into());
                }
                let url = frame_url(frame);
                let s = self
                    .sessions
                    .get_mut(wtoken(&w))
                    .ok_or("web_stale_session")?;
                if url == "about:blank" && s.initial() {
                    return Err("web_document_loading".into());
                }
                let owned = providers::conversation(s.provider, &url);
                let promotion = s.provider == WebProvider::Chatgpt
                    && s.conversation
                        .as_ref()
                        .is_some_and(|c| c.contains("local-chatgpt"))
                    && owned.as_ref().is_some_and(|c| !c.contains("local-chatgpt"))
                    && !s.promoted;
                if s.conversation.is_some() && owned != s.conversation && !promotion {
                    return Err("web_conversation_changed".into());
                }
                if s.conversation.is_none() && owned.is_some() {
                    if !s.submitted {
                        return Err("web_not_fresh".into());
                    }
                    s.conversation = owned;
                }
                if !providers::fresh(s.provider, &url)
                    && providers::conversation(s.provider, &url).is_none()
                {
                    return Err("web_sign_in_required".into());
                }
                if s.provider == WebProvider::Claude {
                    verify_loader(s, frame, s.document_loader_id.clone())?;
                }
                w.frame = frame.clone();
                w.frame["fullURL"] = json!(url);
                self.cdp(w,Step::World,"Page.createIsolatedWorld",json!({"frameId":frame["id"],"worldName":"computa-web-provider-v1","grantUniveralAccess":false}));
            }
            Step::World => {
                w.context = value["executionContextId"]
                    .as_u64()
                    .filter(|n| *n > 0)
                    .ok_or("web_invalid_document")?;
                if self.sessions[wtoken(&w)].provider == WebProvider::Claude {
                    self.cdp(w, Step::FrameAgain, "Page.getFrameTree", json!({}));
                } else {
                    self.evaluate(w);
                }
            }
            Step::FrameAgain => {
                let s = self
                    .sessions
                    .get_mut(wtoken(&w))
                    .ok_or("web_stale_session")?;
                verify_loader(
                    s,
                    &value["frameTree"]["frame"],
                    w.frame["loaderId"].as_str().map(str::to_owned),
                )?;
                self.evaluate(w);
            }
            Step::Dom => {
                if value.get("exceptionDetails").is_some() {
                    return Err("web_invalid_document".into());
                }
                let result = value["result"]["value"].clone();
                if let Some(code) = result["error"].as_str() {
                    if code == "document_changed" && self.sessions[wtoken(&w)].initial() {
                        return Err("web_document_loading".into());
                    }
                    return Err(format!("web_{code}"));
                }
                if w.action == "focus" {
                    if result["acted"] != true {
                        return Err("web_composer_unavailable".into());
                    }
                    self.cdp(w, Step::PreInput, "Page.getFrameTree", json!({}));
                } else if w.action == "submit" {
                    if result["acted"] != true {
                        return Err("web_send_unavailable".into());
                    }
                    self.ledger();
                    self.success(&w.request, self.sessions[wtoken(&w)].snapshot());
                } else if w.action == "toggle" {
                    if result["acted"] != true {
                        return Err("web_temporary_mode_unavailable".into());
                    }
                    self.sessions
                        .get_mut(wtoken(&w))
                        .unwrap()
                        .temporary_requested = true;
                    self.ledger();
                    self.success(&w.request, self.sessions[wtoken(&w)].snapshot());
                } else if w.action == "stopAction" {
                    w.action = "finish".into();
                    w.raw = Value::Null;
                    self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
                } else {
                    let provider = self.sessions[wtoken(&w)].provider;
                    let observation = providers::observe(provider, &result)?;
                    if observation.text.len() > 220_000 {
                        return Err("web_response_too_large".into());
                    }
                    w.raw = result;
                    w.observation = Some(observation);
                    self.observed(w)?;
                }
            }
            Step::PreInput => {
                let s = self
                    .sessions
                    .get_mut(wtoken(&w))
                    .ok_or("web_stale_session")?;
                let f = &value["frameTree"]["frame"];
                if s.provider == WebProvider::Claude {
                    verify_loader(s, f, s.document_loader_id.clone())?;
                }
                if frame_url(f) != w.frame["fullURL"].as_str().unwrap_or("") {
                    return Err("web_document_changed".into());
                }
                let params = json!({"text":w.prompt});
                self.cdp(w, Step::Input, "Input.insertText", params);
            }
            Step::Input => {
                let s = self
                    .sessions
                    .get_mut(wtoken(&w))
                    .ok_or("web_stale_session")?;
                s.submitted = true;
                s.sequence += 1;
                s.pending_submission = s.provider == WebProvider::Claude;
                s.state = "running".into();
                s.baseline = w.observation.as_ref().map_or(0, |o| o.response_count);
                s.response.clear();
                s.last_changed = self.now;
                s.turn_started = self.now;
                if s.provider == WebProvider::Claude && s.sequence == 1 {
                    s.first_user_marker = w
                        .prompt
                        .lines()
                        .next()
                        .and_then(|line| line.strip_prefix("Computa session marker: "))
                        .map(str::to_owned);
                }
                self.ledger();
                w.action = "submit".into();
                self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
            }
            Step::DetachedProvider => {
                let tab = self
                    .sessions
                    .get(wtoken(&w))
                    .map(|s| s.tab_id)
                    .or_else(|| w.raw["tabId"].as_i64())
                    .ok_or("web_stale_session")?;
                self.chrome(w, Step::RemovedProvider, "tabs.remove", json!([tab]), 1000);
            }
            Step::RemovedProvider => {
                self.confirm_closed(w.raw["receipt"].clone());
                let result = if let Some(mut s) = self.sessions.remove(wtoken(&w)) {
                    s.cleanup = if s.submitted {
                        "temporary_closed"
                    } else {
                        "not_created"
                    }
                    .into();
                    s.state = "finished".into();
                    s.failure = None;
                    s.snapshot()
                } else {
                    let mut result = w.raw.clone();
                    result["cleanup"] = w.raw["receipt"]["cleanup"].clone();
                    result["state"] = json!("finished");
                    result["error"] = Value::Null;
                    result
                };
                self.cleanup_failures
                    .retain(|v| v["sessionToken"] != wtoken(&w));
                self.ledger();
                self.success(&w.request, result);
            }
            _ => self.advance_temp(w, value)?,
        }
        Ok(())
    }
    fn evaluate(&mut self, w: Work) {
        let s = &self.sessions[wtoken(&w)];
        let mut plan = providers::dom_plan(s.provider, w.frame["fullURL"].as_str().unwrap_or(""));
        if matches!(
            w.action.as_str(),
            "focus" | "toggle" | "stopAction" | "submit"
        ) {
            let mut guards = serde_json::Map::new();
            for key in [
                "composer",
                "users",
                "identities",
                "answers",
                "fallbackAnswers",
                "exit",
                "badge",
            ] {
                if let Some(value) = w.raw["facts"].get(key) {
                    guards.insert(key.into(), value.clone());
                }
            }
            plan["guards"] = Value::Object(guards);
            if w.action == "submit" {
                plan["guards"]["composer"][0]["value"] = json!(w.prompt);
                plan["guards"]["composer"][0]["text"] = json!(w.prompt);
            }
            let selector = match w.action.as_str() {
                "focus" => plan["queries"][0]["selector"].clone(),
                "toggle" => json!(if s.provider == WebProvider::Claude {
                    "button[aria-label='Use incognito']"
                } else {
                    "button[aria-label='Temporary chat']"
                }),
                "stopAction" => plan["queries"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|q| q["key"] == "stop")
                    .map(|q| q["selector"].clone())
                    .unwrap_or(Value::Null),
                _ => json!(match s.provider {
                    WebProvider::Chatgpt =>
                        "button[data-testid='send-button'],button[aria-label='Send prompt'],button[aria-label='Send message'],button[aria-label='Send']",
                    WebProvider::Gemini =>
                        "button[aria-label='Send message'],button[aria-label='Send'],button.send-button",
                    WebProvider::Claude =>
                        "button[data-testid='chat-input-send'][aria-label='Send message']",
                }),
            };
            plan["action"] =
                json!({"kind":if w.action=="focus"{"focus"}else{"click"},"selector":selector});
        }
        let expression = format!(
            "({})({})",
            include_str!("../platform/dom.js"),
            serde_json::to_string(&plan).unwrap()
        );
        let context = w.context;
        self.cdp(w,Step::Dom,"Runtime.evaluate",json!({"expression":expression,"contextId":context,"returnByValue":true,"awaitPromise":true}));
    }
    fn observed(&mut self, mut w: Work) -> Result<(), String> {
        let o = w.observation.as_ref().unwrap();
        let s = self
            .sessions
            .get_mut(wtoken(&w))
            .ok_or("web_stale_session")?;
        s.validate_observation(
            o,
            if w.action == "prepare" {
                "prepare"
            } else {
                "inspect"
            },
        )?;
        if s.conversation_identity
            .as_ref()
            .is_some_and(|id| Some(id) != o.conversation_identity.as_ref())
        {
            return Err("web_conversation_changed".into());
        }
        if s.conversation_identity.is_none() {
            s.conversation_identity = o.conversation_identity.clone();
        }
        let route = providers::conversation(s.provider, &o.url);
        if s.conversation
            .as_ref()
            .is_some_and(|c| c.contains("local-chatgpt"))
            && route.as_ref().is_some_and(|c| !c.contains("local-chatgpt"))
        {
            if s.promoted || !s.temporary || !o.temporary || s.conversation_identity.is_none() {
                return Err("web_conversation_changed".into());
            }
            s.conversation = route;
            s.promoted = true;
        }
        match w.action.as_str() {
            "prepare" => {
                if !s.temporary || !o.temporary {
                    return Err("web_temporary_mode_unverified".into());
                }
                if !s.submitted
                    && (o.response_count != 0
                        || o.user_count != 0
                        || !providers::fresh(s.provider, &o.url))
                {
                    return Err("web_not_fresh".into());
                }
                if !o.composer || o.busy {
                    return Err("web_composer_unavailable".into());
                }
                if !o.composer_text.trim().is_empty() {
                    return Err("web_composer_not_empty".into());
                }
                w.action = "focus".into();
                self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
            }
            "finish" | "stop" => {
                if s.ownership_lost
                    || s.submitted && (!s.temporary || !o.temporary)
                    || !s.submitted
                        && (o.user_count != 0
                            || o.response_count != 0
                            || s.conversation.is_some()
                            || !providers::fresh(s.provider, &o.url))
                {
                    return Err("web_cleanup_unverified".into());
                }
                if w.action == "stop" && o.busy {
                    w.action = "stopAction".into();
                    self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
                } else {
                    self.close_provider(w);
                }
            }
            _ => {
                if s.state == "loading" {
                    if o.response_count != 0 || o.user_count != 0 || s.conversation.is_some() {
                        return Err("web_not_fresh".into());
                    }
                    if o.composer && o.temporary {
                        s.temporary = true;
                        if s.provider == WebProvider::Claude {
                            s.document_loader_id = w.frame["loaderId"].as_str().map(str::to_owned);
                        }
                        s.state = "ready".into();
                    } else if o.composer
                        && !o.temporary
                        && !s.temporary_requested
                        && s.provider != WebProvider::Chatgpt
                    {
                        w.action = "toggle".into();
                        self.cdp(w, Step::Frame, "Page.getFrameTree", json!({}));
                        return Ok(());
                    } else if o.sign_in {
                        s.state = "needs_sign_in".into();
                        s.failure = Some("web_sign_in_required".into());
                    } else if self.now.saturating_sub(s.created) >= providers::READY_MS {
                        return Err(if o.composer {
                            "web_temporary_mode_unverified"
                        } else {
                            "web_ready_timeout"
                        }
                        .into());
                    }
                } else {
                    if o.interrupted {
                        return Err("web_response_interrupted".into());
                    }
                    if o.response_count > s.baseline && !o.text.is_empty() {
                        if s.response != o.text {
                            s.response = o.text.clone();
                            s.last_changed = self.now;
                        }
                        if !o.busy
                            && o.answer_complete
                            && self.now.saturating_sub(s.last_changed) >= providers::STABLE_MS
                        {
                            s.state = "complete".into();
                        }
                    }
                    if s.state == "running"
                        && self.now.saturating_sub(s.turn_started) >= providers::TURN_MS
                    {
                        return Err("web_response_timeout".into());
                    }
                }
                let snapshot = s.snapshot();
                self.ledger();
                self.success(&w.request, snapshot);
            }
        }
        Ok(())
    }
    fn provider_error(&mut self, w: Work, code: &str) {
        let Some(s) = self.sessions.get_mut(wtoken(&w)) else {
            self.fail(&w.request, "web_stale_session");
            return;
        };
        if w.request.operation == "webProviderPoll"
            && w.action == "inspect"
            && s.initial()
            && matches!(code, "web_document_loading" | "web_invalid_document")
            && self.now.saturating_sub(s.created) < providers::READY_MS
        {
            let snapshot = s.snapshot();
            self.success(&w.request, snapshot);
            return;
        }
        if code == "web_sign_in_required"
            && s.state == "loading"
            && self.now.saturating_sub(s.created) < 5000
        {
            let snapshot = s.snapshot();
            self.success(&w.request, snapshot);
            return;
        }
        let code = if code == "web_document_loading" {
            "web_ready_timeout"
        } else {
            code
        };
        s.failure = Some(code.into());
        s.state = if code == "web_sign_in_required" {
            "needs_sign_in"
        } else {
            "failed"
        }
        .into();
        if matches!(code, "web_document_changed" | "web_conversation_changed") {
            s.ownership_lost = true;
        }
        if w.cleanup {
            s.cleanup = "failed".into();
            let copy = s.clone();
            self.cleanup_warning(&copy, code);
        }
        let snapshot = self.sessions[wtoken(&w)].snapshot();
        self.ledger();
        if w.request.operation == "webProviderSend" {
            self.fail(&w.request, code);
        } else {
            self.success(&w.request, snapshot);
        }
    }
    fn close_provider(&mut self, mut w: Work) {
        let s = self.sessions.get_mut(wtoken(&w)).unwrap();
        s.cleanup = if s.submitted {
            "temporary_closed"
        } else {
            "not_created"
        }
        .into();
        w.raw = s.snapshot();
        w.raw["tabId"] = json!(s.tab_id);
        w.raw["receipt"] = json!({"sessionToken":s.token,"provider":s.provider,"sourceEpoch":s.source_epoch,"generation":s.generation,"cleanup":s.cleanup});
        let tab = s.tab_id;
        self.chrome(
            w,
            Step::DetachedProvider,
            "debugger.detach",
            json!([{"tabId":tab}]),
            1000,
        );
    }
    fn cleanup_warning(&mut self, s: &Session, code: &str) {
        self.cleanup_failures
            .retain(|v| v["sessionToken"] != s.token);
        let value = json!({"provider":s.provider,"sessionToken":s.token,"error":{"code":code}});
        self.cleanup_failures.push(value.clone());
        if self.cleanup_failures.len() > 16 {
            self.cleanup_failures.remove(0);
        }
        self.emit(json!({"version":1,"event":"webProviderCleanupFailed","provider":s.provider,"sessionToken":s.token,"error":{"code":code}}));
    }
    fn revoke(&mut self, suspend: bool, forget: bool) {
        self.revision += 1;
        self.generation = None;
        self.pairing_nonce = None;
        self.live_effects.clear();
        self.background.clear();
        if let Some(w) = self.work.take() {
            self.fail(&w.request, "revoked");
            if matches!(
                w.step,
                Step::CreateProvider
                    | Step::AttachProvider
                    | Step::Attach
                    | Step::TempCreate
                    | Step::RemovedProvider
            ) {
                self.retired.insert(w.effect, w);
            } else {
                self.internal_ids.remove(&w.request.id);
            }
        }
        self.temporary.authorized = false;
        let attachments: Vec<_> = self.attachments.drain().map(|(_, a)| a.target).collect();
        for target in attachments {
            self.background_chrome("debugger.detach", json!([{"targetId":target}]), 1500);
        }
        let providers: Vec<_> = self.sessions.keys().cloned().collect();
        for token in providers {
            self.sessions.get_mut(&token).unwrap().revoked = true;
            self.internal("webProviderFinish", json!({"sessionToken":token}));
        }
        let leases: Vec<_> = self
            .temporary
            .leases
            .values()
            .map(|l| (l.token.clone(), l.task.clone()))
            .collect();
        for (token, task) in leases {
            self.internal(
                "releaseTemporary",
                json!({"leaseToken":token,"taskNonce":task}),
            );
        }
        if suspend {
            self.suspended = true;
        }
        if forget {
            self.pairing = None;
            self.suspended = true;
        }
        self.local_store();
    }
    fn internal(&mut self, operation: &str, params: Value) {
        let r = Request {
            version: 1,
            id: format!("internal-{}", Uuid::new_v4()),
            operation: operation.into(),
            params,
            generation: self.generation.clone().unwrap_or_default(),
        };
        self.internal_ids.insert(r.id.clone());
        self.queue.push_back((r, self.revision));
    }
    fn restore(&mut self, stored: &Value) {
        if let Some(receipts) = stored[providers::RECEIPTS_KEY].as_array() {
            for value in receipts.iter().take(64) {
                if let Ok(receipt) = serde_json::from_value::<CleanupReceipt>(value.clone())
                    && receipt.valid()
                    && !self.cleanup_receipts.contains(&receipt)
                {
                    self.cleanup_receipts.push_back(receipt);
                }
            }
        }
        if let Some(entries) = stored[providers::LEDGER_KEY].as_array() {
            for entry in entries
                .iter()
                .filter(|e| {
                    !matches!(
                        e["cleanup"].as_str(),
                        Some("not_created" | "deleted" | "temporary_closed")
                    )
                })
                .take(4)
            {
                let Some(token) = entry["token"].as_str().filter(|s| uuid_text(s)) else {
                    continue;
                };
                let Some(tab) = entry["tabId"].as_i64().filter(|id| *id >= 0) else {
                    continue;
                };
                let Ok(provider) = serde_json::from_value::<WebProvider>(entry["provider"].clone())
                else {
                    continue;
                };
                let mut s = Session::new(
                    token.into(),
                    tab,
                    provider,
                    "".into(),
                    self.revision,
                    self.now,
                );
                s.recovered = true;
                s.source_epoch = entry["sourceEpoch"]
                    .as_str()
                    .filter(|epoch| uuid_text(epoch))
                    .map(str::to_owned);
                s.generation = entry["generation"]
                    .as_str()
                    .filter(|generation| !generation.is_empty() && generation.len() <= 128)
                    .unwrap_or("")
                    .into();
                s.revoked = true;
                s.state = "interrupted".into();
                s.submitted = entry["submitted"] == true;
                s.temporary = entry["temporary"] == true;
                s.sequence = entry["sequence"].as_u64().unwrap_or(0);
                s.confirmed_user_count = entry["confirmedUserCount"].as_u64().unwrap_or(0);
                s.pending_submission = entry["pendingSubmission"] == true;
                s.ownership_lost = entry["ownershipLost"] == true;
                for (key, target) in [
                    ("documentLoaderId", &mut s.document_loader_id),
                    ("conversation", &mut s.conversation),
                    ("conversationIdentity", &mut s.conversation_identity),
                    ("firstUserMarker", &mut s.first_user_marker),
                    ("firstUserIdentity", &mut s.first_user_identity),
                    ("firstUserFingerprint", &mut s.first_user_fingerprint),
                ] {
                    *target = entry[key].as_str().map(str::to_owned);
                }
                s.promoted = entry["promoted"] == true;
                self.sessions.insert(token.into(), s);
                self.internal("webProviderFinish", json!({"sessionToken":token}));
            }
        }
        self.ledger();
    }
    fn detached(&mut self, source: Value, reason: &str) {
        let tokens: Vec<_> = self
            .sessions
            .values()
            .filter(|s| Some(s.tab_id) == source["tabId"].as_i64())
            .map(|s| s.token.clone())
            .collect();
        for token in tokens {
            let s = self.sessions.get_mut(&token).unwrap();
            if matches!(s.cleanup.as_str(), "not_created" | "temporary_closed") {
                continue;
            }
            s.revoked = true;
            s.state = "failed".into();
            s.cleanup = if s.submitted { "failed" } else { "not_created" }.into();
            s.failure = Some("web_tab_detached".into());
            let copy = s.clone();
            self.cleanup_warning(&copy, "web_tab_detached");
        }
        let attachments: Vec<_> = self
            .attachments
            .values()
            .filter(|a| {
                Some(a.target.as_str()) == source["targetId"].as_str()
                    || a.tab == source["tabId"].as_i64() && a.tab.is_some()
            })
            .map(|a| a.token.clone())
            .collect();
        for token in attachments {
            self.attachments.remove(&token);
            self.emit(json!({"version":1,"event":"detached","generation":self.generation,"attachmentToken":token,"reason":if reason=="target_closed"{"target_closed"}else{"canceled_by_user"}}));
        }
        if reason != "target_closed" {
            self.revoke(true, false);
            self.hello();
            self.effects.push(Effect::Disconnect);
            self.connected = false;
        }
        self.ledger();
    }
    fn takeover(&mut self, tab: i64) {
        let targets = self.temporary.takeover(tab);
        for target in targets {
            let tokens: Vec<_> = self
                .attachments
                .values()
                .filter(|a| a.target == target)
                .map(|a| a.token.clone())
                .collect();
            for token in tokens {
                self.attachments.remove(&token);
                self.emit(json!({"version":1,"event":"detached","generation":self.generation,"attachmentToken":token,"reason":"canceled_by_user"}));
                self.background_chrome("debugger.detach", json!([{"targetId":target}]), 1500);
            }
        }
    }
    fn updated(&mut self, tab_id: i64, change: Value, tab: Value) {
        let url = change["url"].as_str().map(str::to_owned);
        self.temporary.note(tab_id, "update", url.clone());
        let tokens: Vec<_> = self
            .temporary
            .leases
            .values()
            .filter(|l| l.tab == Some(tab_id))
            .map(|l| l.token.clone())
            .collect();
        for token in tokens {
            let l = self.temporary.leases.get_mut(&token).unwrap();
            let mut takeover = tab["active"] == true
                || tab["windowId"].as_i64().is_some_and(|w| w != l.window)
                || change["pinned"] == true
                || change.get("groupId").is_some();
            if let Some(url) = &url
                && url != &l.url
                && !(l.status == "pending" && url == "about:blank")
            {
                l.cleanup_safe = false;
                if l.status == "active"
                    && l.mutation_deadline >= self.now
                    && commands::eligible(url)
                {
                    l.url = url.clone();
                } else {
                    takeover = true;
                }
            }
            if takeover {
                self.takeover(tab_id);
            }
        }
    }
    fn cleanup_late(&mut self, w: &Work, value: &Value) {
        if w.step == Step::RemovedProvider {
            self.confirm_closed(w.raw["receipt"].clone());
            self.sessions.remove(wtoken(w));
            self.cleanup_failures
                .retain(|value| value["sessionToken"] != wtoken(w));
            if self
                .work
                .as_ref()
                .is_some_and(|current| current.cleanup && current.token == w.token)
            {
                let current = self.work.take().unwrap();
                self.live_effects.remove(&current.effect);
                let mut snapshot = w.raw.clone();
                snapshot["state"] = json!("finished");
                snapshot["cleanup"] = w.raw["receipt"]["cleanup"].clone();
                snapshot["error"] = Value::Null;
                self.success(&current.request, snapshot);
            }
            self.ledger();
            return;
        }
        if w.step == Step::CreateProvider
            && let Some(tab) = value["id"].as_i64()
        {
            let provider =
                serde_json::from_value::<WebProvider>(w.request.params["provider"].clone()).ok();
            let activated = self.temporary.events.get(&tab).is_some_and(|event| {
                event.activation > w.raw["eventSequence"].as_u64().unwrap_or(0)
            });
            if value["active"] == false
                && !activated
                && provider.is_some_and(|p| {
                    value.get("url").is_none_or(|url| {
                        url == "about:blank"
                            || url.as_str().is_some_and(|url| providers::fresh(p, url))
                    })
                })
            {
                self.background_chrome("tabs.remove", json!([tab]), 1500);
            } else if let Some(provider) = provider {
                let token = Uuid::new_v4().to_string();
                let mut session = Session::new(
                    token.clone(),
                    tab,
                    provider,
                    "".into(),
                    self.revision,
                    self.now,
                );
                session.revoked = true;
                session.ownership_lost = true;
                session.state = "failed".into();
                session.cleanup = "failed".into();
                self.cleanup_warning(&session, "web_cleanup_unverified");
                self.sessions.insert(token, session);
                self.ledger();
            }
        }
        if w.step == Step::Attach
            && let Some(target) = w.raw["id"].as_str()
        {
            self.background_chrome("debugger.detach", json!([{"targetId":target}]), 1500);
        }
        if w.step == Step::AttachProvider
            && let Some(tab) = w.raw["id"].as_i64()
        {
            self.background_chrome("debugger.detach", json!([{"tabId":tab}]), 1500);
        }
        if w.step == Step::TempCreate {
            let token = wtoken(w);
            if let Some(lease) = self.temporary.leases.get_mut(token)
                && let Some(tab) = value["id"].as_i64()
            {
                lease.tab = Some(tab);
                lease.status = "released".into();
                if value["active"] != false || value["windowId"] != lease.window {
                    lease.cleanup_safe = false;
                }
                let task = lease.task.clone();
                self.internal(
                    "releaseTemporary",
                    json!({"leaseToken":token,"taskNonce":task}),
                );
            }
        }
    }
    fn confirm_closed(&mut self, value: Value) {
        let Ok(receipt) = serde_json::from_value::<CleanupReceipt>(value) else {
            return;
        };
        if !receipt.valid() {
            return;
        }
        self.cleanup_receipts
            .retain(|old| old.session_token != receipt.session_token);
        self.cleanup_receipts.push_back(receipt);
        while self.cleanup_receipts.len() > 64 {
            self.cleanup_receipts.pop_front();
        }
        self.ledger();
        self.hello();
    }
    fn release_temp(&mut self, mut w: Work) {
        let lease = self.temporary.leases[wtoken(&w)].clone();
        if lease.status == "closed" {
            self.success(
                &w.request,
                json!({"released":true,"closed":true,"retained":false}),
            );
            return;
        }
        let tokens: Vec<_> = self
            .attachments
            .values()
            .filter(|a| lease.target.as_deref() == Some(&a.target))
            .map(|a| a.token.clone())
            .collect();
        let mut targets = vec![];
        for token in tokens {
            let a = self.attachments.remove(&token).unwrap();
            targets.push(json!(a.target));
            self.emit(json!({"version":1,"event":"detached","generation":lease.generation,"attachmentToken":token,"reason":"temporary_released"}));
        }
        if lease.status == "active" {
            self.temporary.leases.get_mut(wtoken(&w)).unwrap().status = "released".into();
        }
        w.frame = json!(targets);
        self.retire_temp(w);
    }
    fn retire_temp(&mut self, mut w: Work) {
        if let Some(target) = w.frame.as_array_mut().and_then(|items| items.pop()) {
            self.chrome(
                w,
                Step::TempRetired,
                "debugger.detach",
                json!([{"targetId":target}]),
                1500,
            );
            return;
        }
        let lease = &self.temporary.leases[wtoken(&w)];
        if lease.status == "closed" {
            self.success(
                &w.request,
                json!({"released":true,"closed":true,"retained":false}),
            );
        } else if !lease.cleanup_safe || lease.tab.is_none() {
            self.success(
                &w.request,
                json!({"released":true,"closed":false,"retained":lease.tab.is_some()}),
            );
        } else {
            let tab = lease.tab;
            self.chrome(w, Step::TempReleaseTab, "tabs.get", json!([tab]), 1500);
        }
    }
    fn advance_temp(&mut self, mut w: Work, value: Value) -> Result<(), String> {
        match w.step {
            Step::TempSource => {
                let targets = validate_targets(value)?;
                if let Some(token) = &w.token {
                    let l = &self.temporary.leases[token];
                    let target = targets
                        .iter()
                        .find(|t| {
                            Some(t["id"].as_str().unwrap_or("")) == l.target.as_deref()
                                && t["tabId"].as_i64() == l.tab
                        })
                        .ok_or("stale_temporary_lease")?;
                    self.success(&w.request, l.response(target));
                    return Ok(());
                }
                let source = targets
                    .iter()
                    .find(|t| t["id"] == w.request.params["sourceTargetID"])
                    .ok_or("target_unavailable")?;
                if source["url"] != w.request.params["expectedSourceURL"] {
                    return Err("target_unavailable".into());
                }
                if source["attached"] != false {
                    return Err("target_busy".into());
                }
                if !self
                    .temporary
                    .attachable(source["id"].as_str().ok_or("invalid_inventory")?)
                {
                    return Err("stale_temporary_lease".into());
                }
                let tab = source["tabId"].as_i64().ok_or("target_unavailable")?;
                w.raw = source.clone();
                self.chrome(w, Step::TempSourceTab, "tabs.get", json!([tab]), 15000);
            }
            Step::TempSourceTab => {
                if value["id"] != w.raw["tabId"]
                    || value["windowId"].as_i64().is_none()
                    || value.get("url").is_some_and(|url| url != &w.raw["url"])
                    || value
                        .get("pendingUrl")
                        .is_some_and(|url| !url.is_null() && url != "")
                {
                    return Err("target_unavailable".into());
                }
                w.frame = value;
                self.chrome(
                    w,
                    Step::TempSourceAgain,
                    "debugger.getTargets",
                    json!([]),
                    15000,
                );
            }
            Step::TempSourceAgain => {
                let targets = validate_targets(value)?;
                let source = targets
                    .iter()
                    .find(|t| {
                        t["id"] == w.raw["id"]
                            && t["url"] == w.raw["url"]
                            && t["tabId"] == w.raw["tabId"]
                            && t["attached"] == false
                    })
                    .ok_or("target_busy")?;
                let token = Uuid::new_v4().to_string();
                let task = w.request.params["taskNonce"]
                    .as_str()
                    .ok_or("invalid_request")?
                    .to_owned();
                let window = w.frame["windowId"].as_i64().unwrap();
                let url = source["url"].as_str().unwrap().to_owned();
                let lease = Lease {
                    token: token.clone(),
                    task: task.clone(),
                    generation: w.request.generation.clone(),
                    revision: w.revision,
                    source_target: source["id"].as_str().unwrap().into(),
                    source_url: url.clone(),
                    window,
                    tab: None,
                    target: None,
                    url: url.clone(),
                    status: "pending".into(),
                    cleanup_safe: true,
                    started: self.temporary.sequence,
                    settled: self.temporary.sequence,
                    mutation_deadline: 0,
                };
                self.temporary.tasks.insert(task, token.clone());
                self.temporary.leases.insert(token.clone(), lease);
                w.token = Some(token);
                self.chrome(
                    w,
                    Step::TempCreate,
                    "tabs.create",
                    json!([{"url":url,"active":false,"windowId":window}]),
                    15000,
                );
            }
            Step::TempCreate => {
                let l = self.temporary.leases.get_mut(wtoken(&w)).unwrap();
                let tab = value["id"]
                    .as_i64()
                    .filter(|id| *id >= 0)
                    .ok_or("invalid_temporary_receipt")?;
                l.tab = Some(tab);
                if value["active"] != false
                    || value["windowId"] != l.window
                    || value
                        .get("url")
                        .is_some_and(|url| url != &l.url && url != "about:blank")
                    || value
                        .get("pendingUrl")
                        .is_some_and(|url| url != &l.url && url != "about:blank" && !url.is_null())
                {
                    l.cleanup_safe = false;
                    l.status = "retained".into();
                    return Err("stale_temporary_lease".into());
                }
                if !self
                    .temporary
                    .initial_safe(&self.temporary.leases[wtoken(&w)])
                {
                    return Err("stale_temporary_lease".into());
                }
                w.started = self.now;
                self.chrome(w, Step::TempSettleTab, "tabs.get", json!([tab]), 1500);
            }
            Step::TempSettleTab => {
                w.raw = value;
                self.chrome(
                    w,
                    Step::TempSettleTargets,
                    "debugger.getTargets",
                    json!([]),
                    1500,
                );
            }
            Step::TempSettleTargets => {
                let targets = validate_targets(value)?;
                let l = &self.temporary.leases[wtoken(&w)];
                if !self.temporary.initial_safe(l)
                    || l.status != "pending"
                    || w.raw["id"].as_i64() != l.tab
                    || w.raw["active"] != false
                    || w.raw["windowId"] != l.window
                    || w.raw["pinned"] == true
                    || w.raw["groupId"].as_i64().is_some_and(|id| id != -1)
                {
                    return Err("stale_temporary_lease".into());
                }
                let found: Vec<_> = targets
                    .iter()
                    .filter(|t| t["tabId"].as_i64() == l.tab)
                    .collect();
                let tab_ready = w.raw.get("url").is_none_or(|u| u == &l.url)
                    && w.raw
                        .get("pendingUrl")
                        .is_none_or(|u| u.is_null() || u == "");
                if found.len() == 1
                    && found[0]["url"] == l.url
                    && found[0]["attached"] == false
                    && tab_ready
                {
                    let target = found[0].clone();
                    let l = self.temporary.leases.get_mut(wtoken(&w)).unwrap();
                    l.target = target["id"].as_str().map(str::to_owned);
                    l.status = "active".into();
                    l.settled = self.temporary.sequence;
                    let result = l.response(&target);
                    self.success(&w.request, result);
                } else if self.now.saturating_sub(w.started) >= 2000 {
                    return Err("target_unavailable".into());
                } else {
                    let token = self.id();
                    w.effect = token;
                    w.step = Step::TempSettleTab;
                    self.effects.push(Effect::Schedule {
                        token,
                        after_ms: 50,
                    });
                    self.work = Some(w);
                }
            }
            Step::TempRetired => self.retire_temp(w),
            Step::TempReleaseTab => {
                w.raw = value;
                self.chrome(
                    w,
                    Step::TempReleaseTargets,
                    "debugger.getTargets",
                    json!([]),
                    1500,
                );
            }
            Step::TempReleaseTargets => {
                let targets = validate_targets(value)?;
                let l = &self.temporary.leases[wtoken(&w)];
                if !self.temporary.cleanup_matches(l, &w.raw, &targets) {
                    let l = self.temporary.leases.get_mut(wtoken(&w)).unwrap();
                    l.cleanup_safe = false;
                    l.status = "retained".into();
                    self.success(
                        &w.request,
                        json!({"released":true,"closed":false,"retained":true}),
                    );
                } else {
                    let tab = l.tab;
                    self.chrome(w, Step::TempRemove, "tabs.remove", json!([tab]), 1500);
                }
            }
            Step::TempRemove => {
                self.temporary.leases.get_mut(wtoken(&w)).unwrap().status = "closed".into();
                self.success(
                    &w.request,
                    json!({"released":true,"closed":true,"retained":false}),
                );
            }
            _ => return Err("unsupported_operation".into()),
        }
        Ok(())
    }
}
fn wtoken(w: &Work) -> &str {
    w.token.as_deref().unwrap_or("")
}
fn valid_frame_base(f: &Value) -> bool {
    f["id"].as_str().is_some_and(|s| !s.is_empty())
        && f["url"]
            .as_str()
            .is_some_and(|s| !s.is_empty() && s.len() <= 16384)
}
fn valid_frame(f: &Value) -> bool {
    valid_frame_base(f)
        && f["loaderId"].as_str().is_some_and(|s| !s.is_empty())
        && f["url"].as_str().is_some_and(commands::eligible)
}
fn frame_url(f: &Value) -> String {
    format!(
        "{}{}",
        f["url"].as_str().unwrap_or(""),
        f["urlFragment"].as_str().unwrap_or("")
    )
}
fn verify_loader(s: &mut Session, f: &Value, expected: Option<String>) -> Result<(), String> {
    let changed = f["loaderId"].as_str().is_none_or(|id| id.is_empty())
        || expected
            .as_ref()
            .is_some_and(|old| Some(old.as_str()) != f["loaderId"].as_str());
    if changed && s.initial() {
        return Err("web_document_loading".into());
    }
    if s.ownership_lost || changed || s.recovered && s.document_loader_id.is_none() {
        return s.lose("web_document_changed");
    }
    Ok(())
}
