// Appended inside the exact unchanged allocator module; this function only measures candidates.
pub(super) fn audit_caps(history: &[ResponseItemEnvelope], turn: &str) -> serde_json::Value {
    let mut pending = HashMap::new();
    let mut pairs = Vec::new();
    for (index, envelope) in history.iter().enumerate() {
        assert_eq!(envelope.turn_id(), Some(turn), "wrong-turn receipt");
        match &envelope.item {
            ResponseItem::FunctionCall { call_id, .. } => {
                assert!(
                    pending
                        .insert(call_id.as_str(), (index, envelope))
                        .is_none()
                );
            }
            ResponseItem::FunctionCallOutput {
                call_id, output, ..
            } => {
                assert!(
                    latest_observation_image(output).unwrap().is_none(),
                    "this floor fixture is text-only"
                );
                let (call_index, call) = pending.remove(call_id.as_deref().unwrap()).unwrap();
                pairs.push((call_index, call, index, envelope));
            }
            _ => panic!("unexpected receipt type"),
        }
    }
    assert!(pending.is_empty());
    let latest_index = pairs.last().unwrap().2;
    let mut passes = Vec::new();
    for latest_cap in LATEST_OUTPUT_TEXT_CAPS {
        for older_cap in OUTPUT_TEXT_CAPS
            .into_iter()
            .filter(|cap| *cap <= latest_cap)
        {
            let mut retained = Vec::new();
            let mut per_item_valid = true;
            let mut text_bytes = 0;
            for &(call_index, call, index, source) in &pairs {
                let mut receipt = source.clone();
                let ResponseItem::FunctionCallOutput { output, .. } = &mut receipt.item else {
                    unreachable!()
                };
                let cap = if index == latest_index {
                    latest_cap
                } else {
                    older_cap
                };
                *output = bounded_output(output, cap, false).unwrap();
                let bytes = output_text_bytes(&output.body);
                text_bytes += bytes;
                let serialized = serde_json::to_vec(&receipt.item).unwrap().len();
                per_item_valid &= bytes <= cap
                    && serialized
                        <= if index == latest_index {
                            MAX_LATEST_OUTPUT_BYTES
                        } else {
                            MAX_OUTPUT_BYTES
                        };
                retained.push((call_index, call.clone()));
                retained.push((index, receipt));
            }
            retained.sort_by_key(|(index, _)| *index);
            let items: Vec<_> = retained.iter().map(|(_, item)| item.item.clone()).collect();
            let metadata: Vec<_> = retained.iter().map(|(_, item)| &item.metadata).collect();
            let canonical = serde_json::to_vec(&items).unwrap().len()
                + serde_json::to_vec(&metadata).unwrap().len();
            let mut projected = items;
            prepare_input_for_non_openai_provider(&mut projected);
            let provider = serde_json::to_vec(&projected).unwrap().len();
            passes.push(serde_json::json!({
                "latestCap": latest_cap, "olderCap": older_cap, "providerBytes": provider,
                "canonicalBytes": canonical, "outputTextBytes": text_bytes,
                "perItemValid": per_item_valid,
                "fits": per_item_valid && provider <= MAX_RECEIPT_BYTES && canonical <= MAX_CANONICAL_RECEIPT_BYTES,
            }));
        }
    }
    let minimum = passes
        .iter()
        .filter(|pass| pass["perItemValid"] == true)
        .min_by_key(|pass| pass["providerBytes"].as_u64().unwrap())
        .unwrap()
        .clone();
    serde_json::json!({ "pairs": pairs.len(), "capCombinations": passes.len(),
        "fittingCombinations": passes.iter().filter(|pass| pass["fits"] == true).count(),
        "providerLimit": MAX_RECEIPT_BYTES, "canonicalLimit": MAX_CANONICAL_RECEIPT_BYTES,
        "minimumProviderCandidate": minimum })
}
// END RECEIPT MODULE AUDIT

use codex_history::{ResponseItemEnvelope, RolloutItem};
use codex_protocol::models::{FunctionCallOutputBody, FunctionCallOutputContentItem, ResponseItem};
use compact_tool_receipts::{ReceiptProvider, current_turn_receipts};
use std::collections::HashSet;
use std::io::{BufRead, BufReader};

fn main() {
    // Only sanitized failures may be printed; input bodies and serde error excerpts stay private.
    std::panic::set_hook(Box::new(|_| {
        eprintln!("offline native audit precondition failed")
    }));
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(args.len(), 3);
    let turn = &args[2];
    let path = std::path::Path::new(&args[1]);
    assert!(path.is_absolute());
    let metadata = std::fs::symlink_metadata(path).unwrap();
    assert!(metadata.is_file() && metadata.len() <= 64 * 1024 * 1024);
    let mut active = false;
    let mut started = 0;
    let mut completed = 0;
    let mut checkpoint_line = 0;
    let mut checkpoints = 0;
    let mut appended = 0;
    let mut receipts = Vec::new();
    let mut checkpoint_receipts = Vec::new();
    let mut completion_line = 0;
    let mut missing_post_metadata = 0;
    let mut post_history_truncations = 0;
    for (line_index, line) in BufReader::new(std::fs::File::open(path).unwrap())
        .lines()
        .enumerate()
    {
        let line = line.unwrap();
        assert!(line.len() <= 16 * 1024 * 1024);
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        let payload = &value["payload"];
        if value["type"] == "event_msg"
            && payload["type"] == "task_started"
            && payload["turn_id"] == *turn
        {
            assert_eq!(started, 0);
            active = true;
            started += 1;
        }
        if !active {
            continue;
        }
        if value["type"] == "event_msg"
            && payload["type"] == "task_complete"
            && payload["turn_id"] == *turn
        {
            assert!(
                payload
                    .to_string()
                    .contains("all genuine tool receipts cannot fit")
            );
            completed += 1;
            completion_line = line_index + 1;
            active = false;
            continue;
        }
        if value["type"] != "compacted" && value["type"] != "response_item" {
            continue;
        }
        // The real rollout crate preserves canonical decimal/metadata decoding.
        let decoded = codex_rollout::parse_rollout_line(&line).unwrap();
        match decoded.item {
            RolloutItem::Compacted(compacted) => {
                let replacement = compacted.replacement_history.unwrap();
                receipts = replacement
                    .into_iter()
                    .filter(|item| is_receipt(item, turn))
                    .collect();
                assert!(!receipts.is_empty());
                checkpoint_receipts = receipts.clone();
                checkpoint_line = line_index + 1;
                checkpoints += 1;
                appended = 0;
                missing_post_metadata = 0;
                post_history_truncations = 0;
            }
            RolloutItem::ResponseItem(mut envelope)
                if checkpoint_line > 0 && is_receipt(&envelope, turn) =>
            {
                if envelope.metadata.is_none() {
                    missing_post_metadata += 1;
                }
                if let ResponseItem::FunctionCallOutput { output, .. } = &mut envelope.item {
                    let budget = envelope
                        .metadata
                        .as_ref()
                        .unwrap()
                        .history_truncation_token_limit
                        .unwrap();
                    let before = output.clone();
                    codex_utils_output_truncation::truncate_function_output_payload(
                        output,
                        codex_utils_output_truncation::TruncationPolicy::Tokens(budget),
                        |_| 0,
                    );
                    if *output != before {
                        post_history_truncations += 1;
                    }
                }
                receipts.push(envelope);
                appended += 1;
            }
            _ => {}
        }
    }
    assert_eq!((started, completed, active), (1, 1, false));
    assert_eq!(
        (
            checkpoints,
            checkpoint_receipts.len(),
            appended,
            receipts.len()
        ),
        (3, 42, 14, 56)
    );
    assert_eq!(
        post_history_truncations, 0,
        "unexpected body changes after normal history recording"
    );
    let calls: Vec<_> = receipts
        .iter()
        .filter_map(|item| match &item.item {
            ResponseItem::FunctionCall { call_id, .. } => Some(call_id),
            _ => None,
        })
        .collect();
    assert_eq!(calls.len(), 28);
    assert_eq!(calls.into_iter().collect::<HashSet<_>>().len(), 28);
    let error = current_turn_receipts(&receipts, turn, ReceiptProvider::External)
        .unwrap_err()
        .to_string();
    assert!(error.contains("all genuine tool receipts cannot fit"));
    assert!(current_turn_receipts(&checkpoint_receipts, turn, ReceiptProvider::External).is_ok());
    let audit = compact_tool_receipts::audit_caps(&receipts, turn);
    assert_eq!(audit["fittingCombinations"], 0);
    // Structural controls retain exact 28 call identities/arguments/order but shorten result bodies.
    let mut short = receipts.clone();
    for envelope in &mut short {
        if let ResponseItem::FunctionCallOutput { output, .. } = &mut envelope.item {
            output.body = FunctionCallOutputBody::Text("synthetic ok".to_string());
        }
    }
    let bounded = current_turn_receipts(&short, turn, ReceiptProvider::External).unwrap();
    assert_eq!(bounded.len(), 56);
    assert_eq!(
        bounded, short,
        "short controls must preserve every exact canonical envelope"
    );
    assert_eq!(
        current_turn_receipts(&bounded, turn, ReceiptProvider::External).unwrap(),
        bounded
    );
    let mut duplicate = short.clone();
    duplicate.insert(1, short[0].clone());
    assert!(
        current_turn_receipts(&duplicate, turn, ReceiptProvider::External)
            .unwrap_err()
            .to_string()
            .contains("duplicate function call identity")
    );
    let mut orphan = short.clone();
    orphan.remove(0);
    assert!(current_turn_receipts(&orphan, turn, ReceiptProvider::External).is_err());
    let pending = &short[..short.len() - 1];
    assert!(
        current_turn_receipts(pending, turn, ReceiptProvider::External)
            .unwrap_err()
            .to_string()
            .contains("no completed current-turn output")
    );
    let image_count = receipts
        .iter()
        .map(|item| match &item.item {
            ResponseItem::FunctionCallOutput { output, .. } => match &output.body {
                FunctionCallOutputBody::ContentItems(items) => items
                    .iter()
                    .filter(|item| matches!(item, FunctionCallOutputContentItem::InputImage { .. }))
                    .count(),
                _ => 0,
            },
            _ => 0,
        })
        .sum::<usize>();
    assert_eq!(image_count, 0);
    println!(
        "{}",
        serde_json::json!({ "nativeAllocatorRejected": true, "failureClass": "serialized_receipt_budget",
        "checkpointLine": checkpoint_line, "completionLine": completion_line, "checkpoints": checkpoints,
        "checkpointPairs": checkpoint_receipts.len() / 2, "appendedPairs": appended / 2,
        "postItemsWithoutEnvelopeMetadata": missing_post_metadata,
        "postHistoryTruncations": post_history_truncations, "imageCount": image_count,
        "controlsPassed": 6, "nativeFloor": audit })
    );
}

fn is_receipt(envelope: &ResponseItemEnvelope, turn: &str) -> bool {
    envelope.turn_id() == Some(turn)
        && matches!(
            envelope.item,
            ResponseItem::FunctionCall { .. } | ResponseItem::FunctionCallOutput { .. }
        )
}
