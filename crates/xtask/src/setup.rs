//! Source setup preserves native installation gates without Python, Swift,
//! Node or shell-script subprocess dependencies.
use crate::{
    distribution::{self, Runner, checked, text},
    models,
};
use std::{
    collections::HashSet,
    fs, io,
    path::{Path, PathBuf},
};
#[derive(Clone, Debug, Default)]
pub struct Options {
    pub check: bool,
    pub build_only: bool,
    pub no_launch: bool,
    pub download_model: bool,
    pub signing_identity: Option<String>,
    pub wasm_bindgen: Option<String>,
}
pub fn parse_options(args: &[String]) -> io::Result<Options> {
    let mut result = Options::default();
    let mut seen = HashSet::new();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        if !seen.insert(arg) {
            return Err(distribution::invalid("Duplicate setup option"));
        }
        match arg.as_str() {
            "--check" => result.check = true,
            "--build-only" => result.build_only = true,
            "--no-launch" => result.no_launch = true,
            "--download-model" => result.download_model = true,
            "--signing-identity" | "--wasm-bindgen" => {
                let value = args
                    .next()
                    .filter(|v| {
                        !v.is_empty() && !v.starts_with('-') && !v.chars().any(char::is_control)
                    })
                    .ok_or_else(|| {
                        distribution::invalid("Setup option requires an exact non-option value")
                    })?;
                if arg == "--signing-identity" {
                    result.signing_identity = Some(value.clone());
                } else {
                    result.wasm_bindgen = Some(value.clone());
                }
            }
            _ => return Err(distribution::invalid("Unknown source setup option")),
        }
    }
    if result.check && (result.build_only || result.no_launch || result.download_model) {
        return Err(distribution::invalid(
            "--check is read-only and cannot accompany build, launch or download options",
        ));
    }
    if result.build_only && result.download_model {
        return Err(distribution::invalid(
            "--build-only cannot install model weights",
        ));
    }
    Ok(result)
}
fn version_at_least(actual: &str, minimum: &[u32]) -> bool {
    let number = actual
        .split_whitespace()
        .find(|s| s.bytes().next().is_some_and(|b| b.is_ascii_digit()))
        .unwrap_or(actual);
    let Ok(mut parts) = number
        .split('.')
        .map(str::parse::<u32>)
        .collect::<Result<Vec<_>, _>>()
    else {
        return false;
    };
    parts.resize(minimum.len().max(parts.len()), 0);
    parts.as_slice() >= minimum
}
/// Reads source files and invokes only version/identity queries. It never
/// invokes Cargo builds, tests, installs, directories or network downloads.
pub fn check_prerequisites(root: &Path, wasm_bindgen: &str, runner: &dyn Runner) -> io::Result<()> {
    crate::version::read(root)?;
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return Err(distribution::invalid(
            "Computa requires Apple Silicon macOS",
        ));
    }
    if !version_at_least(
        &checked(runner, &["/usr/bin/sw_vers", "-productVersion"])?,
        &[14, 0],
    ) {
        return Err(distribution::invalid("macOS 14 or later is required"));
    }
    let xcode = checked(runner, &["/usr/bin/xcode-select", "-p"])?;
    if !xcode.ends_with(".app/Contents/Developer") {
        return Err(distribution::invalid(
            "Select a full Xcode installation first",
        ));
    }
    checked(runner, &["/usr/bin/xcodebuild", "-version"])?;
    let rust = checked(runner, &["rustup", "run", "1.95.0", "rustc", "--version"])?;
    if !rust.starts_with("rustc 1.95.0 ") {
        return Err(distribution::invalid(
            "The installed pinned Rust 1.95.0 toolchain is required",
        ));
    }
    let targets = checked(
        runner,
        &[
            "rustup",
            "target",
            "list",
            "--installed",
            "--toolchain",
            "1.95.0",
        ],
    )?;
    if !targets.lines().any(|s| s == "wasm32-unknown-unknown") {
        return Err(distribution::invalid(
            "Install wasm32-unknown-unknown for Rust 1.95.0 first; setup did not download it",
        ));
    }
    if checked(runner, &[wasm_bindgen, "--version"])? != "wasm-bindgen 0.2.129" {
        return Err(distribution::invalid(
            "The matching wasm-bindgen 0.2.129 CLI must already be installed",
        ));
    }
    checked(runner, &["git", "--version"])?;
    checked(runner, &["rustup", "run", "1.95.0", "cargo", "--version"])?;
    for source in [
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
        models::read_regular(&root.join(source), 4 * 1024 * 1024)?;
    }
    crate::runtime_source::read_pin(root)?;
    models::load_manifest(&root.join("Scripts/mlx-model.lock.json"))?;
    models::load_manifest(&root.join("Scripts/mlx-model-9b.lock.json"))?;
    Ok(())
}
fn require_product_profile(debug_assertions: bool) -> io::Result<()> {
    if debug_assertions {
        return Err(distribution::invalid(
            "Source app builds require the release installer so its immutable Metal pin matches the release workers. Run cargo run --locked --release -p xtask -- setup with the requested options.",
        ));
    }
    Ok(())
}

fn render_info_plist(template: &str, version: &crate::version::AppVersion) -> io::Result<String> {
    let plist = template
        .replace("$(DEVELOPMENT_LANGUAGE)", "en")
        .replace("$(EXECUTABLE_NAME)", "Computa")
        .replace("$(PRODUCT_BUNDLE_IDENTIFIER)", distribution::BUNDLE_ID)
        .replace("$(PRODUCT_NAME)", "Computa")
        .replace("$(PRODUCT_BUNDLE_PACKAGE_TYPE)", "APPL")
        .replace("$(MARKETING_VERSION)", &version.marketing)
        .replace("$(CURRENT_PROJECT_VERSION)", &version.build)
        .replace("$(MACOSX_DEPLOYMENT_TARGET)", "14.0");
    if plist.contains("$(") {
        return Err(distribution::invalid(
            "Info.plist contains unresolved build settings",
        ));
    }
    Ok(plist)
}

pub fn build_app(
    root: &Path,
    wasm_bindgen: &str,
    identity: &str,
    runner: &dyn Runner,
) -> io::Result<PathBuf> {
    require_product_profile(cfg!(debug_assertions))?;
    let version = crate::version::read(root)?;
    let source = crate::source_build::capture(root, runner)?;
    crate::runtime_source::build_product_runtime(
        root,
        &root.join(".build/runtime/codex-source-reviewed"),
    )?;
    let resources = crate::assets::build_web(root, wasm_bindgen, true)?;
    crate::runtime_source::run(
        "cargo",
        &[
            "build",
            "--locked",
            "--release",
            "-p",
            "computa-desktop",
            "-p",
            "computa-browser",
            "-p",
            "computa-inference",
        ],
        root,
        false,
    )?;
    let products = root.join("target/SourceInstall");
    models::safe_directory(&products, true)?;
    let stage = tempfile::Builder::new()
        .prefix("build-")
        .tempdir_in(&products)?
        .keep();
    let app = stage.join("Computa.app");
    let contents = app.join("Contents");
    fs::create_dir_all(contents.join("MacOS"))?;
    fs::create_dir_all(contents.join("Resources"))?;
    fs::copy(
        root.join("target/release/computa-desktop"),
        contents.join("MacOS/Computa"),
    )?;
    for resource in ["WebUI", "BrowserExtension", "AgentRuntime"] {
        crate::assets::copy_tree(
            &resources.join(resource),
            &contents.join("Resources").join(resource),
        )?;
    }
    let chrome = contents.join("Resources/ChromeBridge");
    fs::create_dir(&chrome)?;
    fs::copy(
        root.join("target/release/computa-chrome-host"),
        chrome.join("ChromeBridgeHost"),
    )?;
    let inference = contents.join("Resources/InferenceRuntime");
    fs::create_dir(&inference)?;
    fs::copy(
        root.join("target/release/computa-inference-worker"),
        inference.join("computa-inference-worker"),
    )?;
    fs::copy(
        root.join("target/release/computa-grounding-worker"),
        inference.join("computa-grounding-worker"),
    )?;
    let metal = root.join("target/release/NativeInferenceResources");
    // The manifest alone cannot choose a replacement Metal library. Require
    // the installer's immutable native dependency pin before staging it.
    computa_inference::metal_resources::verify_directory(&metal)?;
    distribution::inspect_metal_directory(&metal)?;
    fs::copy(metal.join("mlx.metallib"), inference.join("mlx.metallib"))?;
    fs::copy(metal.join("manifest.json"), inference.join("manifest.json"))?;
    distribution::inspect_metal_directory(&inference)?;
    for (relative, bytes) in distribution::grounding_provenance() {
        let path = app.join(relative);
        fs::create_dir_all(
            path.parent()
                .ok_or_else(|| distribution::invalid("Missing grounding resource parent"))?,
        )?;
        fs::write(path, bytes)?;
    }
    for (name, bytes) in [
        ("mlx-model.lock.json", models::REVIEWED_LOCK),
        ("mlx-model-9b.lock.json", models::REVIEWED_9B_LOCK),
    ] {
        fs::write(contents.join("Resources").join(name), bytes)?;
    }
    let plist = render_info_plist(
        &fs::read_to_string(root.join("Config/Computa-Info.plist"))?,
        &version,
    )?;
    fs::write(contents.join("Info.plist"), plist)?;
    distribution::sign_bundle_with_source(&app, identity, false, runner, root, &source)?;
    if identity != "-" {
        checked(
            runner,
            &[
                "/usr/bin/codesign",
                "--verify",
                "--strict",
                "-R",
                "=anchor apple generic",
                text(&app)?,
            ],
        )?;
    }
    Ok(app)
}
pub enum SetupResult {
    Checked,
    Built(PathBuf),
    Installed(distribution::Installation),
}
pub async fn setup(
    options: &Options,
    root: &Path,
    user_home: &Path,
    runner: &dyn Runner,
) -> io::Result<SetupResult> {
    let wasm_bindgen = options.wasm_bindgen.as_deref().unwrap_or("wasm-bindgen");
    check_prerequisites(root, wasm_bindgen, runner)?;
    let identity = match options.signing_identity.as_deref() {
        Some(identity) => distribution::signing_identity(identity, false, runner)?,
        None => "-".into(),
    };
    if options.check {
        return Ok(SetupResult::Checked);
    }
    if !options.build_only {
        distribution::require_stopped(runner)?;
        distribution::check_existing(user_home, runner)?;
    }
    let app = build_app(root, wasm_bindgen, &identity, runner)?;
    if options.build_only {
        return Ok(SetupResult::Built(app));
    }
    distribution::require_stopped(runner)?;
    distribution::check_existing(user_home, runner)?;
    let model_root = user_home.join("Library/Application Support/LocalCodex/MLX/models");
    let destination = model_root.join(models::reviewed_manifest()?.repo);
    if options.download_model || fs::symlink_metadata(destination).is_ok() {
        models::install_model(&model_root, options.download_model).await?;
    }
    let installed = distribution::install_app(&app, user_home, runner)?;
    if !options.no_launch {
        checked(runner, &["/usr/bin/open", text(&installed.app)?])?;
    }
    Ok(SetupResult::Installed(installed))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn check_and_build_only_reject_mutating_combinations() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(parse_options(&args(&["--check", "--download-model"])).is_err());
        assert!(parse_options(&args(&["--check", "--no-launch"])).is_err());
        assert!(parse_options(&args(&["--build-only", "--download-model"])).is_err());
        assert!(parse_options(&args(&["--signing-identity", "--force"])).is_err());
        assert!(parse_options(&args(&["--check", "--check"])).is_err());
        assert!(parse_options(&args(&["--check"])).unwrap().check);
    }
    #[test]
    fn product_build_requires_matching_release_installer_pin() {
        assert!(require_product_profile(true).is_err());
        assert!(require_product_profile(false).is_ok());
    }
    #[test]
    fn prerequisite_version_comparison_is_numeric() {
        assert!(version_at_least("14.10.1", &[14, 2]));
        assert!(!version_at_least("13.9", &[14, 0]));
        assert!(!version_at_least("unknown", &[14, 0]));
    }
    #[test]
    fn plist_uses_canonical_marketing_and_build_without_unresolved_overrides() {
        let version = crate::version::parse_xcconfig(
            "MARKETING_VERSION = 0.1.1\nCURRENT_PROJECT_VERSION = 2\n",
        )
        .unwrap();
        let rendered =
            render_info_plist(include_str!("../../../Config/Computa-Info.plist"), &version)
                .unwrap();
        assert!(
            rendered.contains("<key>CFBundleShortVersionString</key>\n\t<string>0.1.1</string>")
        );
        assert!(rendered.contains("<key>CFBundleVersion</key>\n\t<string>2</string>"));
        assert!(!rendered.contains("$("));
        assert!(render_info_plist("$(UNREVIEWED)", &version).is_err());
    }
}
