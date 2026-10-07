use computa_contracts::{
    Identifier,
    ui::{AssistantPhase, EntryKind, EntrySnapshot, TaskSnapshot},
};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug)]
pub struct ActivityGroup {
    pub id: String,
    pub entries: Vec<EntrySnapshot>,
    pub timestamp: f64,
    pub is_running: bool,
    pub has_final_answer: bool,
    pub started_at: Option<f64>,
    pub worked_for_seconds: Option<f64>,
    pub timed_answer_id: Option<Identifier>,
}
#[derive(Clone, Debug)]
pub enum ActivityRow {
    Activity(ActivityGroup),
    Entry {
        entry: EntrySnapshot,
        hide_answer_metadata: bool,
    },
}
pub fn reasoning(entry: &EntrySnapshot) -> bool {
    entry.kind == EntryKind::Reasoning
        && !entry.body.trim().is_empty()
        && entry.body.trim() != "Reasoning completed."
}
pub fn disclosure_open(running: bool, final_answer: bool, manual: Option<bool>) -> bool {
    manual.unwrap_or(running && !final_answer)
}
pub fn format_duration(seconds: f64) -> String {
    let mut remaining = if seconds.is_finite() {
        seconds.max(0.0).floor() as u64
    } else {
        0
    };
    let mut parts = Vec::new();
    for (label, unit) in [
        ("w", 604800),
        ("d", 86400),
        ("h", 3600),
        ("m", 60),
        ("s", 1),
    ] {
        let count = remaining / unit;
        if count > 0 {
            parts.push(format!("{count}{label}"));
        }
        remaining %= unit;
        if parts.len() == 2 {
            break;
        }
    }
    if parts.is_empty() {
        "0s".into()
    } else {
        parts.join(" ")
    }
}
pub fn label(group: &ActivityGroup, now: f64) -> String {
    if let Some(seconds) = group.worked_for_seconds {
        format!("Worked for {}", format_duration(seconds))
    } else if group.is_running {
        group
            .started_at
            .map(|start| format!("Working for {}", format_duration(now - start)))
            .unwrap_or_else(|| "Working…".into())
    } else {
        "Worked".into()
    }
}
pub fn timeline(task: &TaskSnapshot) -> Vec<ActivityRow> {
    let busy = task.status == "Running" || task.active_turn_started_at.is_some();
    let last_user = task
        .entries
        .iter()
        .rev()
        .find(|e| e.kind == EntryKind::User);
    let active = busy
        .then(|| {
            task.active_activity_group_id
                .as_ref()
                .or_else(|| last_user.and_then(|e| e.activity_group_id.as_ref().or(Some(&e.id))))
        })
        .flatten()
        .map(|i| i.as_str().to_owned());
    let mut owners = HashMap::new();
    let mut groups: HashMap<String, ActivityGroup> = HashMap::new();
    let mut legacy = format!("legacy:{}", task.id.as_str());
    for entry in &task.entries {
        if entry.kind == EntryKind::User {
            legacy = entry
                .activity_group_id
                .as_ref()
                .unwrap_or(&entry.id)
                .as_str()
                .into();
        }
        let owner = entry
            .activity_group_id
            .as_ref()
            .map(|i| i.as_str())
            .unwrap_or(&legacy)
            .to_owned();
        owners.insert(entry.id.clone(), owner.clone());
        if (entry.kind == EntryKind::User && active.as_ref() == Some(&owner))
            || reasoning(entry)
            || entry.kind == EntryKind::Tool
        {
            let group = groups
                .entry(owner.clone())
                .or_insert_with(|| ActivityGroup {
                    id: owner.clone(),
                    entries: Vec::new(),
                    timestamp: entry.timestamp,
                    is_running: active.as_ref() == Some(&owner),
                    has_final_answer: false,
                    started_at: if active.as_ref() == Some(&owner) {
                        task.active_turn_started_at
                    } else {
                        None
                    },
                    worked_for_seconds: None,
                    timed_answer_id: None,
                });
            if reasoning(entry) || entry.kind == EntryKind::Tool {
                group.entries.push(entry.clone());
            }
        }
    }
    for entry in &task.entries {
        if entry.kind != EntryKind::Assistant || entry.body.trim().is_empty() {
            continue;
        }
        if let Some(group) = owners.get(&entry.id).and_then(|o| groups.get_mut(o)) {
            if entry.assistant_phase == Some(AssistantPhase::FinalAnswer) {
                group.has_final_answer = true;
            }
            if !group.is_running
                && !entry.is_streaming.unwrap_or(false)
                && entry
                    .worked_for_seconds
                    .is_some_and(|s| s.is_finite() && s >= 0.0)
            {
                group.worked_for_seconds = entry.worked_for_seconds;
                group.timed_answer_id = Some(entry.id.clone());
                group.has_final_answer = true;
                group.timestamp = entry.timestamp;
            }
        }
    }
    let mut rows = Vec::new();
    let mut inserted = HashSet::new();
    fn insert(
        rows: &mut Vec<ActivityRow>,
        inserted: &mut HashSet<String>,
        groups: &HashMap<String, ActivityGroup>,
        owner: &str,
    ) {
        if let Some(group) = groups.get(owner)
            && !inserted.contains(owner)
            && (!group.entries.is_empty() || group.is_running)
        {
            rows.push(ActivityRow::Activity(group.clone()));
            inserted.insert(owner.into());
        }
    }
    for entry in &task.entries {
        let owner = &owners[&entry.id];
        if entry.kind == EntryKind::Reasoning {
            if reasoning(entry) {
                insert(&mut rows, &mut inserted, &groups, owner);
            }
            continue;
        }
        if entry.kind == EntryKind::Tool {
            insert(&mut rows, &mut inserted, &groups, owner);
            if !entry
                .tool
                .as_ref()
                .is_some_and(|t| matches!(t.status.as_str(), "Failed" | "Needs approval"))
            {
                continue;
            }
        }
        if entry.kind == EntryKind::Assistant && entry.body.trim().is_empty() {
            continue;
        }
        rows.push(ActivityRow::Entry {
            entry: entry.clone(),
            hide_answer_metadata: groups.get(owner).and_then(|g| g.timed_answer_id.as_ref())
                == Some(&entry.id),
        });
        if entry.kind == EntryKind::User {
            insert(&mut rows, &mut inserted, &groups, owner);
        }
    }
    rows
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_disclosure_overrides_and_duration_bounds() {
        assert!(disclosure_open(true, false, None));
        assert!(!disclosure_open(true, true, None));
        assert!(!disclosure_open(true, false, Some(false)));
        assert_eq!(format_duration(90061.0), "1d 1h");
        assert_eq!(format_duration(f64::NAN), "0s");
        assert_eq!(format_duration(-1.0), "0s");
    }
}
