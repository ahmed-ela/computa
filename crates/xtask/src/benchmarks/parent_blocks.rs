use std::collections::{HashMap, HashSet};
const MAX_RECORDS: usize = 2000;
const MAX_CHARACTERS: usize = 1_000_000;
const MAX_ID: u64 = 9_007_199_254_740_991;
fn id(value: &str) -> Option<u64> {
    if value.is_empty()
        || value.len() > 1 && value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    value.parse::<u64>().ok().filter(|value| *value <= MAX_ID)
}
fn fields(line: &str) -> Option<Vec<&str>> {
    let mut result = vec![];
    let (mut start, mut quoted, mut escaped) = (0, false, false);
    for (index, character) in line.char_indices() {
        if quoted {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                quoted = false;
            }
        } else if character == '"' {
            quoted = true;
        } else if character == ' ' {
            if index > start {
                result.push(&line[start..index]);
            }
            start = index + 1;
        } else if matches!(character, '\t' | '\r') {
            return None;
        }
    }
    if quoted || escaped {
        return None;
    }
    if start < line.len() {
        result.push(&line[start..]);
    }
    Some(result)
}
fn header(line: &str) -> Option<(u64, HashMap<u64, Option<u64>>)> {
    let tokens = fields(line)?;
    if tokens.first() != Some(&"AXSNAPSHOT") {
        return None;
    }
    let roots: Vec<_> = tokens
        .iter()
        .filter_map(|field| field.strip_prefix("root="))
        .collect();
    let maps: Vec<_> = tokens
        .iter()
        .filter_map(|field| field.strip_prefix("parents="))
        .collect();
    if roots.len() != 1 || maps.len() != 1 {
        return None;
    }
    let root = id(roots[0])?;
    let map = maps[0].strip_prefix('[')?.strip_suffix(']')?;
    let entries: Vec<_> = map.split(',').collect();
    if map.is_empty() || entries.len() > MAX_RECORDS {
        return None;
    }
    let mut parents = HashMap::new();
    for entry in entries {
        let (child, parent) = entry.split_once(':')?;
        let child = id(child)?;
        let parent = if parent == "-" {
            None
        } else {
            Some(id(parent)?)
        };
        if parents.insert(child, parent).is_some() {
            return None;
        }
    }
    if parents.get(&root) != Some(&None) {
        return None;
    }
    Some((root, parents))
}
struct Record<'a> {
    raw: &'a str,
    id: u64,
    parent: Option<u64>,
    stem: Option<&'a str>,
}
fn record(raw: &str) -> Option<Record<'_>> {
    let (prefix, _) = raw.split_once(' ')?;
    let identifier = id(prefix.strip_prefix('#')?)?;
    let tokens = fields(raw)?;
    let suffix = raw.rsplit_once(" parent=");
    let parent_fields = tokens
        .iter()
        .filter(|token| token.starts_with("parent="))
        .count();
    let unknown = tokens.iter().any(|token| {
        token.starts_with("ancestry_unknown=") || token.starts_with("ancestry_truncated=")
    });
    let parsed = suffix.and_then(|(stem, parent)| id(parent).map(|parent| (stem, parent)));
    let (parent, stem) =
        if let Some((stem, parent)) = parsed.filter(|_| parent_fields == 1 && !unknown) {
            (Some(parent), Some(stem))
        } else {
            (None, None)
        };
    Some(Record {
        raw,
        id: identifier,
        parent,
        stem,
    })
}
fn valid(
    record: &Record,
    root: u64,
    parents: &HashMap<u64, Option<u64>>,
    duplicates: &HashSet<u64>,
) -> bool {
    let Some(mut cursor) = record.parent else {
        return false;
    };
    if duplicates.contains(&record.id)
        || record.id == root
        || parents
            .get(&record.id)
            .is_some_and(|parent| *parent != record.parent)
    {
        return false;
    }
    let mut seen = HashSet::from([record.id]);
    for _ in 0..32 {
        if !seen.insert(cursor) || duplicates.contains(&cursor) || !parents.contains_key(&cursor) {
            return false;
        }
        if cursor == root {
            return parents.get(&cursor) == Some(&None);
        }
        let Some(Some(parent)) = parents.get(&cursor) else {
            return false;
        };
        cursor = *parent;
    }
    false
}
fn preserved(original: &[&str], encoded: &[String]) -> bool {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for raw in original {
        *counts.entry((*raw).into()).or_default() += 1;
    }
    let (mut parent, mut members, mut decoded) = (None, 0, 0);
    for line in encoded {
        if let Some(value) = line
            .strip_prefix("parent=")
            .and_then(|value| value.strip_suffix(" {"))
        {
            if parent.is_some() || id(value).is_none() {
                return false;
            }
            parent = Some(value);
            members = 0;
            continue;
        }
        if line == "}" {
            if parent.is_none() || members < 2 {
                return false;
            }
            parent = None;
            continue;
        }
        if line
            .split_once(' ')
            .and_then(|(prefix, _)| prefix.strip_prefix('#'))
            .and_then(id)
            .is_none()
        {
            return false;
        }
        let restored =
            parent.map_or_else(|| line.clone(), |parent| format!("{line} parent={parent}"));
        let Some(count) = counts.get_mut(&restored) else {
            return false;
        };
        if *count == 0 {
            return false;
        }
        *count -= 1;
        members += 1;
        decoded += 1;
    }
    parent.is_none() && decoded == original.len() && counts.values().all(|count| *count == 0)
}
/// Factor direct-parent suffixes only when the original record multiset and
/// header survive byte for byte. Bounds preserve the legacy UTF-16 accounting.
pub fn group_ax_snapshot_parents(snapshot: &str, character_budget: usize) -> String {
    let original = || snapshot.to_owned();
    if character_budget == 0
        || character_budget as u128 > MAX_ID as u128
        || super::utf16_len(snapshot) > MAX_CHARACTERS
    {
        return original();
    }
    let trailing = snapshot.ends_with('\n');
    let content = if trailing {
        &snapshot[..snapshot.len() - 1]
    } else {
        snapshot
    };
    let lines: Vec<_> = content.split('\n').collect();
    if lines.len() < 3 || lines.len() > MAX_RECORDS + 1 {
        return original();
    }
    let Some((root, parents)) = header(lines[0]) else {
        return original();
    };
    let mut records = vec![];
    let (mut seen, mut duplicates) = (HashSet::new(), HashSet::new());
    for line in &lines[1..] {
        let Some(record) = record(line) else {
            return original();
        };
        if !seen.insert(record.id) {
            duplicates.insert(record.id);
        }
        records.push(record);
    }
    let mut groups: HashMap<u64, Vec<usize>> = HashMap::new();
    for (index, record) in records.iter().enumerate() {
        if valid(record, root, &parents, &duplicates) {
            groups
                .entry(record.parent.unwrap())
                .or_default()
                .push(index);
        }
    }
    let mut emitted = HashSet::new();
    let mut output = vec![];
    for (index, record) in records.iter().enumerate() {
        let group = record
            .parent
            .and_then(|parent| groups.get(&parent))
            .filter(|members| members.len() >= 2 && members.contains(&index));
        if let Some(members) = group {
            let parent = record.parent.unwrap();
            if emitted.insert(parent) {
                output.push(format!("parent={parent} {{"));
                output.extend(
                    members
                        .iter()
                        .map(|index| records[*index].stem.unwrap().to_owned()),
                );
                output.push("}".into());
            }
        } else {
            output.push(record.raw.to_owned());
        }
    }
    let grouped = format!(
        "{}\n{}{}",
        lines[0],
        output.join("\n"),
        if trailing { "\n" } else { "" }
    );
    if super::utf16_len(&grouped) > super::utf16_len(snapshot)
        || super::utf16_len(&grouped) > character_budget
        || !preserved(&lines[1..], &output)
    {
        return original();
    }
    grouped
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(records: &[&str], parents: &str) -> String {
        format!(
            "AXSNAPSHOT root=0 parents=[{parents}]\n{}",
            records.join("\n")
        )
    }
    #[test]
    fn non_adjacent_siblings_are_grouped_without_changing_records() {
        let raw = snapshot(
            &[
                "#4 value=\"🍀 東京 parent=8\" parent=2",
                "#7 role=button parent=3",
                "#5 value=\"B\" parent=2",
                "#8 role=button parent=3",
            ],
            "0:-,1:0,2:1,3:1",
        );
        let out = group_ax_snapshot_parents(&raw, raw.len());
        assert!(out.contains("parent=2 {\n#4"));
        assert!(out.contains("parent=3 {\n#7"));
        assert!(preserved(
            &raw.split('\n').skip(1).collect::<Vec<_>>(),
            &out.split('\n')
                .skip(1)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        ));
        assert_eq!(group_ax_snapshot_parents(&out, out.len()), out);
    }
    #[test]
    fn ambiguity_cycles_duplicates_and_budgets_fail_closed() {
        for parents in [
            "0:-,2:2",
            "0:-,2:99",
            "0:-,2:0,2:0",
            "0:1,1:0,2:0",
            "0:-,2:04",
        ] {
            let raw = snapshot(
                &["#4 role=button parent=2", "#5 role=button parent=2"],
                parents,
            );
            assert_eq!(group_ax_snapshot_parents(&raw, raw.len()), raw);
        }
        for records in [
            ["#4 role=button parent=2", "#4 role=button parent=2"],
            ["#04 role=button parent=2", "#5 role=button parent=2"],
            ["#4 label=\"unclosed parent=2", "#5 role=button parent=2"],
        ] {
            let raw = snapshot(&records, "0:-,2:0");
            assert_eq!(group_ax_snapshot_parents(&raw, raw.len()), raw);
        }
        let raw = snapshot(
            &["#4 role=button parent=2", "#5 role=button parent=2"],
            "0:-,2:0",
        );
        let out = group_ax_snapshot_parents(&raw, raw.len());
        assert_ne!(out, raw);
        assert_eq!(
            group_ax_snapshot_parents(&raw, super::super::utf16_len(&out) - 1),
            raw
        );
    }
    #[test]
    fn parent_link_bound_and_record_limits_match_legacy() {
        let chain = |depth: usize| {
            std::iter::once("0:-".into())
                .chain((1..=depth).map(|n| format!("{n}:{}", n - 1)))
                .collect::<Vec<_>>()
                .join(",")
        };
        let within = snapshot(
            &["#100 role=button parent=31", "#101 role=button parent=31"],
            &chain(31),
        );
        assert!(group_ax_snapshot_parents(&within, within.len()).contains("parent=31 {"));
        let beyond = snapshot(
            &["#100 role=button parent=32", "#101 role=button parent=32"],
            &chain(32),
        );
        assert_eq!(group_ax_snapshot_parents(&beyond, beyond.len()), beyond);
        let raw = format!(
            "AXSNAPSHOT root=0 parents=[0:-,2:0]\n{}",
            (0..2001)
                .map(|n| format!("#{} role=button parent=2", n + 100))
                .collect::<Vec<_>>()
                .join("\n")
        );
        assert_eq!(group_ax_snapshot_parents(&raw, raw.len()), raw);
    }
}
