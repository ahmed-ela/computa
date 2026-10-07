use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
#[derive(Clone, Debug)]
pub struct Lease {
    pub token: String,
    pub task: String,
    pub generation: String,
    pub revision: u64,
    pub source_target: String,
    pub source_url: String,
    pub window: i64,
    pub tab: Option<i64>,
    pub target: Option<String>,
    pub url: String,
    pub status: String,
    pub cleanup_safe: bool,
    pub started: u64,
    pub settled: u64,
    pub mutation_deadline: u64,
}
impl Lease {
    pub fn response(&self, target: &Value) -> Value {
        json!({"leaseToken":self.token,"taskNonce":self.task,"targetID":self.target,"url":target["url"],"title":target["title"].as_str().unwrap_or("").chars().take(4096).collect::<String>(),"availability":if target["attached"]==false{"available"}else if target["attached"]==true{"busy"}else{"unknown"}})
    }
}
#[derive(Clone, Debug, Default)]
pub struct EventRecord {
    pub activation: u64,
    pub removal: u64,
    pub update: u64,
    pub transition: u64,
    pub url: Option<String>,
}
#[derive(Default)]
pub struct TemporaryTabs {
    pub authorized: bool,
    pub leases: HashMap<String, Lease>,
    pub tasks: HashMap<String, String>,
    pub events: HashMap<i64, EventRecord>,
    pub sequence: u64,
    pub eviction_sequence: u64,
}
impl TemporaryTabs {
    pub fn note(&mut self, tab: i64, kind: &str, url: Option<String>) {
        self.sequence += 1;
        let entry = self.events.entry(tab).or_default();
        match kind {
            "activation" => entry.activation = self.sequence,
            "removal" => entry.removal = self.sequence,
            _ => {
                entry.update = self.sequence;
                if let Some(url) = url {
                    if entry.url.as_ref().is_some_and(|old| old != &url) {
                        entry.transition = self.sequence;
                    }
                    entry.url = Some(url);
                }
            }
        }
        if self.events.len() > 2048 {
            if let Some(old) = self.events.keys().copied().min() {
                self.events.remove(&old);
            }
            self.eviction_sequence = self.sequence;
        }
    }
    pub fn initial_safe(&self, lease: &Lease) -> bool {
        let e = lease.tab.and_then(|tab| self.events.get(&tab));
        self.eviction_sequence <= lease.started
            && e.is_none_or(|e| {
                e.activation <= lease.started
                    && e.removal <= lease.started
                    && e.transition <= lease.started
                    && e.url
                        .as_ref()
                        .is_none_or(|u| u == "about:blank" || u == &lease.url)
            })
    }
    pub fn takeover(&mut self, tab: i64) -> Vec<String> {
        let mut targets = vec![];
        for lease in self
            .leases
            .values_mut()
            .filter(|l| l.tab == Some(tab) && l.status != "closed")
        {
            lease.cleanup_safe = false;
            lease.status = "retained".into();
            if let Some(target) = &lease.target {
                targets.push(target.clone());
            }
        }
        targets
    }
    pub fn attachable(&self, target: &str) -> bool {
        self.leases
            .values()
            .filter(|l| l.target.as_deref() == Some(target))
            .all(|l| l.status == "active")
    }
    pub fn cleanup_matches(&self, lease: &Lease, tab: &Value, targets: &[Value]) -> bool {
        let matching: Vec<_> = targets
            .iter()
            .filter(|t| t["tabId"].as_i64() == lease.tab && t["type"] == "page")
            .collect();
        let events = lease.tab.and_then(|t| self.events.get(&t));
        lease.cleanup_safe
            && lease.tab == tab["id"].as_i64()
            && tab["active"] == false
            && tab["pinned"] != true
            && tab["windowId"] == lease.window
            && tab.get("url").is_none_or(|url| url == &lease.url)
            && tab
                .get("pendingUrl")
                .is_none_or(|url| url.is_null() || url == "")
            && matching.len() == 1
            && matching[0]["url"] == lease.url
            && matching[0]["attached"] == false
            && lease
                .target
                .as_ref()
                .is_none_or(|id| matching[0]["id"] == *id)
            && self.eviction_sequence <= lease.started
            && events.is_none_or(|e| {
                e.activation <= lease.started
                    && e.removal <= lease.started
                    && e.transition <= lease.settled.max(lease.started)
                    && !(e.update > lease.started
                        && e.url.as_ref().is_some_and(|url| url != &lease.url))
            })
    }
    pub fn active_count(&self) -> usize {
        self.leases
            .values()
            .filter(|l| matches!(l.status.as_str(), "pending" | "active"))
            .count()
    }
}
pub fn validate_targets(value: Value) -> Result<Vec<Value>, String> {
    let targets = value.as_array().ok_or("invalid_inventory")?;
    if targets.len() > 2048 {
        return Err("invalid_inventory".into());
    }
    let mut ids = HashSet::new();
    let mut out = vec![];
    for target in targets
        .iter()
        .filter(|t| t["type"] == "page" && t["url"].as_str().is_some_and(crate::commands::eligible))
    {
        let id = target["id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 256)
            .ok_or("invalid_inventory")?;
        if !ids.insert(id.to_owned()) {
            return Err("invalid_inventory".into());
        }
        out.push(target.clone());
    }
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn takeover_is_permanent() {
        let mut t = TemporaryTabs::default();
        let l = Lease {
            token: "a".into(),
            task: "t".into(),
            generation: "g".into(),
            revision: 1,
            source_target: "x".into(),
            source_url: "https://x/".into(),
            window: 1,
            tab: Some(2),
            target: Some("z".into()),
            url: "https://x/".into(),
            status: "active".into(),
            cleanup_safe: true,
            started: 0,
            settled: 0,
            mutation_deadline: 0,
        };
        t.leases.insert("a".into(), l);
        t.takeover(2);
        assert!(!t.attachable("z"));
        assert!(!t.leases["a"].cleanup_safe);
    }
}
