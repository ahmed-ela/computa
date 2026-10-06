use computa_contracts::{
    Identifier,
    ui::{PromptReceiptSnapshot, QueuedPromptSnapshot},
};
pub const MAX_PROMPT_BYTES: usize = 200_000;
pub fn valid_prompt(value: &str) -> bool {
    let value = value.trim();
    !value.is_empty() && value.len() <= MAX_PROMPT_BYTES && !value.contains('\0')
}
pub fn submit_key(key: &str, shift: bool, composing: bool, code: u32, repeat: bool) -> bool {
    key == "Enter" && !shift && !composing && code != 229 && !repeat
}
#[derive(Clone, Debug)]
pub struct PendingSubmission {
    pub request_id: Identifier,
    pub draft: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReceiptResolution {
    pub accepted: bool,
    pub draft: String,
    pub error: Option<String>,
}
pub fn resolve_receipt(
    current: &str,
    pending: &PendingSubmission,
    task: &Identifier,
    receipts: &[PromptReceiptSnapshot],
) -> Option<ReceiptResolution> {
    let receipt = receipts
        .iter()
        .find(|r| r.id == pending.request_id && r.task_id == *task)?;
    Some(if receipt.accepted {
        ReceiptResolution {
            accepted: true,
            draft: if current == pending.draft {
                String::new()
            } else {
                current.into()
            },
            error: None,
        }
    } else {
        ReceiptResolution {
            accepted: false,
            draft: current.into(),
            error: Some("Message was not accepted. Try again.".into()),
        }
    })
}
pub fn reorder(
    items: &[QueuedPromptSnapshot],
    id: &Identifier,
    before: Option<&Identifier>,
) -> Option<Vec<QueuedPromptSnapshot>> {
    if before == Some(id) {
        return None;
    }
    let moving = items.iter().find(|i| i.id == *id)?.clone();
    let mut result: Vec<_> = items.iter().filter(|i| i.id != *id).cloned().collect();
    let index = match before {
        Some(before) => result.iter().position(|i| i.id == *before)?,
        None => result.len(),
    };
    result.insert(index, moving);
    Some(result)
}
pub fn move_before(
    items: &[QueuedPromptSnapshot],
    id: &Identifier,
    direction: i32,
) -> Option<Option<Identifier>> {
    if !matches!(direction, -1 | 1) {
        return None;
    }
    let index = items.iter().position(|i| i.id == *id)?;
    let destination = index.checked_add_signed(direction as isize)?;
    if destination >= items.len() {
        return None;
    }
    let mut result = items.to_vec();
    let moving = result.remove(index);
    result.insert(destination, moving);
    Some(result.get(destination + 1).map(|i| i.id.clone()))
}
pub fn drop_before(
    items: &[QueuedPromptSnapshot],
    id: &Identifier,
    target: &Identifier,
    after: bool,
) -> Option<Option<Identifier>> {
    if id == target || !items.iter().any(|i| i.id == *id) {
        return None;
    }
    let remaining: Vec<_> = items.iter().filter(|i| i.id != *id).collect();
    let index = remaining.iter().position(|i| i.id == *target)?;
    Some(if after {
        remaining.get(index + 1).map(|i| i.id.clone())
    } else {
        Some(target.clone())
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use computa_contracts::ui::QueuedPromptStatus;
    fn id(s: &str) -> Identifier {
        Identifier::new(s).unwrap()
    }
    fn items() -> Vec<QueuedPromptSnapshot> {
        ["a", "b", "c"]
            .into_iter()
            .map(|s| QueuedPromptSnapshot {
                id: id(s),
                text: s.into(),
                status: QueuedPromptStatus::Queued,
                error: None,
            })
            .collect()
    }
    #[test]
    fn acknowledgements_preserve_new_and_other_task_drafts() {
        let pending = PendingSubmission {
            request_id: id("req"),
            draft: "first".into(),
        };
        let receipts = vec![PromptReceiptSnapshot {
            id: id("req"),
            task_id: id("task"),
            accepted: true,
        }];
        assert!(resolve_receipt("first", &pending, &id("other"), &receipts).is_none());
        assert_eq!(
            resolve_receipt("second", &pending, &id("task"), &receipts)
                .unwrap()
                .draft,
            "second"
        );
        assert_eq!(
            resolve_receipt("first", &pending, &id("task"), &receipts)
                .unwrap()
                .draft,
            ""
        );
    }
    #[test]
    fn unicode_byte_limit_and_ime_enter() {
        assert!(valid_prompt(&"x".repeat(MAX_PROMPT_BYTES)));
        assert!(!valid_prompt(&"é".repeat(MAX_PROMPT_BYTES)));
        assert!(!submit_key("Enter", false, true, 13, false));
        assert!(!submit_key("Enter", false, false, 229, false));
        assert!(!submit_key("Enter", true, false, 13, false));
        assert!(submit_key("Enter", false, false, 13, false));
    }
    #[test]
    fn keyboard_and_pointer_moves_share_before_contract() {
        let queue = items();
        assert_eq!(move_before(&queue, &id("b"), -1), Some(Some(id("a"))));
        assert_eq!(move_before(&queue, &id("b"), 1), Some(None));
        assert_eq!(drop_before(&queue, &id("a"), &id("c"), true), Some(None));
        assert!(reorder(&queue, &id("a"), Some(&id("missing"))).is_none());
    }
}
