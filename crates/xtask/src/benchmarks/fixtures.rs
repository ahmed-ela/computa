//! The deterministic legacy AXAssociation fixture protocol, rendered by the
//! production compact formatter. This never inspects or controls an application.
use super::*;
use computa_harness::formatter::{FormatterOptions, format};
use computa_macos::{AxNode, AxSnapshot, WindowInfo};
use serde_json::json;
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
        value: value.map(Into::into),
        element_description: None,
        help: None,
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
fn snapshot(nested: bool, first: &str, second: &str) -> AxSnapshot {
    let mut nodes = vec![
        node(0, None, "AXWindow", Some("Synthetic orders"), None),
        node(1, Some(0), "AXWebArea", Some("Orders"), None),
    ];
    for (label, status, title_backed) in [("Order A", first, false), ("Order B", second, true)] {
        let card = nodes.len();
        nodes.push(node(card, Some(1), "AXGroup", None, None));
        nodes.push(node(
            nodes.len(),
            Some(card),
            "AXHeading",
            Some(label),
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
    AxSnapshot {
        id: Uuid::parse_str("11111111-1111-4111-8111-111111111111")
            .expect("fixed valid fixture UUID"),
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
fn quoted_end(bytes: &[u8], start: usize) -> Option<usize> {
    if bytes.get(start) != Some(&b'"') {
        return None;
    }
    let mut cursor = start + 1;
    while cursor < bytes.len() {
        match bytes[cursor] {
            b'\\' => cursor += 2,
            b'"' => return Some(cursor + 1),
            _ => cursor += 1,
        }
    }
    None
}
/// Removes only structural tokens outside quoted source fields. A label that
/// happens to contain ` parent=` or `sibling_heading=` is preserved verbatim.
fn ablate(observation: &str) -> Result<String> {
    let mut lines = vec![];
    for line in observation.lines() {
        let bytes = line.as_bytes();
        let mut cursor = 0;
        let mut copied = 0;
        let mut output = String::new();
        while cursor < bytes.len() {
            if bytes[cursor] == b'"' {
                cursor = quoted_end(bytes, cursor)
                    .ok_or(BenchmarkError("fixture_invalid_quoted_field"))?;
                continue;
            }
            let tail = &bytes[cursor..];
            let end = if tail.starts_with(b" parents=[") {
                let start = cursor + b" parents=[".len();
                let length = bytes[start..]
                    .iter()
                    .position(|byte| *byte == b']')
                    .ok_or(BenchmarkError("fixture_invalid_parent_map"))?;
                Some(start + length + 1)
            } else if tail.starts_with(b" parent=") {
                let start = cursor + b" parent=".len();
                let mut end = start;
                if bytes.get(end) == Some(&b'-') {
                    end += 1;
                } else {
                    while bytes.get(end).is_some_and(u8::is_ascii_digit) {
                        end += 1;
                    }
                }
                ensure(end > start, "fixture_invalid_parent")?;
                for flag in [
                    b" ancestry_unknown=1".as_slice(),
                    b" ancestry_truncated=1".as_slice(),
                ] {
                    if bytes[end..].starts_with(flag) {
                        end += flag.len();
                        break;
                    }
                }
                Some(end)
            } else if tail.starts_with(b" sibling_heading=#") {
                let mut end = cursor + b" sibling_heading=#".len();
                let start = end;
                while bytes.get(end).is_some_and(u8::is_ascii_digit) {
                    end += 1;
                }
                ensure(
                    end > start && bytes.get(end) == Some(&b':'),
                    "fixture_invalid_sibling_heading",
                )?;
                Some(
                    quoted_end(bytes, end + 1)
                        .ok_or(BenchmarkError("fixture_invalid_sibling_heading"))?,
                )
            } else {
                None
            };
            if let Some(end) = end {
                output.push_str(&line[copied..cursor]);
                cursor = end;
                copied = end;
            } else {
                cursor += 1;
            }
        }
        output.push_str(&line[copied..]);
        lines.push(output);
    }
    Ok(lines.join("\n"))
}

pub fn make_ax_fixtures() -> Result<Value> {
    let mut fixtures = vec![];
    for nested in [false, true] {
        for reversed in [false, true] {
            let first = if reversed {
                "Delivered Friday"
            } else {
                "Arrives Tuesday"
            };
            let second = if reversed {
                "Arrives Tuesday"
            } else {
                "Delivered Friday"
            };
            let source = snapshot(nested, first, second);
            let target = source
                .elements
                .iter()
                .find(|node| {
                    node.role.as_deref() == Some("AXStaticText")
                        && node.value.as_deref() == Some(first)
                })
                .ok_or(BenchmarkError("fixture_target_missing"))?;
            for limited in [false, true] {
                let formatted = format(
                    &source,
                    Some("Synthetic"),
                    &FormatterOptions {
                        element_limit: if limited { 6 } else { 240 },
                        field_character_limit: 72,
                        output_limit: 3000,
                        prioritizes_relevant_elements: true,
                        compact: true,
                        prioritizes_focused_document: true,
                        ..Default::default()
                    },
                )
                .map_err(|_| BenchmarkError("fixture_format_failed"))?
                .text;
                let target_observed = formatted
                    .lines()
                    .find(|line| line.starts_with(&format!("#{} ", target.index)))
                    .is_some_and(|line| line.contains(&format!("value=\"{first}\"")));
                ensure(
                    limited || target_observed,
                    "fixture_full_target_not_observed",
                )?;
                let ablated = ablate(&formatted)?;
                ensure(
                    formatted != ablated && !ablated.contains(" sibling_heading="),
                    "fixture_ablation_failed",
                )?;
                for (variant, observation) in
                    [("ancestry", formatted), ("without_ancestry", ablated)]
                {
                    fixtures.push(json!({
                        "id":format!("{}-{}-{}-{variant}",if nested {"nested"} else {"flat"},if reversed {"reversed"} else {"normal"},if limited {"limited"} else {"full"}),
                        "variant":variant,"expected":if target_observed {first} else {"UNOBSERVED"},
                        "targetObserved":target_observed,"observation":observation
                    }));
                }
            }
        }
    }
    Ok(Value::Array(fixtures))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_sixteen_fixture_shape_and_real_ranking_are_deterministic() {
        let fixtures = make_ax_fixtures().unwrap();
        assert_eq!(fixtures, make_ax_fixtures().unwrap());
        let fixtures = fixtures.as_array().unwrap();
        assert_eq!(fixtures.len(), 16);
        for pair in fixtures.chunks_exact(2) {
            assert_eq!(pair[0]["variant"], "ancestry");
            assert_eq!(pair[1]["variant"], "without_ancestry");
            assert_eq!(pair[0]["expected"], pair[1]["expected"]);
            assert_eq!(pair[0]["targetObserved"], true);
            assert!(
                pair[0]["observation"]
                    .as_str()
                    .unwrap()
                    .contains(" parents=[")
            );
            assert!(
                !pair[1]["observation"]
                    .as_str()
                    .unwrap()
                    .contains(" parents=[")
            );
            assert_eq!(
                pair[0]["observation"]
                    .as_str()
                    .unwrap()
                    .lines()
                    .filter(|line| line.starts_with('#'))
                    .count(),
                if pair[0]["id"].as_str().unwrap().contains("-limited-") {
                    6
                } else if pair[0]["id"].as_str().unwrap().starts_with("nested-") {
                    12
                } else {
                    10
                }
            );
            assert_eq!(
                ablate(pair[0]["observation"].as_str().unwrap()).unwrap(),
                pair[1]["observation"]
            );
        }
    }
    #[test]
    fn legacy_flat_full_observation_protocol_is_byte_exact() {
        let fixtures = make_ax_fixtures().unwrap();
        let expected = [
            "AXSNAPSHOT id=11111111-1111-4111-8111-111111111111 pid=4242 app=\"Synthetic\" bundle=\"example.synthetic\" root=0 shown=10 total=10 source_truncated=0 output_truncated=0 parents=[0:-,1:0,2:1,6:1]",
            "#0 role=\"AXWindow\" label=\"Synthetic orders\" actions=[] parent=-",
            "#1 role=\"AXWebArea\" label=\"Orders\" actions=[] parent=0",
            "#3 role=\"AXHeading\" label=\"Order A\" actions=[] parent=2",
            "#5 role=\"AXButton\" label=\"Details\" actions=[\"AXPress\"] parent=2",
            "#4 role=\"AXStaticText\" value=\"Arrives Tuesday\" actions=[] sibling_heading=#3:\"Order A\" parent=2",
            "#9 role=\"AXButton\" label=\"Details\" actions=[\"AXPress\"] parent=6",
            "#7 role=\"AXHeading\" label=\"Order B\" actions=[] parent=6",
            "#8 role=\"AXStaticText\" label=\"Delivered Friday\" actions=[] sibling_heading=#7:\"Order B\" parent=6",
            "#2 role=\"AXGroup\" actions=[] parent=1",
            "#6 role=\"AXGroup\" actions=[] parent=1",
        ].join("\n");
        assert_eq!(fixtures[0]["observation"], expected);
    }
    #[test]
    fn ablation_preserves_structural_looking_source_text_and_escaped_quotes() {
        let raw = "AXSNAPSHOT app=\"A parents=[1:0]\" parents=[0:-,1:0]\n#4 role=\"AXStaticText\" value=\"literal parent=4 sibling_heading=#1:\\\"fake\\\"\" sibling_heading=#3:\"real \\\"heading\\\"\" parent=2\n#8 role=\"AXGroup\" parent=- ancestry_unknown=1";
        assert_eq!(
            ablate(raw).unwrap(),
            "AXSNAPSHOT app=\"A parents=[1:0]\"\n#4 role=\"AXStaticText\" value=\"literal parent=4 sibling_heading=#1:\\\"fake\\\"\"\n#8 role=\"AXGroup\""
        );
    }
}
