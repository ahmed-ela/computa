use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

const COMMIT: &str = "4607249e430dac1c961df4dc615beae88e33cec8";
const TAG: &str = "rust-v0.155.0-alpha.9.2";
const ORIGIN: &str = "https://github.com/openai/codex.git";
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimePin {
    pub runtime_version: String,
    #[serde(rename = "sourceURL")]
    pub source_url: String,
    pub source_tag: String,
    pub source_commit: String,
    #[serde(rename = "patchSHA256")]
    pub patch_sha256: String,
}
pub fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
pub fn read_pin(root: &Path) -> io::Result<RuntimePin> {
    let pin: RuntimePin = serde_json::from_slice(&crate::models::read_regular(
        &root.join("Runtime/codex-source.lock.json"),
        16 * 1024,
    )?)
    .map_err(invalid)?;
    let reviewed: RuntimePin =
        serde_json::from_str(include_str!("../../../Runtime/codex-source.lock.json"))
            .map_err(invalid)?;
    if pin != reviewed {
        return Err(invalid(
            "App Server source lock differs from the compiled reviewed identity",
        ));
    }
    if pin.source_url != ORIGIN
        || pin.source_tag != TAG
        || pin.source_commit != COMMIT
        || !pin
            .runtime_version
            .strip_prefix("mactopus-")
            .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        || pin.patch_sha256.len() != 64
        || !pin
            .patch_sha256
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid("Invalid pinned App Server source"));
    }
    Ok(pin)
}
fn invalid(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
pub fn run(program: &str, args: &[&str], cwd: &Path, capture: bool) -> io::Result<String> {
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit());
    if capture {
        let mut child = command.stdout(Stdio::piped()).spawn()?;
        let mut output = Vec::new();
        child
            .stdout
            .take()
            .ok_or_else(|| invalid("Missing process output"))?
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut output)?;
        if output.len() > 16 * 1024 * 1024 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(invalid("Build output limit exceeded"));
        }
        if !child.wait()?.success() {
            return Err(invalid(format!("{program} failed")));
        }
        String::from_utf8(output)
            .map(|s| s.trim().into())
            .map_err(invalid)
    } else {
        if !command.stdout(Stdio::inherit()).status()?.success() {
            return Err(invalid(format!("{program} failed")));
        }
        Ok(String::new())
    }
}
fn git(source: &Path, args: &[&str]) -> io::Result<String> {
    run("git", args, source, true)
}
fn reviewed_diff(source: &Path) -> io::Result<String> {
    git(
        source,
        &[
            "--no-pager",
            "-c",
            "core.abbrev=7",
            "-c",
            "color.ui=false",
            "-c",
            "diff.algorithm=myers",
            "-c",
            "diff.mnemonicPrefix=false",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "--binary",
            "HEAD",
            "--",
        ],
    )
}
fn identity(source: &Path, pin: &RuntimePin) -> io::Result<()> {
    if git(source, &["rev-parse", "HEAD"])? != pin.source_commit
        || git(source, &["remote", "get-url", "origin"])? != pin.source_url
    {
        return Err(invalid(
            "Existing runtime checkout has the wrong source identity; left untouched",
        ));
    }
    if !git(source, &["ls-files", "--others", "--exclude-standard"])?.is_empty() {
        return Err(invalid(
            "Runtime source contains unreviewed files; left untouched",
        ));
    }
    Ok(())
}
pub fn verify(source: &Path, pin: &RuntimePin, patch: &Path) -> io::Result<()> {
    identity(source, pin)?;
    let bytes = fs::read(patch)?;
    if digest(&bytes) != pin.patch_sha256 {
        return Err(invalid("Runtime patch differs from the lock checksum"));
    }
    if reviewed_diff(source)? != std::str::from_utf8(&bytes).map_err(invalid)?.trim() {
        return Err(invalid(
            "Runtime checkout differs from the exact reviewed patch; left untouched",
        ));
    }
    Ok(())
}
pub fn prepare(root: &Path, source: &Path) -> io::Result<RuntimePin> {
    let pin = read_pin(root)?;
    let patch = root.join("Runtime/patches/compaction-retention.patch");
    let bytes = fs::read(&patch)?;
    if digest(&bytes) != pin.patch_sha256 {
        return Err(invalid("Runtime patch differs from lock checksum"));
    }
    match fs::symlink_metadata(source) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => return Err(invalid("Runtime source must be a real directory")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::create_dir_all(
                source
                    .parent()
                    .ok_or_else(|| invalid("Missing runtime parent"))?,
            )?;
            run(
                "git",
                &[
                    "clone",
                    "--config",
                    "core.autocrlf=false",
                    "--depth",
                    "1",
                    "--single-branch",
                    "--branch",
                    &pin.source_tag,
                    &pin.source_url,
                    path(source)?,
                ],
                root,
                false,
            )?;
        }
        Err(error) => return Err(error),
    }
    identity(source, &pin)?;
    if reviewed_diff(source)?.is_empty() {
        run(
            "git",
            &["apply", "--index", "--check", path(&patch)?],
            source,
            false,
        )?;
        run("git", &["apply", "--index", path(&patch)?], source, false)?;
    }
    verify(source, &pin, &patch)?;
    Ok(pin)
}
pub fn path(path: &Path) -> io::Result<&str> {
    path.to_str()
        .ok_or_else(|| invalid("Build path must be UTF-8"))
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeManifest {
    pub schema_version: u32,
    pub runtime_version: String,
    pub source_commit: String,
    #[serde(rename = "patchSHA256")]
    pub patch_sha256: String,
    #[serde(rename = "binarySHA256")]
    pub binary_sha256: String,
    pub binary_size: u64,
    pub platform: String,
    pub architecture: String,
    pub executable: String,
}
pub fn validate_macho(bytes: &[u8]) -> io::Result<()> {
    if bytes.len() < 32 || bytes.len() > 512 * 1024 * 1024 {
        return Err(invalid("Runtime executable size is invalid"));
    }
    let u32_at = |offset| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    if u32_at(0) != 0xfeedfacf || u32_at(4) != 0x0100000c || u32_at(12) != 2 {
        return Err(invalid("Runtime is not a thin arm64 Mach-O executable"));
    }
    Ok(())
}
/// Product setup may reuse only the repository's compiled-reviewed dedicated
/// artifact, after verifying the exact upstream checkout and reviewed patch.
/// No installed app, PATH binary, or locally selected manifest is a fallback.
pub fn build_product_runtime(root: &Path, source: &Path) -> io::Result<PathBuf> {
    let pin = prepare(root, source)?;
    let resources = root.join("Sources/Computa/Resources");
    let directory = resources.join("AgentRuntime");
    let binary = directory.join("codex-app-server");
    match fs::symlink_metadata(&binary) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return build(root, source, true),
        Err(error) => return Err(error),
        Ok(_) => {}
    }
    let artifact = reviewed_runtime(&resources, &pin)?;
    run(
        "/usr/bin/codesign",
        &["--verify", "--strict", path(&artifact.executable)?],
        root,
        false,
    )?;
    let parent = root.join("target/product-resources");
    crate::models::safe_directory(&parent, true)?;
    let stage = tempfile::Builder::new()
        .prefix("reviewed-runtime-")
        .tempdir_in(&parent)?;
    let target = stage.path().join("AgentRuntime");
    fs::create_dir(&target)?;
    for name in ["codex-app-server", "manifest.json", "LICENSE", "NOTICE"] {
        let input = if matches!(name, "LICENSE" | "NOTICE") {
            source.join(name)
        } else {
            directory.join(name)
        };
        let bytes = crate::models::read_regular(&input, 512 * 1024 * 1024)?;
        fs::write(target.join(name), bytes)?;
    }
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(
        target.join("codex-app-server"),
        fs::Permissions::from_mode(0o755),
    )?;
    reviewed_runtime(stage.path(), &pin)?;
    verify(
        source,
        &pin,
        &root.join("Runtime/patches/compaction-retention.patch"),
    )?;
    let destination = parent.join("AgentRuntime");
    let backup = parent.join(format!("AgentRuntime-backup-{}", uuid::Uuid::new_v4()));
    let had_previous = match fs::symlink_metadata(&destination) {
        Ok(md) if md.is_dir() && !md.file_type().is_symlink() => true,
        Ok(_) => {
            return Err(invalid(
                "Product runtime destination must be a real directory",
            ));
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => false,
        Err(e) => return Err(e),
    };
    if had_previous {
        fs::rename(&destination, &backup)?;
    }
    if let Err(error) = fs::rename(&target, &destination) {
        if had_previous {
            let _ = fs::rename(&backup, &destination);
        }
        return Err(error);
    }
    // A previous build is retained as a reversible build artifact, never used
    // as authority for the just-published reviewed executable.
    Ok(destination)
}
fn reviewed_runtime(
    resources: &Path,
    pin: &RuntimePin,
) -> io::Result<computa_runtime::artifact::RuntimeArtifact> {
    let artifact =
        computa_runtime::artifact::RuntimeArtifact::resolve(resources).map_err(invalid)?;
    let reviewed: computa_runtime::artifact::Manifest = serde_json::from_str(include_str!(
        "../../../Sources/Computa/Resources/AgentRuntime/manifest.json"
    ))
    .map_err(invalid)?;
    let actual = serde_json::to_value(&artifact.manifest).map_err(invalid)?;
    let expected = serde_json::to_value(reviewed).map_err(invalid)?;
    if actual != expected
        || artifact.manifest.runtime_version != pin.runtime_version
        || artifact.manifest.source_commit != pin.source_commit
        || artifact.manifest.patch_sha256 != pin.patch_sha256
    {
        return Err(invalid(
            "Dedicated source runtime differs from the compiled reviewed artifact",
        ));
    }
    Ok(artifact)
}
pub fn build(root: &Path, source: &Path, release: bool) -> io::Result<PathBuf> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return Err(invalid("App Server build requires arm64 macOS"));
    }
    let pin = prepare(root, source)?;
    let cargo_dir = source.join("codex-rs");
    let target = root.join(".build/runtime/codex-source/codex-rs/target");
    let profile = if release { "release" } else { "dev-small" };
    if !run(
        "rustup",
        &["run", "1.95.0", "rustc", "--version"],
        &cargo_dir,
        true,
    )?
    .starts_with("rustc 1.95.0 ")
    {
        return Err(invalid("Rust 1.95.0 is required"));
    }
    let config = format!("profile.{profile}.build-override.strip=\"none\"");
    let output = run(
        "rustup",
        &[
            "run",
            "1.95.0",
            "cargo",
            "build",
            "--locked",
            "--profile",
            profile,
            "--config",
            &config,
            "--target-dir",
            path(&target)?,
            "--message-format=json-render-diagnostics",
            "-p",
            "codex-app-server",
            "--bin",
            "codex-app-server",
        ],
        &cargo_dir,
        true,
    )?;
    let mut artifacts = Vec::new();
    for line in output.lines() {
        let value: serde_json::Value = serde_json::from_str(line).map_err(invalid)?;
        if value["reason"] == "compiler-artifact"
            && value["target"]["name"] == "codex-app-server"
            && value["target"]["kind"]
                .as_array()
                .is_some_and(|k| k.iter().any(|v| v == "bin"))
            && let Some(path) = value["executable"].as_str()
        {
            artifacts.push(PathBuf::from(path));
        }
    }
    if artifacts.len() != 1 {
        return Err(invalid("Cargo did not report one App Server executable"));
    }
    let built = artifacts.remove(0);
    if !built.starts_with(&target) {
        return Err(invalid("Unexpected App Server artifact location"));
    }
    verify(
        source,
        &pin,
        &root.join("Runtime/patches/compaction-retention.patch"),
    )?;
    let metadata = fs::symlink_metadata(&built)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(invalid("Runtime executable must be a regular file"));
    }
    validate_macho(&fs::read(&built)?)?;
    let destination = root.join("target/product-resources/AgentRuntime");
    fs::create_dir_all(&destination)?;
    let executable = destination.join("codex-app-server");
    fs::copy(built, &executable)?;
    run(
        "/usr/bin/codesign",
        &[
            "--force",
            "--options",
            "runtime",
            "--sign",
            "-",
            path(&executable)?,
        ],
        root,
        false,
    )?;
    run(
        "/usr/bin/codesign",
        &["--verify", "--strict", path(&executable)?],
        root,
        false,
    )?;
    let bytes = fs::read(executable)?;
    let manifest = RuntimeManifest {
        schema_version: 1,
        runtime_version: pin.runtime_version,
        source_commit: pin.source_commit,
        patch_sha256: pin.patch_sha256,
        binary_sha256: digest(&bytes),
        binary_size: bytes.len() as u64,
        platform: "macos".into(),
        architecture: "arm64".into(),
        executable: "codex-app-server".into(),
    };
    fs::write(
        destination.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest).map_err(invalid)?,
    )?;
    for name in ["LICENSE", "NOTICE"] {
        fs::copy(source.join(name), destination.join(name))?;
    }
    Ok(destination)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pinned_source_and_patch_match_reviewed_repository() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let pin = read_pin(&root).unwrap();
        assert_eq!(
            digest(&fs::read(root.join("Runtime/patches/compaction-retention.patch")).unwrap()),
            pin.patch_sha256
        );
    }
    #[test]
    fn source_lock_cannot_select_a_different_reviewed_patch() {
        let temp = tempfile::tempdir().unwrap();
        fs::create_dir(temp.path().join("Runtime")).unwrap();
        let mut pin: RuntimePin =
            serde_json::from_str(include_str!("../../../Runtime/codex-source.lock.json")).unwrap();
        pin.patch_sha256 = "1".repeat(64);
        fs::write(
            temp.path().join("Runtime/codex-source.lock.json"),
            serde_json::to_vec(&pin).unwrap(),
        )
        .unwrap();
        assert!(read_pin(temp.path()).is_err());
    }
    #[test]
    fn runtime_reuse_rejects_self_selected_binary_manifest() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join("AgentRuntime");
        fs::create_dir(&directory).unwrap();
        let mut bytes = vec![0; 32];
        for (offset, value) in [(0, 0xfeedfacfu32), (4, 0x0100000c), (12, 2), (16, 1)] {
            bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        let mut manifest: computa_runtime::artifact::Manifest = serde_json::from_str(include_str!(
            "../../../Sources/Computa/Resources/AgentRuntime/manifest.json"
        ))
        .unwrap();
        manifest.binary_sha256 = digest(&bytes);
        manifest.binary_size = 32;
        fs::write(directory.join("codex-app-server"), bytes).unwrap();
        fs::set_permissions(
            directory.join("codex-app-server"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::write(
            directory.join("manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        assert!(computa_runtime::artifact::RuntimeArtifact::resolve(temp.path()).is_ok());
        let pin: RuntimePin =
            serde_json::from_str(include_str!("../../../Runtime/codex-source.lock.json")).unwrap();
        assert!(reviewed_runtime(temp.path(), &pin).is_err());
    }
    #[test]
    fn thin_executable_architecture_and_kind_are_checked() {
        let mut header = vec![0; 32];
        for (offset, value) in [(0, 0xfeedfacfu32), (4, 0x0100000c), (12, 2)] {
            header[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        }
        assert!(validate_macho(&header).is_ok());
        header[12] = 6;
        assert!(validate_macho(&header).is_err());
        assert!(validate_macho(&header[..20]).is_err());
    }
}
