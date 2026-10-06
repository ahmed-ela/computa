//! Distribution tools only run explicit native commands. They never strip
//! quarantine, create credentials, terminate apps or publish a release.
use crate::models::{read_regular, safe_directory};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
pub const BUNDLE_ID: &str = "com.ahmedelamin.LocalCodex";
pub fn grounding_provenance() -> [(&'static str, &'static [u8]); 6] {
    [
        (
            "Contents/Resources/VisualGrounding/model-manifest.json",
            include_bytes!("../../computa-inference/src/grounding_backend/model-manifest.json"),
        ),
        (
            "Contents/Resources/VisualGrounding/native-prompts.json",
            include_bytes!("../../computa-inference/src/grounding_backend/native-prompts.json"),
        ),
        (
            "Contents/Resources/VisualGrounding/owl-system.txt",
            include_bytes!("../../computa-inference/src/grounding_backend/owl-system.txt"),
        ),
        (
            "Contents/Resources/VisualGrounding/source-manifest.json",
            include_bytes!("../../computa-inference/src/grounding_backend/source-manifest.json"),
        ),
        (
            "Contents/Resources/VisualGrounding/native-model-manifest.json",
            include_bytes!(
                "../../computa-inference/src/grounding_backend/native-model-manifest.json"
            ),
        ),
        (
            "Contents/Resources/VisualGrounding/native-conversion-parity.json",
            include_bytes!(
                "../../computa-inference/src/grounding_backend/native-conversion-parity.json"
            ),
        ),
    ]
}
const APPLE_REQUIREMENT: &str =
    "=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists";
pub struct CommandResult {
    pub code: i32,
    pub stdout: String,
}
pub trait Runner {
    fn run(&self, command: &[String]) -> io::Result<CommandResult>;
}
pub struct SystemRunner;
impl Runner for SystemRunner {
    fn run(&self, args: &[String]) -> io::Result<CommandResult> {
        let mut child = Command::new(
            args.first()
                .ok_or_else(|| invalid("Empty native command"))?,
        )
        .args(&args[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
        let mut output = Vec::new();
        child
            .stdout
            .take()
            .ok_or_else(|| invalid("Missing command output"))?
            .take(16 * 1024 * 1024 + 1)
            .read_to_end(&mut output)?;
        if output.len() > 16 * 1024 * 1024 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(invalid("Native command output exceeds limit"));
        }
        Ok(CommandResult {
            code: child.wait()?.code().unwrap_or(-1),
            stdout: String::from_utf8(output).map_err(invalid)?,
        })
    }
}
pub fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}
pub fn text(path: &Path) -> io::Result<&str> {
    let text = path.to_str().ok_or_else(|| invalid("Path is not UTF-8"))?;
    if text.chars().any(char::is_control) {
        return Err(invalid("Path contains control characters"));
    }
    Ok(text)
}
pub fn checked(runner: &dyn Runner, args: &[&str]) -> io::Result<String> {
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let result = runner.run(&args)?;
    if result.code != 0 {
        return Err(invalid(format!(
            "Native command failed: {}",
            args.first().map_or("unknown", String::as_str)
        )));
    }
    Ok(result.stdout.trim().into())
}
pub fn require_stopped(runner: &dyn Runner) -> io::Result<()> {
    for name in ["Computa", "Mactopus"] {
        let result = runner.run(&["/usr/bin/pgrep".into(), "-x".into(), name.into()])?;
        match result.code {
            1 => {}
            0 => {
                return Err(invalid(format!(
                    "Quit {name} normally before installation; no process was stopped"
                )));
            }
            _ => {
                return Err(invalid(
                    "Could not establish that the installed app is stopped",
                ));
            }
        }
    }
    Ok(())
}
pub fn digest_file(path: &Path) -> io::Result<String> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let before = file.metadata()?;
    if !before.is_file() || before.nlink() != 1 {
        return Err(invalid("Expected an unlinked regular file"));
    }
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    let mut size = 0u64;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
        size += n as u64;
    }
    let after = file.metadata()?;
    if size != before.len()
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return Err(invalid("File changed during integrity inspection"));
    }
    Ok(hex::encode(digest.finalize()))
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileEntry {
    pub path: String,
    pub kind: String,
    pub sha256: String,
    pub size: u64,
    pub executable: bool,
}
pub fn bundle_files(app: &Path) -> io::Result<Vec<FileEntry>> {
    safe_directory(app, false)?;
    fn visit(root: &Path, directory: &Path, result: &mut Vec<FileEntry>) -> io::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.file_type().is_symlink() {
                return Err(invalid("Rust app bundles cannot contain symlinks"));
            }
            if metadata.is_dir() {
                visit(root, &path, result)?;
            } else if metadata.is_file() {
                let relative = text(path.strip_prefix(root).map_err(invalid)?)?.replace('\\', "/");
                result.push(FileEntry {
                    path: relative,
                    kind: "file".into(),
                    sha256: digest_file(&path)?,
                    size: metadata.len(),
                    executable: metadata.mode() & 0o111 != 0,
                });
            } else {
                return Err(invalid("Application contains a special file"));
            }
        }
        Ok(())
    }
    let mut result = Vec::new();
    visit(app, app, &mut result)?;
    result.sort_by(|a, b| a.path.as_bytes().cmp(b.path.as_bytes()));
    Ok(result)
}
pub fn inspect_basic(app: &Path, executable: &str, runner: &dyn Runner) -> io::Result<()> {
    safe_directory(app, false)?;
    read_regular(&app.join("Contents/Info.plist"), 1024 * 1024)?;
    let plist = app.join("Contents/Info.plist");
    if checked(
        runner,
        &[
            "/usr/bin/plutil",
            "-extract",
            "CFBundleIdentifier",
            "raw",
            "-o",
            "-",
            text(&plist)?,
        ],
    )? != BUNDLE_ID
        || checked(
            runner,
            &[
                "/usr/bin/plutil",
                "-extract",
                "CFBundleExecutable",
                "raw",
                "-o",
                "-",
                text(&plist)?,
            ],
        )? != executable
    {
        return Err(invalid("Refusing an app with an unknown bundle identity"));
    }
    let binary = app.join("Contents/MacOS").join(executable);
    let metadata = fs::symlink_metadata(&binary)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.mode() & 0o111 == 0 {
        return Err(invalid(
            "App executable is missing, nonregular or not executable",
        ));
    }
    checked(
        runner,
        &[
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            text(app)?,
        ],
    )?;
    Ok(())
}
pub fn inspect_rust_app(app: &Path, runner: &dyn Runner) -> io::Result<Vec<FileEntry>> {
    inspect_basic(app, "Computa", runner)?;
    let files = bundle_files(app)?;
    for required in [
        "Contents/MacOS/Computa",
        "Contents/Resources/ChromeBridge/ChromeBridgeHost",
        "Contents/Resources/AgentRuntime/codex-app-server",
        "Contents/Resources/AgentRuntime/manifest.json",
        "Contents/Resources/InferenceRuntime/computa-inference-worker",
        "Contents/Resources/InferenceRuntime/computa-grounding-worker",
        "Contents/Resources/InferenceRuntime/mlx.metallib",
        "Contents/Resources/InferenceRuntime/manifest.json",
        "Contents/Resources/WebUI/index.html",
        "Contents/Resources/BrowserExtension/manifest.json",
    ] {
        if !files.iter().any(|f| f.path == required) {
            return Err(invalid(format!(
                "Required Rust release artifact is missing: {required}"
            )));
        }
    }
    for (name, expected) in [
        ("mlx-model.lock.json", crate::models::REVIEWED_LOCK),
        ("mlx-model-9b.lock.json", crate::models::REVIEWED_9B_LOCK),
    ] {
        if read_regular(&app.join("Contents/Resources").join(name), 4 * 1024 * 1024)? != expected {
            return Err(invalid(
                "Bundled model provisioning pins differ from the reviewed installer",
            ));
        }
    }
    for file in &files {
        if file.path.ends_with(".py") || file.path.ends_with(".ts") || file.path.ends_with(".tsx") {
            return Err(invalid(
                "Production bundle contains a legacy Python or TypeScript dependency",
            ));
        }
    }
    computa_runtime::artifact::RuntimeArtifact::resolve(&app.join("Contents/Resources"))
        .map_err(invalid)?;
    inspect_metal_directory(&app.join("Contents/Resources/InferenceRuntime"))?;
    for (relative, expected) in grounding_provenance() {
        if read_regular(&app.join(relative), 1024 * 1024)? != expected {
            return Err(invalid(
                "Grounding provenance differs from the reviewed native manifest or prompts",
            ));
        }
    }
    for binary in [
        "Contents/MacOS/Computa",
        "Contents/Resources/ChromeBridge/ChromeBridgeHost",
        "Contents/Resources/AgentRuntime/codex-app-server",
        "Contents/Resources/InferenceRuntime/computa-inference-worker",
        "Contents/Resources/InferenceRuntime/computa-grounding-worker",
    ] {
        let path = app.join(binary);
        let architectures = checked(runner, &["/usr/bin/lipo", "-archs", text(&path)?])?;
        if !architectures.split_whitespace().any(|a| a == "arm64") {
            return Err(invalid("Every release executable must contain arm64"));
        }
        let libraries = checked(
            runner,
            &["/usr/bin/otool", "-arch", "arm64", "-L", text(&path)?],
        )?;
        for line in libraries
            .lines()
            .skip(1)
            .filter(|line| !line.trim().is_empty())
        {
            let dependency = line.trim().split(" (").next().unwrap_or("");
            if !dependency.starts_with("/System/Library/") && !dependency.starts_with("/usr/lib/") {
                return Err(invalid(
                    "Release executable links an unreviewed non-system dynamic dependency",
                ));
            }
        }
    }
    Ok(files)
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetalManifest {
    pub schema_version: u32,
    pub backend: String,
    pub file: String,
    pub bytes: u64,
    pub sha256: String,
}
/// Compare the exact native build resource pin; compiled worker startup also
/// checks its embedded SHA, so a moved app never relies on the build tree.
pub fn inspect_metal_directory(directory: &Path) -> io::Result<MetalManifest> {
    let bytes = read_regular(&directory.join("manifest.json"), 4096)?;
    let value = computa_contracts::strict_json::parse(&bytes).map_err(invalid)?;
    let manifest: MetalManifest = serde_json::from_value(value).map_err(invalid)?;
    if manifest.schema_version != 1
        || manifest.backend != "mlex-0.1.3"
        || manifest.file != "mlx.metallib"
        || !(4..=512 * 1024 * 1024).contains(&manifest.bytes)
        || manifest.sha256.len() != 64
        || !manifest
            .sha256
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid("Native Metal resource manifest differs"));
    }
    let library = directory.join(&manifest.file);
    let metadata = fs::symlink_metadata(&library)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() != manifest.bytes
        || digest_file(&library)? != manifest.sha256
    {
        return Err(invalid(
            "Native Metal library differs from its exact build resource pin",
        ));
    }
    let mut file = fs::File::open(&library)?;
    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)?;
    if &magic != b"MTLB" {
        return Err(invalid("Native MLX resource is not a Metal library"));
    }
    Ok(manifest)
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ReleaseChannel {
    Notarized,
    SignedTest,
}
pub fn verify_release_gates(
    app: &Path,
    channel: ReleaseChannel,
    runner: &dyn Runner,
) -> io::Result<Vec<FileEntry>> {
    let files = inspect_rust_app(app, runner)?;
    for relative in [
        "Contents/MacOS/Computa",
        "Contents/Resources/ChromeBridge/ChromeBridgeHost",
        "Contents/Resources/AgentRuntime/codex-app-server",
        "Contents/Resources/InferenceRuntime/computa-inference-worker",
        "Contents/Resources/InferenceRuntime/computa-grounding-worker",
    ] {
        checked(
            runner,
            &[
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "-R",
                APPLE_REQUIREMENT,
                text(&app.join(relative))?,
            ],
        )?;
    }
    checked(
        runner,
        &[
            "/usr/bin/codesign",
            "--verify",
            "--deep",
            "--strict",
            "-R",
            APPLE_REQUIREMENT,
            text(app)?,
        ],
    )?;
    crate::source_build::inspect_sealed_receipt(app, &files)?;
    if channel == ReleaseChannel::Notarized {
        checked(
            runner,
            &["/usr/bin/xcrun", "stapler", "validate", text(app)?],
        )?;
        checked(
            runner,
            &[
                "/usr/sbin/spctl",
                "--assess",
                "--type",
                "execute",
                text(app)?,
            ],
        )?;
    }
    Ok(files)
}
pub fn signing_identity(
    requested: &str,
    developer_only: bool,
    runner: &dyn Runner,
) -> io::Result<String> {
    if requested.is_empty()
        || requested.len() > 512
        || requested.starts_with('-')
        || requested.chars().any(char::is_control)
    {
        return Err(invalid("Expected an exact installed code-signing identity"));
    }
    let output = checked(
        runner,
        &[
            "/usr/bin/security",
            "find-identity",
            "-v",
            "-p",
            "codesigning",
        ],
    )?;
    let mut matches = Vec::new();
    for line in output.lines() {
        let Some((_, rest)) = line.trim().split_once(") ") else {
            continue;
        };
        let Some((hash, name)) = rest.split_once(" \"") else {
            continue;
        };
        let Some(name) = name.strip_suffix('"') else {
            continue;
        };
        if hash.len() != 40
            || !hash.bytes().all(|b| b.is_ascii_hexdigit())
            || developer_only && !name.starts_with("Developer ID Application: ")
        {
            continue;
        }
        if requested == name || requested.eq_ignore_ascii_case(hash) {
            matches.push(hash.to_owned());
        }
    }
    if matches.len() != 1 {
        return Err(invalid(
            "The requested installed signing identity is missing or ambiguous; no identity was created",
        ));
    }
    Ok(matches.remove(0))
}
pub fn sign_bundle_in_place(
    app: &Path,
    identity: &str,
    release: bool,
    runner: &dyn Runner,
) -> io::Result<()> {
    let old = if app.join(crate::source_build::RECEIPT_PATH).try_exists()? {
        Some(crate::source_build::load_verified_sealed_receipt(
            app,
            &bundle_files(app)?,
            runner,
        )?)
    } else {
        None
    };
    sign_bundle(app, identity, release, runner, None, old.as_ref())
}
/// Source authority comes exclusively from a clean native checkpoint captured
/// before the build. It is sealed after nested signing and checked again after
/// the final outer application signature.
pub fn sign_bundle_with_source(
    app: &Path,
    identity: &str,
    release: bool,
    runner: &dyn Runner,
    source_root: &Path,
    snapshot: &crate::source_build::SourceSnapshot,
) -> io::Result<()> {
    crate::source_build::verify_unchanged(source_root, snapshot, runner)?;
    sign_bundle(app, identity, release, runner, Some(snapshot), None)?;
    crate::source_build::verify_unchanged(source_root, snapshot, runner)
}
fn sign_bundle(
    app: &Path,
    identity: &str,
    release: bool,
    runner: &dyn Runner,
    source: Option<&crate::source_build::SourceSnapshot>,
    old: Option<&crate::source_build::VerifiedSourceReceipt>,
) -> io::Result<()> {
    // Sign nested Rust executables inside out. Only the App Server hash changes
    // in its integrity manifest; exact upstream provenance remains unchanged.
    let runtime = app.join("Contents/Resources/AgentRuntime/codex-app-server");
    let manifest_path = app.join("Contents/Resources/AgentRuntime/manifest.json");
    computa_runtime::artifact::RuntimeArtifact::resolve(&app.join("Contents/Resources"))
        .map_err(invalid)?;
    let timestamp = if release {
        "--timestamp"
    } else {
        "--timestamp=none"
    };
    for (relative, id) in [
        (
            "Contents/Resources/AgentRuntime/codex-app-server",
            "AgentRuntime",
        ),
        (
            "Contents/Resources/ChromeBridge/ChromeBridgeHost",
            "ChromeBridgeHost",
        ),
        (
            "Contents/Resources/InferenceRuntime/computa-inference-worker",
            "InferenceWorker",
        ),
        (
            "Contents/Resources/InferenceRuntime/computa-grounding-worker",
            "GroundingWorker",
        ),
    ] {
        checked(
            runner,
            &[
                "/usr/bin/codesign",
                "--force",
                "--options",
                "runtime",
                timestamp,
                "--identifier",
                &format!("{BUNDLE_ID}.{id}"),
                "--sign",
                identity,
                text(&app.join(relative))?,
            ],
        )?;
        checked(
            runner,
            &[
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                text(&app.join(relative))?,
            ],
        )?;
    }
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&read_regular(&manifest_path, 16 * 1024)?).map_err(invalid)?;
    manifest["binarySHA256"] = serde_json::Value::String(digest_file(&runtime)?);
    manifest["binarySize"] = fs::metadata(&runtime)?.len().into();
    fs::write(
        &manifest_path,
        serde_json::to_vec_pretty(&manifest).map_err(invalid)?,
    )?;
    checked(
        runner,
        &[
            "/usr/bin/codesign",
            "--force",
            "--options",
            "runtime",
            timestamp,
            "--sign",
            identity,
            text(app)?,
        ],
    )?;
    // The preliminary outer signature supplies the final main-code identity.
    // SourceBuild omits only signature-envelope/resource-seal metadata to avoid
    // a receipt sealing its own hash through the CodeResources special slot.
    if let Some(snapshot) = source {
        crate::source_build::write_receipt(app, snapshot, &bundle_files(app)?)?;
    } else if let Some(receipt) = old {
        crate::source_build::rebind_verified_receipt(app, receipt, &bundle_files(app)?)?;
    }
    if source.is_some() || old.is_some() {
        checked(
            runner,
            &[
                "/usr/bin/codesign",
                "--force",
                "--options",
                "runtime",
                timestamp,
                "--sign",
                identity,
                text(app)?,
            ],
        )?;
        let files = bundle_files(app)?;
        if let Some(snapshot) = source {
            crate::source_build::verify_receipt(app, snapshot, &files)?;
        } else {
            crate::source_build::inspect_sealed_receipt(app, &files)?;
        }
    }
    inspect_rust_app(app, runner)?;
    Ok(())
}
pub fn sign_release(
    source: &Path,
    output: &Path,
    requested: &str,
    runner: &dyn Runner,
) -> io::Result<PathBuf> {
    let files = inspect_rust_app(source, runner)?;
    crate::source_build::load_verified_sealed_receipt(source, &files, runner)?;
    require_separate(source, output)?;
    if fs::symlink_metadata(output).is_ok() {
        return Err(invalid("Signing output already exists; no app was changed"));
    }
    let identity = signing_identity(requested, true, runner)?;
    safe_directory(
        output
            .parent()
            .ok_or_else(|| invalid("Missing signing output parent"))?,
        true,
    )?;
    checked(runner, &["/usr/bin/ditto", text(source)?, text(output)?])?;
    let copied = bundle_files(output)?;
    if copied != files {
        return Err(invalid("Signing copy differs from the verified source"));
    }
    let receipt = crate::source_build::load_verified_sealed_receipt(output, &copied, runner)?;
    sign_bundle(output, &identity, true, runner, None, Some(&receipt))?;
    verify_release_gates(output, ReleaseChannel::SignedTest, runner)?;
    Ok(output.to_owned())
}
fn require_separate(a: &Path, b: &Path) -> io::Result<()> {
    if !a.is_absolute() || !b.is_absolute() || a == b || a.starts_with(b) || b.starts_with(a) {
        return Err(invalid("Source and output must be separate absolute paths"));
    }
    Ok(())
}
fn existing_app(applications: &Path, runner: &dyn Runner) -> io::Result<Option<PathBuf>> {
    let current = applications.join("Computa.app");
    let legacy = applications.join("Mactopus.app");
    let has_current = fs::symlink_metadata(&current).is_ok();
    let has_legacy = fs::symlink_metadata(&legacy).is_ok();
    if has_current && has_legacy {
        return Err(invalid(
            "Both Computa.app and Mactopus.app exist; resolve duplicate installations first",
        ));
    }
    let app = if has_current {
        Some(current)
    } else if has_legacy {
        Some(legacy)
    } else {
        None
    };
    if let Some(app) = &app {
        inspect_basic(app, if has_legacy { "Mactopus" } else { "Computa" }, runner)?;
    }
    Ok(app)
}
pub fn check_existing(user_home: &Path, runner: &dyn Runner) -> io::Result<Option<PathBuf>> {
    let applications = user_home.join("Applications");
    if fs::symlink_metadata(&applications).is_err() {
        return Ok(None);
    }
    safe_directory(&applications, false)?;
    existing_app(&applications, runner)
}
#[derive(Debug)]
pub struct Installation {
    pub app: PathBuf,
    pub backup: Option<PathBuf>,
    pub stage: PathBuf,
}
pub fn install_app(
    source: &Path,
    user_home: &Path,
    runner: &dyn Runner,
) -> io::Result<Installation> {
    install_app_with(source, user_home, runner, |a, b| fs::rename(a, b))
}
pub fn install_app_with<F: FnMut(&Path, &Path) -> io::Result<()>>(
    source: &Path,
    user_home: &Path,
    runner: &dyn Runner,
    move_path: F,
) -> io::Result<Installation> {
    let files = inspect_rust_app(source, runner)?;
    crate::source_build::load_verified_sealed_receipt(source, &files, runner)?;
    install_verified(source, user_home, "Computa", true, runner, move_path)
}
fn inspect_install(
    source: &Path,
    executable: &str,
    rust: bool,
    runner: &dyn Runner,
) -> io::Result<Vec<FileEntry>> {
    if rust {
        inspect_rust_app(source, runner)
    } else {
        inspect_basic(source, executable, runner)?;
        bundle_files(source)
    }
}
fn install_verified<F: FnMut(&Path, &Path) -> io::Result<()>>(
    source: &Path,
    user_home: &Path,
    executable: &str,
    rust: bool,
    runner: &dyn Runner,
    mut move_path: F,
) -> io::Result<Installation> {
    let source_files = inspect_install(source, executable, rust, runner)?;
    require_stopped(runner)?;
    let applications = user_home.join("Applications");
    safe_directory(&applications, true)?;
    let previous = existing_app(&applications, runner)?;
    let previous_files = previous.as_ref().map(|p| bundle_files(p)).transpose()?;
    let stage = tempfile::Builder::new()
        .prefix(".computa-install-")
        .tempdir_in(&applications)?
        .keep();
    let staged = stage.join(format!("{executable}.app"));
    checked(runner, &["/usr/bin/ditto", text(source)?, text(&staged)?])?;
    if inspect_install(&staged, executable, rust, runner)? != source_files {
        return Err(invalid(
            "Staged application differs from the verified source",
        ));
    }
    require_stopped(runner)?;
    if existing_app(&applications, runner)? != previous
        || previous.as_ref().map(|p| bundle_files(p)).transpose()? != previous_files
    {
        return Err(invalid(
            "Installed app changed during staging; no app was replaced",
        ));
    }
    let destination = applications.join(format!("{executable}.app"));
    let backup = if let Some(previous) = &previous {
        let backup_root = applications.join("Computa Backups");
        safe_directory(&backup_root, true)?;
        let container = tempfile::Builder::new()
            .prefix("rust-release-")
            .tempdir_in(&backup_root)?
            .keep();
        let backup = container.join(
            previous
                .file_name()
                .ok_or_else(|| invalid("Missing previous app name"))?,
        );
        move_path(previous, &backup)?;
        Some(backup)
    } else {
        None
    };
    if let Err(error) = move_path(&staged, &destination) {
        if let (Some(backup), Some(previous)) = (&backup, &previous)
            && fs::symlink_metadata(previous).is_err()
            && move_path(backup, previous).is_err()
        {
            return Err(invalid(format!(
                "Install and rollback failed. Previous app preserved at {}; staged app at {}",
                backup.display(),
                staged.display()
            )));
        }
        return Err(invalid(format!(
            "Install failed; the previous app was preserved. Staged app: {}. {error}",
            staged.display()
        )));
    }
    let verified = inspect_install(&destination, executable, rust, runner)
        .is_ok_and(|files| files == source_files);
    if !verified {
        // Preserve the failed new copy in its stage before restoring the previous
        // bundle. Backups are never deleted or overwritten.
        if move_path(&destination, &staged).is_err() {
            return Err(invalid(format!(
                "Installed verification failed; new app remains at {}, backup at {:?}",
                destination.display(),
                backup
            )));
        }
        if let (Some(backup), Some(previous)) = (&backup, &previous)
            && move_path(backup, previous).is_err()
        {
            return Err(invalid(format!(
                "Installed verification and rollback failed; backup preserved at {}, new app at {}",
                backup.display(),
                staged.display()
            )));
        }
        return Err(invalid(format!(
            "Installed verification failed; previous app restored and new copy retained at {}",
            staged.display()
        )));
    }
    Ok(Installation {
        app: destination,
        backup,
        stage,
    })
}
/// Restore a verified app from this user's retained native backup tree. It
/// stages a copy and backs up the current app; the selected backup stays intact.
/// A legacy Mactopus backup is restored with its original executable/name.
pub fn restore_backup(
    backup: &Path,
    user_home: &Path,
    runner: &dyn Runner,
) -> io::Result<Installation> {
    let backup_root = user_home.join("Applications/Computa Backups");
    safe_directory(&backup_root, false)?;
    safe_directory(backup, false)?;
    if !backup.starts_with(&backup_root) || backup.parent() == Some(backup_root.as_path()) {
        return Err(invalid(
            "Restore source must be an app inside a retained backup container",
        ));
    }
    let executable = match backup.file_name().and_then(|n| n.to_str()) {
        Some("Computa.app") => "Computa",
        Some("Mactopus.app") => "Mactopus",
        _ => return Err(invalid("Unknown native backup name")),
    };
    install_verified(backup, user_home, executable, false, runner, |a, b| {
        fs::rename(a, b)
    })
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReleaseManifest {
    pub schema_version: u32,
    pub bundle_identifier: String,
    pub version: String,
    pub tag: String,
    pub app_version: String,
    pub architecture: String,
    pub minimum_mac_os: String,
    pub channel: ReleaseChannel,
    pub notarized_app_verified: bool,
    pub model_included: bool,
    #[serde(rename = "modelManifestSHA256")]
    pub model_manifest_sha256: String,
    pub app_files: Vec<FileEntry>,
}
pub struct PackageOptions {
    pub app: PathBuf,
    pub output: PathBuf,
    pub installer: PathBuf,
    pub tag: String,
    pub channel: ReleaseChannel,
}
pub struct Package {
    pub dmg: PathBuf,
    pub manifest: PathBuf,
    pub stage: PathBuf,
}
fn version(value: &str) -> bool {
    let base = value.split(['-', '+']).next().unwrap_or("");
    base.split('.').count() == 3
        && base
            .split('.')
            .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
}
pub fn package_release(options: &PackageOptions, runner: &dyn Runner) -> io::Result<Package> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return Err(invalid("Packaging requires Apple Silicon macOS"));
    }
    let release_version = options
        .tag
        .strip_prefix('v')
        .filter(|v| version(v))
        .ok_or_else(|| invalid("Expected a safe release tag vMAJOR.MINOR.PATCH"))?;
    require_separate(&options.app, &options.output)?;
    let files = verify_release_gates(&options.app, options.channel, runner)?;
    let installer_metadata = fs::symlink_metadata(&options.installer)?;
    if !installer_metadata.is_file()
        || installer_metadata.file_type().is_symlink()
        || installer_metadata.mode() & 0o111 == 0
    {
        return Err(invalid("Expected a signed Rust installer executable"));
    }
    checked(
        runner,
        &[
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "-R",
            APPLE_REQUIREMENT,
            text(&options.installer)?,
        ],
    )?;
    if options.channel == ReleaseChannel::Notarized {
        checked(
            runner,
            &[
                "/usr/sbin/spctl",
                "--assess",
                "--type",
                "execute",
                text(&options.installer)?,
            ],
        )?;
    }
    let plist = options.app.join("Contents/Info.plist");
    let app_version = checked(
        runner,
        &[
            "/usr/bin/plutil",
            "-extract",
            "CFBundleShortVersionString",
            "raw",
            "-o",
            "-",
            text(&plist)?,
        ],
    )?;
    let minimum = checked(
        runner,
        &[
            "/usr/bin/plutil",
            "-extract",
            "LSMinimumSystemVersion",
            "raw",
            "-o",
            "-",
            text(&plist)?,
        ],
    )?;
    if !version(&app_version)
        || minimum
            .split('.')
            .next()
            .and_then(|s| s.parse::<u32>().ok())
            .is_none_or(|n| n < 14)
        || minimum
            .split('.')
            .any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(invalid("Release plist version or minimum macOS is invalid"));
    }
    safe_directory(&options.output, true)?;
    let stem = format!(
        "Computa-{release_version}-arm64{}",
        if options.channel == ReleaseChannel::SignedTest {
            "-signed-test"
        } else {
            ""
        }
    );
    let image = options.output.join(format!("{stem}.dmg"));
    let manifest_output = options.output.join(format!("{stem}.manifest.json"));
    let checksum_output = options.output.join("SHA256SUMS");
    for output in [&image, &manifest_output, &checksum_output] {
        if fs::symlink_metadata(output).is_ok() {
            return Err(invalid(
                "Release outputs already exist; nothing was overwritten",
            ));
        }
    }
    let stage = tempfile::Builder::new()
        .prefix(".computa-release-")
        .tempdir_in(&options.output)?
        .keep();
    let payload = stage.join("payload");
    fs::create_dir(&payload)?;
    checked(
        runner,
        &[
            "/usr/bin/ditto",
            "--rsrc",
            "--extattr",
            "--acl",
            text(&options.app)?,
            text(&payload.join("Computa.app"))?,
        ],
    )?;
    if verify_release_gates(&payload.join("Computa.app"), options.channel, runner)? != files {
        return Err(invalid("Packaging changed the verified signed application"));
    }
    fs::copy(&options.installer, payload.join("Computa Installer"))?;
    // Native grounding conversion is implemented inside the signed installer.
    // Its immutable library must travel with it as well as with app workers.
    let metal = options.app.join("Contents/Resources/InferenceRuntime");
    for resource in ["mlx.metallib", "manifest.json"] {
        fs::copy(metal.join(resource), payload.join(resource))?;
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    computa_inference::metal_resources::verify_directory(&payload)?;
    fs::write(
        payload.join("mlx-model.lock.json"),
        crate::models::REVIEWED_LOCK,
    )?;
    fs::write(
        payload.join("mlx-model-9b.lock.json"),
        crate::models::REVIEWED_9B_LOCK,
    )?;
    std::os::unix::fs::symlink("/Applications", payload.join("Applications"))?;
    let manifest = ReleaseManifest {
        schema_version: 2,
        bundle_identifier: BUNDLE_ID.into(),
        version: release_version.into(),
        tag: options.tag.clone(),
        app_version,
        architecture: "arm64".into(),
        minimum_mac_os: minimum.clone(),
        channel: options.channel,
        notarized_app_verified: options.channel == ReleaseChannel::Notarized,
        model_included: false,
        model_manifest_sha256: hex::encode(Sha256::digest(crate::models::REVIEWED_LOCK)),
        app_files: files,
    };
    let bytes = serde_json::to_vec_pretty(&manifest).map_err(invalid)?;
    write_new(&payload.join("release-manifest.json"), &bytes)?;
    write_new(&payload.join("READ ME.txt"),format!("Computa {release_version}, Apple Silicon macOS {minimum}+\n\nRun the signed Rust installer with install-release --package-root PATH --download-model to authorize the pinned 4B download. Existing verified model installations work offline; without that flag no weights are downloaded. Existing app backups and chats are preserved. Quit Computa and Mactopus before installation. Grant macOS permissions and Chrome consent separately. Channel: {:?}. The app notarization ticket does not notarize the DMG; assess the image separately before publishing.\n",options.channel).as_bytes())?;
    let mut checksums = String::new();
    for name in [
        "Computa Installer",
        "READ ME.txt",
        "mlx-model.lock.json",
        "release-manifest.json",
    ] {
        checksums.push_str(&format!("{}  {name}\n", digest_file(&payload.join(name))?));
    }
    write_new(&payload.join("SHA256SUMS"), checksums.as_bytes())?;
    let staged_image = stage.join(format!("{stem}.dmg"));
    checked(
        runner,
        &[
            "/usr/bin/hdiutil",
            "create",
            "-volname",
            &format!("Computa {release_version}"),
            "-srcfolder",
            text(&payload)?,
            "-fs",
            "HFS+",
            "-format",
            "UDZO",
            text(&staged_image)?,
        ],
    )?;
    checked(
        runner,
        &["/usr/bin/hdiutil", "verify", text(&staged_image)?],
    )?;
    let image_hash = digest_file(&staged_image)?;
    fs::rename(&staged_image, &image)?;
    write_new(&manifest_output, &bytes)?;
    write_new(
        &checksum_output,
        format!(
            "{image_hash}  {stem}.dmg\n{}  {stem}.manifest.json\n",
            digest_file(&manifest_output)?
        )
        .as_bytes(),
    )?;
    Ok(Package {
        dmg: image,
        manifest: manifest_output,
        stage,
    })
}
fn write_new(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}
/// Release package validation happens before any native install command or
/// model download; unreviewed legacy/Python installer manifests are rejected.
pub async fn install_release(
    package: &Path,
    user_home: &Path,
    download_model: bool,
    launch: bool,
    runner: &dyn Runner,
) -> io::Result<Installation> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return Err(invalid("Release installation requires Apple Silicon macOS"));
    }
    safe_directory(package, false)?;
    let value = computa_contracts::strict_json::parse(&read_regular(
        &package.join("release-manifest.json"),
        4 * 1024 * 1024,
    )?)
    .map_err(invalid)?;
    let manifest: ReleaseManifest = serde_json::from_value(value).map_err(invalid)?;
    if manifest.schema_version != 2
        || manifest.bundle_identifier != BUNDLE_ID
        || manifest.architecture != "arm64"
        || manifest.model_included
        || manifest.tag != format!("v{}", manifest.version)
        || !version(&manifest.version)
        || manifest.notarized_app_verified != (manifest.channel == ReleaseChannel::Notarized)
        || manifest.model_manifest_sha256
            != hex::encode(Sha256::digest(crate::models::REVIEWED_LOCK))
    {
        return Err(invalid("Unsupported or changed Rust release manifest"));
    }
    crate::models::load_manifest(&package.join("mlx-model.lock.json"))?;
    let app = package.join("Computa.app");
    if verify_release_gates(&app, manifest.channel, runner)? != manifest.app_files {
        return Err(invalid("Application differs from its release manifest"));
    }
    let plist = app.join("Contents/Info.plist");
    if checked(
        runner,
        &[
            "/usr/bin/plutil",
            "-extract",
            "CFBundleShortVersionString",
            "raw",
            "-o",
            "-",
            text(&plist)?,
        ],
    )? != manifest.app_version
        || checked(
            runner,
            &[
                "/usr/bin/plutil",
                "-extract",
                "LSMinimumSystemVersion",
                "raw",
                "-o",
                "-",
                text(&plist)?,
            ],
        )? != manifest.minimum_mac_os
    {
        return Err(invalid("Release plist metadata differs from its manifest"));
    }
    require_stopped(runner)?;
    check_existing(user_home, runner)?;
    let actual = checked(runner, &["/usr/bin/sw_vers", "-productVersion"])?;
    let components = |v: &str| -> io::Result<Vec<u32>> {
        v.split('.')
            .map(|s| s.parse::<u32>().map_err(invalid))
            .collect()
    };
    let mut actual = components(&actual)?;
    let mut minimum = components(&manifest.minimum_mac_os)?;
    let count = actual.len().max(minimum.len());
    actual.resize(count, 0);
    minimum.resize(count, 0);
    if actual < minimum {
        return Err(invalid("This release requires a newer macOS version"));
    }
    crate::models::install_model(
        &user_home.join("Library/Application Support/LocalCodex/MLX/models"),
        download_model,
    )
    .await?;
    let installed = install_app(&app, user_home, runner)?;
    if launch {
        checked(runner, &["/usr/bin/open", text(&installed.app)?])?;
    }
    Ok(installed)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    struct Fake;
    impl Runner for Fake {
        fn run(&self, args: &[String]) -> io::Result<CommandResult> {
            let stdout = if args[0] == "/usr/bin/security" {
                "  1) 0123456789012345678901234567890123456789 \"Developer ID Application: Owned (TEAM)\"\n".into()
            } else {
                String::new()
            };
            Ok(CommandResult {
                code: if args[0] == "/usr/bin/pgrep" { 1 } else { 0 },
                stdout,
            })
        }
    }
    #[test]
    fn signing_requires_one_exact_installed_identity() {
        let runner = Fake;
        assert_eq!(
            signing_identity("Developer ID Application: Owned (TEAM)", true, &runner).unwrap(),
            "0123456789012345678901234567890123456789"
        );
        assert!(signing_identity("Owned", true, &runner).is_err());
        assert!(signing_identity("--force", true, &runner).is_err());
    }
    #[test]
    fn inventory_rejects_symlinked_entries_and_orders_whole_utf8_paths() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        fs::create_dir(root.join("Resources")).unwrap();
        fs::write(root.join("Resources/z"), b"z").unwrap();
        fs::write(root.join("Resources.plist"), b"a").unwrap();
        let files = bundle_files(&root).unwrap();
        assert_eq!(files[0].path, "Resources.plist");
        std::os::unix::fs::symlink("Resources.plist", root.join("link")).unwrap();
        assert!(bundle_files(&root).is_err());
    }
    #[test]
    fn release_versions_and_output_separation_are_strict() {
        assert!(version("1.2.3-beta.1"));
        assert!(!version("1.2"));
        assert!(!version("1.2.3/unsafe"));
        assert!(require_separate(Path::new("/tmp/app"), Path::new("/tmp/app/output")).is_err());
    }
    struct FixtureRunner {
        commands: std::sync::Mutex<Vec<Vec<String>>>,
        deny_notarization: bool,
        mutate_signature: bool,
    }
    impl FixtureRunner {
        fn new() -> Self {
            Self {
                commands: std::sync::Mutex::new(vec![]),
                deny_notarization: false,
                mutate_signature: false,
            }
        }
    }
    impl Runner for FixtureRunner {
        fn run(&self, args: &[String]) -> io::Result<CommandResult> {
            self.commands.lock().unwrap().push(args.to_vec());
            let mut code = 0;
            let stdout=match args[0].as_str(){
                "/usr/bin/plutil"=>match args[2].as_str(){
                    "CFBundleIdentifier"=>BUNDLE_ID.into(),
                    "CFBundleExecutable"=>if args.last().unwrap().contains("Mactopus.app") {"Mactopus".into()} else {"Computa".into()},
                    "CFBundleShortVersionString"=>"0.1.0".into(),"LSMinimumSystemVersion"=>"14.0".into(),_=>String::new(),
                },
                "/usr/bin/pgrep"=>{code=1;String::new()},
                "/usr/bin/lipo"=>"arm64".into(),
                "/usr/bin/otool"=>"binary:\n /usr/lib/libSystem.B.dylib (compatibility version 1.0.0)".into(),
                "/usr/bin/security"=>"  1) 0123456789012345678901234567890123456789 \"Developer ID Application: Owned (TEAM)\"\n".into(),
                "/usr/bin/ditto"=>{crate::assets::copy_tree(Path::new(&args[args.len()-2]),Path::new(args.last().unwrap()))?;String::new()},
                "/usr/bin/codesign"=>{if self.mutate_signature&&args.iter().any(|a|a=="--force")&&args.last().unwrap().ends_with("codex-app-server"){fs::OpenOptions::new().append(true).open(args.last().unwrap())?.write_all(b"signed")?;}String::new()},
                "/usr/bin/xcrun" if args[1]=="stapler"=>{if self.deny_notarization{code=1;}String::new()},
                "/usr/bin/hdiutil" if args[1]=="create"=>{fs::write(args.last().unwrap(),b"test disk image")?;String::new()},
                "/usr/bin/sw_vers"=>"14.2.1".into(),
                "/usr/bin/xcode-select"=>"/Applications/Xcode.app/Contents/Developer".into(),
                "rustup" if args[1]=="run"=>"rustc 1.95.0 (fixture)".into(),
                "rustup" if args[1]=="target"=>"aarch64-apple-darwin\nwasm32-unknown-unknown".into(),
                "wasm-bindgen"=>"wasm-bindgen 0.2.129".into(),
                _=>String::new(),
            };
            Ok(CommandResult { code, stdout })
        }
    }
    fn fixture_app(path: &Path, marker: &str) {
        let mut macho = vec![0u8; 32];
        macho[0..4].copy_from_slice(&0xfeedfacfu32.to_le_bytes());
        macho[4..8].copy_from_slice(&0x0100000cu32.to_le_bytes());
        macho[12..16].copy_from_slice(&2u32.to_le_bytes());
        macho[16..20].copy_from_slice(&1u32.to_le_bytes());
        for binary in [
            "Contents/MacOS/Computa",
            "Contents/Resources/ChromeBridge/ChromeBridgeHost",
            "Contents/Resources/AgentRuntime/codex-app-server",
            "Contents/Resources/InferenceRuntime/computa-inference-worker",
            "Contents/Resources/InferenceRuntime/computa-grounding-worker",
        ] {
            let file = path.join(binary);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            let mut bytes = macho.clone();
            if binary.ends_with("Computa") {
                bytes.extend_from_slice(marker.as_bytes());
            }
            fs::write(&file, bytes).unwrap();
            fs::set_permissions(file, fs::Permissions::from_mode(0o755)).unwrap();
        }
        for (relative, bytes) in grounding_provenance() {
            let path = path.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, bytes).unwrap();
        }
        for (name, bytes) in [
            ("mlx-model.lock.json", crate::models::REVIEWED_LOCK),
            ("mlx-model-9b.lock.json", crate::models::REVIEWED_9B_LOCK),
        ] {
            fs::write(path.join("Contents/Resources").join(name), bytes).unwrap();
        }
        let metal = path.join("Contents/Resources/InferenceRuntime");
        let bytes = b"MTLBnativefixture";
        fs::write(metal.join("mlx.metallib"), bytes).unwrap();
        fs::write(
            metal.join("manifest.json"),
            serde_json::to_vec(&MetalManifest {
                schema_version: 1,
                backend: "mlex-0.1.3".into(),
                file: "mlx.metallib".into(),
                bytes: bytes.len() as u64,
                sha256: hex::encode(Sha256::digest(bytes)),
            })
            .unwrap(),
        )
        .unwrap();
        for (name, data) in [
            ("Contents/Info.plist", "<plist/>"),
            ("Contents/Resources/WebUI/index.html", "<div/>"),
            ("Contents/Resources/BrowserExtension/manifest.json", "{}"),
        ] {
            let file = path.join(name);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, data).unwrap();
        }
        let manifest = serde_json::json!({"schemaVersion":1,"runtimeVersion":"mactopus-5","sourceCommit":computa_runtime::artifact::SOURCE_COMMIT,"patchSHA256":computa_runtime::artifact::PATCH_SHA256,"binarySHA256":digest_file(&path.join("Contents/Resources/AgentRuntime/codex-app-server")).unwrap(),"binarySize":32,"platform":"macos","architecture":"arm64","executable":"codex-app-server"});
        fs::write(
            path.join("Contents/Resources/AgentRuntime/manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
    }
    #[test]
    fn moved_app_requires_both_native_workers_and_exact_colocated_metal_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let app = temp.path().canonicalize().unwrap().join("Computa.app");
        fixture_app(&app, "native");
        let runner = FixtureRunner::new();
        inspect_rust_app(&app, &runner).expect("The valid moved-app fixture must pass inspection");
        let runtime = app.join("Contents/Resources/InferenceRuntime");
        let library = runtime.join("mlx.metallib");
        let original = fs::read(&library).unwrap();
        fs::remove_file(&library).unwrap();
        assert!(inspect_rust_app(&app, &runner).is_err());
        fs::write(&library, b"MTLBsubstituted").unwrap();
        assert!(inspect_rust_app(&app, &runner).is_err());
        fs::write(&library, original).unwrap();
        fs::remove_file(runtime.join("computa-grounding-worker")).unwrap();
        assert!(inspect_rust_app(&app, &runner).is_err());
    }
    #[test]
    fn failed_commit_restores_previous_app_and_preserves_source_and_stage() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let source = root.join("Build/Computa.app");
        fixture_app(&source, "new");
        let home = root.join("user");
        let previous = home.join("Applications/Computa.app");
        fixture_app(&previous, "old");
        let old_files = bundle_files(&previous).unwrap();
        let source_files = bundle_files(&source).unwrap();
        let mut moves = 0;
        let result = install_verified(
            &source,
            &home,
            "Computa",
            true,
            &FixtureRunner::new(),
            |a, b| {
                moves += 1;
                if moves == 2 {
                    return Err(io::Error::other("injected commit failure"));
                }
                fs::rename(a, b)
            },
        );
        assert!(result.is_err());
        assert_eq!(moves, 3);
        assert_eq!(bundle_files(&previous).unwrap(), old_files);
        assert_eq!(bundle_files(&source).unwrap(), source_files);
        assert!(fs::read_dir(home.join("Applications")).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".computa-install-")
        }));
    }
    #[test]
    fn install_backup_and_restore_keep_both_verified_versions() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let source = root.join("Build/Computa.app");
        fixture_app(&source, "new");
        let home = root.join("user");
        let previous = home.join("Applications/Computa.app");
        fixture_app(&previous, "old");
        let old = bundle_files(&previous).unwrap();
        let new = bundle_files(&source).unwrap();
        let runner = FixtureRunner::new();
        let installed = install_verified(&source, &home, "Computa", true, &runner, |a, b| {
            fs::rename(a, b)
        })
        .unwrap();
        let backup = installed.backup.unwrap();
        assert_eq!(bundle_files(&backup).unwrap(), old);
        assert_eq!(bundle_files(&installed.app).unwrap(), new);
        let restored = restore_backup(&backup, &home, &runner).unwrap();
        assert_eq!(bundle_files(&restored.app).unwrap(), old);
        assert_eq!(bundle_files(&restored.backup.unwrap()).unwrap(), new);
        assert_eq!(bundle_files(&backup).unwrap(), old);
    }
    #[test]
    fn duplicate_installations_stop_before_staging_or_backup() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let source = root.join("Build/Computa.app");
        fixture_app(&source, "new");
        let home = root.join("user");
        fixture_app(&home.join("Applications/Computa.app"), "old");
        let legacy = home.join("Applications/Mactopus.app");
        fixture_app(&legacy, "legacy");
        fs::rename(
            legacy.join("Contents/MacOS/Computa"),
            legacy.join("Contents/MacOS/Mactopus"),
        )
        .unwrap();
        let before = bundle_files(&home).unwrap();
        let runner = FixtureRunner::new();
        assert!(
            install_verified(&source, &home, "Computa", true, &runner, |a, b| fs::rename(
                a, b
            ))
            .is_err()
        );
        assert_eq!(bundle_files(&home).unwrap(), before);
        assert!(
            !runner
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|c| c[0] == "/usr/bin/ditto")
        );
    }
    #[test]
    fn nested_signing_updates_runtime_integrity_without_changing_upstream_provenance() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let source = root.join("Build/Computa.app");
        fixture_app(&source, "new");
        let before = bundle_files(&source).unwrap();
        let output = root.join("Signed/Computa.app");
        let mut runner = FixtureRunner::new();
        runner.mutate_signature = true;
        fs::create_dir(output.parent().unwrap()).unwrap();
        checked(
            &runner,
            &[
                "/usr/bin/ditto",
                text(&source).unwrap(),
                text(&output).unwrap(),
            ],
        )
        .unwrap();
        sign_bundle_in_place(&output, "-", false, &runner).unwrap();
        assert_eq!(bundle_files(&source).unwrap(), before);
        let artifact =
            computa_runtime::artifact::RuntimeArtifact::resolve(&output.join("Contents/Resources"))
                .unwrap();
        assert_eq!(
            artifact.manifest.source_commit,
            computa_runtime::artifact::SOURCE_COMMIT
        );
        assert_eq!(
            artifact.manifest.patch_sha256,
            computa_runtime::artifact::PATCH_SHA256
        );
        assert_eq!(artifact.manifest.binary_size, 38);
    }
    #[test]
    fn product_install_and_release_signing_reject_missing_source_authority_before_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let source = root.join("Build/Computa.app");
        fixture_app(&source, "new");
        let before = bundle_files(&source).unwrap();
        let home = root.join("user");
        let output = root.join("Signed/Computa.app");
        let runner = FixtureRunner::new();
        assert!(install_app(&source, &home, &runner).is_err());
        assert!(!home.exists());
        assert!(
            sign_release(
                &source,
                &output,
                "Developer ID Application: Owned (TEAM)",
                &runner
            )
            .is_err()
        );
        assert!(!output.exists());
        assert_eq!(before, bundle_files(&source).unwrap());
        assert!(
            !runner
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|c| c[0] == "/usr/bin/ditto")
        );
    }
    #[test]
    fn notarization_failure_stops_before_image_or_output_creation() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let app = root.join("Computa.app");
        fixture_app(&app, "new");
        let installer = root.join("installer");
        fs::write(&installer, b"fixture").unwrap();
        fs::set_permissions(&installer, fs::Permissions::from_mode(0o755)).unwrap();
        let output = root.join("release");
        let mut runner = FixtureRunner::new();
        runner.deny_notarization = true;
        assert!(
            package_release(
                &PackageOptions {
                    app,
                    output: output.clone(),
                    installer,
                    tag: "v0.1.0".into(),
                    channel: ReleaseChannel::Notarized
                },
                &runner
            )
            .is_err()
        );
        assert!(!output.exists());
        assert!(
            !runner
                .commands
                .lock()
                .unwrap()
                .iter()
                .any(|c| c[0] == "/usr/bin/hdiutil")
        );
    }
    #[test]
    fn source_check_is_nonmutating_and_never_invokes_build_or_network() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        for file in [
            "Cargo.lock",
            "rust-toolchain.toml",
            "Config/Computa-Info.plist",
            "Runtime/codex-source.lock.json",
            "Runtime/patches/compaction-retention.patch",
            "Scripts/mlx-model.lock.json",
            "Scripts/mlx-model-9b.lock.json",
            "crates/computa-inference/src/grounding_backend/model-manifest.json",
            "crates/computa-inference/src/grounding_backend/native-prompts.json",
            "crates/computa-inference/src/grounding_backend/owl-system.txt",
            "crates/computa-inference/src/grounding_backend/source-manifest.json",
            "crates/computa-inference/src/grounding_backend/native-model-manifest.json",
            "crates/computa-inference/src/grounding_backend/native-conversion-parity.json",
        ] {
            let destination = root.join(file);
            fs::create_dir_all(destination.parent().unwrap()).unwrap();
            fs::copy(repo.join(file), destination).unwrap();
        }
        let before = bundle_files(&root).unwrap();
        let runner = FixtureRunner::new();
        crate::setup::check_prerequisites(&root, "wasm-bindgen", &runner).unwrap();
        assert_eq!(bundle_files(&root).unwrap(), before);
        assert!(
            runner
                .commands
                .lock()
                .unwrap()
                .iter()
                .all(|c| !c.iter().any(|a| matches!(
                    a.as_str(),
                    "build" | "install" | "clone" | "open" | "--force"
                )))
        );
    }
}
