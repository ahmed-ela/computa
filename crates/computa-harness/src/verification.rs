//! Verification plans retain exact AX identity and pre-input baselines. Labels
//! and indices are never promoted to identity across observations.
use computa_contracts::tools::{Postcondition, PostconditionKind};
use computa_macos::{AxNode, AxSnapshot};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use uuid::Uuid;

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum VerificationError {
    #[error("The intended postcondition does not match the observed target.")]
    InvalidRequest,
    #[error("The verification target was not exposed in the current observation.")]
    Unexposed,
    #[error("The control has no retained exact AX identity or unique stable identifier.")]
    UnstableIdentity,
    #[error("The verification identity is ambiguous.")]
    AmbiguousIdentity,
    #[error("The bound process, document or observation scope changed.")]
    WrongTarget,
    #[error("The native baseline changed before input. Observe again; no input was sent.")]
    BaselineChanged,
    #[error(
        "That rendered property already held before input; the observation does not verify a changed outcome."
    )]
    UnchangedProperty,
    #[error("The declared property was not observed. No action was repeated.")]
    NotObserved,
    #[error("The evidence is incomplete and cannot prove this postcondition.")]
    Incomplete,
    #[error("Verification requires a fresh live observation.")]
    Stale,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum SemanticMutation {
    Press,
    SetText(String),
    OtherAction(String),
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Anchor {
    pub token: Uuid,
    pub identifier: Option<String>,
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub semantics: String,
    pub include_value: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VerificationPlan {
    pub kind: PostconditionKind,
    pub target_generation: Uuid,
    pub process_identifier: i32,
    pub document: Option<String>,
    pub expected: String,
    pub action: Anchor,
    pub result: Anchor,
    pub baseline: String,
    pub baseline_snapshot_id: Uuid,
    pub baseline_satisfied: bool,
    pub action_selection_baseline: Option<bool>,
    pub detail_baseline_matched: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VerifiedProperty {
    pub property: String,
    pub expected_value: String,
    pub observation_id: Uuid,
}
fn digest(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}
pub fn canonical(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn semantics(node: &AxNode, include_value: bool) -> String {
    digest(
        &serde_json::to_string(&(
            node.role.as_deref(),
            node.subrole.as_deref(),
            node.title.as_deref(),
            node.element_description.as_deref(),
            node.help.as_deref(),
            node.link_url.as_deref(),
            include_value.then_some(node.value.as_deref()),
        ))
        .unwrap(),
    )
}
fn anchor(
    node: &AxNode,
    snapshot: &AxSnapshot,
    include_value: bool,
) -> Result<Anchor, VerificationError> {
    if node.identity.is_nil() {
        return Err(VerificationError::UnstableIdentity);
    }
    let identifier = node
        .identifier
        .as_ref()
        .filter(|id| {
            !snapshot.source_truncated
                && !id.is_empty()
                && snapshot
                    .elements
                    .iter()
                    .filter(|n| n.identifier.as_ref() == Some(id))
                    .count()
                    == 1
        })
        .cloned();
    Ok(Anchor {
        token: node.identity,
        identifier,
        role: node.role.clone(),
        subrole: node.subrole.clone(),
        semantics: semantics(node, include_value),
        include_value,
    })
}
fn resolve<'a>(
    anchor: &Anchor,
    snapshot: &'a AxSnapshot,
    check_semantics: bool,
) -> Result<&'a AxNode, VerificationError> {
    let by_token: Vec<_> = snapshot
        .elements
        .iter()
        .filter(|n| n.identity == anchor.token)
        .collect();
    let matches = if by_token.is_empty() {
        if snapshot.source_truncated {
            return Err(VerificationError::Incomplete);
        }
        let id = anchor
            .identifier
            .as_ref()
            .ok_or(VerificationError::UnstableIdentity)?;
        snapshot
            .elements
            .iter()
            .filter(|n| {
                n.identifier.as_ref() == Some(id)
                    && n.role == anchor.role
                    && n.subrole == anchor.subrole
            })
            .collect()
    } else {
        by_token
    };
    if matches.len() != 1 {
        return Err(if matches.is_empty() {
            VerificationError::WrongTarget
        } else {
            VerificationError::AmbiguousIdentity
        });
    }
    let node = matches[0];
    if node.role != anchor.role || node.subrole != anchor.subrole {
        return Err(VerificationError::WrongTarget);
    }
    if check_semantics && semantics(node, anchor.include_value) != anchor.semantics {
        return Err(VerificationError::BaselineChanged);
    }
    Ok(node)
}
fn region_text(snapshot: &AxSnapshot, node: &AxNode) -> Result<String, VerificationError> {
    if snapshot.source_truncated || node.children_truncated || node.text_truncated {
        return Err(VerificationError::Incomplete);
    }
    let descendants = snapshot.descendants(node.index);
    if descendants
        .iter()
        .any(|n| n.children_truncated || n.text_truncated)
    {
        return Err(VerificationError::Incomplete);
    }
    let text = descendants
        .iter()
        .filter(|n| {
            !snapshot
                .elements
                .iter()
                .any(|child| child.parent_index == Some(n.index))
        })
        .filter_map(|n| {
            [
                n.value.as_deref(),
                n.title.as_deref(),
                n.element_description.as_deref(),
            ]
            .into_iter()
            .flatten()
            .map(canonical)
            .find(|v| !v.is_empty())
        })
        .collect::<Vec<_>>()
        .join(" ");
    if text.len() > 8192 {
        return Err(VerificationError::Incomplete);
    }
    Ok(canonical(&text))
}
fn property(
    kind: PostconditionKind,
    node: &AxNode,
    snapshot: &AxSnapshot,
) -> Result<String, VerificationError> {
    match kind {
        PostconditionKind::Selection => node
            .is_selected
            .map(|v| v.to_string())
            .ok_or(VerificationError::Incomplete),
        PostconditionKind::Value => node
            .value
            .clone()
            .filter(|v| v.len() <= 8192 && !node.text_truncated)
            .ok_or(VerificationError::Incomplete),
        PostconditionKind::RegionText | PostconditionKind::DetailView => {
            region_text(snapshot, node)
        }
        _ => Err(VerificationError::InvalidRequest),
    }
}
fn fields(node: &AxNode) -> Vec<String> {
    [
        node.value.as_deref(),
        node.title.as_deref(),
        node.element_description.as_deref(),
    ]
    .into_iter()
    .flatten()
    .map(canonical)
    .filter(|s| !s.is_empty())
    .collect()
}
fn require_complete(snapshot: &AxSnapshot) -> Result<(), VerificationError> {
    if snapshot.source_truncated
        || snapshot
            .elements
            .iter()
            .any(|n| n.children_truncated || n.text_truncated)
    {
        Err(VerificationError::Incomplete)
    } else {
        Ok(())
    }
}
fn detail_matches(
    snapshot: &AxSnapshot,
    region: &AxNode,
    expected: &str,
) -> Result<usize, VerificationError> {
    require_complete(snapshot)?;
    Ok(snapshot
        .descendants(region.index)
        .iter()
        .filter(|node| {
            !snapshot
                .elements
                .iter()
                .any(|child| child.parent_index == Some(node.index))
                && fields(node).iter().any(|value| value == expected)
        })
        .count())
}
fn unique_target_text(
    snapshot: &AxSnapshot,
    target: &AxNode,
    expected: &str,
) -> Result<(), VerificationError> {
    require_complete(snapshot)?;
    let mut matching = HashSet::new();
    for node in &snapshot.elements {
        if fields(node).iter().any(|value| value == expected) {
            let mut current = Some(node.index);
            let mut seen = HashSet::new();
            while let Some(index) = current {
                if seen.len() > 128 || !seen.insert(index) {
                    return Err(VerificationError::Incomplete);
                }
                let ancestor = snapshot
                    .node(index)
                    .map_err(|_| VerificationError::Incomplete)?;
                if ancestor.role == target.role {
                    matching.insert(index);
                }
                current = ancestor.parent_index;
            }
        }
    }
    if !matching.contains(&target.index) {
        return Err(VerificationError::WrongTarget);
    }
    if matching.len() != 1 {
        return Err(VerificationError::AmbiguousIdentity);
    }
    Ok(())
}
impl VerificationPlan {
    pub fn compile(
        request: Option<&Postcondition>,
        mutation: &SemanticMutation,
        element_index: usize,
        snapshot: &AxSnapshot,
        exposed: &HashSet<usize>,
    ) -> Result<Self, VerificationError> {
        if !exposed.contains(&element_index) {
            return Err(VerificationError::Unexposed);
        }
        let action = snapshot
            .node(element_index)
            .map_err(|_| VerificationError::Unexposed)?;
        if action.is_enabled == Some(false) {
            return Err(VerificationError::InvalidRequest);
        }
        let inferred = match mutation {
            SemanticMutation::SetText(text) => Some(Postcondition {
                kind: PostconditionKind::Value,
                element_index: Some(element_index),
                detail_element_index: None,
                expected: Some(text.clone()),
            }),
            SemanticMutation::Press if action.is_selected.is_some() => Some(Postcondition {
                kind: PostconditionKind::Selection,
                element_index: Some(element_index),
                detail_element_index: None,
                expected: Some("true".into()),
            }),
            _ => None,
        };
        let request = request
            .or(inferred.as_ref())
            .ok_or(VerificationError::InvalidRequest)?;
        let expected = request
            .expected
            .as_ref()
            .ok_or(VerificationError::InvalidRequest)?;
        if expected.len() > 4096
            || (request.kind != PostconditionKind::Value && expected.trim().is_empty())
        {
            return Err(VerificationError::InvalidRequest);
        }
        let target_index = match request.kind {
            PostconditionKind::Selection => {
                if !matches!(mutation, SemanticMutation::Press)
                    || !matches!(expected.as_str(), "true" | "false")
                    || request.detail_element_index.is_some()
                    || request.element_index.is_some_and(|i| i != element_index)
                {
                    return Err(VerificationError::InvalidRequest);
                }
                element_index
            }
            PostconditionKind::Value => {
                if request.detail_element_index.is_some() {
                    return Err(VerificationError::InvalidRequest);
                }
                if let SemanticMutation::SetText(text) = mutation {
                    if text != expected
                        || !action.is_value_settable
                        || request.element_index.is_some_and(|i| i != element_index)
                    {
                        return Err(VerificationError::InvalidRequest);
                    }
                    element_index
                } else {
                    request
                        .element_index
                        .ok_or(VerificationError::InvalidRequest)?
                }
            }
            PostconditionKind::RegionText => {
                if !matches!(mutation, SemanticMutation::Press)
                    || request.detail_element_index.is_some()
                {
                    return Err(VerificationError::InvalidRequest);
                }
                request
                    .element_index
                    .ok_or(VerificationError::InvalidRequest)?
            }
            PostconditionKind::DetailView => {
                if !matches!(mutation, SemanticMutation::Press) || request.element_index.is_some() {
                    return Err(VerificationError::InvalidRequest);
                }
                request
                    .detail_element_index
                    .ok_or(VerificationError::InvalidRequest)?
            }
            _ => return Err(VerificationError::InvalidRequest),
        };
        if !exposed.contains(&target_index) {
            return Err(VerificationError::Unexposed);
        }
        let target = snapshot
            .node(target_index)
            .map_err(|_| VerificationError::Unexposed)?;
        if matches!(
            request.kind,
            PostconditionKind::RegionText | PostconditionKind::DetailView
        ) && !target.is_region()
        {
            return Err(VerificationError::InvalidRequest);
        }
        if request.kind == PostconditionKind::DetailView
            && (target_index == element_index
                || snapshot
                    .descendants(target_index)
                    .iter()
                    .any(|n| n.index == element_index)
                || snapshot
                    .descendants(element_index)
                    .iter()
                    .any(|n| n.index == target_index))
        {
            return Err(VerificationError::InvalidRequest);
        }
        let expected = if matches!(
            request.kind,
            PostconditionKind::RegionText | PostconditionKind::DetailView
        ) {
            canonical(expected)
        } else {
            expected.clone()
        };
        let baseline = property(request.kind, target, snapshot)?;
        let detail_baseline_matched = if request.kind == PostconditionKind::DetailView {
            unique_target_text(snapshot, action, &expected)?;
            let count = detail_matches(snapshot, target, &expected)?;
            if count > 1 {
                return Err(VerificationError::AmbiguousIdentity);
            }
            count == 1
        } else {
            false
        };
        let satisfied = if request.kind == PostconditionKind::DetailView {
            detail_baseline_matched && action.is_selected != Some(false)
        } else {
            baseline == expected
        };
        Ok(Self {
            kind: request.kind,
            target_generation: snapshot.target_generation,
            process_identifier: snapshot.window.process_identifier,
            document: snapshot.window.document.clone(),
            expected,
            action: anchor(
                action,
                snapshot,
                !matches!(mutation, SemanticMutation::SetText(_)),
            )?,
            result: anchor(target, snapshot, false)?,
            baseline,
            baseline_snapshot_id: snapshot.id,
            baseline_satisfied: satisfied,
            action_selection_baseline: action.is_selected,
            detail_baseline_matched,
        })
    }
    fn check(&self, snapshot: &AxSnapshot) -> Result<(), VerificationError> {
        if snapshot.target_generation != self.target_generation
            || snapshot.window.process_identifier != self.process_identifier
            || snapshot.window.document != self.document
        {
            return Err(VerificationError::WrongTarget);
        }
        Ok(())
    }
    pub fn revalidate(&self, snapshot: &AxSnapshot) -> Result<Uuid, VerificationError> {
        self.check(snapshot)?;
        let action = resolve(&self.action, snapshot, true)?;
        if self.kind == PostconditionKind::DetailView {
            unique_target_text(snapshot, action, &self.expected)?;
        }
        let target = resolve(&self.result, snapshot, false)?;
        if property(self.kind, target, snapshot)? != self.baseline
            || action.is_selected != self.action_selection_baseline
        {
            return Err(VerificationError::BaselineChanged);
        }
        Ok(action.identity)
    }
    pub fn evaluate(&self, snapshot: &AxSnapshot) -> Result<VerifiedProperty, VerificationError> {
        self.check(snapshot)?;
        if snapshot.id == self.baseline_snapshot_id && !self.baseline_satisfied {
            return Err(VerificationError::Stale);
        }
        let target = resolve(&self.result, snapshot, false)?;
        let mut observed = property(self.kind, target, snapshot)?;
        if self.kind == PostconditionKind::DetailView {
            let action = resolve(&self.action, snapshot, false)?;
            unique_target_text(snapshot, action, &self.expected)?;
            if self.action_selection_baseline.is_some() && action.is_selected != Some(true) {
                return Err(VerificationError::NotObserved);
            }
            let count = detail_matches(snapshot, target, &self.expected)?;
            if count != 1 {
                return Err(if count > 1 {
                    VerificationError::AmbiguousIdentity
                } else {
                    VerificationError::NotObserved
                });
            }
            if !self.baseline_satisfied
                && observed == self.baseline
                && action.is_selected == self.action_selection_baseline
            {
                return Err(VerificationError::NotObserved);
            }
            observed = self.expected.clone();
        }
        if observed != self.expected {
            return Err(VerificationError::NotObserved);
        }
        Ok(VerifiedProperty {
            property: format!(
                "native:token:{}:{}",
                self.result.token,
                serde_json::to_value(self.kind).unwrap().as_str().unwrap()
            ),
            expected_value: self.expected.clone(),
            observation_id: snapshot.id,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::semantic::fixtures;
    #[test]
    fn set_text_baseline_is_rechecked_and_exact_value_verified() {
        let s = fixtures::snapshot("old");
        let plan = VerificationPlan::compile(
            None,
            &SemanticMutation::SetText("new".into()),
            0,
            &s,
            &HashSet::from([0]),
        )
        .unwrap();
        let mut changed = s.clone();
        changed.id = Uuid::new_v4();
        changed.elements[0].value = Some("third party".into());
        assert_eq!(
            plan.revalidate(&changed),
            Err(VerificationError::BaselineChanged)
        );
        changed.elements[0].value = Some("new".into());
        assert!(plan.evaluate(&changed).is_ok());
    }
    #[test]
    fn labels_and_indices_cannot_replace_ax_identity() {
        let s = fixtures::snapshot("old");
        let plan = VerificationPlan::compile(
            None,
            &SemanticMutation::SetText("new".into()),
            0,
            &s,
            &HashSet::from([0]),
        )
        .unwrap();
        let mut other = s.clone();
        other.id = Uuid::new_v4();
        other.elements[0].identity = Uuid::new_v4();
        other.elements[0].identifier = None;
        other.elements[0].value = Some("new".into());
        assert!(plan.evaluate(&other).is_err());
    }
    #[test]
    fn truncated_regions_cannot_prove_absence_or_postconditions() {
        let mut s = fixtures::snapshot("old");
        s.elements[0].role = Some("AXGroup".into());
        s.source_truncated = true;
        assert_eq!(
            VerificationPlan::compile(
                Some(&Postcondition {
                    kind: PostconditionKind::RegionText,
                    element_index: Some(0),
                    detail_element_index: None,
                    expected: Some("new".into())
                }),
                &SemanticMutation::Press,
                0,
                &s,
                &HashSet::from([0])
            )
            .unwrap_err(),
            VerificationError::Incomplete
        );
    }
    #[test]
    fn detail_view_proves_one_rendered_leaf_and_retains_unique_action_identity() {
        let mut s = fixtures::snapshot("");
        let template = s.elements[0].clone();
        s.elements.clear();
        let mut root = template.clone();
        root.index = 0;
        root.role = Some("AXWindow".into());
        root.title = Some("Window".into());
        root.value = None;
        root.is_value_settable = false;
        s.elements.push(root);
        let mut action = template.clone();
        action.index = 1;
        action.parent_index = Some(0);
        action.identity = Uuid::new_v4();
        action.role = Some("AXRow".into());
        action.title = Some("Record".into());
        action.value = None;
        action.is_value_settable = false;
        action.is_selected = Some(false);
        s.elements.push(action);
        let mut detail = template.clone();
        detail.index = 2;
        detail.parent_index = Some(0);
        detail.identity = Uuid::new_v4();
        detail.role = Some("AXGroup".into());
        detail.title = Some("Details".into());
        detail.value = None;
        detail.is_value_settable = false;
        s.elements.push(detail);
        let mut leaf = template;
        leaf.index = 3;
        leaf.parent_index = Some(2);
        leaf.identity = Uuid::new_v4();
        leaf.role = Some("AXStaticText".into());
        leaf.title = Some("Old record".into());
        leaf.value = None;
        leaf.is_value_settable = false;
        s.elements.push(leaf);
        let request = Postcondition {
            kind: PostconditionKind::DetailView,
            element_index: None,
            detail_element_index: Some(2),
            expected: Some("Record".into()),
        };
        let plan = VerificationPlan::compile(
            Some(&request),
            &SemanticMutation::Press,
            1,
            &s,
            &HashSet::from([1, 2]),
        )
        .unwrap();
        assert!(!plan.baseline_satisfied);
        let mut fresh = s.clone();
        fresh.id = Uuid::new_v4();
        fresh.elements[1].is_selected = Some(true);
        fresh.elements[3].title = Some("Record".into());
        assert!(plan.evaluate(&fresh).is_ok());
        let mut duplicate = fresh.elements[3].clone();
        duplicate.index = 4;
        duplicate.identity = Uuid::new_v4();
        fresh.elements.push(duplicate);
        assert_eq!(
            plan.evaluate(&fresh),
            Err(VerificationError::AmbiguousIdentity)
        );
        let mut virtualized = s;
        virtualized.id = Uuid::new_v4();
        virtualized.elements[1].title = Some("Different record".into());
        assert!(plan.revalidate(&virtualized).is_err());
    }
}
