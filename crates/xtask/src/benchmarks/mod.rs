//! Bounded benchmark tools. Synthetic observations never grant desktop authority.
mod association;
mod context;
mod evidence;
mod evidence_replay;
mod evidence_runner;
mod fixtures;
mod grounding_cascade;
mod images;
mod lifecycle;
mod lookup_server;
mod matrix;
mod matrix_runner;
mod native_matrix;
mod opaque;
mod paired_context;
mod parent_blocks;
mod receipt_floor;
mod replay;
mod rollouts;
mod serving;
mod streams;
mod wire;

pub use association::ax_run;
pub use context::{
    PreparedReplay, context_capture, context_replay, context_request, prepare_context_replay,
    summarize_context_response,
};
pub use evidence::{
    EvidenceAnswer, EvidenceCandidates, EvidenceFixture, EvidenceScore,
    derive_poisoned_memory_claim, evidence_corpus, make_evidence_fixtures,
    poisoned_memory_checkpoint, score_evidence_answer,
};
pub use evidence_replay::{
    RecordedRegression, RetentionReplay, prepare_recorded_regression, prepare_retention_replay,
};
pub use evidence_runner::{
    EvidenceArm, EvidenceMode, EvidenceReplayOptions, EvidenceRetentionOptions, EvidenceRunOptions,
    evidence_regression, evidence_retention, evidence_run, summarize_evidence,
};
pub use fixtures::make_ax_fixtures;
pub use grounding_cascade::{GroundingCascadeOptions, grounding_cascade};
pub use images::{format_ocr_files, native_ocr, render_fixtures};
pub use lifecycle::{
    ParentDeathOptions, ProcessIdentity, parent_death_probe, parent_death_supervisor,
    parse_process_identity, same_process_identity,
};
pub use lookup_server::serve_lookup_fixtures;
pub use matrix::summarize_computer_matrix;
pub use matrix_runner::{
    MatrixEvidence, MatrixFuture, MatrixOutcome, MatrixQualifier, MatrixRunOptions, MatrixTask,
    MatrixTrial, computer_matrix_plan, run_computer_matrix, run_computer_matrix_with_qualifier,
};
pub use native_matrix::{NativeMatrixConfig, NativeMatrixQualifier};
pub use opaque::{
    OPAQUE_QUESTION, OcrSource, OpaqueRunOptions, assess_perception, extract_capture, format_ocr,
    make_opaque_fixtures, opaque_run,
};
pub use paired_context::{
    PairedContext, PairingPlan, paired_context_files, parse_pairing_plan, prepare_paired_context,
};
pub use parent_blocks::group_ax_snapshot_parents;
pub use receipt_floor::{ReceiptFloorOptions, receipt_floor_audit};
pub use replay::replay_layout;
pub use rollouts::{
    audit_clickability, audit_lookup, receipt_text, summarize_clickability, summarize_lookup,
};
pub use serving::{
    BoundaryProbeOptions, ServingProbeOptions, boundary_probe, serving_probe,
    validate_boundary_exhausted, validate_boundary_overflow, validate_rust_boundary_overflow,
};
pub use streams::{
    CancelAt, DELAYED_CANCELLATION_MS, ObservationMode, SseDecoder, assert_early_cancellation,
    cancellation_reached, consistent_text, delayed_cancellation_reached, exact_text, final_text,
    stream_completed, stream_function_call,
};
pub use wire::audit_wire;

use serde_json::Value;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

pub const MODEL: &str = "lmstudio-community/Qwen3.5-4B-MLX-4bit";
const MAX_FILE: usize = 16 * 1024 * 1024;
#[derive(Debug, thiserror::Error)]
#[error("Benchmark stopped ({0}); no operation was retried")]
pub struct BenchmarkError(pub &'static str);
type Result<T> = std::result::Result<T, BenchmarkError>;
fn ensure(ok: bool, code: &'static str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(BenchmarkError(code))
    }
}
fn utf16_len(value: &str) -> usize {
    value.encode_utf16().count()
}
fn hash(value: impl AsRef<[u8]>) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(value.as_ref()))
}
fn read(path: &Path) -> Result<Vec<u8>> {
    read_bounded(path, MAX_FILE)
}
fn read_bounded(path: &Path, maximum: usize) -> Result<Vec<u8>> {
    ensure(
        (1..=64 * 1024 * 1024).contains(&maximum),
        "invalid_file_bound",
    )?;
    ensure(path.is_absolute(), "absolute_path_required")?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| BenchmarkError("file_read_failed_redacted"))?;
    let meta = file
        .metadata()
        .map_err(|_| BenchmarkError("file_metadata_failed_redacted"))?;
    ensure(
        meta.is_file() && meta.len() <= maximum as u64,
        "file_too_large_or_invalid",
    )?;
    let mut bytes = vec![];
    file.take((maximum + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| BenchmarkError("file_read_failed_redacted"))?;
    ensure(bytes.len() <= maximum, "file_grew_beyond_limit")?;
    Ok(bytes)
}
fn parse(bytes: &[u8]) -> Result<Value> {
    computa_contracts::strict_json::parse(bytes)
        .map_err(|_| BenchmarkError("invalid_json_redacted"))
}
fn read_json(path: &Path) -> Result<Value> {
    parse(&read(path)?)
}
fn read_text(path: &Path) -> Result<String> {
    String::from_utf8(read(path)?).map_err(|_| BenchmarkError("invalid_utf8_redacted"))
}
fn private_output(path: &Path) -> Result<PathBuf> {
    ensure(path.is_absolute(), "absolute_output_path_required")?;
    let meta =
        std::fs::symlink_metadata(path).map_err(|_| BenchmarkError("output_directory_missing"))?;
    ensure(
        meta.is_dir() && !meta.file_type().is_symlink() && meta.permissions().mode() & 0o077 == 0,
        "output_directory_must_be_private",
    )?;
    path.canonicalize()
        .map_err(|_| BenchmarkError("output_directory_invalid"))
}
fn save(output: &Path, name: &str, value: &Value) -> Result<()> {
    ensure(
        !name.is_empty() && !name.contains('/') && !name.contains('\0'),
        "invalid_output_name",
    )?;
    private_output(output)?;
    let bytes =
        serde_json::to_vec_pretty(value).map_err(|_| BenchmarkError("json_encode_failed"))?;
    ensure(bytes.len() <= MAX_FILE, "output_too_large")?;
    let temporary = output.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temporary)
            .map_err(|_| BenchmarkError("output_write_failed"))?;
        file.write_all(&bytes)
            .map_err(|_| BenchmarkError("output_write_failed"))?;
        file.sync_all()
            .map_err(|_| BenchmarkError("output_write_failed"))?;
        std::fs::rename(&temporary, output.join(name))
            .map_err(|_| BenchmarkError("output_write_failed"))?;
        File::open(output)
            .and_then(|directory| directory.sync_all())
            .map_err(|_| BenchmarkError("output_write_failed"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
async fn require_idle(lms: &Path) -> Result<()> {
    ensure(lms.is_absolute(), "absolute_lms_path_required")?;
    let mut command = tokio::process::Command::new(lms);
    command.args(["ps", "--json"]).kill_on_drop(true);
    let output = tokio::time::timeout(std::time::Duration::from_secs(10), command.output())
        .await
        .map_err(|_| BenchmarkError("model_state_timeout"))?
        .map_err(|_| BenchmarkError("model_state_unavailable"))?;
    ensure(
        output.status.success() && output.stdout.len() <= MAX_FILE,
        "model_state_unavailable",
    )?;
    let models = parse(&output.stdout)?;
    let list = models
        .as_array()
        .ok_or(BenchmarkError("invalid_model_state"))?;
    ensure(
        list.len() == 1
            && list[0]["identifier"] == MODEL
            && list[0]["status"] == "idle"
            && list[0]["queued"] == 0
            && list[0]["parallel"] == 1,
        "sole_idle_serial_model_required",
    )
}
fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(45))
        .build()
        .map_err(|_| BenchmarkError("http_client_unavailable"))
}
async fn response(client: &reqwest::Client, request: &Value) -> Result<(u16, Result<Value>)> {
    let response = client
        .post("http://127.0.0.1:1234/v1/responses")
        .json(request)
        .send()
        .await
        .map_err(|_| BenchmarkError("provider_transport_failed"))?;
    let status = response.status().as_u16();
    ensure(
        response
            .content_length()
            .is_none_or(|count| count <= MAX_FILE as u64),
        "provider_response_too_large",
    )?;
    let mut response = response;
    let mut bytes = vec![];
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| BenchmarkError("provider_transport_failed"))?
    {
        ensure(
            bytes.len() + chunk.len() <= MAX_FILE,
            "provider_response_too_large",
        )?;
        bytes.extend_from_slice(&chunk);
    }
    if !(200..300).contains(&status) {
        return Ok((status, Ok(Value::Null)));
    }
    Ok((status, parse(&bytes)))
}
fn final_answer(value: &Value) -> String {
    value["output"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "message" && item["role"] == "assistant")
        .flat_map(|item| item["content"].as_array().into_iter().flatten())
        .filter(|part| part["type"] == "output_text")
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .concat()
        .trim()
        .to_owned()
}
