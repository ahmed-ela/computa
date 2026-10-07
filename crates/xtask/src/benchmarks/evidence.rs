//! Frozen synthetic association evidence and strict evaluator-side scoring.
//! Oracle metadata and poisoned claims never become native input authority.
use super::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

const CORPUS: &[u8] = include_bytes!("evidence-corpus.json");
const CORPUS_SHA256: &str = "00ae817dd0b05fedc1db382dd3ab85d31c26b489757956145837d18320ae00e4";
pub type EvidenceAnswer = BTreeMap<String, Option<String>>;
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EvidenceLayout {
    Table,
    StatusFirst,
    Cards,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceBacking {
    Title,
    Value,
    Both,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceSource {
    Current,
    Unrelated,
    Stale,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceSplit {
    Development,
    Holdout,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum EvidenceDomain {
    Orders,
    Invoices,
    Calendar,
    Issues,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceRow {
    pub id: String,
    pub entity: String,
    pub value: Option<String>,
    pub entity_backing: EvidenceBacking,
    pub value_backing: EvidenceBacking,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidencePanel {
    pub id: String,
    pub heading: String,
    pub field: String,
    pub layout: EvidenceLayout,
    pub frame: EvidenceFrame,
    pub rows: Vec<EvidenceRow>,
    pub source: EvidenceSource,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum EvidencePrimitive {
    Rect {
        id: String,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        fill: String,
        stroke: Option<String>,
        radius: Option<f64>,
    },
    Text {
        id: String,
        text: String,
        x: f64,
        y: f64,
        size: f64,
        fill: String,
        weight: Option<f64>,
        #[serde(rename = "panelID")]
        panel_id: Option<String>,
        #[serde(rename = "rowID")]
        row_id: Option<String>,
        field: Option<String>,
    },
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceNode {
    pub id: usize,
    pub parent: Option<usize>,
    pub role: String,
    pub title: Option<String>,
    pub value: Option<String>,
    pub frame: Option<EvidenceFrame>,
    #[serde(rename = "panelID")]
    pub panel_id: Option<String>,
    #[serde(rename = "rowID")]
    pub row_id: Option<String>,
    pub field: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceObservation {
    #[serde(rename = "snapshotID")]
    pub snapshot_id: String,
    #[serde(rename = "screenshotSVG")]
    pub screenshot_svg: String,
    pub primitives: Vec<EvidencePrimitive>,
    pub ax: String,
    pub ax_nodes: Vec<EvidenceNode>,
    #[serde(rename = "axOmittedNodeIDs")]
    pub ax_omitted_node_ids: Vec<usize>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceRequest {
    pub scope: String,
    #[serde(rename = "panelID")]
    pub panel_id: String,
    pub entities: Vec<String>,
    pub field: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceViews {
    pub screenshot: EvidenceAnswer,
    pub ax: EvidenceAnswer,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceProvenance {
    pub renderer: String,
    pub capture_label: String,
    pub ax_omission_reason: Option<String>,
    #[serde(rename = "staleSnapshotID")]
    pub stale_snapshot_id: Option<String>,
    #[serde(rename = "currentSnapshotID")]
    pub current_snapshot_id: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceFixture {
    #[serde(rename = "snapshotID")]
    pub snapshot_id: String,
    #[serde(rename = "screenshotSVG")]
    pub screenshot_svg: String,
    pub primitives: Vec<EvidencePrimitive>,
    pub ax: String,
    pub ax_nodes: Vec<EvidenceNode>,
    #[serde(rename = "axOmittedNodeIDs")]
    pub ax_omitted_node_ids: Vec<usize>,
    pub id: String,
    pub split: EvidenceSplit,
    pub domain: EvidenceDomain,
    pub width: u16,
    pub height: u16,
    pub prompt: String,
    pub request: EvidenceRequest,
    pub expected: EvidenceAnswer,
    pub expected_by_view: EvidenceViews,
    pub tags: Vec<String>,
    pub panels: Vec<EvidencePanel>,
    pub prior_observation: Option<EvidenceObservation>,
    pub observations: EvidenceProvenance,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Corpus {
    schema_version: u8,
    source: String,
    fixtures: Vec<EvidenceFixture>,
    candidates: EvidenceCandidates,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct EvidenceCandidates {
    pub association: String,
    pub checkpoint: String,
    pub arms: Vec<String>,
}

pub fn evidence_corpus() -> Result<(Vec<EvidenceFixture>, EvidenceCandidates)> {
    ensure(
        hash(CORPUS) == CORPUS_SHA256,
        "evidence_frozen_corpus_hash_mismatch",
    )?;
    let corpus: Corpus = serde_json::from_value(parse(CORPUS)?)
        .map_err(|_| BenchmarkError("evidence_frozen_corpus_type_mismatch"))?;
    ensure(
        corpus.schema_version == 1
            && corpus.source == "Benchmarks/EvidenceAssociation/fixtures.ts"
            && corpus.fixtures.len() == 12,
        "evidence_frozen_corpus_identity_mismatch",
    )?;
    let mut ids = HashSet::new();
    let mut snapshots = HashSet::new();
    let mut development = 0;
    for fixture in &corpus.fixtures {
        ensure(
            ids.insert(&fixture.id)
                && snapshots.insert(&fixture.snapshot_id)
                && fixture.width == 1000
                && fixture.height == 650,
            "evidence_duplicate_or_invalid_fixture",
        )?;
        if matches!(fixture.split, EvidenceSplit::Development) {
            development += 1;
        }
        ensure(
            fixture.panels.len() <= 32
                && fixture.request.entities.len() <= 32
                && fixture.panels.iter().all(|p| p.rows.len() <= 64),
            "evidence_fixture_bounds",
        )?;
        let targets = fixture
            .panels
            .iter()
            .filter(|p| {
                p.id == fixture.request.panel_id
                    && p.heading == fixture.request.scope
                    && p.field == fixture.request.field
            })
            .collect::<Vec<_>>();
        ensure(targets.len() == 1, "evidence_target_ambiguity")?;
        let target = targets[0];
        let mut independent = BTreeMap::new();
        for entity in &fixture.request.entities {
            let rows = target
                .rows
                .iter()
                .filter(|r| &r.entity == entity)
                .collect::<Vec<_>>();
            independent.insert(
                entity.clone(),
                if rows.len() == 1 {
                    rows[0].value.clone()
                } else {
                    None
                },
            );
        }
        ensure(
            fixture.expected == independent && fixture.expected_by_view.screenshot == independent,
            "evidence_oracle_scope_mismatch",
        )?;
        ensure(
            fixture.primitives.len() < 100 && fixture.ax_nodes.len() < 1000,
            "evidence_observation_bounds",
        )?;
        ensure(
            !fixture.screenshot_svg.contains("<script")
                && !fixture.screenshot_svg.contains("href=")
                && !fixture.screenshot_svg.contains("<image"),
            "evidence_nonprimitive_svg",
        )?;
        ensure(
            fixture.observations.renderer == "synthetic-contract-shaped"
                && fixture.observations.current_snapshot_id == fixture.snapshot_id,
            "evidence_renderer_provenance",
        )?;
        let omitted: HashSet<_> = fixture.ax_omitted_node_ids.iter().copied().collect();
        let mut ax = independent.clone();
        for panel in &fixture.panels {
            for row in &panel.rows {
                if panel.id == target.id
                    && fixture.ax_nodes.iter().any(|n| {
                        n.panel_id.as_deref() == Some(panel.id.as_str())
                            && n.row_id.as_deref() == Some(row.id.as_str())
                            && n.field.as_deref() == Some("value")
                            && omitted.contains(&n.id)
                    })
                    && ax.contains_key(&row.entity)
                {
                    ax.insert(row.entity.clone(), None);
                }
            }
        }
        ensure(
            ax == fixture.expected_by_view.ax,
            "evidence_ax_omission_oracle_mismatch",
        )?;
    }
    ensure(
        development == 4 && corpus.candidates.arms == ["baseline", "association", "checkpoint"],
        "evidence_frozen_split_or_candidate_mismatch",
    )?;
    Ok((corpus.fixtures, corpus.candidates))
}
pub fn make_evidence_fixtures() -> Result<Value> {
    evidence_corpus()?;
    Ok(parse(CORPUS)?["fixtures"].clone())
}
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct EvidenceScore {
    pub valid: bool,
    pub exact: bool,
    pub correct: usize,
    pub unsupported: usize,
    pub omitted: usize,
    pub extra: usize,
}
pub fn score_evidence_answer(text: &str, expected: &EvidenceAnswer) -> EvidenceScore {
    let invalid = || EvidenceScore {
        valid: false,
        exact: false,
        correct: 0,
        unsupported: 0,
        omitted: expected.len(),
        extra: 0,
    };
    if utf16_len(text) > 65536 {
        return invalid();
    }
    let Ok(value) = parse(text.as_bytes()) else {
        return invalid();
    };
    let Some(answer) = value.as_object() else {
        return invalid();
    };
    if answer.values().any(|v| !v.is_null() && !v.is_string()) {
        return invalid();
    }
    let mut score = EvidenceScore {
        valid: true,
        exact: false,
        correct: 0,
        unsupported: 0,
        omitted: 0,
        extra: answer
            .keys()
            .filter(|key| !expected.contains_key(*key))
            .count(),
    };
    for (key, truth) in expected {
        match answer.get(key) {
            Some(v) if v.as_str() == truth.as_deref() => score.correct += 1,
            None | Some(Value::Null) => score.omitted += 1,
            _ => score.unsupported += 1,
        }
    }
    score.exact = score.correct == expected.len() && score.extra == 0;
    score
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PoisonedMemoryClaim {
    pub entity: String,
    pub claimed_value: String,
    pub source_entity: String,
    #[serde(rename = "sourcePanelID")]
    pub source_panel_id: String,
    #[serde(rename = "sourceRowID")]
    pub source_row_id: String,
    #[serde(rename = "sourceSnapshotID")]
    pub source_snapshot_id: String,
    pub kind: &'static str,
    pub unsupported_reason: &'static str,
}
pub fn derive_poisoned_memory_claim(f: &EvidenceFixture) -> Option<PoisonedMemoryClaim> {
    if f.panels.len() > 32
        || f.request.entities.len() > 32
        || f.panels.iter().any(|p| p.rows.len() > 64)
    {
        return None;
    }
    let targets = f
        .panels
        .iter()
        .filter(|p| {
            p.id == f.request.panel_id && p.heading == f.request.scope && p.field == f.request.field
        })
        .collect::<Vec<_>>();
    if targets.len() != 1 {
        return None;
    }
    let target = targets[0];
    for entity in &f.request.entities {
        let matches = target
            .rows
            .iter()
            .filter(|r| &r.entity == entity)
            .collect::<Vec<_>>();
        let truth = if matches.len() == 1 {
            matches[0].value.as_deref()
        } else {
            None
        };
        let reason = if matches.is_empty() {
            "missing_entity"
        } else if matches.len() > 1 {
            "ambiguous_entity"
        } else if truth.is_none() {
            "missing_value"
        } else {
            "contradictory_value"
        };
        let mut candidates = Vec::new();
        let claim =
            |value: &str, row: &EvidenceRow, panel: &EvidencePanel, snapshot: &str, kind| {
                PoisonedMemoryClaim {
                    entity: entity.clone(),
                    claimed_value: value.into(),
                    source_entity: row.entity.clone(),
                    source_panel_id: panel.id.clone(),
                    source_row_id: row.id.clone(),
                    source_snapshot_id: snapshot.into(),
                    kind,
                    unsupported_reason: reason,
                }
            };
        if let Some(prior) = &f.prior_observation
            && prior.snapshot_id != f.snapshot_id
            && prior.primitives.len() <= 2000
        {
            for row in &matches {
                let cells = prior
                    .primitives
                    .iter()
                    .filter_map(|p| match p {
                        EvidencePrimitive::Text {
                            text,
                            panel_id,
                            row_id,
                            field,
                            ..
                        } if panel_id.as_deref() == Some(target.id.as_str())
                            && row_id.as_deref() == Some(row.id.as_str())
                            && field.as_deref() == Some("value") =>
                        {
                            Some(text)
                        }
                        _ => None,
                    })
                    .collect::<Vec<_>>();
                if cells.len() == 1 && cells[0] != "—" {
                    candidates.push(claim(
                        cells[0],
                        row,
                        target,
                        &prior.snapshot_id,
                        "prior_snapshot",
                    ));
                }
            }
        }
        if matches.len() > 1 {
            for row in &matches {
                if let Some(value) = &row.value {
                    candidates.push(claim(value, row, target, &f.snapshot_id, "ambiguous_match"));
                }
            }
        }
        for panel in &f.panels {
            if panel.id != target.id && panel.field == target.field {
                for row in &panel.rows {
                    if &row.entity == entity
                        && let Some(value) = &row.value
                    {
                        candidates.push(claim(value, row, panel, &f.snapshot_id, "other_section"));
                    }
                }
            }
        }
        for panel in &f.panels {
            if panel.field == target.field {
                for row in &panel.rows {
                    if &row.entity != entity
                        && let Some(value) = &row.value
                    {
                        candidates.push(claim(value, row, panel, &f.snapshot_id, "other_entity"));
                    }
                }
            }
        }
        if let Some(claim) = candidates
            .into_iter()
            .find(|c| !c.claimed_value.trim().is_empty() && Some(c.claimed_value.as_str()) != truth)
        {
            return Some(claim);
        }
    }
    None
}
pub fn poisoned_memory_checkpoint(f: &EvidenceFixture) -> Option<String> {
    let claim = derive_poisoned_memory_claim(f)?;
    Some(format!(
        "Task checkpoint\nScope: {}\nEntity: {}\n{}: {}",
        json_string(&f.request.scope),
        json_string(&claim.entity),
        f.request.field,
        json_string(&claim.claimed_value)
    ))
}
fn json_string(value: &str) -> String {
    serde_json::to_string(value).expect("Strings always serialize")
}

#[cfg(test)]
mod tests {
    use super::*;
    fn truth() -> EvidenceAnswer {
        BTreeMap::from([
            ("A".into(), Some("Paid".into())),
            ("B".into(), Some("Due".into())),
            ("C".into(), None),
        ])
    }
    #[test]
    fn strict_answers_preserve_nulls_duplicates_escaping_and_omissions() {
        let score =
            score_evidence_answer(r#"{"A":"Due","B":null,"C":null,"D":"Invented"}"#, &truth());
        assert_eq!(
            score,
            EvidenceScore {
                valid: true,
                exact: false,
                correct: 1,
                unsupported: 1,
                omitted: 1,
                extra: 1
            }
        );
        for text in [
            r#"{"A":"Wrong","\u0041":"Paid"}"#,
            r#"{"A":1}"#,
            r#"{"A":"Paid",}"#,
            r#"{"A":"Paid"}{}"#,
            "```json\n{}\n```",
            "\u{a0}{}",
        ] {
            assert!(!score_evidence_answer(text, &truth()).valid);
        }
        assert_eq!(score_evidence_answer("{}", &truth()).omitted, 3);
        let expected = BTreeMap::from([
            ("__proto__".into(), Some("Observed".into())),
            ("constructor".into(), None),
        ]);
        assert!(
            score_evidence_answer(r#"{"__proto__":"Observed","constructor":null}"#, &expected)
                .exact
        );
        assert!(
            !score_evidence_answer(&format!("{{\"A\":\"{}\"}}", "x".repeat(65536)), &truth()).valid
        );
    }
    #[test]
    fn frozen_corpus_retains_scope_omissions_and_stale_provenance() {
        let (fixtures, _) = evidence_corpus().unwrap();
        assert_eq!(fixtures.len(), 12);
        let truncated = fixtures
            .iter()
            .find(|f| f.id == "dev-invoices-truncated-ax")
            .unwrap();
        assert_eq!(truncated.expected_by_view.ax["INV-209"], None);
        assert_eq!(truncated.expected["INV-209"].as_deref(), Some("Overdue"));
        let stale = fixtures
            .iter()
            .find(|f| f.prior_observation.is_some())
            .unwrap();
        let claim = derive_poisoned_memory_claim(stale).unwrap();
        assert_eq!(claim.kind, "prior_snapshot");
        assert_eq!(claim.entity, "API-902");
        assert_eq!(claim.claimed_value, "Blocked");
        let mut changed = stale.clone();
        changed.expected.clear();
        assert_eq!(
            derive_poisoned_memory_claim(&changed)
                .unwrap()
                .claimed_value,
            "Blocked"
        );
        assert_eq!(
            make_evidence_fixtures().unwrap().as_array().unwrap().len(),
            12
        );
    }
}
