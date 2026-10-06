//! Compact AX presentation. Structural context never grants field coverage or
//! action authority; callers may mint references only from returned rows.
use computa_macos::{AxNode, AxSnapshot, Rect};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    ops::Range,
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Debug)]
pub struct FormatterOptions {
    pub element_limit: usize,
    pub field_character_limit: usize,
    pub action_limit: usize,
    pub output_limit: usize,
    pub prioritizes_relevant_elements: bool,
    pub preferred_text: Option<String>,
    pub compact: bool,
    pub prioritizes_focused_document: bool,
    pub included_indices: Option<HashSet<usize>>,
    pub allows_raise: bool,
    pub max_ancestor_depth: usize,
    pub presentation_row_byte_reserve: usize,
}
impl Default for FormatterOptions {
    fn default() -> Self {
        Self {
            element_limit: 120,
            field_character_limit: 96,
            action_limit: 6,
            output_limit: 12000,
            prioritizes_relevant_elements: false,
            preferred_text: None,
            compact: false,
            prioritizes_focused_document: false,
            included_indices: None,
            allows_raise: true,
            max_ancestor_depth: 32,
            presentation_row_byte_reserve: 0,
        }
    }
}
impl FormatterOptions {
    fn bounded(&self) -> Self {
        let mut options = self.clone();
        options.element_limit = options.element_limit.min(2000);
        options.field_character_limit = options.field_character_limit.clamp(1, 4096);
        options.action_limit = options.action_limit.min(128);
        options.output_limit = options.output_limit.clamp(512, 1_000_000);
        options.max_ancestor_depth = options.max_ancestor_depth.clamp(1, 128);
        options.presentation_row_byte_reserve = options.presentation_row_byte_reserve.min(1024);
        options.preferred_text = options.preferred_text.map(|text| text.trim().to_owned());
        options
    }
}
#[derive(Clone, Debug)]
pub struct PresentedField {
    pub field: &'static str,
    pub text: String,
    pub spans: Vec<Range<usize>>,
    pub total_utf8: usize,
    pub truncated: bool,
    pub kind: &'static str,
    pub provenance: &'static str,
}
#[derive(Clone, Debug)]
pub struct FormattedRow {
    pub index: usize,
    pub text: String,
    pub parent_index: Option<usize>,
    pub actions: Vec<String>,
    pub settable: bool,
    pub fields: Vec<PresentedField>,
    pub context: RowContext,
}
/// Presentation only. Ancestor and sibling indices are never published fields
/// and do not mint action references.
#[derive(Clone, Debug, Default)]
pub struct RowContext {
    pub observed_parent: Option<usize>,
    pub ancestors: Vec<usize>,
    pub ancestry_unknown: bool,
    pub ancestry_truncated: bool,
    pub sibling_heading: Option<SiblingHeading>,
}
#[derive(Clone, Debug)]
pub struct SiblingHeading {
    pub index: usize,
    /// Bounded, quoted and escaped display text, including its surrounding quotes.
    pub label: String,
}
#[derive(Clone, Debug)]
pub struct FormattedObservation {
    pub text: String,
    pub rows: Vec<FormattedRow>,
    pub exposed_indices: HashSet<usize>,
    pub output_truncated: bool,
    pub field_truncated: bool,
    pub root: Option<usize>,
    pub parents: BTreeMap<usize, Option<usize>>,
}
#[derive(Clone, Debug, thiserror::Error)]
#[error("The Accessibility observation cannot be formatted within the requested bounds")]
pub struct FormatError;
enum Ancestry {
    Known(Vec<usize>),
    Unknown,
    Truncated,
}
fn nonempty(value: Option<&str>) -> Option<&str> {
    value.filter(|value| !value.chars().all(char::is_whitespace))
}
fn label(node: &AxNode) -> Option<(&'static str, &str)> {
    [
        ("title", node.title.as_deref()),
        ("description", node.element_description.as_deref()),
        ("identifier", node.identifier.as_deref()),
        ("help", node.help.as_deref()),
    ]
    .into_iter()
    .find_map(|(field, text)| nonempty(text).map(|text| (field, text)))
}
fn normalize(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}
fn escape(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}
fn quoted(value: Option<&str>, limit: usize, truncated: &mut bool) -> String {
    let Some(value) = nonempty(value) else {
        return "-".into();
    };
    let normalized = normalize(value);
    let graphemes = normalized.graphemes(true).collect::<Vec<_>>();
    let clipped = if graphemes.len() > limit {
        *truncated = true;
        format!("{}…", graphemes[..limit.saturating_sub(1)].concat())
    } else {
        normalized
    };
    format!("\"{}\"", escape(&clipped))
}
fn ancestry(
    node: &AxNode,
    root: Option<usize>,
    by_index: &HashMap<usize, &AxNode>,
    maximum: usize,
) -> Ancestry {
    let Some(root) = root.filter(|_| by_index.contains_key(&node.index)) else {
        return Ancestry::Unknown;
    };
    let mut current = node;
    let mut ancestors = vec![];
    let mut visited = HashSet::from([node.index]);
    loop {
        if current.index == root {
            return if current.parent_index.is_none() {
                Ancestry::Known(ancestors)
            } else {
                Ancestry::Unknown
            };
        }
        let Some(parent) = current.parent_index else {
            return Ancestry::Unknown;
        };
        if ancestors.len() >= maximum {
            return Ancestry::Truncated;
        }
        let Some(next) = by_index.get(&parent).filter(|_| visited.insert(parent)) else {
            return Ancestry::Unknown;
        };
        ancestors.push(parent);
        current = next;
    }
}
fn descendant_indices(
    nodes: &[AxNode],
    by_index: &HashMap<usize, &AxNode>,
    predicate: impl Fn(&AxNode) -> bool,
) -> HashSet<usize> {
    let mut membership = HashMap::new();
    for node in nodes {
        let mut cursor = node.index;
        let mut path = vec![];
        let mut visited = HashSet::new();
        let mut belongs = false;
        while let Some(current) = by_index.get(&cursor) {
            if path.len() >= by_index.len() {
                break;
            }
            if let Some(known) = membership.get(&cursor) {
                belongs = *known;
                break;
            }
            if !visited.insert(cursor) {
                break;
            }
            path.push(cursor);
            if predicate(current) {
                belongs = true;
                break;
            }
            let Some(parent) = current.parent_index else {
                break;
            };
            cursor = parent;
        }
        for index in path {
            membership.insert(index, belongs);
        }
    }
    membership
        .into_iter()
        .filter_map(|(index, belongs)| belongs.then_some(index))
        .collect()
}
fn interactive(node: &AxNode) -> bool {
    !node.actions.is_empty()
        || node.is_value_settable
        || matches!(
            node.role.as_deref(),
            Some(
                "AXButton"
                    | "AXCheckBox"
                    | "AXComboBox"
                    | "AXLink"
                    | "AXMenuItem"
                    | "AXPopUpButton"
                    | "AXRadioButton"
                    | "AXSearchField"
                    | "AXSlider"
                    | "AXTextArea"
                    | "AXTextField"
            )
        )
}
fn readable(node: &AxNode) -> bool {
    matches!(node.role.as_deref(), Some("AXHeading" | "AXStaticText"))
        && (label(node).is_some() || nonempty(node.value.as_deref()).is_some())
}
fn unhelpful(frame: Option<Rect>, window: Option<Rect>) -> bool {
    let Some(frame) = frame else {
        return false;
    };
    if ![frame.x, frame.y, frame.width, frame.height]
        .iter()
        .all(|value| value.is_finite())
        || frame.width <= 1.0
        || frame.height <= 1.0
    {
        return true;
    }
    let Some(window) = window.filter(|window| {
        [window.x, window.y, window.width, window.height]
            .iter()
            .all(|value| value.is_finite())
            && window.width > 0.0
            && window.height > 0.0
    }) else {
        return false;
    };
    (frame.x + frame.width).min(window.x + window.width) - frame.x.max(window.x) <= 1.0
        || (frame.y + frame.height).min(window.y + window.height) - frame.y.max(window.y) <= 1.0
}
fn query_key(value: &str) -> String {
    normalize(&value.nfc().collect::<String>())
        .replace(['\u{2018}', '\u{2019}'], "'")
        .replace(['\u{201c}', '\u{201d}'], "\"")
        .to_lowercase()
}
fn node_key(node: &AxNode) -> usize {
    node as *const AxNode as usize
}
fn matches_query(nodes: &[AxNode], query: Option<&str>) -> HashSet<usize> {
    let Some(query) = query.filter(|query| !query.is_empty()) else {
        return HashSet::new();
    };
    let literal = query.to_lowercase();
    let searchable = |node: &AxNode| {
        [
            node.role.as_deref(),
            node.subrole.as_deref(),
            node.title.as_deref(),
            node.element_description.as_deref(),
            node.help.as_deref(),
            node.identifier.as_deref(),
            node.value.as_deref(),
        ]
        .into_iter()
        .filter_map(nonempty)
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
    };
    let literal_matches = nodes
        .iter()
        .filter(|node| searchable(node).contains(&literal))
        .map(node_key)
        .collect::<HashSet<_>>();
    if !literal_matches.is_empty() {
        return literal_matches;
    }
    let key = query_key(query);
    if key.is_empty() {
        return HashSet::new();
    }
    nodes
        .iter()
        .filter(|node| {
            [
                node.title.as_deref(),
                node.element_description.as_deref(),
                node.help.as_deref(),
                node.value.as_deref(),
            ]
            .into_iter()
            .filter_map(nonempty)
            .any(|field| query_key(field).contains(&key))
        })
        .map(node_key)
        .collect()
}
fn relevance(
    node: &AxNode,
    root: Option<usize>,
    document: &HashSet<usize>,
    matches: bool,
    focused: bool,
) -> i32 {
    if Some(node.index) == root {
        return 10000;
    }
    let in_document = document.contains(&node.index);
    let mut score = if in_document { 3000 } else { 0 };
    if node.is_focused == Some(true) && (focused || !document.is_empty()) {
        score = score.max(8000);
    }
    if focused {
        score = score.max(match node.role.as_deref() {
            Some("AXHeading") => 6000,
            Some("AXWebArea" | "AXDocument") => 5000,
            _ => 0,
        });
    }
    if matches {
        score += 20000;
        score += match node.role.as_deref() {
            Some("AXHeading") => 3000,
            Some(
                "AXButton" | "AXCheckBox" | "AXComboBox" | "AXLink" | "AXMenuItem"
                | "AXPopUpButton" | "AXSearchField" | "AXSlider" | "AXTextArea" | "AXTextField",
            ) => 3500,
            _ => 0,
        };
    }
    let has_label = label(node).is_some();
    let has_value = nonempty(node.value.as_deref()).is_some();
    if in_document && matches!(node.role.as_deref(), Some("AXHeading" | "AXStaticText")) {
        if has_label || has_value {
            score += 400;
        }
    } else {
        if has_label {
            score += 400;
        }
        if has_value {
            score += 300;
        }
    }
    if node.is_focused == Some(true) {
        score += 200;
    }
    if node.is_value_settable {
        score += 300;
    }
    if !node.actions.is_empty() {
        score += 400;
    }
    score
        + match node.role.as_deref() {
            Some(
                "AXButton" | "AXCheckBox" | "AXComboBox" | "AXLink" | "AXMenuItem"
                | "AXPopUpButton" | "AXRadioButton" | "AXSearchField" | "AXSlider" | "AXTextArea"
                | "AXTextField",
            ) => 1000,
            Some("AXHeading" | "AXStaticText") => 40,
            _ => 0,
        }
}
fn interleave(nodes: Vec<&AxNode>) -> Vec<&AxNode> {
    let headings = nodes
        .iter()
        .copied()
        .filter(|node| readable(node) && node.role.as_deref() == Some("AXHeading"))
        .collect::<Vec<_>>();
    let facts = nodes
        .iter()
        .copied()
        .filter(|node| readable(node) && node.role.as_deref() != Some("AXHeading"))
        .collect::<Vec<_>>();
    let mut reading = vec![];
    for index in 0..headings.len().max(facts.len()) {
        reading.extend(headings.get(index).copied());
        reading.extend(facts.get(index).copied());
    }
    let controls = nodes
        .iter()
        .copied()
        .filter(|node| !readable(node) && interactive(node))
        .collect::<Vec<_>>();
    let other = nodes
        .iter()
        .copied()
        .filter(|node| !readable(node) && !interactive(node))
        .collect::<Vec<_>>();
    let mut output = vec![];
    for index in 0..reading.len().max(controls.len()) {
        output.extend(reading.get(index).copied());
        output.extend(controls.get(index).copied());
    }
    output.extend(other);
    output
}
fn selection<'a>(
    snapshot: &'a AxSnapshot,
    nodes: &'a [AxNode],
    root: Option<usize>,
    by_index: &HashMap<usize, &AxNode>,
    document: &HashSet<usize>,
    options: &FormatterOptions,
) -> Vec<&'a AxNode> {
    if let Some(included) = &options.included_indices {
        return nodes
            .iter()
            .filter(|node| included.contains(&node.index))
            .take(options.element_limit)
            .collect();
    }
    if !options.prioritizes_relevant_elements {
        return snapshot
            .elements
            .iter()
            .take(options.element_limit)
            .collect();
    }
    let has_query = options
        .preferred_text
        .as_ref()
        .is_some_and(|query| !query.is_empty());
    let matches = matches_query(nodes, options.preferred_text.as_deref());
    let main = descendant_indices(nodes, by_index, |node| {
        node.subrole.as_deref() == Some("AXLandmarkMain")
    });
    let candidates = if document.is_empty() && !has_query {
        &nodes[..nodes.len().min(options.element_limit)]
    } else {
        nodes
    };
    let mut ordered = candidates
        .iter()
        .enumerate()
        .map(|(offset, node)| {
            (
                node,
                relevance(
                    node,
                    root,
                    document,
                    matches.contains(&node_key(node)),
                    options.prioritizes_focused_document,
                ) + if document.contains(&node.index) && main.contains(&node.index) {
                    2000
                } else {
                    0
                },
                offset,
            )
        })
        .collect::<Vec<_>>();
    ordered.sort_by(|(a, pa, oa), (b, pb, ob)| {
        pb.cmp(pa).then(a.index.cmp(&b.index)).then(oa.cmp(ob))
    });
    let ordered = ordered
        .into_iter()
        .map(|(node, _, _)| node)
        .collect::<Vec<_>>();
    if document.is_empty() {
        return ordered.into_iter().take(options.element_limit).collect();
    }
    let frame = nodes
        .iter()
        .find(|node| Some(node.index) == root && node.role.as_deref() == Some("AXWindow"))
        .and_then(|node| node.frame);
    let representative = if options.prioritizes_focused_document {
        ordered
            .iter()
            .find(|node| {
                document.contains(&node.index)
                    && !unhelpful(node.frame, frame)
                    && matches!(node.role.as_deref(), Some("AXWebArea" | "AXDocument"))
            })
            .map(|node| node.index)
    } else {
        None
    };
    let pinned = |node: &AxNode| {
        Some(node.index) == root
            || node.is_focused == Some(true)
            || matches.contains(&node_key(node))
            || Some(node.index) == representative
    };
    let mut output = ordered
        .iter()
        .copied()
        .filter(|node| pinned(node))
        .collect::<Vec<_>>();
    let pinned_indices = output.iter().map(|node| node.index).collect::<HashSet<_>>();
    let mut groups = vec![];
    if has_query {
        for node in ordered
            .iter()
            .filter(|node| document.contains(&node.index) && matches.contains(&node_key(node)))
        {
            if let Some(parent) = node.parent_index.filter(|parent| !groups.contains(parent))
                && let Some(group) = by_index.get(&parent)
                && group.role.as_deref() == Some("AXGroup")
                && !group
                    .subrole
                    .as_deref()
                    .is_some_and(|subrole| subrole.starts_with("AXLandmark"))
                && document.contains(&parent)
                && matches!(
                    ancestry(node, root, by_index, options.max_ancestor_depth),
                    Ancestry::Known(_)
                )
            {
                groups.push(parent);
                if groups.len() == 2 {
                    break;
                }
            }
        }
    }
    let mut facts = vec![];
    let mut actions = vec![];
    for group in groups {
        let siblings = ordered
            .iter()
            .copied()
            .filter(|node| {
                node.parent_index == Some(group)
                    && by_index.contains_key(&node.index)
                    && !pinned_indices.contains(&node.index)
                    && !unhelpful(node.frame, frame)
            })
            .collect::<Vec<_>>();
        facts.extend(
            siblings
                .iter()
                .copied()
                .filter(|node| {
                    node.role.as_deref() == Some("AXStaticText")
                        && (label(node).is_some() || nonempty(node.value.as_deref()).is_some())
                })
                .take(2),
        );
        actions.extend(
            siblings
                .iter()
                .copied()
                .filter(|node| node.role.as_deref() != Some("AXStaticText") && interactive(node))
                .take(1),
        );
    }
    output.extend(facts);
    output.extend(actions);
    let used = output.iter().map(|node| node.index).collect::<HashSet<_>>();
    let remaining = ordered
        .into_iter()
        .filter(|node| !used.contains(&node.index))
        .collect::<Vec<_>>();
    output.extend(interleave(
        remaining
            .iter()
            .copied()
            .filter(|node| document.contains(&node.index) && !unhelpful(node.frame, frame))
            .collect(),
    ));
    output.extend(
        remaining
            .iter()
            .copied()
            .filter(|node| !document.contains(&node.index)),
    );
    output.extend(interleave(
        remaining
            .into_iter()
            .filter(|node| document.contains(&node.index) && unhelpful(node.frame, frame))
            .collect(),
    ));
    output.truncate(options.element_limit);
    output
}
fn allowed_action(action: &str, allows_raise: bool) -> bool {
    matches!(
        action,
        "AXPress"
            | "AXIncrement"
            | "AXDecrement"
            | "AXShowMenu"
            | "AXConfirm"
            | "AXCancel"
            | "AXPick"
    ) || allows_raise && action == "AXRaise"
}
fn allowed_actions(node: &AxNode, options: &FormatterOptions) -> Vec<String> {
    node.actions
        .iter()
        .filter(|action| allowed_action(action, options.allows_raise))
        .take(options.action_limit)
        .cloned()
        .collect()
}
fn spans(text: &str, limit: usize) -> (Vec<Range<usize>>, bool) {
    let mut origins = vec![];
    let mut whitespace = vec![];
    let mut single_space = false;
    for (offset, character) in text.grapheme_indices(true) {
        let range = offset..offset + character.len();
        if character.chars().all(char::is_whitespace) {
            whitespace.push(range);
            single_space = whitespace.len() == 1 && character == " ";
        } else {
            if !origins.is_empty() && !whitespace.is_empty() {
                origins.push(single_space.then(|| whitespace[0].clone()));
            }
            whitespace.clear();
            single_space = false;
            origins.push(Some(range));
        }
    }
    let clipped = origins.len() > limit;
    let retained = if clipped {
        limit.saturating_sub(1)
    } else {
        origins.len()
    };
    let mut result: Vec<Range<usize>> = vec![];
    for origin in origins.into_iter().take(retained).flatten() {
        if let Some(last) = result.last_mut().filter(|last| last.end == origin.start) {
            last.end = origin.end;
        } else {
            result.push(origin);
        }
    }
    (result, clipped)
}
fn provenance(
    node: &AxNode,
    root: Option<usize>,
    by_index: &HashMap<usize, &AxNode>,
    depth: usize,
) -> &'static str {
    let Ancestry::Known(ancestors) = ancestry(node, root, by_index, depth) else {
        return "unknown";
    };
    for index in std::iter::once(node.index).chain(ancestors) {
        let Some(node) = by_index.get(&index) else {
            return "unknown";
        };
        let kind = match node.subrole.as_deref() {
            Some("AXLandmarkMain") => "main",
            Some("AXLandmarkNavigation") => "navigation",
            Some("AXLandmarkComplementary") => "complementary",
            Some("AXLandmarkBanner") => "banner",
            Some("AXLandmarkContentInfo") => "contentinfo",
            _ => {
                if node.role.as_deref() == Some("AXArticle") {
                    "article"
                } else {
                    continue;
                }
            }
        };
        return kind;
    }
    "unknown"
}
fn control(node: &AxNode) -> bool {
    node.is_value_settable
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
}
fn kind(
    node: &AxNode,
    provenance: &str,
    root: Option<usize>,
    by_index: &HashMap<usize, &AxNode>,
    depth: usize,
) -> &'static str {
    if provenance == "navigation" || node.role.as_deref() == Some("AXLink") {
        return "navigation";
    }
    if control(node) {
        return "control";
    }
    if let Ancestry::Known(ancestors) = ancestry(node, root, by_index, depth)
        && ancestors
            .iter()
            .any(|index| by_index.get(index).is_some_and(|node| control(node)))
    {
        return "control";
    }
    match node.role.as_deref() {
        Some("AXStaticText" | "AXHeading") => "readable",
        Some("AXWindow" | "AXApplication" | "AXWebArea" | "AXDocument") => "metadata",
        _ => "unknown",
    }
}
fn exact_link(raw: &str) -> bool {
    if raw.is_empty()
        || raw.len() > 512
        || raw.chars().any(|character| {
            character.is_whitespace() || character.is_control() || character == '\\'
        })
    {
        return false;
    }
    let bytes = raw.as_bytes();
    let mut offset = 0;
    let mut decoded_bytes = Vec::with_capacity(bytes.len());
    while offset < bytes.len() {
        if bytes[offset] == b'%' {
            let Some(pair) = bytes.get(offset + 1..offset + 3) else {
                return false;
            };
            let Some(high) = (pair[0] as char).to_digit(16) else {
                return false;
            };
            let Some(low) = (pair[1] as char).to_digit(16) else {
                return false;
            };
            let decoded = (high * 16 + low) as u8;
            decoded_bytes.push(decoded);
            offset += 3;
        } else {
            decoded_bytes.push(bytes[offset]);
            offset += 1;
        }
    }
    if String::from_utf8(decoded_bytes)
        .map_or(true, |decoded| decoded.chars().any(char::is_control))
    {
        return false;
    }
    if raw.split_once("://").is_none_or(|(_, rest)| {
        rest.split(['/', '?', '#'])
            .next()
            .is_none_or(|authority| authority.contains('@'))
    }) {
        return false;
    }
    url::Url::parse(raw).is_ok_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some_and(|host| !host.is_empty())
            && url.username().is_empty()
            && url.password().is_none()
            && url.port() != Some(0)
    })
}
fn fields(
    node: &AxNode,
    root: Option<usize>,
    by_index: &HashMap<usize, &AxNode>,
    options: &FormatterOptions,
) -> Vec<PresentedField> {
    let provenance = provenance(node, root, by_index, options.max_ancestor_depth);
    let kind = kind(node, provenance, root, by_index, options.max_ancestor_depth);
    let mut output = vec![];
    for (field, value, kind) in [
        (
            "label",
            label(node).map(|(_, value)| value),
            if label(node).is_some_and(|(field, _)| field == "identifier") {
                "metadata"
            } else {
                kind
            },
        ),
        ("value", nonempty(node.value.as_deref()), kind),
    ] {
        if let Some(text) = value {
            let (spans, truncated) = spans(text, options.field_character_limit);
            let mut ignored = false;
            let shown = quoted(Some(text), options.field_character_limit, &mut ignored);
            output.push(PresentedField {
                field,
                text: shown,
                spans,
                total_utf8: text.len(),
                truncated,
                kind,
                provenance,
            });
        }
    }
    if node.role.as_deref() == Some("AXLink")
        && let Some(raw) = node.link_url.as_deref().filter(|raw| exact_link(raw))
    {
        output.push(PresentedField {
            field: "linkURL",
            text: raw.to_owned(),
            spans: std::iter::once(0..raw.len()).collect(),
            total_utf8: raw.len(),
            truncated: false,
            kind: "navigation",
            provenance,
        });
    }
    output
}
fn number(value: f64) -> String {
    if value == 0.0 {
        return "0".into();
    }
    if !value.is_finite() {
        return value.to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    if !(-4..6).contains(&exponent) {
        let scientific = format!("{value:.5e}");
        let (mantissa, exponent) = scientific.split_once('e').unwrap();
        let exponent = exponent.parse::<i32>().unwrap();
        format!(
            "{}e{:+03}",
            mantissa.trim_end_matches('0').trim_end_matches('.'),
            exponent
        )
    } else {
        let precision = (5 - exponent).max(0) as usize;
        let formatted = format!("{value:.precision$}");
        if formatted.contains('.') {
            formatted
                .trim_end_matches('0')
                .trim_end_matches('.')
                .to_owned()
        } else {
            formatted
        }
    }
}
fn frame(frame: Rect) -> String {
    format!(
        "[{},{},{},{}]",
        number(frame.x),
        number(frame.y),
        number(frame.width),
        number(frame.height)
    )
}
fn bit(value: bool) -> usize {
    usize::from(value)
}
struct Candidate {
    index: usize,
    line: String,
    ancestors: Vec<usize>,
    fields: Vec<PresentedField>,
    context: RowContext,
}

pub fn format(
    snapshot: &AxSnapshot,
    application_name: Option<&str>,
    options: &FormatterOptions,
) -> Result<FormattedObservation, FormatError> {
    if snapshot.elements.len() > 100_000 {
        return Err(FormatError);
    }
    let options = options.bounded();
    let nodes = &snapshot.elements[..snapshot.elements.len().min(2000)];
    let mut by_index = HashMap::new();
    let mut duplicates = HashSet::new();
    for node in nodes {
        if by_index.insert(node.index, node).is_some() {
            duplicates.insert(node.index);
        }
    }
    for duplicate in &duplicates {
        by_index.remove(duplicate);
    }
    let root = nodes
        .iter()
        .find(|node| node.parent_index.is_none())
        .map(|node| node.index);
    let document = descendant_indices(nodes, &by_index, |node| {
        matches!(node.role.as_deref(), Some("AXWebArea" | "AXDocument"))
    });
    let mut headings: HashMap<usize, Vec<&AxNode>> = HashMap::new();
    if options.compact && snapshot.elements.len() <= 2000 {
        for node in nodes
            .iter()
            .filter(|node| node.role.as_deref() == Some("AXHeading"))
        {
            if let Some(parent) = node.parent_index {
                headings.entry(parent).or_default().push(node);
            }
        }
    }
    let selected = selection(snapshot, nodes, root, &by_index, &document, &options);
    let mut format_truncated =
        options.included_indices.is_none() && snapshot.elements.len() > selected.len();
    let mut field_truncated = snapshot.elements.iter().any(|node| node.text_truncated);
    let app = quoted(
        application_name,
        options.field_character_limit.min(48),
        &mut format_truncated,
    );
    let bundle = quoted(
        snapshot.window.bundle_identifier.as_deref(),
        options.field_character_limit.min(48),
        &mut format_truncated,
    );
    let mut candidates = vec![];
    for node in selected {
        let observed_ancestry = ancestry(node, root, &by_index, options.max_ancestor_depth);
        let mut context = RowContext::default();
        let (parent, ancestors) = match observed_ancestry {
            Ancestry::Known(ancestors) => {
                context.observed_parent = node.parent_index;
                context.ancestors = ancestors.clone();
                (
                    format!(
                        " parent={}",
                        node.parent_index
                            .map_or("-".into(), |parent| parent.to_string())
                    ),
                    ancestors,
                )
            }
            Ancestry::Unknown => {
                context.ancestry_unknown = true;
                (" parent=- ancestry_unknown=1".into(), vec![])
            }
            Ancestry::Truncated => {
                context.ancestry_truncated = true;
                format_truncated = true;
                (" parent=- ancestry_truncated=1".into(), vec![])
            }
        };
        let mut sibling = String::new();
        if options.compact
            && node.role.as_deref() == Some("AXStaticText")
            && let Some(parent) = node.parent_index
            && let Some(group) = by_index.get(&parent)
            && group.role.as_deref() == Some("AXGroup")
            && !group
                .subrole
                .as_deref()
                .is_some_and(|subrole| subrole.starts_with("AXLandmark"))
            && document.contains(&parent)
            && matches!(
                ancestry(node, root, &by_index, options.max_ancestor_depth),
                Ancestry::Known(_)
            )
            && let Some(heading) = headings
                .get(&parent)
                .filter(|headings| headings.len() == 1)
                .and_then(|headings| headings.first())
            && by_index.contains_key(&heading.index)
            && let Some((_, label)) = label(heading)
        {
            let label = quoted(
                Some(label),
                options.field_character_limit,
                &mut format_truncated,
            );
            context.sibling_heading = Some(SiblingHeading {
                index: heading.index,
                label: label.clone(),
            });
            sibling = format!(" sibling_heading=#{}:{}", heading.index, label);
        }
        let role = match (
            nonempty(node.role.as_deref()),
            nonempty(node.subrole.as_deref()),
        ) {
            (Some(role), Some(subrole)) => Some(format!("{role}/{subrole}")),
            (Some(role), None) => Some(role.to_owned()),
            (None, Some(subrole)) => Some(subrole.to_owned()),
            _ => None,
        };
        let role = quoted(
            role.as_deref(),
            options.field_character_limit,
            &mut format_truncated,
        );
        let label = quoted(
            label(node).map(|(_, text)| text),
            options.field_character_limit,
            &mut format_truncated,
        );
        let value = quoted(
            node.value.as_deref(),
            options.field_character_limit,
            &mut format_truncated,
        );
        let actions = allowed_actions(node, &options);
        if node
            .actions
            .iter()
            .filter(|action| allowed_action(action, options.allows_raise))
            .nth(actions.len())
            .is_some()
        {
            format_truncated = true;
        }
        let actions = format!(
            "[{}]",
            actions
                .iter()
                .map(|action| quoted(
                    Some(action),
                    options.field_character_limit,
                    &mut format_truncated
                ))
                .collect::<Vec<_>>()
                .join(",")
        );
        let link = if node.role.as_deref() == Some("AXLink") {
            node.link_url.as_deref().map_or(String::new(), |raw| {
                if exact_link(raw) {
                    format!(" url=\"{}\"", escape(raw))
                } else {
                    format_truncated = true;
                    field_truncated = true;
                    " url_omitted=1".into()
                }
            })
        } else {
            String::new()
        };
        let line = if options.compact {
            format!(
                "#{} role={role}{}{} actions={actions}{}{}{}{}{}{}{}",
                node.index,
                if label == "-" {
                    String::new()
                } else {
                    format!(" label={label}")
                },
                if value == "-" {
                    String::new()
                } else {
                    format!(" value={value}")
                },
                if node.is_value_settable {
                    " settable=1"
                } else {
                    ""
                },
                if node.is_focused == Some(true) {
                    " focused=1"
                } else {
                    ""
                },
                node.is_selected
                    .map_or(String::new(), |value| format!(" selected={}", bit(value))),
                node.frame.map_or(String::new(), |value| format!(
                    " screen_frame={}",
                    frame(value)
                )),
                link,
                sibling,
                parent
            )
        } else {
            format!(
                "#{} parent={} role={role} label={label} value={value} frame={} enabled={} focused={}{} actions={actions} settable={}{}",
                node.index,
                node.parent_index
                    .map_or("-".into(), |parent| parent.to_string()),
                node.frame.map_or("-".into(), frame),
                node.is_enabled
                    .map_or("-".into(), |value| bit(value).to_string()),
                node.is_focused
                    .map_or("-".into(), |value| bit(value).to_string()),
                node.is_selected
                    .map_or(String::new(), |value| format!(" selected={}", bit(value))),
                bit(node.is_value_settable),
                link
            )
        };
        let fields = fields(node, root, &by_index, &options);
        field_truncated |= fields.iter().any(|field| field.truncated);
        candidates.push(Candidate {
            index: node.index,
            line,
            ancestors: if options.compact { ancestors } else { vec![] },
            fields,
            context,
        });
    }
    let count = candidates.len();
    let mut retained = count;
    let mut ancestor_counts: BTreeMap<usize, usize> = BTreeMap::new();
    for candidate in &candidates {
        for ancestor in &candidate.ancestors {
            *ancestor_counts.entry(*ancestor).or_default() += 1;
        }
    }
    let text = loop {
        let parent_map = if options.compact {
            format!(
                " parents=[{}]",
                ancestor_counts
                    .iter()
                    .filter(|(_, count)| **count > 0)
                    .filter_map(|(index, _)| by_index.get(index).map(|node| format!(
                        "{index}:{}",
                        node.parent_index
                            .map_or("-".into(), |parent| parent.to_string())
                    )))
                    .collect::<Vec<_>>()
                    .join(",")
            )
        } else {
            String::new()
        };
        let header = format!(
            "AXSNAPSHOT id={} pid={} app={app} bundle={bundle} root={} shown={retained} total={} source_truncated={} output_truncated={}{}",
            snapshot.id.to_string().to_uppercase(),
            snapshot.window.process_identifier,
            root.map_or("-".into(), |root| root.to_string()),
            snapshot.elements.len(),
            bit(snapshot.source_truncated),
            bit(format_truncated || retained < count),
            parent_map
        );
        let text = std::iter::once(header)
            .chain(
                candidates[..retained]
                    .iter()
                    .map(|candidate| candidate.line.clone()),
            )
            .collect::<Vec<_>>()
            .join("\n");
        let size = if options.presentation_row_byte_reserve > 0 {
            text.len() + retained * options.presentation_row_byte_reserve + 512
        } else {
            text.graphemes(true).count()
        };
        if size <= options.output_limit {
            break text;
        }
        if retained == 0 {
            return Err(FormatError);
        }
        retained -= 1;
        for ancestor in &candidates[retained].ancestors {
            *ancestor_counts.get_mut(ancestor).unwrap() -= 1;
        }
    };
    let beyond = snapshot
        .elements
        .iter()
        .skip(nodes.len())
        .map(|node| node.index)
        .collect::<HashSet<_>>();
    let exposed = candidates[..retained]
        .iter()
        .filter(|candidate| {
            by_index.contains_key(&candidate.index) && !beyond.contains(&candidate.index)
        })
        .map(|candidate| candidate.index)
        .collect::<HashSet<_>>();
    let rows = candidates
        .into_iter()
        .take(retained)
        .filter(|candidate| exposed.contains(&candidate.index))
        .map(|candidate| {
            let node = by_index[&candidate.index];
            FormattedRow {
                index: node.index,
                text: candidate.line,
                parent_index: node
                    .parent_index
                    .filter(|parent| *parent != node.index && exposed.contains(parent)),
                actions: if node.is_enabled != Some(false) {
                    allowed_actions(node, &options)
                        .into_iter()
                        .filter(|action| {
                            action.graphemes(true).count() <= options.field_character_limit
                        })
                        .collect()
                } else {
                    vec![]
                },
                settable: node.is_enabled != Some(false) && node.is_value_settable,
                fields: candidate.fields,
                context: candidate.context,
            }
        })
        .collect();
    Ok(FormattedObservation {
        text,
        rows,
        exposed_indices: exposed,
        output_truncated: format_truncated || retained < count,
        field_truncated,
        root,
        parents: ancestor_counts
            .into_iter()
            .filter(|(_, count)| *count > 0)
            .filter_map(|(index, _)| by_index.get(&index).map(|node| (index, node.parent_index)))
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use computa_macos::WindowInfo;
    use uuid::Uuid;

    fn node(
        index: usize,
        parent: Option<usize>,
        role: &str,
        title: Option<&str>,
        value: Option<&str>,
    ) -> AxNode {
        AxNode {
            index,
            parent_index: parent,
            identity: Uuid::from_u128(index as u128 + 1),
            role: Some(role.into()),
            subrole: None,
            title: title.map(Into::into),
            element_description: None,
            help: None,
            value: value.map(Into::into),
            identifier: None,
            link_url: None,
            frame: None,
            is_enabled: None,
            is_selected: None,
            is_focused: None,
            is_value_settable: false,
            actions: if role == "AXButton" {
                vec!["AXPress".into()]
            } else {
                vec![]
            },
            children_truncated: false,
            text_truncated: false,
        }
    }
    fn snapshot(nodes: Vec<AxNode>) -> AxSnapshot {
        AxSnapshot {
            id: Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
            target_generation: Uuid::from_u128(1),
            window: WindowInfo {
                window_id: None,
                process_identifier: 4242,
                bundle_identifier: Some("example.synthetic".into()),
                title: None,
                frame: None,
                is_main: false,
                is_focused: false,
                document: None,
            },
            elements: nodes,
            source_truncated: false,
            captured_at: 0.0,
        }
    }
    fn cards(nested: bool) -> AxSnapshot {
        let mut nodes = vec![
            node(0, None, "AXWindow", Some("Synthetic orders"), None),
            node(1, Some(0), "AXWebArea", Some("Orders"), None),
        ];
        for (title, status, title_backed) in [
            ("Order A", "Arrives Tuesday", false),
            ("Order B", "Delivered Friday", true),
        ] {
            let card = nodes.len();
            nodes.push(node(card, Some(1), "AXGroup", None, None));
            nodes.push(node(
                nodes.len(),
                Some(card),
                "AXHeading",
                Some(title),
                None,
            ));
            let parent = if nested {
                let group = nodes.len();
                nodes.push(node(group, Some(card), "AXGroup", None, None));
                group
            } else {
                card
            };
            nodes.push(node(
                nodes.len(),
                Some(parent),
                "AXStaticText",
                title_backed.then_some(status),
                (!title_backed).then_some(status),
            ));
            nodes.push(node(
                nodes.len(),
                Some(card),
                "AXButton",
                Some("Details"),
                None,
            ));
        }
        snapshot(nodes)
    }
    fn compact() -> FormatterOptions {
        FormatterOptions {
            compact: true,
            prioritizes_relevant_elements: true,
            prioritizes_focused_document: true,
            field_character_limit: 72,
            output_limit: 3000,
            ..Default::default()
        }
    }
    #[test]
    fn ranked_compact_cards_preserve_value_fact_and_omitted_parent_paths() {
        for nested in [false, true] {
            let snapshot = cards(nested);
            let target = snapshot
                .elements
                .iter()
                .find(|node| node.value.as_deref() == Some("Arrives Tuesday"))
                .unwrap();
            let result = format(
                &snapshot,
                Some("Synthetic"),
                &FormatterOptions {
                    element_limit: 6,
                    ..compact()
                },
            )
            .unwrap();
            assert_eq!(result.rows.len(), 6);
            assert!(result.text.starts_with(
                "AXSNAPSHOT id=11111111-1111-4111-8111-111111111111 pid=4242 app=\"Synthetic\""
            ));
            assert!(
                result.rows.iter().any(|row| row.index == target.index
                    && row.text.contains("value=\"Arrives Tuesday\""))
            );
            assert!(result.text.contains(" parents=[0:-,1:0,2:1"));
            assert!(!result.exposed_indices.contains(&2));
            assert!(!result.rows.iter().any(|row| row.index == 2));
            if !nested {
                assert!(result.text.contains(" sibling_heading=#3:\"Order A\""));
            } else {
                assert!(!result.text.contains("sibling_heading="));
            }
        }
    }
    #[test]
    fn literal_query_wins_before_typographic_fallback_and_duplicate_indices_never_publish() {
        let mut snapshot = cards(false);
        snapshot.elements[3].title = Some("Mira’s order".into());
        snapshot.elements[7].title = Some("Mira's order".into());
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                preferred_text: Some("Mira's order".into()),
                ..compact()
            },
        )
        .unwrap();
        assert_eq!(result.rows[0].index, 7);
        snapshot.elements[7].title = Some("Different order".into());
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                preferred_text: Some("Mira's order".into()),
                ..compact()
            },
        )
        .unwrap();
        assert_eq!(result.rows[0].index, 3);
        snapshot
            .elements
            .push(node(3, Some(1), "AXButton", Some("unrelated"), None));
        let result = format(&snapshot, None, &compact()).unwrap();
        assert!(!result.exposed_indices.contains(&3));
        assert!(!result.rows.iter().any(|row| row.index == 3));
    }
    #[test]
    fn clipping_covers_only_actual_utf8_bytes_and_whitespace_is_context() {
        let raw = "  e\u{301}\t\n  👩‍💻 tail  ";
        let snapshot = snapshot(vec![
            node(0, None, "AXWindow", None, None),
            node(1, Some(0), "AXStaticText", None, Some(raw)),
        ]);
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                compact: true,
                field_character_limit: 4,
                ..Default::default()
            },
        )
        .unwrap();
        let field = &result.rows[1].fields[0];
        assert_eq!(field.text, "\"e\u{301} 👩‍💻…\"");
        assert_eq!(field.total_utf8, raw.len());
        assert!(field.truncated);
        assert_eq!(
            field
                .spans
                .iter()
                .map(|span| &raw[span.clone()])
                .collect::<Vec<_>>(),
            vec!["e\u{301}", "👩‍💻"]
        );
        assert!(
            field
                .spans
                .iter()
                .all(|span| raw.is_char_boundary(span.start) && raw.is_char_boundary(span.end))
        );
        assert!(result.field_truncated);
    }
    #[test]
    fn malformed_ancestry_cannot_invent_parent_context() {
        let snapshot = snapshot(vec![
            node(0, None, "AXWindow", None, None),
            node(1, Some(2), "AXGroup", None, None),
            node(2, Some(1), "AXStaticText", None, Some("Fact")),
            node(3, Some(99), "AXStaticText", None, Some("Orphan")),
        ]);
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                compact: true,
                ..Default::default()
            },
        )
        .unwrap();
        for index in [1, 2, 3] {
            assert!(
                result
                    .rows
                    .iter()
                    .find(|row| row.index == index)
                    .unwrap()
                    .text
                    .ends_with("parent=- ancestry_unknown=1")
            );
        }
        assert!(result.text.contains("parents=[]"));
    }
    #[test]
    fn included_rows_do_not_resurrect_omitted_fields_or_actions() {
        let snapshot = cards(false);
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                included_indices: Some(HashSet::from([4])),
                ..compact()
            },
        )
        .unwrap();
        assert_eq!(result.exposed_indices, HashSet::from([4]));
        assert_eq!(result.rows.len(), 1);
        assert_eq!(result.rows[0].parent_index, None);
        assert_eq!(result.rows[0].fields.len(), 1);
        assert_eq!(result.rows[0].fields[0].field, "value");
        assert!(result.rows[0].actions.is_empty());
        assert!(result.text.contains("sibling_heading=#3:\"Order A\""));
        assert!(!result.rows.iter().any(|row| row.index == 3));
        assert_eq!(result.root, Some(0));
        assert_eq!(
            result.parents,
            BTreeMap::from([(0, None), (1, Some(0)), (2, Some(1))])
        );
        let context = &result.rows[0].context;
        assert_eq!(context.observed_parent, Some(2));
        assert_eq!(context.ancestors, vec![2, 1, 0]);
        assert!(!context.ancestry_unknown && !context.ancestry_truncated);
        let heading = context.sibling_heading.as_ref().unwrap();
        assert_eq!(heading.index, 3);
        assert_eq!(heading.label, "\"Order A\"");
    }
    #[test]
    fn ambiguous_sibling_headings_and_landmarks_do_not_establish_association() {
        let mut snapshot = cards(false);
        snapshot
            .elements
            .push(node(10, Some(2), "AXHeading", Some("Another title"), None));
        let result = format(&snapshot, None, &compact()).unwrap();
        assert!(
            !result
                .rows
                .iter()
                .find(|row| row.index == 4)
                .unwrap()
                .text
                .contains("sibling_heading")
        );
        snapshot.elements.pop();
        snapshot.elements[2].subrole = Some("AXLandmarkMain".into());
        let result = format(&snapshot, None, &compact()).unwrap();
        assert!(
            !result
                .rows
                .iter()
                .find(|row| row.index == 4)
                .unwrap()
                .text
                .contains("sibling_heading")
        );
        assert_eq!(
            result
                .rows
                .iter()
                .find(|row| row.index == 4)
                .unwrap()
                .fields[0]
                .provenance,
            "main"
        );
    }
    #[test]
    fn byte_budget_drops_whole_rows_and_authority_together() {
        let mut snapshot = cards(false);
        snapshot.elements[4].value = Some("界".repeat(500));
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                output_limit: 1000,
                field_character_limit: 500,
                presentation_row_byte_reserve: 32,
                ..compact()
            },
        )
        .unwrap();
        assert!(result.text.len() + result.rows.len() * 32 + 512 <= 1000);
        assert!(result.output_truncated);
        assert_eq!(result.rows.len(), result.exposed_indices.len());
        for row in &result.rows {
            assert!(result.text.lines().any(|line| line == row.text));
        }
        assert!(!result.exposed_indices.contains(&4));
    }
    #[test]
    fn impossible_metadata_budget_and_depth_bound_fail_closed() {
        let snapshot = cards(true);
        assert!(
            format(
                &snapshot,
                None,
                &FormatterOptions {
                    output_limit: 512,
                    presentation_row_byte_reserve: 1,
                    ..compact()
                }
            )
            .is_err()
        );
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                included_indices: Some(HashSet::from([5])),
                max_ancestor_depth: 2,
                ..compact()
            },
        )
        .unwrap();
        let context = &result.rows[0].context;
        assert!(context.ancestry_truncated);
        assert!(context.ancestors.is_empty());
        assert!(context.observed_parent.is_none());
        assert!(result.parents.is_empty());
        assert!(result.output_truncated);
    }
    #[test]
    fn only_exact_safe_link_destinations_are_exposed_without_clipping() {
        for safe in [
            "https://example.test/a?x=1#b",
            "http://example.test:65535/",
            "https://example.test/a%20b",
        ] {
            assert!(exact_link(safe), "{safe}");
        }
        for unsafe_url in [
            "javascript:alert(1)",
            "file:///x",
            "https://user@example.test/",
            "https://@example.test/",
            "https://example.test:0/",
            "https://example.test/a b",
            "https://example.test/\\x",
            "https://example.test/%00",
            "https://example.test/%C2%85",
            "https://example.test/%FF",
            "https://example.test/%QQ",
        ] {
            assert!(!exact_link(unsafe_url), "{unsafe_url}");
        }
        let mut link = node(1, Some(0), "AXLink", Some("Destination"), None);
        link.link_url = Some("https://example.test/long-destination".into());
        let result = format(
            &snapshot(vec![node(0, None, "AXWindow", None, None), link]),
            None,
            &FormatterOptions {
                field_character_limit: 5,
                compact: true,
                ..Default::default()
            },
        )
        .unwrap();
        let field = result.rows[1]
            .fields
            .iter()
            .find(|field| field.field == "linkURL")
            .unwrap();
        assert_eq!(field.text, "https://example.test/long-destination");
        assert!(!field.truncated);
        assert_eq!(field.spans, vec![0..field.text.len()]);
    }
    #[test]
    fn disabled_and_clipped_actions_do_not_grant_dispatch() {
        let mut snapshot = cards(false);
        snapshot.elements[5].is_enabled = Some(false);
        snapshot.elements[9].actions =
            vec!["ArbitraryAction".into(), "AXRaise".into(), "AXPress".into()];
        let result = format(
            &snapshot,
            None,
            &FormatterOptions {
                allows_raise: false,
                field_character_limit: 6,
                ..compact()
            },
        )
        .unwrap();
        assert!(
            result
                .rows
                .iter()
                .find(|row| row.index == 5)
                .unwrap()
                .actions
                .is_empty()
        );
        assert!(
            result
                .rows
                .iter()
                .find(|row| row.index == 9)
                .unwrap()
                .actions
                .is_empty()
        );
        assert!(result.output_truncated);
    }
}
