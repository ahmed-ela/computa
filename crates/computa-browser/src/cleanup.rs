//! Terminal receipt recovery only. A receipt can never revive a session or permit mutation.
use crate::{BrowserError, ChromeLink};
use computa_contracts::{
    chrome::{CleanupReceipt, Hello},
    models::WebProvider,
    responses::{BrowserCleanup, BrowserSnapshot, BrowserState},
};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use uuid::Uuid;
const MAX_TRACKED: usize = 256;
#[derive(Clone)]
struct Owned {
    installation: String,
    pairing: String,
    epoch: String,
    generation: Uuid,
    provider: WebProvider,
    snapshot: BrowserSnapshot,
    confirmed: bool,
    delivered: bool,
}
#[derive(Default)]
struct State {
    records: HashMap<Uuid, Owned>,
    reserved: usize,
}
#[derive(Default)]
pub struct CleanupProofStore {
    state: Mutex<State>,
}
pub(crate) struct StartReservation {
    store: Arc<CleanupProofStore>,
    active: bool,
}
impl Drop for StartReservation {
    fn drop(&mut self) {
        if self.active {
            self.store.state.lock().unwrap().reserved -= 1;
        }
    }
}
impl CleanupProofStore {
    pub fn new() -> Self {
        Self::default()
    }
    pub(crate) fn reserve(self: &Arc<Self>) -> Result<StartReservation, BrowserError> {
        let mut state = self.state.lock().unwrap();
        if state.records.len() + state.reserved >= MAX_TRACKED
            && let Some(token) = state
                .records
                .iter()
                .find(|(_, owned)| owned.confirmed && owned.delivered)
                .map(|(token, _)| *token)
        {
            state.records.remove(&token);
        }
        if state.records.len() + state.reserved >= MAX_TRACKED {
            return Err(BrowserError::Rejected("capacity_exceeded".into()));
        }
        state.reserved += 1;
        Ok(StartReservation {
            store: self.clone(),
            active: true,
        })
    }
    pub(crate) fn register(
        &self,
        mut reservation: StartReservation,
        hello: &Hello,
        generation: Uuid,
        snapshot: &BrowserSnapshot,
    ) -> Result<(), BrowserError> {
        let pairing = hello
            .pairing_token
            .as_ref()
            .filter(|token| token.len() >= 32)
            .ok_or(BrowserError::Identity)?;
        if !hello.valid() || !hello.paired || hello.suspended {
            return Err(BrowserError::Identity);
        }
        let mut state = self.state.lock().unwrap();
        state.reserved -= 1;
        reservation.active = false;
        if state.records.contains_key(&snapshot.session_token) {
            return Err(BrowserError::Identity);
        }
        state.records.insert(
            snapshot.session_token,
            Owned {
                installation: hello.installation_id.clone(),
                pairing: pairing.clone(),
                epoch: hello.bridge_epoch.clone(),
                generation,
                provider: snapshot.provider,
                snapshot: snapshot.clone(),
                confirmed: false,
                delivered: false,
            },
        );
        Ok(())
    }
    /// Call only with the newly accepted, signature-verified live link. Matching
    /// pairing material authenticates continuity across worker/helper reconnects.
    pub fn observe(&self, link: &Arc<ChromeLink>) -> Result<usize, BrowserError> {
        link.check()?;
        let hello = link.hello().ok_or(BrowserError::Identity)?;
        Ok(self.observe_verified(&hello))
    }
    fn observe_verified(&self, hello: &Hello) -> usize {
        if !hello.valid() || !hello.paired {
            return 0;
        }
        let Some(pairing) = hello.pairing_token.as_ref() else {
            return 0;
        };
        let mut state = self.state.lock().unwrap();
        let mut confirmed = 0;
        for receipt in &hello.cleanup_receipts {
            let Ok(token) = Uuid::parse_str(&receipt.session_token) else {
                continue;
            };
            let Some(owned) = state.records.get_mut(&token) else {
                continue;
            };
            if owned.installation == hello.installation_id
                && owned.pairing == *pairing
                && matches_receipt(owned, receipt)
            {
                if !owned.confirmed {
                    confirmed += 1;
                }
                owned.confirmed = true;
            }
        }
        confirmed
    }
    pub(crate) fn update(
        &self,
        generation: Uuid,
        snapshot: &BrowserSnapshot,
    ) -> Result<(), BrowserError> {
        let mut state = self.state.lock().unwrap();
        let owned = state
            .records
            .get_mut(&snapshot.session_token)
            .ok_or(BrowserError::Identity)?;
        if owned.generation != generation
            || owned.provider != snapshot.provider
            || snapshot.sequence < owned.snapshot.sequence
        {
            return Err(BrowserError::Identity);
        }
        owned.snapshot = snapshot.clone();
        if snapshot
            .cleanup
            .as_ref()
            .is_some_and(|cleanup| cleanup.closed)
        {
            owned.confirmed = true;
            owned.delivered = true;
        }
        Ok(())
    }
    pub(crate) fn finished(&self, generation: Uuid, token: Uuid) -> Option<BrowserSnapshot> {
        let mut state = self.state.lock().unwrap();
        let owned = state.records.get_mut(&token)?;
        if owned.generation != generation || !owned.confirmed {
            return None;
        }
        owned.delivered = true;
        let mut result = owned.snapshot.clone();
        result.state = BrowserState::Finished;
        result.cleanup = Some(BrowserCleanup {
            closed: true,
            error: None,
        });
        result.error = None;
        Some(result)
    }
}
fn matches_receipt(owned: &Owned, receipt: &CleanupReceipt) -> bool {
    receipt.valid()
        && receipt.source_epoch == owned.epoch
        && receipt.generation == owned.generation.to_string()
        && receipt.provider == owned.provider
        && receipt.session_token == owned.snapshot.session_token.to_string()
}
#[cfg(test)]
mod tests {
    use super::*;
    use computa_contracts::chrome::EXTENSION_ID;
    use computa_contracts::responses::BrowserState;
    fn fixture() -> (Arc<CleanupProofStore>, Hello, Uuid, Uuid) {
        let store = Arc::new(CleanupProofStore::new());
        let generation = Uuid::new_v4();
        let token = Uuid::new_v4();
        let hello = Hello {
            version: 1,
            event: "hello".into(),
            installation_id: Uuid::new_v4().to_string(),
            extension_id: EXTENSION_ID.into(),
            bridge_epoch: Uuid::new_v4().to_string(),
            paired: true,
            suspended: false,
            pairing_token: Some("a".repeat(64)),
            pairing_nonce: None,
            capabilities: None,
            cleanup_receipts: vec![],
        };
        let snapshot = BrowserSnapshot {
            session_token: token,
            provider: WebProvider::Claude,
            state: BrowserState::Running,
            sequence: 1,
            text: String::new(),
            cleanup: None,
            error: None,
        };
        let reserve = store.reserve().unwrap();
        store
            .register(reserve, &hello, generation, &snapshot)
            .unwrap();
        (store, hello, generation, token)
    }
    #[test]
    fn authenticated_reconnect_can_only_confirm_exact_old_owned_session() {
        let (store, mut hello, generation, token) = fixture();
        let old_epoch = hello.bridge_epoch.clone();
        hello.bridge_epoch = Uuid::new_v4().to_string();
        hello.cleanup_receipts.push(CleanupReceipt {
            session_token: token.to_string(),
            provider: WebProvider::Claude,
            source_epoch: old_epoch,
            generation: generation.to_string(),
            cleanup: "not_created".into(),
        });
        assert_eq!(store.observe_verified(&hello), 1);
        let result = store.finished(generation, token).unwrap();
        assert!(result.cleanup.unwrap().closed);
        assert_eq!(result.state, BrowserState::Finished);
        assert!(store.finished(Uuid::new_v4(), token).is_none());
    }
    #[test]
    fn changed_pairing_installation_epoch_provider_and_generation_never_confirm_cleanup() {
        for field in [
            "pairing",
            "installation",
            "epoch",
            "provider",
            "generation",
            "cleanup",
        ] {
            let (store, mut hello, generation, token) = fixture();
            let mut receipt = CleanupReceipt {
                session_token: token.to_string(),
                provider: WebProvider::Claude,
                source_epoch: hello.bridge_epoch.clone(),
                generation: generation.to_string(),
                cleanup: "not_created".into(),
            };
            match field {
                "pairing" => hello.pairing_token = Some("b".repeat(64)),
                "installation" => hello.installation_id = Uuid::new_v4().to_string(),
                "epoch" => receipt.source_epoch = Uuid::new_v4().to_string(),
                "provider" => receipt.provider = WebProvider::Gemini,
                "generation" => receipt.generation = Uuid::new_v4().to_string(),
                _ => receipt.cleanup = "failed".into(),
            };
            hello.cleanup_receipts.push(receipt);
            assert_eq!(store.observe_verified(&hello), 0);
            assert!(store.finished(generation, token).is_none());
        }
    }
    #[test]
    fn canceled_start_reservation_releases_capacity() {
        let store = Arc::new(CleanupProofStore::new());
        for _ in 0..300 {
            drop(store.reserve().unwrap());
        }
        assert_eq!(store.state.lock().unwrap().reserved, 0);
    }
}
