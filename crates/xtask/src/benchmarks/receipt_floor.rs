//! Exact pinned allocator instrumentation, offline only. No live inference.
use super::*;
use serde_json::json;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
const ALLOCATOR_HASH: &str = "ebef138ff0b4808fe21f081ad645f48311d2940b19f4994155796b87c6b46f6f";
const HARNESS: &str =
    include_str!("../../../../Benchmarks/ReceiptOverflow/native-floor-harness.rs");
const LIBRARIES: [(&str, &str); 6] = [
    ("codex_protocol", "libcodex_protocol-c20e9de3c3d8c0ee.rlib"),
    ("codex_history", "libcodex_history-735ccdf773b43ff1.rlib"),
    ("codex_rollout", "libcodex_rollout-a5b9b21ce7963d44.rlib"),
    (
        "codex_utils_output_truncation",
        "libcodex_utils_output_truncation-62bac46a284bf25f.rlib",
    ),
    ("base64", "libbase64-245335b498ff70ed.rlib"),
    ("serde_json", "libserde_json-3a9be4674f0338ce.rlib"),
];
#[derive(Clone, Debug)]
pub struct ReceiptFloorOptions {
    pub source: PathBuf,
    pub dependencies: PathBuf,
    pub compiler: PathBuf,
    pub rollout: PathBuf,
    pub turn: uuid::Uuid,
    pub output: PathBuf,
    pub manifest: PathBuf,
}
fn projection(client: &str) -> Result<String> {
    ensure(
        client.len() <= 4 * 1024 * 1024,
        "allocator_client_source_bound",
    )?;
    let pattern=regex::Regex::new(r"pub\(crate\) fn prepare_input_for_non_openai_provider\(input: &mut \[ResponseItem\]\) \{\n[\s\S]*?\n\}").map_err(|_|BenchmarkError("allocator_projection_pattern_invalid"))?;
    let matches = pattern.find_iter(client).collect::<Vec<_>>();
    ensure(matches.len() == 1, "one_exact_provider_projection_required")?;
    Ok(matches[0].as_str().into())
}
fn compose(allocator: &str, projection: &str, harness: &str) -> Result<String> {
    let pieces = harness
        .split("// END RECEIPT MODULE AUDIT")
        .collect::<Vec<_>>();
    ensure(
        pieces.len() == 2,
        "invalid_offline_instrumentation_boundary",
    )?;
    let code = format!(
        "mod client {{ use codex_protocol::models::ResponseItem;\n{projection}\n}}\nmod compact_tool_receipts {{\n{allocator}\n{}\n}}\n{}",
        pieces[0], pieces[1]
    );
    ensure(
        code.len() <= 8 * 1024 * 1024,
        "offline_compiler_source_bound",
    )?;
    Ok(code)
}
async fn capture(
    program: &Path,
    args: &[String],
    cwd: &Path,
    input: Option<&str>,
    seconds: u64,
    maximum: usize,
    output: &Path,
) -> Result<String> {
    ensure(
        program.is_absolute() && cwd.is_absolute(),
        "absolute_offline_command_paths_required",
    )?;
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LC_ALL", "C")
        .stdin(if input.is_some() {
            std::process::Stdio::piped()
        } else {
            std::process::Stdio::null()
        })
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| BenchmarkError("offline_command_spawn_failed"))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or(BenchmarkError("offline_command_stdout_missing"))?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or(BenchmarkError("offline_command_stderr_missing"))?;
    let operation = async {
        let write = async {
            if let Some(input) = input {
                let mut stdin = child
                    .stdin
                    .take()
                    .ok_or(BenchmarkError("offline_compiler_stdin_missing"))?;
                stdin
                    .write_all(input.as_bytes())
                    .await
                    .map_err(|_| BenchmarkError("offline_compiler_input_failed"))?;
                stdin
                    .shutdown()
                    .await
                    .map_err(|_| BenchmarkError("offline_compiler_input_failed"))?;
            }
            Ok::<_, BenchmarkError>(())
        };
        let out = async {
            let mut bytes = vec![];
            (&mut stdout)
                .take((maximum + 1) as u64)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| BenchmarkError("offline_command_output_failed"))?;
            ensure(bytes.len() <= maximum, "offline_command_output_bound")?;
            Ok::<_, BenchmarkError>(bytes)
        };
        let err = async {
            let mut bytes = vec![];
            (&mut stderr)
                .take(1024 * 1024 + 1)
                .read_to_end(&mut bytes)
                .await
                .map_err(|_| BenchmarkError("offline_command_diagnostic_failed"))?;
            ensure(
                bytes.len() <= 1024 * 1024,
                "offline_command_diagnostic_bound",
            )?;
            Ok::<_, BenchmarkError>(bytes)
        };
        let (_, out, err) = tokio::try_join!(write, out, err)?;
        let status = child
            .wait()
            .await
            .map_err(|_| BenchmarkError("offline_command_wait_failed"))?;
        if !status.success() {
            super::opaque::write_new(
                output,
                &format!("failure-{}.txt", uuid::Uuid::new_v4()),
                &err,
            )?;
            return Err(BenchmarkError(
                "offline_command_failed_private_diagnostics_retained",
            ));
        }
        String::from_utf8(out)
            .map(|out| out.trim().into())
            .map_err(|_| BenchmarkError("offline_command_output_utf8"))
    };
    tokio::time::timeout(Duration::from_secs(seconds), operation)
        .await
        .map_err(|_| BenchmarkError("offline_command_deadline"))?
}
async fn verify_source(
    source: &Path,
    pin: &crate::runtime_source::RuntimePin,
    patch: &[u8],
    output: &Path,
) -> Result<()> {
    let git = Path::new("/usr/bin/git");
    let head = capture(
        git,
        &["rev-parse".into(), "HEAD".into()],
        source,
        None,
        10,
        4096,
        output,
    )
    .await?;
    let remote = capture(
        git,
        &["remote".into(), "get-url".into(), "origin".into()],
        source,
        None,
        10,
        4096,
        output,
    )
    .await?;
    let diff = capture(
        git,
        &[
            "--no-pager".into(),
            "-c".into(),
            "core.abbrev=7".into(),
            "-c".into(),
            "color.ui=false".into(),
            "-c".into(),
            "diff.algorithm=myers".into(),
            "-c".into(),
            "diff.mnemonicPrefix=false".into(),
            "diff".into(),
            "--no-ext-diff".into(),
            "--no-textconv".into(),
            "--no-renames".into(),
            "--binary".into(),
            "HEAD".into(),
            "--".into(),
        ],
        source,
        None,
        10,
        4 * 1024 * 1024,
        output,
    )
    .await?;
    let extra = capture(
        git,
        &[
            "ls-files".into(),
            "--others".into(),
            "--exclude-standard".into(),
        ],
        source,
        None,
        10,
        1024 * 1024,
        output,
    )
    .await?;
    ensure(
        head == pin.source_commit
            && remote == pin.source_url
            && hash(patch) == pin.patch_sha256
            && diff
                == std::str::from_utf8(patch)
                    .map_err(|_| BenchmarkError("offline_patch_utf8"))?
                    .trim()
            && extra.is_empty(),
        "pinned_source_patch_identity_mismatch",
    )
}
fn artifact_digest(path: &Path) -> Result<(String, u64)> {
    use sha2::{Digest, Sha256};
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| BenchmarkError("cached_rlib_unavailable"))?;
    let before = file
        .metadata()
        .map_err(|_| BenchmarkError("cached_rlib_metadata_failed"))?;
    ensure(
        before.is_file() && before.len() > 0 && before.len() <= 1024 * 1024 * 1024,
        "cached_rlib_invalid_bound",
    )?;
    let mut digest = Sha256::new();
    let mut bytes = [0u8; 1024 * 1024];
    let mut count = 0u64;
    loop {
        let n = file
            .read(&mut bytes)
            .map_err(|_| BenchmarkError("cached_rlib_read_failed"))?;
        if n == 0 {
            break;
        }
        count += n as u64;
        ensure(count <= before.len(), "cached_rlib_changed")?;
        digest.update(&bytes[..n]);
    }
    let after = file
        .metadata()
        .map_err(|_| BenchmarkError("cached_rlib_metadata_failed"))?;
    use std::os::unix::fs::MetadataExt;
    ensure(
        count == before.len()
            && before.dev() == after.dev()
            && before.ino() == after.ino()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec(),
        "cached_rlib_changed",
    )?;
    Ok((hex::encode(digest.finalize()), count))
}
/// Compile existing frozen Rust instrumentation against existing exact cached artifacts.
/// No Cargo, network, provider, model, browser, or desktop action is used.
pub async fn receipt_floor_audit(options: &ReceiptFloorOptions) -> Result<Value> {
    ensure(
        options.source.is_absolute()
            && options.dependencies.is_absolute()
            && options.compiler.is_absolute()
            && options.manifest.is_absolute(),
        "absolute_offline_source_paths_required",
    )?;
    let output = private_output(&options.output)?;
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .map_err(|_| BenchmarkError("repository_identity_failed"))?;
    ensure(
        !output.starts_with(&root)
            && !output.join("native-receipt-floor").exists()
            && !output.join("audit.json").exists(),
        "private_external_fresh_audit_required",
    )?;
    let pin = crate::runtime_source::read_pin(&root)
        .map_err(|_| BenchmarkError("runtime_source_pin_invalid"))?;
    let patch = read(&root.join("Runtime/patches/compaction-retention.patch"))?;
    let manifest = read_json(&options.manifest)?;
    ensure(
        manifest["patchSHA256"] == pin.patch_sha256
            && manifest["sourceCommit"] == pin.source_commit,
        "packaged_runtime_manifest_pin_mismatch",
    )?;
    verify_source(&options.source, &pin, &patch, &output).await?;
    let allocator_path = options
        .source
        .join("codex-rs/core/src/compact_tool_receipts.rs");
    let allocator = read_text(&allocator_path)?;
    ensure(
        hash(&allocator) == ALLOCATOR_HASH,
        "frozen_baseline_allocator_changed",
    )?;
    let client = read_text(&options.source.join("codex-rs/core/src/client.rs"))?;
    let projection = projection(&client)?;
    let code = compose(&allocator, &projection, HARNESS)?;
    let rollout = super::rollouts::read_large_rollout(&options.rollout)?;
    let rollout_hash = hash(&rollout);
    let mut library_hashes = serde_json::Map::new();
    for (name, file) in LIBRARIES {
        let (digest, bytes) = artifact_digest(&options.dependencies.join(file))?;
        library_hashes.insert(
            name.into(),
            json!({"file":file,"sha256":digest,"bytes":bytes}),
        );
    }
    let binary = output.join("native-receipt-floor");
    let compiler = capture(
        &options.compiler,
        &["-Vv".into()],
        &output,
        None,
        10,
        8192,
        &output,
    )
    .await?;
    ensure(
        compiler.starts_with("rustc 1.95.0 "),
        "exact_offline_compiler_version_required",
    )?;
    let mut args = vec![
        "--edition=2024".into(),
        "--crate-name".into(),
        "heydash_receipt_floor".into(),
        "-".into(),
        "-C".into(),
        "debuginfo=0".into(),
        "-L".into(),
        format!(
            "dependency={}",
            options
                .dependencies
                .to_str()
                .ok_or(BenchmarkError("offline_dependencies_utf8"))?
        ),
    ];
    for (name, file) in LIBRARIES {
        args.push("--extern".into());
        args.push(format!(
            "{name}={}",
            options
                .dependencies
                .join(file)
                .to_str()
                .ok_or(BenchmarkError("offline_dependencies_utf8"))?
        ));
    }
    args.extend([
        "-o".into(),
        binary
            .to_str()
            .ok_or(BenchmarkError("offline_binary_path_utf8"))?
            .into(),
    ]);
    let started = Instant::now();
    capture(
        &options.compiler,
        &args,
        &output,
        Some(&code),
        120,
        1024 * 1024,
        &output,
    )
    .await?;
    let compile_ms = started.elapsed().as_secs_f64() * 1000.0;
    let result = capture(
        &binary,
        &[
            options
                .rollout
                .to_str()
                .ok_or(BenchmarkError("rollout_path_utf8"))?
                .into(),
            options.turn.to_string(),
        ],
        &output,
        None,
        30,
        8 * 1024 * 1024,
        &output,
    )
    .await?;
    let result = parse(result.as_bytes())?;
    ensure(result.is_object(), "invalid_offline_audit_result")?;
    ensure(
        hash(read(&allocator_path)?) == hash(&allocator)
            && hash(super::rollouts::read_large_rollout(&options.rollout)?) == rollout_hash,
        "offline_source_or_rollout_changed",
    )?;
    verify_source(&options.source, &pin, &patch, &output).await?;
    for (name, file) in LIBRARIES {
        ensure(
            artifact_digest(&options.dependencies.join(file))?.0 == library_hashes[name]["sha256"],
            "cached_rlib_changed",
        )?;
    }
    let (binary_hash, binary_bytes) = artifact_digest(&binary)?;
    let mut audit = json!({"schemaVersion":1,"offlineOnly":true,"productionSourceUnchanged":true,"sourceCommit":pin.source_commit,"patchSHA256":pin.patch_sha256,"allocatorSHA256":hash(&allocator),"projectionSHA256":hash(&projection),"instrumentationSHA256":hash(HARNESS),"compilerInputSHA256":hash(code),"runnerSHA256":hash(include_bytes!("receipt_floor.rs")),"rolloutSHA256":rollout_hash,"binarySHA256":binary_hash,"compiler":compiler,"libraryHashes":library_hashes,"compileMS":compile_ms,"binaryBytes":binary_bytes,"protocol":"computa-rust-offline-receipt-floor-v1"});
    audit
        .as_object_mut()
        .unwrap()
        .extend(result.as_object().unwrap().clone());
    super::opaque::write_new(
        &output,
        "audit.json",
        &serde_json::to_vec_pretty(&audit).map_err(|_| BenchmarkError("audit_encode_failed"))?,
    )?;
    Ok(audit)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn instrumentation_and_projection_boundaries_are_exact() {
        let source = "pub(crate) fn prepare_input_for_non_openai_provider(input: &mut [ResponseItem]) {\n    let _ = input;\n}";
        assert_eq!(projection(source).unwrap(), source);
        assert!(projection(&format!("{source}\n{source}")).is_err());
        let code = compose(
            "allocator",
            source,
            "inside\n// END RECEIPT MODULE AUDIT\noutside",
        )
        .unwrap();
        assert!(code.contains("allocator\ninside"));
        assert!(code.ends_with("\noutside"));
        assert!(compose("a", source, "no boundary").is_err());
        assert!(
            compose(
                "a",
                source,
                "// END RECEIPT MODULE AUDIT\n// END RECEIPT MODULE AUDIT"
            )
            .is_err()
        );
    }
    #[test]
    fn cached_artifact_digest_rejects_symlinks_and_retains_byte_identity() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file.rlib");
        std::fs::write(&path, b"synthetic bytes only").unwrap();
        let digest = artifact_digest(&path).unwrap();
        assert_eq!(digest, (hash(b"synthetic bytes only"), 20));
        let link = root.path().join("link.rlib");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(artifact_digest(&link).is_err());
    }
}
