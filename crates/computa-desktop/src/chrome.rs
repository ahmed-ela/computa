//! Native-only Chrome pairing and admission. Website messages cannot invoke these controls.
use computa_browser::{
    ApplePeerVerifier, BridgeServer, BrowserError, ChromeLink, CleanupProofStore,
    ExtensionBrowserTransport, LinkEvent, identity, leases::BrowserController,
};
use computa_contracts::chrome::Hello;
use computa_state::preferences::{Preferences, PreferencesStore};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use tokio::sync::{Mutex, broadcast};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[derive(Clone)]
pub enum ChromeEvent {
    Proposal {
        id: Uuid,
        installation: String,
        extension: String,
    },
    Connected {
        controller: Arc<BrowserController>,
        generation: Uuid,
    },
    Disconnected {
        generation: Uuid,
    },
    Status {
        text: String,
    },
    PreferencesChanged(Preferences),
}
#[derive(Clone)]
pub struct ChromeProposal {
    pub id: Uuid,
    pub installation: String,
    pub extension: String,
}
#[derive(Clone)]
pub struct ChromeSnapshot {
    pub proposal: Option<ChromeProposal>,
    pub connected: Option<Arc<BrowserController>>,
    pub status: String,
}
#[derive(Clone)]
struct Proposal {
    public: ChromeProposal,
    link: Uuid,
    epoch: String,
    nonce: String,
    revision: u64,
}
#[derive(Default)]
struct Authority {
    revision: u64,
    conflicted: HashSet<String>,
}
impl Authority {
    fn quarantine(&mut self, hellos: &HashMap<Uuid, Hello>) -> Vec<Uuid> {
        let mut counts = HashMap::new();
        for hello in hellos.values() {
            *counts
                .entry(hello.installation_id.clone())
                .or_insert(0usize) += 1;
        }
        let conflicts: Vec<_> = counts
            .into_iter()
            .filter(|(_, count)| *count > 1)
            .map(|(installation, _)| installation)
            .collect();
        if !conflicts.is_empty() {
            self.revision += 1;
            self.conflicted.extend(conflicts);
        }
        hellos
            .iter()
            .filter(|(_, hello)| self.conflicted.contains(&hello.installation_id))
            .map(|(id, _)| *id)
            .collect()
    }
    fn unique(&self, id: Uuid, hello: &Hello, hellos: &HashMap<Uuid, Hello>) -> bool {
        hello.valid()
            && !self.conflicted.contains(&hello.installation_id)
            && hellos.get(&id).is_some_and(|current| {
                current.installation_id == hello.installation_id
                    && current.bridge_epoch == hello.bridge_epoch
            })
            && hellos
                .values()
                .filter(|current| current.installation_id == hello.installation_id)
                .count()
                == 1
    }
    fn proposal_matches(
        &self,
        proposal: &Proposal,
        hello: &Hello,
        hellos: &HashMap<Uuid, Hello>,
    ) -> bool {
        proposal.revision == self.revision
            && self.unique(proposal.link, hello, hellos)
            && hello.event == "pairRequested"
            && !hello.paired
            && !hello.suspended
            && hello.installation_id == proposal.public.installation
            && hello.extension_id == proposal.public.extension
            && hello.bridge_epoch == proposal.epoch
            && hello.pairing_nonce.as_deref() == Some(&proposal.nonce)
    }
}
struct State {
    links: HashMap<Uuid, Arc<ChromeLink>>,
    hellos: HashMap<Uuid, Hello>,
    authority: Authority,
    proposal: Option<Proposal>,
    connected: Option<Arc<BrowserController>>,
    authorizing: Option<Uuid>,
    prefs: Preferences,
    status: String,
    stopped: bool,
}
pub struct ChromeCoordinator {
    state: Mutex<State>,
    control: Mutex<()>,
    events: broadcast::Sender<ChromeEvent>,
    store: Arc<PreferencesStore>,
    server: Mutex<Option<Arc<BridgeServer>>>,
    stop: CancellationToken,
    pub cleanup_proofs: Arc<CleanupProofStore>,
}
impl ChromeCoordinator {
    pub fn start(store: Arc<PreferencesStore>) -> Result<Arc<Self>, BrowserError> {
        identity::verify_current_application()?;
        // Only the signed OS-home installed product can repair its exact host
        // manifest. Staged/qualification apps never point Chrome at their helper.
        let registration_status = match computa_browser::registration::plan_current_installation() {
            Ok(plan) => match computa_browser::registration::apply_current_installation(&plan) {
                Ok(receipt) if receipt.changed => {
                    "Chrome host registration repaired; waiting for the paired extension".into()
                }
                Ok(_) => "Browser extension not connected".into(),
                Err(error) => error.to_string(),
            },
            Err(error) => error.to_string(),
        };
        let server = Arc::new(BridgeServer::bind(
            &identity::default_directory()?,
            Arc::new(ApplePeerVerifier),
        )?);
        let prefs = store
            .load()
            .map_err(|_| BrowserError::Configuration)?
            .unwrap_or_default();
        let (events, _) = broadcast::channel(128);
        let coordinator = Arc::new(Self {
            state: Mutex::new(State {
                links: HashMap::new(),
                hellos: HashMap::new(),
                authority: Authority::default(),
                proposal: None,
                connected: None,
                authorizing: None,
                prefs,
                status: registration_status,
                stopped: false,
            }),
            control: Mutex::new(()),
            events,
            store,
            server: Mutex::new(Some(server.clone())),
            stop: CancellationToken::new(),
            cleanup_proofs: Arc::new(CleanupProofStore::new()),
        });
        let weak = Arc::downgrade(&coordinator);
        let stop = coordinator.stop.clone();
        tokio::spawn(async move {
            loop {
                let link = tokio::select! {_ = stop.cancelled()=>break,link=server.accept()=>link};
                let Some(coordinator) = weak.upgrade() else {
                    break;
                };
                match link {
                    Ok(link) => coordinator.accept(link).await,
                    Err(_) => {
                        coordinator
                            .status("A Chrome bridge peer could not be verified")
                            .await;
                        tokio::select! {_ = stop.cancelled()=>break,_ = tokio::time::sleep(std::time::Duration::from_millis(100))=>{}}
                    }
                }
            }
        });
        Ok(coordinator)
    }
    pub fn events(&self) -> broadcast::Receiver<ChromeEvent> {
        self.events.subscribe()
    }
    pub async fn snapshot(&self) -> ChromeSnapshot {
        let state = self.state.lock().await;
        ChromeSnapshot {
            proposal: state
                .proposal
                .as_ref()
                .map(|proposal| proposal.public.clone()),
            connected: state.connected.clone(),
            status: state.status.clone(),
        }
    }
    pub fn transport(&self, controller: &Arc<BrowserController>) -> ExtensionBrowserTransport {
        ExtensionBrowserTransport {
            link: controller.link.clone(),
            generation: controller.generation,
            cleanup_proofs: self.cleanup_proofs.clone(),
        }
    }
    fn emit(&self, event: ChromeEvent) {
        let _ = self.events.send(event);
    }
    async fn status(&self, text: &str) {
        self.state.lock().await.status = text.into();
        self.emit(ChromeEvent::Status { text: text.into() });
    }
    async fn accept(self: &Arc<Self>, link: Arc<ChromeLink>) {
        {
            let mut state = self.state.lock().await;
            if state.stopped || state.links.len() >= 4 {
                link.close(BrowserError::Unavailable);
                return;
            }
            state.links.insert(link.id, link.clone());
        }
        let mut events = link.events();
        let weak = Arc::downgrade(self);
        let stop = self.stop.clone();
        // A hello may arrive between the verified accept and subscription.
        if let Some(hello) = link.hello() {
            self.hello(link.clone(), hello).await;
        }
        tokio::spawn(async move {
            loop {
                let event = tokio::select! {_ = stop.cancelled()=>break,event=events.recv()=>event};
                let Some(coordinator) = weak.upgrade() else {
                    break;
                };
                match event{
            Ok(LinkEvent::Hello(hello))=>coordinator.hello(link.clone(),hello).await,
            Ok(LinkEvent::Disconnected)=>{coordinator.lost(link.id).await;break;},
            Ok(LinkEvent::CleanupFailed)=>coordinator.status("A temporary website session could not be closed. Check the Computa extension in Chrome.").await,
            Ok(LinkEvent::Detached(_))=>{},Err(_)=>{link.close(BrowserError::Closed);coordinator.lost(link.id).await;break;}
        }
            }
        });
    }
    async fn hello(self: &Arc<Self>, link: Arc<ChromeLink>, hello: Hello) {
        let mut close = vec![];
        let mut lost = None;
        let mut authorize = None;
        let mut proposal = None;
        {
            let mut state = self.state.lock().await;
            if state.stopped || !state.links.contains_key(&link.id) {
                return;
            }
            if state.hellos.get(&link.id).is_some_and(|old| {
                old.installation_id != hello.installation_id
                    || old.bridge_epoch != hello.bridge_epoch
                    || old.paired && !hello.paired
                    || !old.suspended && hello.suspended
            }) {
                state.authority.revision += 1;
            }
            state.hellos.insert(link.id, hello.clone());
            let hellos = state.hellos.clone();
            let conflicts = state.authority.quarantine(&hellos);
            if !conflicts.is_empty() {
                state.proposal = None;
                state.authorizing = None;
                if state
                    .connected
                    .as_ref()
                    .is_some_and(|controller| conflicts.contains(&controller.link.id))
                {
                    lost = state
                        .connected
                        .take()
                        .map(|controller| controller.generation);
                }
                close = conflicts
                    .iter()
                    .filter_map(|id| state.links.get(id).cloned())
                    .collect();
                state.status = "Browser profile identity conflict — no access granted".into();
            } else {
                if (hello.suspended || !hello.paired)
                    && state
                        .connected
                        .as_ref()
                        .is_some_and(|controller| controller.link.id == link.id)
                {
                    lost = state
                        .connected
                        .take()
                        .map(|controller| controller.generation);
                }
                // Receipt continuity is checked only after installation uniqueness.
                let _ = self.cleanup_proofs.observe(&link);
                let candidates: Vec<_> = state
                    .hellos
                    .iter()
                    .filter(|(_, value)| {
                        value.event == "pairRequested"
                            && !value.paired
                            && value.pairing_nonce.is_some()
                    })
                    .map(|(id, value)| (*id, value.clone()))
                    .collect();
                if candidates.len() == 1 {
                    let (id, value) = &candidates[0];
                    let nonce = value.pairing_nonce.clone().unwrap();
                    let unchanged = state.proposal.as_ref().is_some_and(|proposal| {
                        proposal.link == *id
                            && proposal.epoch == value.bridge_epoch
                            && proposal.nonce == nonce
                            && proposal.revision == state.authority.revision
                    });
                    if !unchanged {
                        let public = ChromeProposal {
                            id: Uuid::new_v4(),
                            installation: value.installation_id.clone(),
                            extension: value.extension_id.clone(),
                        };
                        state.proposal = Some(Proposal {
                            public: public.clone(),
                            link: *id,
                            epoch: value.bridge_epoch.clone(),
                            nonce,
                            revision: state.authority.revision,
                        });
                        proposal = Some(public);
                    }
                } else {
                    state.proposal = None;
                }
                if hello.suspended {
                    state.status = "Browser access paused in Chrome".into();
                } else if hello.paired
                    && state.connected.is_none()
                    && state.authorizing.is_none()
                    && state.prefs.extension_enabled
                    && state.prefs.extension_installation_id.as_deref()
                        == Some(&hello.installation_id)
                {
                    if let Ok(Some(token)) = identity::pairing_load(&hello.installation_id)
                        && hello.pairing_token.as_deref() == Some(&token)
                    {
                        state.authorizing = Some(link.id);
                        authorize = Some((token, state.authority.revision));
                    }
                } else if state.proposal.is_some() {
                    state.status = "Extension ready — approve pairing in Computa".into();
                } else if state.connected.is_none() {
                    state.status = "Open the Computa extension and choose Pair".into();
                }
            }
            if let Some(generation) = lost {
                self.emit(ChromeEvent::Disconnected { generation });
            }
            if let Some(public) = proposal {
                self.emit(ChromeEvent::Proposal {
                    id: public.id,
                    installation: public.installation,
                    extension: public.extension,
                });
            }
            self.emit(ChromeEvent::Status {
                text: state.status.clone(),
            });
        }
        for other in close {
            other.close(BrowserError::Identity);
        }
        if let Some((token, revision)) = authorize {
            let owner = self.clone();
            tokio::spawn(async move {
                let _ = owner.authorize(link, hello, token, revision).await;
            });
        }
    }
    async fn authorize(
        &self,
        link: Arc<ChromeLink>,
        hello: Hello,
        token: String,
        revision: u64,
    ) -> Result<(), BrowserError> {
        let temporary = {
            let mut state = self.state.lock().await;
            if state.stopped
                || revision != state.authority.revision
                || state.authorizing != Some(link.id)
                || !state.authority.unique(link.id, &hello, &state.hellos)
            {
                if state.authority.revision == revision && state.authorizing == Some(link.id) {
                    state.authorizing = None;
                }
                return Err(BrowserError::Identity);
            }
            temporary_matches(
                state.prefs.temporary_tabs.as_ref(),
                &hello.installation_id,
                &token,
            ) && hello
                .capabilities
                .as_ref()
                .is_some_and(|caps| caps["temporaryTabsVersion"] == 1)
        };
        let generation = Uuid::new_v4();
        let controller = BrowserController::authorize(
            link.clone(),
            &hello.installation_id,
            &token,
            generation,
            temporary,
        )
        .await;
        match controller {
            Ok(controller) => {
                let valid = {
                    let mut state = self.state.lock().await;
                    let current = link.hello();
                    let valid = !state.stopped
                        && state.authority.revision == revision
                        && state.authorizing == Some(link.id)
                        && state.connected.is_none()
                        && current.as_ref().is_some_and(|current| {
                            state.authority.unique(link.id, current, &state.hellos)
                                && current.installation_id == hello.installation_id
                                && current.bridge_epoch == hello.bridge_epoch
                                && current.paired
                                && !current.suspended
                                && current.pairing_token.as_deref() == Some(&token)
                        });
                    if state.authority.revision == revision && state.authorizing == Some(link.id) {
                        state.authorizing = None;
                    }
                    if valid {
                        state.connected = Some(controller.clone());
                        state.status = "Browser extension authorized".into();
                        self.emit(ChromeEvent::Connected {
                            controller: controller.clone(),
                            generation,
                        });
                        self.emit(ChromeEvent::Status {
                            text: state.status.clone(),
                        });
                    }
                    valid
                };
                if !valid {
                    let _ = controller.shutdown().await;
                    return Err(BrowserError::Identity);
                }
                Ok(())
            }
            Err(error) => {
                let mut state = self.state.lock().await;
                if state.authority.revision == revision && state.authorizing == Some(link.id) {
                    state.authorizing = None;
                    state.status =
                        "Chrome authorization could not complete. No operation was replayed."
                            .into();
                    self.emit(ChromeEvent::Status {
                        text: state.status.clone(),
                    });
                }
                Err(error)
            }
        }
    }
    async fn lost(&self, id: Uuid) {
        {
            let mut state = self.state.lock().await;
            state.links.remove(&id);
            state.hellos.remove(&id);
            if state.authorizing == Some(id) {
                state.authority.revision += 1;
                state.authorizing = None;
            }
            if state
                .proposal
                .as_ref()
                .is_some_and(|proposal| proposal.link == id)
            {
                state.proposal = None;
            }
            if state
                .connected
                .as_ref()
                .is_some_and(|controller| controller.link.id == id)
            {
                state.authority.revision += 1;
                let generation = state
                    .connected
                    .take()
                    .map(|controller| controller.generation);
                if let Some(generation) = generation {
                    self.emit(ChromeEvent::Disconnected { generation });
                    state.status = "Browser extension reconnecting".into();
                    self.emit(ChromeEvent::Status {
                        text: state.status.clone(),
                    });
                }
            }
        }
    }
    /// The native approval UI must pass the exact proposal ID it displayed.
    pub async fn pair(&self, id: Uuid) -> Result<(), BrowserError> {
        let _control = self.control.lock().await;
        let (proposal, link) = {
            let mut state = self.state.lock().await;
            let proposal = state
                .proposal
                .clone()
                .filter(|proposal| proposal.public.id == id)
                .ok_or(BrowserError::Identity)?;
            let link = state
                .links
                .get(&proposal.link)
                .cloned()
                .ok_or(BrowserError::Closed)?;
            let hello = link.hello().ok_or(BrowserError::Identity)?;
            if state.stopped
                || state.authorizing.is_some()
                || state.connected.is_some()
                || !state
                    .authority
                    .proposal_matches(&proposal, &hello, &state.hellos)
            {
                return Err(BrowserError::Identity);
            }
            state.authorizing = Some(proposal.link);
            (proposal, link)
        };
        let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let mut committed = false;
        let result=async{
            let reply=link.request("approvePair",json!({"installationId":proposal.public.installation,"pairingNonce":proposal.nonce,"pairingToken":token}),Uuid::new_v4()).await?;
            if reply["paired"]!=true{return Err(BrowserError::Identity);}
            let current=link.hello().ok_or(BrowserError::Identity)?;
            {let mut state=self.state.lock().await;
                if state.stopped||state.authority.revision!=proposal.revision||state.authorizing!=Some(link.id)||!state.authority.unique(link.id,&current,&state.hellos)||!paired_proposal_matches(&proposal,&current,&token){return Err(BrowserError::Identity);}
                identity::pairing_save(&current.installation_id,&token)?;
                let saved=self.store.update_chrome(&state.prefs,|prefs|{prefs.extension_enabled=true;prefs.extension_installation_id=Some(current.installation_id.clone());prefs.temporary_tabs=None;});
                match saved{Ok(prefs)=>{state.prefs=prefs.clone();state.proposal=None;committed=true;self.emit(ChromeEvent::PreferencesChanged(prefs));},Err(_)=>{let _=identity::pairing_forget(&current.installation_id);return Err(BrowserError::Configuration);}}
            }
            self.authorize(link.clone(),current,token.clone(),proposal.revision).await
        }.await;
        if result.is_err() {
            let mut state = self.state.lock().await;
            if state.authority.revision == proposal.revision && state.authorizing == Some(link.id) {
                state.authorizing = None;
            }
            drop(state);
            // Exact token only: this cannot revoke an unrelated saved pairing.
            if !committed {
                let _ = link
                    .request(
                        "revokePair",
                        json!({"installationId":proposal.public.installation,"pairingToken":token}),
                        Uuid::new_v4(),
                    )
                    .await;
            }
        }
        result
    }
    /// Removes native and remembered authority for the exact displayed generation.
    pub async fn disconnect(&self, generation: Uuid) -> Result<(), BrowserError> {
        let _control = self.control.lock().await;
        let (controller, hello, saved) = {
            let mut state = self.state.lock().await;
            let controller = state
                .connected
                .clone()
                .filter(|controller| controller.generation == generation)
                .ok_or(BrowserError::Identity)?;
            let hello = controller
                .link
                .hello()
                .or_else(|| state.hellos.get(&controller.link.id).cloned());
            state.authority.revision += 1;
            state.connected = None;
            state.proposal = None;
            state.authorizing = None;
            let saved = self.store.update_chrome(&state.prefs, |prefs| {
                prefs.extension_enabled = false;
                prefs.extension_installation_id = None;
                prefs.temporary_tabs = None;
            });
            state.prefs.extension_enabled = false;
            state.prefs.extension_installation_id = None;
            state.prefs.temporary_tabs = None;
            if let Ok(prefs) = &saved {
                state.prefs = prefs.clone();
                self.emit(ChromeEvent::PreferencesChanged(prefs.clone()));
            }
            (controller, hello, saved)
        };
        self.emit(ChromeEvent::Disconnected { generation });
        let warnings = controller.cleanup_for_reauthorization().await;
        if let Some(hello) = &hello
            && let Some(token) = &hello.pairing_token
        {
            let _ = controller
                .link
                .request(
                    "revokePair",
                    json!({"installationId":hello.installation_id,"pairingToken":token}),
                    Uuid::new_v4(),
                )
                .await;
        }
        controller.link.close(BrowserError::Closed);
        let forgotten = hello.map_or(Err(BrowserError::Identity), |hello| {
            identity::pairing_forget(&hello.installation_id)
        });
        self.status(if warnings.is_empty() {
            "Browser authorization removed"
        } else {
            "Browser authorization removed; temporary cleanup remains unconfirmed"
        })
        .await;
        saved.map_err(|_| BrowserError::Configuration)?;
        forgotten
    }
    /// Separate native approval for task-owned temporary copies, pairing-bound.
    pub async fn grant_temporary(&self, generation: Uuid) -> Result<(), BrowserError> {
        let _control = self.control.lock().await;
        let (controller, hello, token, revision) = {
            let mut state = self.state.lock().await;
            let controller = state
                .connected
                .clone()
                .filter(|controller| controller.generation == generation)
                .ok_or(BrowserError::Identity)?;
            let hello = controller.link.hello().ok_or(BrowserError::Identity)?;
            let token = identity::pairing_load(&hello.installation_id)?
                .filter(|token| hello.pairing_token.as_deref() == Some(token))
                .ok_or(BrowserError::Identity)?;
            if state.stopped
                || !state
                    .authority
                    .unique(controller.link.id, &hello, &state.hellos)
                || hello.suspended
                || !hello.paired
            {
                return Err(BrowserError::Identity);
            }
            if !hello
                .capabilities
                .as_ref()
                .is_some_and(|caps| caps["temporaryTabsVersion"] == 1)
            {
                return Err(BrowserError::ReloadRequired);
            }
            let prefs = self
                .store
                .update_chrome(&state.prefs, |prefs| {
                    prefs.temporary_tabs = Some(temporary_grant(&hello.installation_id, &token))
                })
                .map_err(|_| BrowserError::Configuration)?;
            state.prefs = prefs.clone();
            state.connected = None;
            state.authorizing = Some(controller.link.id);
            state.authority.revision += 1;
            self.emit(ChromeEvent::PreferencesChanged(prefs));
            (controller, hello, token, state.authority.revision)
        };
        self.emit(ChromeEvent::Disconnected { generation });
        // The old controller is already revoked locally; authorize a fresh
        // generation on the same link only after exact lease cleanup.
        let warnings = controller.cleanup_for_reauthorization().await;
        if !warnings.is_empty() {
            self.state.lock().await.authorizing = None;
            self.status("Temporary workspace cleanup remains unconfirmed")
                .await;
            return Err(BrowserError::Unavailable);
        }
        self.authorize(controller.link.clone(), hello, token, revision)
            .await
    }
    pub async fn shutdown(&self) -> Vec<Value> {
        self.stop.cancel();
        let _control = self.control.lock().await;
        let (controller, links) = {
            let mut state = self.state.lock().await;
            state.stopped = true;
            state.authority.revision += 1;
            state.proposal = None;
            state.authorizing = None;
            let controller = state.connected.take();
            let links = state
                .links
                .drain()
                .map(|(_, link)| link)
                .collect::<Vec<_>>();
            state.hellos.clear();
            (controller, links)
        };
        let warnings = if let Some(controller) = controller {
            self.emit(ChromeEvent::Disconnected {
                generation: controller.generation,
            });
            controller.shutdown().await
        } else {
            vec![]
        };
        for link in links {
            link.close(BrowserError::Closed);
        }
        self.server.lock().await.take();
        warnings
    }
}
fn temporary_grant(installation: &str, token: &str) -> Value {
    json!({"version":1,"installationID":installation,"pairingDigest":hex::encode(Sha256::digest(token.as_bytes()))})
}
fn paired_proposal_matches(proposal: &Proposal, hello: &Hello, token: &str) -> bool {
    hello.valid()
        && hello.event == "hello"
        && hello.installation_id == proposal.public.installation
        && hello.extension_id == proposal.public.extension
        && hello.bridge_epoch == proposal.epoch
        && hello.paired
        && !hello.suspended
        && hello.pairing_nonce.is_none()
        && hello.pairing_token.as_deref() == Some(token)
}
fn temporary_matches(value: Option<&Value>, installation: &str, token: &str) -> bool {
    value.is_some_and(|value| {
        value.get("version") == Some(&json!(1))
            && value["installationID"] == installation
            && value["pairingDigest"] == hex::encode(Sha256::digest(token.as_bytes()))
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use computa_contracts::chrome::EXTENSION_ID;
    fn hello(installation: &str) -> Hello {
        serde_json::from_value(json!({"version":1,"event":"hello","installationId":installation,"extensionId":EXTENSION_ID,"bridgeEpoch":Uuid::new_v4(),"paired":true,"suspended":false,"pairingToken":"a".repeat(64)})).unwrap()
    }
    #[test]
    fn copied_installation_remains_quarantined_after_one_link_disappears() {
        let installation = Uuid::new_v4().to_string();
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let a = hello(&installation);
        let mut hellos = HashMap::from([(first, a.clone()), (second, hello(&installation))]);
        let mut authority = Authority::default();
        assert_eq!(authority.quarantine(&hellos).len(), 2);
        assert!(!authority.unique(first, &a, &hellos));
        hellos.remove(&second);
        assert_eq!(authority.quarantine(&hellos), vec![first]);
        assert!(!authority.unique(first, &a, &hellos));
    }
    #[test]
    fn legacy_temporary_grant_requires_exact_installation_and_pairing_digest() {
        let grant = temporary_grant("owned", "token");
        assert_eq!(
            grant["pairingDigest"],
            "3c469e9d6c5875d37a43f353d4f88e61fcf812c66eee3457465a40b0da4153e0"
        );
        assert!(temporary_matches(Some(&grant), "owned", "token"));
        assert!(!temporary_matches(Some(&grant), "replacement", "token"));
        assert!(!temporary_matches(Some(&grant), "owned", "different"));
        assert!(!temporary_matches(None, "owned", "token"));
    }
    #[test]
    fn pairing_proposal_and_accepted_ack_are_exact_scope_capabilities() {
        let installation = Uuid::new_v4().to_string();
        let link = Uuid::new_v4();
        let nonce = Uuid::new_v4().to_string();
        let mut source = hello(&installation);
        source.event = "pairRequested".into();
        source.paired = false;
        source.pairing_token = None;
        source.pairing_nonce = Some(nonce.clone());
        let proposal = Proposal {
            public: ChromeProposal {
                id: Uuid::new_v4(),
                installation,
                extension: EXTENSION_ID.into(),
            },
            link,
            epoch: source.bridge_epoch.clone(),
            nonce,
            revision: 0,
        };
        let authority = Authority::default();
        let hellos = HashMap::from([(link, source.clone())]);
        assert!(authority.proposal_matches(&proposal, &source, &hellos));
        for changed in ["nonce", "epoch", "paired", "suspended", "installation"] {
            let mut changed_source = source.clone();
            match changed {
                "nonce" => changed_source.pairing_nonce = Some(Uuid::new_v4().to_string()),
                "epoch" => changed_source.bridge_epoch = Uuid::new_v4().to_string(),
                "paired" => changed_source.paired = true,
                "suspended" => changed_source.suspended = true,
                _ => changed_source.installation_id = Uuid::new_v4().to_string(),
            };
            assert!(
                !authority.proposal_matches(&proposal, &changed_source, &hellos),
                "{changed}"
            );
        }
        source.event = "hello".into();
        source.paired = true;
        source.pairing_nonce = None;
        source.pairing_token = Some("a".repeat(64));
        assert!(paired_proposal_matches(&proposal, &source, &"a".repeat(64)));
        assert!(!paired_proposal_matches(
            &proposal,
            &source,
            &"b".repeat(64)
        ));
        source.bridge_epoch = Uuid::new_v4().to_string();
        assert!(!paired_proposal_matches(
            &proposal,
            &source,
            &"a".repeat(64)
        ));
    }
}
