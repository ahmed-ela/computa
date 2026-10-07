//! Compatibility proof for unplanned foreground input. A fresh rendered
//! property may reconcile delivery; neither a new index nor an unseen field is
//! evidence that the input changed anything.
use crate::{
    semantic::ReadPublication,
    verification::{VerificationError, VerifiedProperty},
};
use computa_macos::{AxNode, AxSnapshot, BoundApplication};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(crate) struct LegacyBaseline {
    generation: Uuid,
    window_token: Uuid,
    pid: i32,
    snapshot_id: Uuid,
    captured_at: f64,
    properties: BTreeMap<String, String>,
}
fn fingerprint(text: &str) -> String {
    hex::encode(Sha256::digest(text.as_bytes()))
}
struct IdentityContext<'a> {
    snapshot: &'a AxSnapshot,
    by_index: HashMap<usize, &'a AxNode>,
    tokens: HashMap<Uuid, usize>,
    identifiers: HashMap<&'a str, usize>,
}
impl<'a> IdentityContext<'a> {
    fn new(snapshot: &'a AxSnapshot) -> Self {
        let mut by_index = HashMap::new();
        let mut duplicates = HashSet::new();
        let mut tokens = HashMap::new();
        let mut identifiers = HashMap::new();
        for node in &snapshot.elements {
            if by_index.insert(node.index, node).is_some() {
                duplicates.insert(node.index);
            }
            *tokens.entry(node.identity).or_default() += 1;
            if let Some(id) = node.identifier.as_deref() {
                *identifiers.entry(id).or_default() += 1;
            }
        }
        for index in duplicates {
            by_index.remove(&index);
        }
        Self {
            snapshot,
            by_index,
            tokens,
            identifiers,
        }
    }
    fn identity(&self, node: &AxNode) -> Result<String, VerificationError> {
        if !self.by_index.contains_key(&node.index) {
            return Err(VerificationError::AmbiguousIdentity);
        }
        let identifier = if !node.identity.is_nil() && self.tokens.get(&node.identity) == Some(&1) {
            format!("token:{}", node.identity)
        } else if !self.snapshot.source_truncated
            && let Some(identifier) = node
                .identifier
                .as_ref()
                .filter(|identifier| !identifier.is_empty())
            && self.identifiers.get(identifier.as_str()) == Some(&1)
        {
            format!("ax:{identifier}")
        } else {
            return Err(VerificationError::UnstableIdentity);
        };
        let mut current = node;
        let mut seen = HashSet::new();
        let mut document = "native-window";
        loop {
            if seen.len() >= 64 || !seen.insert(current.index) {
                return Err(VerificationError::Incomplete);
            }
            if matches!(current.role.as_deref(), Some("AXWebArea" | "AXDocument")) {
                document = current
                    .link_url
                    .as_deref()
                    .filter(|url| url::Url::parse(url).is_ok())
                    .ok_or(VerificationError::Incomplete)?;
                break;
            }
            let Some(parent) = current.parent_index else {
                break;
            };
            current = self
                .by_index
                .get(&parent)
                .copied()
                .ok_or(VerificationError::Incomplete)?;
        }
        Ok(fingerprint(
            &serde_json::to_string(&[document, identifier.as_str()]).unwrap(),
        ))
    }
}
fn value(node: &AxNode, property: &str) -> Option<String> {
    match property {
        "text" => [node.title.as_deref(), node.element_description.as_deref()]
            .into_iter()
            .flatten()
            .find(|text| !text.is_empty())
            .map(str::to_owned),
        "value" => node.value.clone(),
        _ => None,
    }
}
fn complete(publication: &ReadPublication, node: &AxNode, property: &str) -> bool {
    let field = if property == "text" { "label" } else { "value" };
    publication.receipt.exposures.iter().any(|exposure| {
        exposure.node_id == node.identity.to_string()
            && exposure.field == field
            && exposure.start_utf8 == 0
            && exposure.end_utf8 == exposure.total_utf8
    }) && (property != "text" || value(node, property).as_deref() == Some(node.label().as_str()))
}
impl LegacyBaseline {
    pub(crate) fn capture(
        publication: &ReadPublication,
        fresh: &AxSnapshot,
        binding: &BoundApplication,
    ) -> Option<Self> {
        if publication.snapshot.target_generation != binding.generation
            || fresh.target_generation != binding.generation
            || fresh.window.process_identifier != binding.application.process_identifier
            || fresh.window.window_id != publication.snapshot.window.window_id
        {
            return None;
        }
        let mut properties = BTreeMap::new();
        let mut bytes = 0usize;
        let source_context = IdentityContext::new(&publication.snapshot);
        let fresh_context = IdentityContext::new(fresh);
        let mut live: HashMap<String, Vec<&AxNode>> = HashMap::new();
        for node in &fresh.elements {
            if let Ok(key) = fresh_context.identity(node) {
                live.entry(key).or_default().push(node);
            }
        }
        for node in &publication.snapshot.elements {
            if !publication.exposed.contains(&node.index) {
                continue;
            }
            let Ok(key) = source_context.identity(node) else {
                continue;
            };
            let Some(fresh_node) = live
                .get(&key)
                .filter(|nodes| nodes.len() == 1)
                .map(|nodes| nodes[0])
            else {
                continue;
            };
            for field in ["text", "value"] {
                if !complete(publication, node, field) {
                    continue;
                }
                let Some(value) = value(fresh_node, field).filter(|value| value.len() <= 8192)
                else {
                    continue;
                };
                let property = format!("native:{key}:{field}");
                let additional = property.len() + value.len();
                if properties.len() >= 128 || bytes + additional > 32 * 1024 {
                    continue;
                }
                bytes += additional;
                properties.insert(property, fingerprint(&value));
            }
        }
        Some(Self {
            generation: binding.generation,
            window_token: binding.window_token,
            pid: binding.application.process_identifier,
            snapshot_id: fresh.id,
            captured_at: fresh.captured_at,
            properties,
        })
    }
    pub(crate) fn verify(
        &self,
        publication: &ReadPublication,
        index: usize,
        field: &str,
        expected: &str,
        fresh: &AxSnapshot,
        binding: &BoundApplication,
    ) -> Result<VerifiedProperty, VerificationError> {
        if !["text", "value"].contains(&field) || expected.is_empty() || expected.len() > 8192 {
            return Err(VerificationError::InvalidRequest);
        }
        if binding.generation != self.generation
            || binding.window_token != self.window_token
            || binding.application.process_identifier != self.pid
            || fresh.target_generation != self.generation
            || fresh.window.process_identifier != self.pid
        {
            return Err(VerificationError::WrongTarget);
        }
        if fresh.id == self.snapshot_id
            || fresh.id == publication.snapshot.id
            || fresh.captured_at < self.captured_at
        {
            return Err(VerificationError::Stale);
        }
        if !publication.exposed.contains(&index) {
            return Err(VerificationError::Unexposed);
        }
        let node = publication
            .snapshot
            .node(index)
            .map_err(|_| VerificationError::Unexposed)?;
        if !complete(publication, node, field) || value(node, field).as_deref() != Some(expected) {
            return Err(VerificationError::NotObserved);
        }
        let key = IdentityContext::new(&publication.snapshot).identity(node)?;
        let property = format!("native:{key}:{field}");
        let previous = self
            .properties
            .get(&property)
            .ok_or(VerificationError::Incomplete)?;
        if previous == &fingerprint(expected) {
            return Err(VerificationError::UnchangedProperty);
        }
        let context = IdentityContext::new(fresh);
        let matches: Vec<_> = fresh
            .elements
            .iter()
            .filter(|candidate| context.identity(candidate).ok().as_ref() == Some(&key))
            .collect();
        if matches.len() != 1 {
            return Err(VerificationError::AmbiguousIdentity);
        }
        if value(matches[0], field).as_deref() != Some(expected) {
            return Err(VerificationError::NotObserved);
        }
        Ok(VerifiedProperty {
            property,
            expected_value: expected.into(),
            observation_id: fresh.id,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::semantic::{SemanticReader, fixtures};
    use computa_contracts::tools::ReadArgs;
    use computa_macos::RunningApplication;
    fn binding(snapshot: &AxSnapshot) -> BoundApplication {
        BoundApplication {
            application: RunningApplication {
                process_identifier: 7,
                bundle_identifier: Some("test.app".into()),
                localized_name: Some("Test".into()),
                is_active: true,
                is_terminated: false,
                activation_policy: 0,
                launch_time: Some(1.0),
            },
            window: snapshot.window.clone(),
            window_token: Uuid::new_v4(),
            generation: snapshot.target_generation,
            activated: true,
        }
    }
    #[test]
    fn proof_requires_changed_complete_original_property_and_same_evidence_identity() {
        let before = fixtures::snapshot("old");
        let binding = binding(&before);
        let mut reader = SemanticReader::default();
        let publication = reader
            .start(before.clone(), ReadArgs::default(), None, 4096)
            .unwrap();
        let baseline = LegacyBaseline::capture(&publication, &before, &binding).unwrap();
        let mut changed = before.clone();
        changed.id = Uuid::new_v4();
        changed.elements[0].value = Some("new".into());
        let after = reader
            .start(changed.clone(), ReadArgs::default(), None, 4096)
            .unwrap();
        let mut fresh = changed.clone();
        fresh.id = Uuid::new_v4();
        assert!(
            baseline
                .verify(&after, 0, "value", "new", &fresh, &binding)
                .is_ok()
        );
        let mut replacement = fresh.clone();
        replacement.elements[0].identity = Uuid::new_v4();
        assert!(
            baseline
                .verify(&after, 0, "value", "new", &replacement, &binding)
                .is_err()
        );
        assert!(
            baseline
                .verify(&publication, 0, "value", "old", &fresh, &binding)
                .is_err()
        );
        let mut hidden = after.clone();
        hidden
            .receipt
            .exposures
            .retain(|field| field.field != "value");
        assert!(
            baseline
                .verify(&hidden, 0, "value", "new", &fresh, &binding)
                .is_err()
        );
        assert!(
            baseline
                .verify(&after, 0, "text", "new", &fresh, &binding)
                .is_err()
        );
    }
    #[test]
    fn copied_tokens_in_a_different_document_or_target_cannot_reconcile_input() {
        let mut before = fixtures::snapshot("old");
        let root = &mut before.elements[0];
        root.role = Some("AXWebArea".into());
        root.link_url = Some("https://example.test/one".into());
        let binding = binding(&before);
        let mut reader = SemanticReader::default();
        let publication = reader
            .start(before.clone(), ReadArgs::default(), None, 4096)
            .unwrap();
        let baseline = LegacyBaseline::capture(&publication, &before, &binding).unwrap();
        let mut changed = before.clone();
        changed.id = Uuid::new_v4();
        changed.elements[0].value = Some("new".into());
        changed.elements[0].link_url = Some("https://example.test/two".into());
        let after = reader
            .start(changed.clone(), ReadArgs::default(), None, 4096)
            .unwrap();
        changed.id = Uuid::new_v4();
        assert!(
            baseline
                .verify(&after, 0, "value", "new", &changed, &binding)
                .is_err()
        );
        let mut other = binding.clone();
        other.window_token = Uuid::new_v4();
        assert!(
            baseline
                .verify(&after, 0, "value", "new", &changed, &other)
                .is_err()
        );
    }
}
