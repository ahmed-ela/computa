//! UTF-8 bounded semantic publication with opaque cursor and action references.
//! A captured but unpublished field grants neither coverage nor action authority.
use crate::formatter::{self, FormatterOptions, RowContext};
use computa_contracts::tools::{ReadArgs, ReadView};
use computa_macos::{AxNode, AxSnapshot};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FieldExposure {
    #[serde(rename = "nodeID")]
    pub node_id: String,
    pub field: String,
    #[serde(rename = "startUTF8")]
    pub start_utf8: usize,
    #[serde(rename = "endUTF8")]
    pub end_utf8: usize,
    #[serde(rename = "totalUTF8")]
    pub total_utf8: usize,
    pub kind: String,
    pub provenance: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReadReceipt {
    pub id: Uuid,
    #[serde(rename = "sourceID")]
    pub source_id: Uuid,
    pub target_generation: String,
    pub consistency: String,
    pub view: ReadView,
    pub query: Option<String>,
    #[serde(rename = "subtreeNodeID")]
    pub subtree_node_id: Option<String>,
    pub selected_element_count: usize,
    pub selected_field_count: usize,
    pub source_truncated: bool,
    pub field_truncated: bool,
    pub output_truncated: bool,
    pub exposures: Vec<FieldExposure>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReferenceCapability {
    Action(String),
    Field,
    Link,
    Region,
}
#[derive(Clone, Debug)]
pub struct ModelReference {
    pub snapshot_id: Uuid,
    pub index: usize,
    pub identity: Uuid,
    pub capability: ReferenceCapability,
}
#[derive(Clone, Debug)]
pub struct ReadPublication {
    pub text: String,
    pub receipt: ReadReceipt,
    pub snapshot: AxSnapshot,
    pub exposed: HashSet<usize>,
    pub references: HashMap<String, ModelReference>,
    pub next_cursor: Option<Uuid>,
}
#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum ReadError {
    #[error(
        "The semantic read cursor is stale or belongs to another observation. Start a fresh read."
    )]
    StaleCursor,
    #[error("A cursor owns its original filters and subtree; it cannot be repurposed.")]
    InvalidContinuation,
    #[error("Subtree reads require both the current snapshot_id and an exposed element_index.")]
    UnexposedSubtree,
    #[error(
        "overview is a browser-only view. Native apps support all, content, headings and links."
    )]
    NativeOverview,
    #[error("The semantic output budget is too small for a complete record.")]
    OutputBudget,
    #[error("The read request is invalid.")]
    InvalidRequest,
}
#[derive(Clone, Debug)]
struct Field {
    index: usize,
    field: &'static str,
    text: String,
    offset: usize,
}
#[derive(Clone, Debug)]
struct RetainedRead {
    snapshot: AxSnapshot,
    request: ReadArgs,
    selected: HashSet<usize>,
    fields: Vec<Field>,
    next: usize,
    cursor: Uuid,
    browser: bool,
    root: Option<usize>,
    contexts: HashMap<usize, RowContext>,
    provenance: HashMap<usize, &'static str>,
    kinds: HashMap<usize, &'static str>,
}
#[derive(Default)]
pub struct SemanticReader {
    retained: Option<RetainedRead>,
}
impl SemanticReader {
    pub fn invalidate(&mut self) {
        self.retained = None
    }
    pub fn start(
        &mut self,
        snapshot: AxSnapshot,
        args: ReadArgs,
        exposed: Option<&HashSet<usize>>,
        maximum_bytes: usize,
    ) -> Result<ReadPublication, ReadError> {
        self.start_platform(snapshot, args, exposed, maximum_bytes, false)
    }
    pub fn start_browser(
        &mut self,
        snapshot: AxSnapshot,
        args: ReadArgs,
        exposed: Option<&HashSet<usize>>,
        maximum_bytes: usize,
    ) -> Result<ReadPublication, ReadError> {
        self.start_platform(snapshot, args, exposed, maximum_bytes, true)
    }
    fn start_platform(
        &mut self,
        snapshot: AxSnapshot,
        args: ReadArgs,
        exposed: Option<&HashSet<usize>>,
        maximum_bytes: usize,
        browser: bool,
    ) -> Result<ReadPublication, ReadError> {
        if args.cursor.is_some() {
            return Err(ReadError::InvalidContinuation);
        }
        if args.view == Some(ReadView::Overview) && !browser {
            return Err(ReadError::NativeOverview);
        }
        if args
            .query
            .as_ref()
            .is_some_and(|q| q.trim().is_empty() || q.chars().count() > 200)
        {
            return Err(ReadError::InvalidRequest);
        }
        let subtree = match (&args.snapshot_id, args.element_index) {
            (None, None) => None,
            (Some(id), Some(index))
                if Uuid::parse_str(id).ok() == Some(snapshot.id)
                    && exposed.is_some_and(|e| e.contains(&index)) =>
            {
                Some(index)
            }
            _ => return Err(ReadError::UnexposedSubtree),
        };
        let candidates: Vec<_> = if let Some(index) = subtree {
            snapshot.descendants(index)
        } else {
            snapshot.elements.iter().collect()
        };
        let view = args.view.unwrap_or(ReadView::All);
        let query = args.query.as_ref().map(|q| q.trim().to_lowercase());
        let mut filtered: Vec<_> = candidates
            .into_iter()
            .filter(|node| match view {
                ReadView::All => true,
                ReadView::Content => {
                    node.is_readable() || node.is_region() || node.is_value_settable
                }
                ReadView::Headings => node.is_heading(),
                ReadView::Links => {
                    node.link_url.is_some() || node.role.as_deref() == Some("AXLink")
                }
                ReadView::Overview => {
                    node.is_heading()
                        || node.is_value_settable
                        || !node.actions.is_empty()
                        || node.link_url.is_some()
                }
            })
            .filter(|node| {
                query.as_ref().is_none_or(|q| {
                    [
                        node.label(),
                        node.value.clone().unwrap_or_default(),
                        node.link_url.clone().unwrap_or_default(),
                    ]
                    .iter()
                    .any(|text| text.to_lowercase().contains(q))
                })
            })
            .collect();
        // Rank using the same compact Accessibility presentation as the native
        // harness. The formatter's clipped display never becomes a read receipt:
        // the original fields below retain exact byte offsets and continuations.
        let presentation = formatter::format(
            &snapshot,
            None,
            &FormatterOptions {
                element_limit: 2000,
                field_character_limit: 48,
                action_limit: 6,
                output_limit: 1_000_000,
                prioritizes_relevant_elements: true,
                prioritizes_focused_document: true,
                preferred_text: args.query.clone(),
                compact: true,
                allows_raise: false,
                max_ancestor_depth: 16,
                ..Default::default()
            },
        )
        .map_err(|_| ReadError::InvalidRequest)?;
        let rank: HashMap<_, _> = presentation
            .rows
            .iter()
            .enumerate()
            .map(|(position, row)| (row.index, position))
            .collect();
        filtered.sort_by_key(|node| {
            (
                rank.get(&node.index).copied().unwrap_or(usize::MAX),
                node.index,
            )
        });
        let contexts = presentation
            .rows
            .iter()
            .map(|row| (row.index, row.context.clone()))
            .collect();
        let provenance = presentation
            .rows
            .iter()
            .map(|row| {
                (
                    row.index,
                    row.fields
                        .first()
                        .map_or("unknown", |field| field.provenance),
                )
            })
            .collect();
        let kinds = presentation
            .rows
            .iter()
            .map(|row| {
                (
                    row.index,
                    row.fields.first().map_or("unknown", |field| field.kind),
                )
            })
            .collect();
        let selected = filtered.iter().map(|n| n.index).collect();
        let mut fields = vec![];
        for node in filtered {
            let label = node.label();
            fields.push(Field {
                index: node.index,
                field: "label",
                text: label,
                offset: 0,
            });
            if let Some(value) = &node.value {
                fields.push(Field {
                    index: node.index,
                    field: "value",
                    text: value.clone(),
                    offset: 0,
                })
            }
            if let Some(url) = &node.link_url {
                fields.push(Field {
                    index: node.index,
                    field: "linkURL",
                    text: url.clone(),
                    offset: 0,
                })
            }
        }
        let mut retained = RetainedRead {
            snapshot,
            request: args,
            selected,
            fields,
            next: 0,
            cursor: Uuid::new_v4(),
            browser,
            root: presentation.root,
            contexts,
            provenance,
            kinds,
        };
        // A subtree read expands the exact retained observation selected by its
        // snapshot ID. It performs no new native/browser read and must not claim
        // that captured bytes were revalidated against the live page.
        let publication = publish(&mut retained, maximum_bytes, subtree.is_none())?;
        self.retained = publication.next_cursor.map(|_| retained);
        Ok(publication)
    }
    pub fn continue_read(
        &mut self,
        cursor: Uuid,
        args: Option<&ReadArgs>,
        generation: Uuid,
        maximum_bytes: usize,
    ) -> Result<ReadPublication, ReadError> {
        let retained = self.retained.as_mut().ok_or(ReadError::StaleCursor)?;
        if retained.cursor != cursor || retained.snapshot.target_generation != generation {
            return Err(ReadError::StaleCursor);
        }
        if let Some(args) = args
            && (args.snapshot_id.is_some()
                || args.element_index.is_some()
                || args
                    .view
                    .is_some_and(|v| v != retained.request.view.unwrap_or(ReadView::All))
                || args
                    .query
                    .as_ref()
                    .is_some_and(|q| Some(q) != retained.request.query.as_ref()))
        {
            return Err(ReadError::InvalidContinuation);
        }
        let publication = publish(retained, maximum_bytes, false)?;
        if publication.next_cursor.is_none() {
            self.retained = None
        }
        Ok(publication)
    }
}
fn field_kind(node: &AxNode) -> &'static str {
    if node.link_url.is_some() || node.role.as_deref() == Some("AXLink") {
        "navigation"
    } else if node.is_value_settable
        || !node.actions.is_empty()
        || matches!(
            node.role.as_deref(),
            Some(
                "AXButton"
                    | "AXCheckBox"
                    | "AXComboBox"
                    | "AXMenuItem"
                    | "AXPopUpButton"
                    | "AXRadioButton"
                    | "AXSearchField"
                    | "AXSlider"
                    | "AXTextField"
                    | "AXToolbar"
                    | "AXTabGroup"
            )
        )
    {
        "control"
    } else if matches!(node.role.as_deref(), Some("AXStaticText" | "AXHeading")) {
        "readable"
    } else if matches!(
        node.role.as_deref(),
        Some("AXWindow" | "AXApplication" | "AXWebArea" | "AXDocument")
    ) {
        "metadata"
    } else {
        "unknown"
    }
}
fn escape(text: &str) -> String {
    serde_json::to_string(text).expect("Rust string is serializable")
}
fn mint(prefix: &str) -> String {
    format!("{prefix}_{}", &Uuid::new_v4().simple().to_string()[..12])
}
fn publish(
    retained: &mut RetainedRead,
    maximum_bytes: usize,
    is_live: bool,
) -> Result<ReadPublication, ReadError> {
    if !(1024..=65536).contains(&maximum_bytes) {
        return Err(ReadError::OutputBudget);
    }
    let mut output = format!(
        "AXSNAPSHOT id={} snapshot_id={} pid={} root={} target_generation={} view={} source_truncated={} consistency={}\nREFERENCES current_page_only=true. Each new read replaces these references.\n",
        retained.snapshot.id,
        retained.snapshot.id,
        retained.snapshot.window.process_identifier,
        retained.root.map_or("-".into(), |root| root.to_string()),
        retained.snapshot.target_generation,
        serde_json::to_value(retained.request.view.unwrap_or(ReadView::All))
            .unwrap()
            .as_str()
            .unwrap(),
        retained.snapshot.source_truncated,
        if is_live {
            "liveValidatedPage"
        } else {
            "immutableCapture"
        }
    );
    let reserve = 600usize;
    let mut exposed = HashSet::new();
    let mut references = HashMap::new();
    let mut exposures = vec![];
    let mut rows: HashMap<usize, String> = HashMap::new();
    // Keep host metadata separate from untrusted quoted field bytes. Parent
    // tokens can be added only after the page's actually exposed rows are known.
    let mut published_lines: Vec<(usize, String, String)> = Vec::new();
    let mut body_bytes = 0usize;
    let parent_reserve = 32usize;
    while retained.next < retained.fields.len() {
        let field = &mut retained.fields[retained.next];
        let node = retained
            .snapshot
            .node(field.index)
            .map_err(|_| ReadError::InvalidRequest)?;
        let prefix = if let Some(prefix) = rows.get(&node.index) {
            prefix.clone()
        } else {
            let mut addresses = vec![];
            let mut issue = |capability, prefix: &str| {
                let token = mint(prefix);
                references.insert(
                    token.clone(),
                    ModelReference {
                        snapshot_id: retained.snapshot.id,
                        index: node.index,
                        identity: node.identity,
                        capability,
                    },
                );
                token
            };
            if node.is_region() || node.is_readable() {
                addresses.push(format!(
                    "region_ref={}",
                    issue(ReferenceCapability::Region, "r")
                ))
            }
            let enabled = node.is_enabled != Some(false);
            let follow_link = enabled
                && retained.browser
                && node.link_url.is_some()
                && node.has_action("AXPress");
            if follow_link {
                addresses.push(format!(
                    "link_ref={}",
                    issue(ReferenceCapability::Link, "l")
                ))
            }
            if enabled && node.is_value_settable {
                addresses.push(format!(
                    "field_ref={}",
                    issue(ReferenceCapability::Field, "f")
                ))
            }
            for action in node.actions.iter().filter(|_| enabled).take(6) {
                if [
                    "AXPress",
                    "AXIncrement",
                    "AXDecrement",
                    "AXShowMenu",
                    "AXConfirm",
                    "AXCancel",
                    "AXPick",
                ]
                .contains(&action.as_str())
                    && !(follow_link && action == "AXPress")
                {
                    addresses.push(format!(
                        "action_ref={} action={}",
                        issue(ReferenceCapability::Action(action.clone()), "a"),
                        action
                    ))
                }
            }
            let context = retained.contexts.get(&node.index);
            let structural_context = context
                .map(|context| {
                    if context.ancestry_unknown {
                        " ancestry_unknown=true".into()
                    } else if context.ancestry_truncated {
                        " ancestry_truncated=true".into()
                    } else {
                        format!(
                            "{} ancestors=[{}]",
                            context
                                .observed_parent
                                .map(|parent| format!(" parent_index={parent}"))
                                .unwrap_or_default(),
                            context
                                .ancestors
                                .iter()
                                .map(usize::to_string)
                                .collect::<Vec<_>>()
                                .join(",")
                        )
                    }
                })
                .unwrap_or_else(|| " ancestry_unknown=true".into());
            let sibling = context
                .and_then(|context| context.sibling_heading.as_ref())
                .map(|heading| format!(" sibling_heading={}", heading.label))
                .unwrap_or_default();
            let prefix = format!(
                "#{} {} role={}{}{}{}{}{} ",
                node.index,
                addresses.join(" "),
                escape(node.role.as_deref().unwrap_or("unknown")),
                structural_context,
                sibling,
                node.is_selected
                    .map(|v| format!(" selected={v}"))
                    .unwrap_or_default(),
                if enabled && node.is_value_settable {
                    " settable=true"
                } else {
                    ""
                },
                node.is_enabled
                    .map(|enabled| format!(" enabled={enabled}"))
                    .unwrap_or_default()
            );
            rows.insert(node.index, prefix.clone());
            prefix
        };
        let remaining = &field.text[field.offset..];
        let mut end = remaining.len();
        let mut suffix;
        loop {
            suffix = format!(
                "{}={} utf8={}..{}/{} content_kind={}\n",
                field.field,
                escape(&remaining[..end]),
                field.offset,
                field.offset + end,
                field.text.len(),
                retained
                    .kinds
                    .get(&node.index)
                    .copied()
                    .unwrap_or_else(|| field_kind(node))
            );
            let line_len = prefix.len() + suffix.len() + parent_reserve;
            if output.len() + body_bytes + line_len + reserve <= maximum_bytes {
                break;
            }
            if end == 0 {
                break;
            }
            end = end.saturating_sub(
                (line_len + output.len() + body_bytes + reserve)
                    .saturating_sub(maximum_bytes)
                    .max(1),
            );
            while end > 0 && !remaining.is_char_boundary(end) {
                end -= 1
            }
        }
        let line_len = prefix.len() + suffix.len() + parent_reserve;
        if output.len() + body_bytes + line_len + reserve > maximum_bytes
            || (end == 0 && !remaining.is_empty())
        {
            break;
        }
        body_bytes += line_len;
        published_lines.push((node.index, prefix, suffix));
        exposed.insert(node.index);
        exposures.push(FieldExposure {
            node_id: node.identity.to_string(),
            field: field.field.into(),
            start_utf8: field.offset,
            end_utf8: field.offset + end,
            total_utf8: field.text.len(),
            kind: retained
                .kinds
                .get(&node.index)
                .copied()
                .unwrap_or_else(|| field_kind(node))
                .into(),
            provenance: retained
                .provenance
                .get(&node.index)
                .copied()
                .unwrap_or("unknown")
                .into(),
        });
        if end < remaining.len() {
            field.offset += end;
            break;
        }
        retained.next += 1;
    }
    if exposures.is_empty() && !retained.fields.is_empty() {
        return Err(ReadError::OutputBudget);
    }
    references.retain(|_, r| exposed.contains(&r.index));
    let regions: HashMap<usize, &str> = references
        .iter()
        .filter_map(|(token, reference)| {
            (reference.capability == ReferenceCapability::Region)
                .then_some((reference.index, token.as_str()))
        })
        .collect();
    for (index, prefix, suffix) in published_lines {
        output.push_str(&prefix);
        if let Some(parent_token) = retained
            .contexts
            .get(&index)
            .and_then(|context| context.observed_parent)
            .filter(|parent| *parent != index)
            .and_then(|parent| regions.get(&parent))
        {
            output.push_str(&format!("parent_ref={parent_token} "));
        }
        output.push_str(&suffix);
    }
    let has_more = retained.next < retained.fields.len();
    let next_cursor = has_more.then(|| {
        retained.cursor = Uuid::new_v4();
        retained.cursor
    });
    let receipt = ReadReceipt {
        id: Uuid::new_v4(),
        source_id: retained.snapshot.id,
        target_generation: retained.snapshot.target_generation.to_string(),
        consistency: if is_live {
            "liveValidatedPage"
        } else {
            "immutableCapture"
        }
        .into(),
        view: retained.request.view.unwrap_or(ReadView::All),
        query: retained.request.query.clone(),
        subtree_node_id: retained
            .request
            .element_index
            .and_then(|i| retained.snapshot.node(i).ok())
            .map(|n| n.identity.to_string()),
        selected_element_count: retained.selected.len(),
        selected_field_count: retained.fields.len(),
        source_truncated: retained.snapshot.source_truncated,
        field_truncated: has_more,
        output_truncated: has_more,
        exposures,
    };
    output.push_str(&format!("READ_RECEIPT id={} returned_elements={} selected_elements={} field_truncated={} output_truncated={}{}\n",receipt.id,exposed.len(),retained.selected.len(),has_more,has_more,next_cursor.map(|c|format!(" next_cursor={c}")).unwrap_or_default()));
    if output.len() > maximum_bytes {
        return Err(ReadError::OutputBudget);
    }
    Ok(ReadPublication {
        text: output,
        receipt,
        snapshot: retained.snapshot.clone(),
        exposed,
        references,
        next_cursor,
    })
}

#[cfg(test)]
pub(crate) mod fixtures {
    use super::*;
    use computa_macos::*;
    pub fn snapshot(value: &str) -> AxSnapshot {
        AxSnapshot {
            id: Uuid::new_v4(),
            target_generation: Uuid::new_v4(),
            window: WindowInfo {
                window_id: Some(1),
                process_identifier: 7,
                bundle_identifier: Some("test.app".into()),
                title: Some("window".into()),
                frame: Some(Rect {
                    x: 0.,
                    y: 0.,
                    width: 800.,
                    height: 600.,
                }),
                is_main: true,
                is_focused: false,
                document: None,
            },
            elements: vec![AxNode {
                index: 0,
                parent_index: None,
                identity: Uuid::new_v4(),
                role: Some("AXTextArea".into()),
                subrole: None,
                title: Some("Body".into()),
                element_description: None,
                help: None,
                value: Some(value.into()),
                identifier: Some("body".into()),
                link_url: None,
                frame: None,
                is_enabled: Some(true),
                is_selected: None,
                is_focused: None,
                is_value_settable: true,
                actions: vec![],
                children_truncated: false,
                text_truncated: false,
            }],
            source_truncated: false,
            captured_at: 1.,
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_subtree_read_never_claims_fresh_live_observation() {
        let snapshot = fixtures::snapshot("retained exact value");
        let mut reader = SemanticReader::default();
        let original = reader
            .start(snapshot.clone(), ReadArgs::default(), None, 4096)
            .unwrap();
        assert_eq!(original.receipt.consistency, "liveValidatedPage");
        let subtree = reader
            .start(
                snapshot,
                ReadArgs {
                    snapshot_id: Some(original.snapshot.id.to_string()),
                    element_index: Some(0),
                    ..Default::default()
                },
                Some(&original.exposed),
                4096,
            )
            .unwrap();
        assert_eq!(subtree.receipt.consistency, "immutableCapture");
        assert!(subtree.text.contains("consistency=immutableCapture"));
        assert!(subtree.text.contains("retained exact value"));
        assert_eq!(subtree.receipt.source_id, original.receipt.source_id);
    }
    #[test]
    fn disabled_controls_are_readable_but_receive_no_mutation_capability() {
        let mut snapshot = fixtures::snapshot("disabled value");
        snapshot.elements[0].is_enabled = Some(false);
        snapshot.elements[0].actions = vec!["AXPress".into()];
        let publication = SemanticReader::default()
            .start(snapshot, ReadArgs::default(), None, 4096)
            .unwrap();
        assert!(publication.text.contains("enabled=false"));
        assert!(
            publication
                .references
                .values()
                .all(|reference| reference.capability == ReferenceCapability::Region)
        );
        assert!(
            publication
                .receipt
                .exposures
                .iter()
                .any(|field| field.field == "value")
        );
    }
    #[test]
    fn structural_context_does_not_grant_unpublished_ancestor_or_sibling_authority() {
        let mut snapshot = fixtures::snapshot("");
        let template = snapshot.elements[0].clone();
        let node = |index, parent, role: &str, title: &str| {
            let mut node = template.clone();
            node.index = index;
            node.parent_index = parent;
            node.identity = Uuid::new_v4();
            node.role = Some(role.into());
            node.title = Some(title.into());
            node.value = None;
            node.is_value_settable = false;
            node.actions.clear();
            node
        };
        let root = node(0, None, "AXWebArea", "window");
        let group = node(1, Some(0), "AXGroup", "card");
        let heading = node(2, Some(1), "AXHeading", "Account actions");
        let value = node(3, Some(1), "AXStaticText", "Open account");
        snapshot.elements = vec![root, group, heading, value];
        let publication = SemanticReader::default()
            .start_browser(
                snapshot,
                ReadArgs {
                    view: Some(ReadView::Content),
                    query: Some("Open account".into()),
                    ..Default::default()
                },
                None,
                4096,
            )
            .unwrap();
        assert_eq!(publication.exposed, HashSet::from([3]));
        assert!(
            publication
                .text
                .contains("sibling_heading=\"Account actions\"")
        );
        assert!(publication.text.contains("parent_index=1"));
        assert!(!publication.text.contains("parent_ref="));
        assert!(
            publication
                .references
                .values()
                .all(|reference| reference.index == 3
                    && reference.capability == ReferenceCapability::Region)
        );
        assert!(publication.receipt.exposures.iter().all(|field|field.node_id==publication.snapshot.elements[3].identity.to_string()));
    }
    #[test]
    fn proven_browser_links_have_one_navigation_choice() {
        let mut snapshot = fixtures::snapshot("");
        let link = &mut snapshot.elements[0];
        link.role = Some("AXLink".into());
        link.is_value_settable = false;
        link.link_url = Some("https://example.test/account".into());
        link.actions = vec!["AXPress".into()];
        let publication = SemanticReader::default()
            .start_browser(snapshot, ReadArgs::default(), None, 4096)
            .unwrap();
        assert_eq!(publication.references.len(), 1);
        assert!(
            publication
                .references
                .values()
                .all(|reference| reference.capability == ReferenceCapability::Link)
        );
    }
    #[test]
    fn parent_tokens_address_only_actual_published_rows_and_legacy_receipt_keys_are_preserved() {
        let mut snapshot = fixtures::snapshot("readable");
        let mut root = snapshot.elements[0].clone();
        root.role = Some("AXWindow".into());
        root.is_value_settable = false;
        root.value = None;
        let mut child = snapshot.elements[0].clone();
        child.index = 1;
        child.parent_index = Some(0);
        child.identity = Uuid::new_v4();
        child.role = Some("AXStaticText".into());
        child.is_value_settable = false;
        snapshot.elements = vec![root, child];
        let publication = SemanticReader::default()
            .start(snapshot, ReadArgs::default(), None, 4096)
            .unwrap();
        let parent = publication
            .references
            .iter()
            .find(|(_, reference)| {
                reference.index == 0 && reference.capability == ReferenceCapability::Region
            })
            .unwrap()
            .0;
        assert!(publication.text.contains(&format!("parent_ref={parent}")));
        let encoded = serde_json::to_value(&publication.receipt).unwrap();
        assert!(encoded.get("sourceID").is_some());
        assert!(encoded.get("sourceId").is_none());
        let field = &encoded["exposures"][0];
        assert!(field.get("nodeID").is_some());
        assert!(field.get("startUTF8").is_some());
        assert!(field.get("endUTF8").is_some());
        assert!(field.get("totalUTF8").is_some());
    }
    #[test]
    fn continuation_exposes_exact_utf8_tails_and_consumes_each_cursor_once() {
        let s = fixtures::snapshot(&"😀é".repeat(2000));
        let generation = s.target_generation;
        let mut reader = SemanticReader::default();
        let mut publication = reader.start(s, ReadArgs::default(), None, 2048).unwrap();
        let mut reconstructed = String::new();
        let mut seen = HashSet::new();
        loop {
            assert!(publication.text.len() <= 2048);
            for e in &publication.receipt.exposures {
                if e.field == "value" {
                    let node = &publication.snapshot.elements[0];
                    reconstructed.push_str(&node.value.as_ref().unwrap()[e.start_utf8..e.end_utf8]);
                }
            }
            let Some(cursor) = publication.next_cursor else {
                break;
            };
            assert!(seen.insert(cursor));
            publication = reader
                .continue_read(cursor, None, generation, 2048)
                .unwrap();
            assert!(
                reader
                    .continue_read(cursor, None, generation, 2048)
                    .is_err()
            );
        }
        assert_eq!(reconstructed, "😀é".repeat(2000));
    }
    #[test]
    fn unpublished_nodes_never_receive_references() {
        let s = fixtures::snapshot(&"x".repeat(10000));
        let mut reader = SemanticReader::default();
        let publication = reader.start(s, ReadArgs::default(), None, 2048).unwrap();
        assert!(
            publication
                .references
                .values()
                .all(|r| publication.exposed.contains(&r.index))
        );
    }
    #[test]
    fn cursor_filters_and_generation_cannot_change() {
        let s = fixtures::snapshot(&"x".repeat(10000));
        let generation = s.target_generation;
        let mut reader = SemanticReader::default();
        let p = reader.start(s, ReadArgs::default(), None, 2048).unwrap();
        let cursor = p.next_cursor.unwrap();
        assert!(
            reader
                .continue_read(cursor, None, Uuid::new_v4(), 2048)
                .is_err()
        );
        assert!(
            reader
                .continue_read(
                    cursor,
                    Some(&ReadArgs {
                        view: Some(ReadView::Links),
                        ..Default::default()
                    }),
                    generation,
                    2048
                )
                .is_err()
        );
    }
}
