//! Three pinned visual grounders, implemented in Rust over MLX tensors.
//! Model names, publisher protocols and the frozen agreement cascade are
//! preserved. No checkpoint downloads, Python, remote code or browser authority.
use crate::grounding::{self, Point, Selection};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[path = "grounding_backend/conversion.rs"]
pub mod conversion;
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[path = "grounding_backend/florence.rs"]
mod florence;
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[path = "grounding_backend/native_conversion.rs"]
pub mod native_conversion;
#[path = "grounding_backend/processor.rs"]
mod processor;
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[path = "grounding_backend/qwen_vl.rs"]
mod qwen_vl;
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
#[path = "grounding_backend/tensor.rs"]
mod tensor;
const MANIFEST: &[u8] = include_bytes!("grounding_backend/model-manifest.json");
const NATIVE_MANIFEST: &[u8] = include_bytes!("grounding_backend/native-model-manifest.json");
const SOURCE_MANIFEST: &[u8] = include_bytes!("grounding_backend/source-manifest.json");
const NUMERICAL_PARITY: &[u8] = include_bytes!("grounding_backend/native-conversion-parity.json");
const NATIVE_FORMAT: &str = "computa-native-grounding-v1";
const CONVERTER: &str = "computa-mlx-affine-v1";
const OWL_SYSTEM: &str = include_str!("grounding_backend/owl-system.txt");
pub const METHOD_VERSION: &str = "goclick-guiowl-showui-agreement-v2";
pub const MODEL_IDS: [&str; 3] = ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"];
#[derive(Debug, thiserror::Error)]
pub enum GroundingError {
    #[error("The three pinned grounding models are not installed.")]
    Unavailable,
    #[error("The local grounding installation differs from its pinned model manifest.")]
    Installation,
    #[error("Screenshot must be a single bounded PNG observation.")]
    Image,
    #[error("The grounding target contains unsupported formatting or exceeds its bound.")]
    Target,
    #[error("The pinned image processor configuration is unsupported.")]
    Processor,
    #[error("Visual grounding was cancelled or exceeded its cooperative deadline.")]
    Cancelled,
    #[error("A native visual model failed; no coordinate was authorized.")]
    Model,
    #[error("{0}")]
    Refusal(#[from] grounding::GroundingRefusal),
    #[error("Native visual inference requires an Apple Silicon macOS worker.")]
    Platform,
}
#[derive(Clone, Debug, Serialize)]
pub struct GroundingReply {
    pub protocol_version: u32,
    pub method_version: &'static str,
    pub image_sha256: String,
    pub target_sha256: String,
    pub width: u32,
    pub height: u32,
    pub selection: Selection,
    pub model_points: BTreeMap<&'static str, Option<Point>>,
    pub model_seconds: BTreeMap<&'static str, f64>,
    pub elapsed_seconds: f64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    models: BTreeMap<String, ModelPin>,
}
#[derive(Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Source {
    repo: String,
    revision: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelPin {
    source: Source,
    files: BTreeMap<String, String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordedModel {
    source: Source,
    files: BTreeMap<String, RecordedFile>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordedFile {
    bytes: u64,
    sha256: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InstallationReceipt {
    schema_version: u32,
    model_manifest_sha256: String,
    runtime_manifest_sha256: String,
    models: BTreeMap<String, RecordedModel>,
    runtime: Value,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeManifest {
    schema_version: u32,
    artifact_format: String,
    converter: String,
    source_manifest_sha256: String,
    numerical_parity_sha256: String,
    models: BTreeMap<String, ModelPin>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeReceipt {
    schema_version: u32,
    model_manifest_sha256: String,
    source_manifest_sha256: String,
    conversion_format: String,
    numerical_parity_sha256: String,
    models: BTreeMap<String, RecordedModel>,
    runtime: NativeRuntimeReceipt,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeRuntimeReceipt {
    backend: String,
    format: String,
}
struct SelectedInstallation {
    manifest: Manifest,
    recorded: BTreeMap<String, RecordedModel>,
}
fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn selected_installation(bytes: &[u8]) -> Result<SelectedInstallation, GroundingError> {
    let value =
        computa_contracts::strict_json::parse(bytes).map_err(|_| GroundingError::Installation)?;
    let (manifest, recorded) = match value["schema_version"].as_u64() {
        Some(3) => {
            let receipt: InstallationReceipt =
                serde_json::from_value(value).map_err(|_| GroundingError::Installation)?;
            let manifest: Manifest = serde_json::from_value(
                computa_contracts::strict_json::parse(MANIFEST)
                    .map_err(|_| GroundingError::Installation)?,
            )
            .map_err(|_| GroundingError::Installation)?;
            if receipt.schema_version != 3 || receipt.model_manifest_sha256 != digest(MANIFEST) {
                return Err(GroundingError::Installation);
            }
            // Historical runtime fields are migration evidence only. Rust does
            // not load the old interpreter or claim its package installation.
            let _ = (&receipt.runtime_manifest_sha256, &receipt.runtime);
            (manifest, receipt.models)
        }
        Some(4) => {
            let receipt: NativeReceipt =
                serde_json::from_value(value).map_err(|_| GroundingError::Installation)?;
            let native: NativeManifest = serde_json::from_value(
                computa_contracts::strict_json::parse(NATIVE_MANIFEST)
                    .map_err(|_| GroundingError::Installation)?,
            )
            .map_err(|_| GroundingError::Installation)?;
            let sources = computa_contracts::strict_json::parse(SOURCE_MANIFEST)
                .map_err(|_| GroundingError::Installation)?;
            if native.schema_version != 1
                || native.artifact_format != NATIVE_FORMAT
                || native.converter != CONVERTER
                || native.source_manifest_sha256 != digest(SOURCE_MANIFEST)
                || native.numerical_parity_sha256 != digest(NUMERICAL_PARITY)
                || receipt.schema_version != 4
                || receipt.model_manifest_sha256 != digest(NATIVE_MANIFEST)
                || receipt.source_manifest_sha256 != native.source_manifest_sha256
                || receipt.numerical_parity_sha256 != native.numerical_parity_sha256
                || receipt.conversion_format != CONVERTER
                || receipt.runtime.backend != "computa-rust-mlx"
                || receipt.runtime.format != NATIVE_FORMAT
                || sources["schemaVersion"] != 1
                || sources["models"].as_object().is_none_or(|m| {
                    m.keys().map(String::as_str).collect::<BTreeSet<_>>()
                        != BTreeSet::from(MODEL_IDS)
                })
                || native.models.iter().any(|(name, pin)| {
                    sources["models"][name]["repo"].as_str() != Some(&pin.source.repo)
                        || sources["models"][name]["revision"].as_str()
                            != Some(&pin.source.revision)
                })
            {
                return Err(GroundingError::Installation);
            }
            (
                Manifest {
                    schema_version: native.schema_version,
                    models: native.models,
                },
                receipt.models,
            )
        }
        _ => return Err(GroundingError::Installation),
    };
    if manifest.schema_version != 1
        || manifest
            .models
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>()
            != BTreeSet::from(MODEL_IDS)
        || recorded.keys().collect::<BTreeSet<_>>()
            != manifest.models.keys().collect::<BTreeSet<_>>()
    {
        return Err(GroundingError::Installation);
    }
    for (name, pin) in &manifest.models {
        let record = &recorded[name];
        if record.source != pin.source
            || record.files.keys().collect::<BTreeSet<_>>()
                != pin.files.keys().collect::<BTreeSet<_>>()
            || record.files.iter().any(|(name, file)| {
                file.sha256 != pin.files[name] || file.bytes > 16 * 1024 * 1024 * 1024
            })
        {
            return Err(GroundingError::Installation);
        }
    }
    Ok(SelectedInstallation { manifest, recorded })
}
#[derive(Clone, Debug, PartialEq)]
struct FileIdentity {
    bytes: u64,
    modified: Option<std::time::SystemTime>,
    #[cfg(unix)]
    dev: u64,
    #[cfg(unix)]
    ino: u64,
}
impl FileIdentity {
    fn from(metadata: &fs::Metadata) -> Self {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Self {
            bytes: metadata.len(),
            modified: metadata.modified().ok(),
            #[cfg(unix)]
            dev: metadata.dev(),
            #[cfg(unix)]
            ino: metadata.ino(),
        }
    }
}
/// Paths remain private so an inference request cannot select arbitrary weights.
pub struct VerifiedGroundingInstallation {
    root: PathBuf,
    manifest: Manifest,
    identities: BTreeMap<PathBuf, FileIdentity>,
}
impl VerifiedGroundingInstallation {
    pub fn verify(
        model_root: &Path,
        mut alive: impl FnMut() -> bool,
    ) -> Result<Self, GroundingError> {
        if !model_root.is_absolute() {
            return Err(GroundingError::Installation);
        }
        let root_meta =
            fs::symlink_metadata(model_root).map_err(|_| GroundingError::Unavailable)?;
        if !root_meta.is_dir() || root_meta.file_type().is_symlink() {
            return Err(GroundingError::Installation);
        }
        let root = fs::canonicalize(model_root).map_err(|_| GroundingError::Installation)?;
        if root != model_root {
            return Err(GroundingError::Installation);
        }
        let receipt_path = root
            .parent()
            .ok_or(GroundingError::Installation)?
            .join("installation.json");
        let bytes = bounded_file(&receipt_path, 1024 * 1024)?;
        let SelectedInstallation {
            manifest,
            recorded: recorded_models,
        } = selected_installation(&bytes)?;
        let dirs = fs::read_dir(&root)
            .map_err(|_| GroundingError::Installation)?
            .map(|e| {
                e.map_err(|_| GroundingError::Installation).and_then(|e| {
                    let m =
                        fs::symlink_metadata(e.path()).map_err(|_| GroundingError::Installation)?;
                    if !m.is_dir() || m.file_type().is_symlink() {
                        return Err(GroundingError::Installation);
                    }
                    e.file_name()
                        .into_string()
                        .map_err(|_| GroundingError::Installation)
                })
            })
            .collect::<Result<BTreeSet<_>, _>>()?;
        if dirs != manifest.models.keys().cloned().collect() {
            return Err(GroundingError::Installation);
        }
        let mut identities = BTreeMap::new();
        for (name, pin) in &manifest.models {
            let recorded = &recorded_models[name];
            if recorded.source != pin.source
                || recorded.files.keys().collect::<BTreeSet<_>>()
                    != pin.files.keys().collect::<BTreeSet<_>>()
            {
                return Err(GroundingError::Installation);
            }
            let dir = root.join(name);
            let files = model_file_names(&dir)?;
            if files != pin.files.keys().cloned().collect() {
                return Err(GroundingError::Installation);
            }
            for (file, hash) in &pin.files {
                if Path::new(file).components().count() != 1
                    || hash.len() != 64
                    || !hash
                        .bytes()
                        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
                {
                    return Err(GroundingError::Installation);
                }
                let path = dir.join(file);
                let record = &recorded.files[file];
                if record.sha256 != *hash || record.bytes > 16 * 1024 * 1024 * 1024 {
                    return Err(GroundingError::Installation);
                }
                let (digest, identity) = hash_file(&path, &mut alive)?;
                if digest != *hash || identity.bytes != record.bytes {
                    return Err(GroundingError::Installation);
                }
                identities.insert(path, identity);
            }
            let index = bounded_file(&dir.join("model.safetensors.index.json"), 16 * 1024 * 1024)?;
            let index = computa_contracts::strict_json::parse(&index)
                .map_err(|_| GroundingError::Installation)?;
            let shards = index["weight_map"]
                .as_object()
                .filter(|m| !m.is_empty() && m.len() <= 100_000)
                .ok_or(GroundingError::Installation)?;
            if shards.values().any(|v| {
                v.as_str()
                    .is_none_or(|s| !s.ends_with(".safetensors") || !pin.files.contains_key(s))
            }) {
                return Err(GroundingError::Installation);
            }
        }
        Ok(Self {
            root,
            manifest,
            identities,
        })
    }
    fn unchanged(&self) -> Result<(), GroundingError> {
        for (path, identity) in &self.identities {
            let m = fs::symlink_metadata(path).map_err(|_| GroundingError::Installation)?;
            if !m.is_file() || m.file_type().is_symlink() || FileIdentity::from(&m) != *identity {
                return Err(GroundingError::Installation);
            }
        }
        Ok(())
    }
    fn directory(&self, id: &str) -> Result<PathBuf, GroundingError> {
        if !self.manifest.models.contains_key(id) {
            return Err(GroundingError::Installation);
        }
        Ok(self.root.join(id))
    }
}
fn model_file_names(directory: &Path) -> Result<BTreeSet<String>, GroundingError> {
    let mut files = BTreeSet::new();
    for entry in fs::read_dir(directory).map_err(|_| GroundingError::Installation)? {
        let entry = entry.map_err(|_| GroundingError::Installation)?;
        let metadata =
            fs::symlink_metadata(entry.path()).map_err(|_| GroundingError::Installation)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| GroundingError::Installation)?;
        // HF's historical local_dir download bookkeeping is never a model
        // input. Do not traverse it, follow links or count it as pinned content.
        if name == ".cache" && metadata.is_dir() && !metadata.file_type().is_symlink() {
            continue;
        }
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(GroundingError::Installation);
        }
        files.insert(name);
    }
    Ok(files)
}
fn open_regular(path: &Path) -> Result<File, GroundingError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options
        .open(path)
        .map_err(|_| GroundingError::Installation)?;
    if !file
        .metadata()
        .map_err(|_| GroundingError::Installation)?
        .is_file()
    {
        return Err(GroundingError::Installation);
    }
    Ok(file)
}
fn bounded_file(path: &Path, max: usize) -> Result<Vec<u8>, GroundingError> {
    let file = open_regular(path)?;
    let before = FileIdentity::from(&file.metadata().map_err(|_| GroundingError::Installation)?);
    if before.bytes > max as u64 {
        return Err(GroundingError::Installation);
    }
    let mut data = Vec::new();
    file.take(max as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|_| GroundingError::Installation)?;
    if data.len() != before.bytes as usize {
        return Err(GroundingError::Installation);
    }
    let after = fs::symlink_metadata(path).map_err(|_| GroundingError::Installation)?;
    if FileIdentity::from(&after) != before || after.file_type().is_symlink() {
        return Err(GroundingError::Installation);
    }
    Ok(data)
}
fn hash_file(
    path: &Path,
    alive: &mut impl FnMut() -> bool,
) -> Result<(String, FileIdentity), GroundingError> {
    let mut file = open_regular(path)?;
    let before = FileIdentity::from(&file.metadata().map_err(|_| GroundingError::Installation)?);
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut read = 0;
    loop {
        if !alive() {
            return Err(GroundingError::Cancelled);
        }
        let n = file
            .read(&mut buffer)
            .map_err(|_| GroundingError::Installation)?;
        if n == 0 {
            break;
        }
        read += n as u64;
        if read > before.bytes {
            return Err(GroundingError::Installation);
        }
        digest.update(&buffer[..n]);
    }
    let after = FileIdentity::from(&file.metadata().map_err(|_| GroundingError::Installation)?);
    if before != after || read != before.bytes {
        return Err(GroundingError::Installation);
    }
    Ok((hex::encode(digest.finalize()), before))
}
fn target(value: &str) -> Result<(), GroundingError> {
    let forbidden =
        regex::Regex::new(r"[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]").map_err(|_| GroundingError::Target)?;
    if value.is_empty()
        || value.chars().count() > 512
        || value.trim() != value
        || forbidden.is_match(value)
    {
        Err(GroundingError::Target)
    } else {
        Ok(())
    }
}
fn descriptor(value: &str) -> &str {
    let value = value.trim().trim_end_matches('.');
    if value
        .get(..6)
        .is_some_and(|s| s.eq_ignore_ascii_case("click "))
    {
        &value[6..]
    } else {
        value
    }
}
fn go_prompt(value: &str) -> String {
    format!(
        "Where is the {} element? (Output the center coordinates of the target)",
        descriptor(value)
    )
}
const SHOWUI_SYSTEM: &str = "Based on the screenshot of the page, I give a text description and you give its corresponding location. The coordinate represents a clickable location [x, y] for an element, which is a relative coordinate on the screenshot, scaled from 0 to 1.";
fn owl_point(raw: &str, width: u32, height: u32) -> Option<Point> {
    if raw.len() > 16_000 {
        return None;
    }
    let (opens, closes) = (
        raw.matches("<think>").count(),
        raw.matches("</think>").count(),
    );
    if opens > 1
        || closes > 1
        || (opens == 1 && closes == 0)
        || (opens == 1 && closes == 1 && raw.find("<think>")? > raw.find("</think>")?)
    {
        return None;
    }
    let content = if closes == 1 {
        raw.split_once("</think>")?.1.trim()
    } else {
        raw.trim()
    };
    if regex::Regex::new(r"(?i)<\s*/?\s*think|<\s*/?\s*(?:t|th|thi|thin)\s*$")
        .ok()?
        .is_match(content)
        || content.matches("<tool_call>").count() != 1
        || content.matches("</tool_call>").count() != 1
    {
        return None;
    }
    let (_note, rest) = content.split_once("<tool_call>")?;
    let (call, tail) = rest.split_once("</tool_call>")?;
    if !tail.replace("<|im_end|>", "").trim().is_empty() {
        return None;
    }
    let value = computa_contracts::strict_json::parse(call.trim().as_bytes()).ok()?;
    let map = value.as_object()?;
    if map.len() != 2 || value["name"] != "computer_use" {
        return None;
    }
    let args = value["arguments"].as_object()?;
    if args.len() != 2
        || args
            .keys()
            .any(|k| !matches!(k.as_str(), "action" | "coordinate"))
        || !matches!(
            args.get("action")?.as_str()?,
            "left_click" | "right_click" | "double_click" | "triple_click"
        )
    {
        return None;
    }
    let coord = args.get("coordinate")?.as_array()?;
    if coord.len() != 2 {
        return None;
    }
    let x = coord[0].as_f64()?;
    let y = coord[1].as_f64()?;
    if !x.is_finite()
        || !y.is_finite()
        || !(0.0..=1000.0).contains(&x)
        || !(0.0..=1000.0).contains(&y)
    {
        return None;
    }
    Point {
        x: x * f64::from(width.saturating_sub(1)) / 1000.0,
        y: y * f64::from(height.saturating_sub(1)) / 1000.0,
    }
    .valid(width, height)
}
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
mod native {
    use super::*;
    use mlex::{
        Array,
        nn::WeightMap,
        quant::Quantization,
        tokenizer::{ChatMessage, ContentPart, ImageContent, Tokenizer},
    };
    /// Own on one inference worker thread. All model/KV/vision caches are local;
    /// no tensor, raw prose or proposed click crosses into AppKit authority.
    pub struct OwnedGrounder {
        installation: VerifiedGroundingInstallation,
        go: florence::Florence,
        go_tokenizer: Tokenizer,
        go_processor: Value,
        owl: qwen_vl::QwenVl,
        show: qwen_vl::QwenVl,
        // MLX stream selection and resident-slot lifetime stay on the worker
        // that constructs the grounder, even though raw Array is Send+Sync.
        thread_affinity: std::marker::PhantomData<std::rc::Rc<()>>,
    }
    fn load_json(path: &Path) -> Result<Value, GroundingError> {
        computa_contracts::strict_json::parse(&bounded_file(path, 16 * 1024 * 1024)?)
            .map_err(|_| GroundingError::Installation)
    }
    fn load_weights(path: &Path, config: &Value) -> Result<WeightMap, GroundingError> {
        let tensors = mlex::weights::load_all(path).map_err(|_| GroundingError::Model)?;
        let quant = Quantization::from_config(config).map_err(|_| GroundingError::Installation)?;
        Ok(WeightMap::new(tensors, quant))
    }
    pub(super) fn processor_config(dir: &Path) -> Result<Value, GroundingError> {
        let mut config = load_json(&dir.join("preprocessor_config.json"))?;
        let additional = dir.join("processor_config.json");
        if additional.exists() {
            let extra = load_json(&additional)?;
            if let Some(overrides) = extra["image_processor"].as_object() {
                let map = config.as_object_mut().ok_or(GroundingError::Processor)?;
                for (k, v) in overrides {
                    map.insert(k.clone(), v.clone());
                }
            }
        }
        Ok(config)
    }
    impl OwnedGrounder {
        pub fn load_verified(
            installation: VerifiedGroundingInstallation,
            mut alive: impl FnMut() -> bool,
        ) -> Result<Self, GroundingError> {
            installation.unchanged()?;
            let started = Instant::now();
            let mut active = || alive() && started.elapsed() < Duration::from_secs(180);
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            let go_dir = installation.directory(MODEL_IDS[0])?;
            let cfg = load_json(&go_dir.join("config.json"))?;
            let go = florence::Florence::load(&mut load_weights(&go_dir, &cfg)?, &cfg)
                .map_err(|_| GroundingError::Model)?;
            let go_tokenizer = Tokenizer::load(&go_dir).map_err(|_| GroundingError::Model)?;
            let go_processor = processor_config(&go_dir)?;
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            let owl_dir = installation.directory(MODEL_IDS[1])?;
            let cfg = load_json(&owl_dir.join("config.json"))?;
            let owl = qwen_vl::QwenVl::load(
                &mut load_weights(&owl_dir, &cfg)?,
                &cfg,
                &processor_config(&owl_dir)?,
                Tokenizer::load(&owl_dir).map_err(|_| GroundingError::Model)?,
            )
            .map_err(|_| GroundingError::Model)?;
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            let show_dir = installation.directory(MODEL_IDS[2])?;
            let cfg = load_json(&show_dir.join("config.json"))?;
            let show = qwen_vl::QwenVl::load(
                &mut load_weights(&show_dir, &cfg)?,
                &cfg,
                &processor_config(&show_dir)?,
                Tokenizer::load(&show_dir).map_err(|_| GroundingError::Model)?,
            )
            .map_err(|_| GroundingError::Model)?;
            mlex::array::synchronize().map_err(|_| GroundingError::Model)?;
            installation.unchanged()?;
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            Ok(Self {
                installation,
                go,
                go_tokenizer,
                go_processor,
                owl,
                show,
                thread_affinity: std::marker::PhantomData,
            })
        }
        /// Warm all three fixed models without publishing a coordinate. This
        /// benchmark-only operation uses the same production processors and
        /// prompts, including ShowUI when the first pair already agrees.
        pub fn warm_png(
            &mut self,
            png: &[u8],
            mut alive: impl FnMut() -> bool,
        ) -> Result<(), GroundingError> {
            let target = computa_contracts::grounding::WARMUP_TARGET;
            let started = Instant::now();
            let mut active = || alive() && started.elapsed() < Duration::from_secs(60);
            let used_show = match self.ground_png(png, target, &mut active) {
                Ok(reply) => reply.selection.used_showui,
                Err(GroundingError::Refusal(
                    grounding::GroundingRefusal::InsufficientValidPoints
                    | grounding::GroundingRefusal::NoPairAgreement,
                )) => true,
                Err(error) => return Err(error),
            };
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            if !used_show {
                let messages = vec![ChatMessage {
                    role: "user".into(),
                    content: vec![
                        ContentPart::Text(SHOWUI_SYSTEM.into()),
                        ContentPart::Image(ImageContent { bytes: png.into() }),
                        ContentPart::Text(target.into()),
                    ],
                    ..Default::default()
                }];
                let _ = self
                    .show
                    .generate(png, &messages, 32, &mut active)
                    .map_err(|_| {
                        if active() {
                            GroundingError::Model
                        } else {
                            GroundingError::Cancelled
                        }
                    })?;
            }
            mlex::array::synchronize().map_err(|_| GroundingError::Model)?;
            self.installation.unchanged()?;
            if active() {
                Ok(())
            } else {
                Err(GroundingError::Cancelled)
            }
        }
        pub fn ground_png(
            &mut self,
            png: &[u8],
            instruction: &str,
            mut alive: impl FnMut() -> bool,
        ) -> Result<GroundingReply, GroundingError> {
            target(instruction)?;
            let rgb = processor::png(png)?;
            self.installation.unchanged()?;
            let (width, height) = (rgb.width(), rgb.height());
            let started = Instant::now();
            let mut active = || alive() && started.elapsed() < Duration::from_secs(120);
            let mut times = BTreeMap::new();
            let at = Instant::now();
            let pixels = processor::florence_pixels(&rgb, &self.go_processor)?;
            let h = self.go_processor["size"]["height"]
                .as_i64()
                .ok_or(GroundingError::Processor)? as i32;
            let w = self.go_processor["size"]["width"]
                .as_i64()
                .ok_or(GroundingError::Processor)? as i32;
            // Florence's processor supplies float32 pixels; its DaViT does
            // not cast them to weight dtype before convolution.
            let pixels = Array::from_slice(&pixels, &[1, 3, h, w]);
            let tokens = self
                .go_tokenizer
                .encode(&go_prompt(instruction))
                .map_err(|_| GroundingError::Model)?;
            let generated = self
                .go
                .generate(&pixels, &tokens, &mut active)
                .map_err(|_| {
                    if active() {
                        GroundingError::Model
                    } else {
                        GroundingError::Cancelled
                    }
                })?;
            let raw = self
                .go_tokenizer
                .decode_raw(&generated)
                .map_err(|_| GroundingError::Model)?;
            let go = grounding::goclick_point(&raw, width, height);
            times.insert(MODEL_IDS[0], at.elapsed().as_secs_f64());
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            let at = Instant::now();
            let owl_messages = owl_messages(png, instruction)?;
            let owl_raw = self
                .owl
                .generate(png, &owl_messages, 256, &mut active)
                .map_err(|_| {
                    if active() {
                        GroundingError::Model
                    } else {
                        GroundingError::Cancelled
                    }
                })?;
            let owl = owl_point(&owl_raw, width, height);
            times.insert(MODEL_IDS[1], at.elapsed().as_secs_f64());
            let (use_show, _) = grounding::requires_showui(go, owl, width, height);
            let mut show = None;
            if use_show {
                let at = Instant::now();
                let messages = vec![ChatMessage {
                    role: "user".into(),
                    content: vec![
                        ContentPart::Text(SHOWUI_SYSTEM.into()),
                        ContentPart::Image(ImageContent { bytes: png.into() }),
                        ContentPart::Text(instruction.into()),
                    ],
                    ..Default::default()
                }];
                let raw = self
                    .show
                    .generate(png, &messages, 32, &mut active)
                    .map_err(|_| {
                        if active() {
                            GroundingError::Model
                        } else {
                            GroundingError::Cancelled
                        }
                    })?;
                show = grounding::showui_point(&raw, width, height);
                times.insert(MODEL_IDS[2], at.elapsed().as_secs_f64());
            }
            if !active() {
                return Err(GroundingError::Cancelled);
            }
            mlex::array::synchronize().map_err(|_| GroundingError::Model)?;
            let selection = grounding::select(go, owl, show, width, height)?;
            Ok(GroundingReply {
                protocol_version: 1,
                method_version: METHOD_VERSION,
                image_sha256: hex::encode(Sha256::digest(png)),
                target_sha256: hex::encode(Sha256::digest(instruction.as_bytes())),
                width,
                height,
                selection,
                model_points: BTreeMap::from([
                    (MODEL_IDS[0], go),
                    (MODEL_IDS[1], owl),
                    (MODEL_IDS[2], show),
                ]),
                model_seconds: times,
                elapsed_seconds: started.elapsed().as_secs_f64(),
            })
        }
    }
    fn owl_messages(png: &[u8], instruction: &str) -> Result<Vec<ChatMessage>, GroundingError> {
        let system = owl_system()?;
        Ok(vec![
            ChatMessage::system(system),
            ChatMessage {
                role: "user".into(),
                content: vec![
                    ContentPart::Text(format!(
                        "Please generate the next move according to the UI screenshot, instruction and previous actions.\n\nInstruction: {instruction}\n\nPrevious actions:\nNone"
                    )),
                    ContentPart::Image(ImageContent { bytes: png.into() }),
                ],
                ..Default::default()
            },
        ])
    }
}
#[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
pub use native::OwnedGrounder;
fn owl_system() -> Result<String, GroundingError> {
    // Exact task-independent protocol overlay frozen from the baseline,
    // including JSON insertion order and publisher whitespace.
    if hex::encode(Sha256::digest(OWL_SYSTEM.as_bytes()))
        != "adefe76b20adbedf89cf8d96cab0a91a0c870ae9ef736770e161861d730ae607"
    {
        return Err(GroundingError::Installation);
    }
    Ok(OWL_SYSTEM.into())
}
#[cfg(test)]
mod tests {
    use super::*;
    fn receipt_fixture(schema: u32) -> Value {
        let pins: Value = serde_json::from_slice(if schema == 4 {
            NATIVE_MANIFEST
        } else {
            MANIFEST
        })
        .unwrap();
        let models = pins["models"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, pin)| {
                let files = pin["files"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(file, hash)| {
                        (file.clone(), serde_json::json!({"bytes":1,"sha256":hash}))
                    })
                    .collect::<serde_json::Map<_, _>>();
                (
                    name.clone(),
                    serde_json::json!({"source":pin["source"],"files":files}),
                )
            })
            .collect::<serde_json::Map<_, _>>();
        if schema == 4 {
            serde_json::json!({"schema_version":4,"model_manifest_sha256":digest(NATIVE_MANIFEST),"source_manifest_sha256":digest(SOURCE_MANIFEST),"conversion_format":CONVERTER,"numerical_parity_sha256":digest(NUMERICAL_PARITY),"models":models,"runtime":{"backend":"computa-rust-mlx","format":NATIVE_FORMAT}})
        } else {
            serde_json::json!({"schema_version":3,"model_manifest_sha256":digest(MANIFEST),"runtime_manifest_sha256":"historical-evidence-only","models":models,"runtime":{"historical_python":"not-loaded"}})
        }
    }
    #[test]
    fn receipt_lanes_select_separate_compiled_pins_and_preserve_legacy_three() {
        let legacy =
            selected_installation(&serde_json::to_vec(&receipt_fixture(3)).unwrap()).unwrap();
        let native =
            selected_installation(&serde_json::to_vec(&receipt_fixture(4)).unwrap()).unwrap();
        assert_eq!(legacy.manifest.models.len(), 3);
        assert_eq!(native.manifest.models.len(), 3);
        assert_eq!(
            native.manifest.models[MODEL_IDS[0]].files["model.safetensors"],
            "5a8c5e5953a221880837c2b5689aefe5f3c2b61c8c262265d0568671dfb44917"
        );
        assert!(
            !native.manifest.models[MODEL_IDS[0]]
                .files
                .contains_key("processor_config.json")
        );
        assert!(
            legacy.manifest.models[MODEL_IDS[0]]
                .files
                .contains_key("processor_config.json")
        );
    }
    #[test]
    fn receipt_four_rejects_changed_provenance_converter_runtime_or_cross_lane_hashes() {
        for field in [
            "model_manifest_sha256",
            "source_manifest_sha256",
            "numerical_parity_sha256",
            "conversion_format",
        ] {
            let mut receipt = receipt_fixture(4);
            receipt[field] = Value::String("0".repeat(64));
            assert!(
                selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err(),
                "{field}"
            );
        }
        for field in ["backend", "format"] {
            let mut receipt = receipt_fixture(4);
            receipt["runtime"][field] = Value::String("unreviewed".into());
            assert!(
                selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err(),
                "{field}"
            );
        }
        let mut receipt = receipt_fixture(4);
        receipt["model_manifest_sha256"] = Value::String(digest(MANIFEST));
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
        receipt = receipt_fixture(4);
        receipt["runtime"]["download_url"] = serde_json::json!("https://unreviewed.invalid");
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
    }
    #[test]
    fn receipt_four_rejects_changed_source_file_pins_extra_files_and_duplicate_fields() {
        let mut receipt = receipt_fixture(4);
        receipt["models"][MODEL_IDS[0]]["source"]["revision"] = serde_json::json!("unreviewed");
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
        receipt = receipt_fixture(4);
        receipt["models"][MODEL_IDS[0]]["files"]["model.safetensors"]["sha256"] =
            serde_json::json!("0".repeat(64));
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
        receipt = receipt_fixture(4);
        receipt["models"][MODEL_IDS[0]]["files"]["processor_config.json"] =
            serde_json::json!({"bytes":1,"sha256":"0".repeat(64)});
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
        receipt = receipt_fixture(4);
        receipt["models"][MODEL_IDS[0]]["files"]
            .as_object_mut()
            .unwrap()
            .remove("tokenizer.json");
        assert!(selected_installation(&serde_json::to_vec(&receipt).unwrap()).is_err());
        let text = serde_json::to_string(&receipt_fixture(4)).unwrap();
        let duplicate = format!("{{\"schema_version\":4,{}", &text[1..]);
        assert!(selected_installation(duplicate.as_bytes()).is_err());
    }
    #[test]
    fn legacy_download_metadata_is_not_a_model_input_and_links_still_fail() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config.json"), b"{}").unwrap();
        fs::create_dir(directory.path().join(".cache")).unwrap();
        fs::write(
            directory
                .path()
                .join(".cache")
                .join("untrusted bookkeeping"),
            b"not model data",
        )
        .unwrap();
        assert_eq!(
            model_file_names(directory.path()).unwrap(),
            BTreeSet::from(["config.json".into()])
        );
        fs::create_dir(directory.path().join("unexpected")).unwrap();
        assert!(model_file_names(directory.path()).is_err());
        fs::remove_dir(directory.path().join("unexpected")).unwrap();
        #[cfg(unix)]
        {
            fs::remove_dir_all(directory.path().join(".cache")).unwrap();
            std::os::unix::fs::symlink(directory.path(), directory.path().join(".cache")).unwrap();
            assert!(model_file_names(directory.path()).is_err());
        }
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64", feature = "native-mlx"))]
    #[test]
    fn showui_processor_uses_pinned_preprocessor_without_requiring_an_absent_extra_file() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory.path().join("preprocessor_config.json"),
            br#"{"min_pixels":3136,"max_pixels":16777216,"patch_size":14}"#,
        )
        .unwrap();
        let config = native::processor_config(directory.path()).unwrap();
        assert_eq!(config["patch_size"], 14);
        assert_eq!(config["min_pixels"], 3136);
        fs::write(
            directory.path().join("processor_config.json"),
            br#"{"image_processor":{"max_pixels":1048576}}"#,
        )
        .unwrap();
        let config = native::processor_config(directory.path()).unwrap();
        assert_eq!(config["patch_size"], 14);
        assert_eq!(config["max_pixels"], 1048576);
    }
    #[test]
    fn owl_is_one_exact_native_click_with_normalized_coordinates() {
        let raw = "Action: Click search\n<tool_call>{\"name\":\"computer_use\",\"arguments\":{\"action\":\"left_click\",\"coordinate\":[1000,500]}}</tool_call>";
        assert_eq!(owl_point(raw, 100, 80), Some(Point { x: 99.0, y: 39.5 }));
        assert!(owl_point(&format!("{raw}{raw}"), 100, 80).is_none());
        assert!(owl_point(&raw.replace("1000,500", "true,500"), 100, 80).is_none());
        assert_eq!(
            owl_point(&raw.replace("left_click", "double_click"), 100, 80),
            Some(Point { x: 99.0, y: 39.5 })
        );
        assert!(owl_point(&raw.replace("left_click", "middle_click"), 100, 80).is_none());
    }
    #[test]
    fn native_prompts_restrict_capabilities_before_any_image() {
        let system = owl_system().unwrap();
        assert!(system.contains("Controlled environment capabilities"));
        assert!(!system.contains("* `wait`"));
        assert!(!system.contains("Previous"));
        assert_eq!(
            go_prompt("Click the Search field."),
            "Where is the the Search field element? (Output the center coordinates of the target)"
        );
        assert!(target("abc\u{200b}").is_err());
        assert!(target("Search").is_ok());
    }
    #[test]
    fn verified_reads_reject_links_changes_and_cancelled_hashing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("weight-fixture");
        fs::write(&path, b"immutable weight fixture").unwrap();
        let (hash, identity) = hash_file(&path, &mut || true).unwrap();
        assert_eq!(
            hash,
            hex::encode(Sha256::digest(b"immutable weight fixture"))
        );
        assert_eq!(identity.bytes, 24);
        assert!(matches!(
            hash_file(&path, &mut || false),
            Err(GroundingError::Cancelled)
        ));
        assert!(bounded_file(&path, 4).is_err());
        #[cfg(unix)]
        {
            let link = directory.path().join("untrusted-link");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(bounded_file(&link, 1024).is_err());
        }
        let installation = VerifiedGroundingInstallation {
            root: directory.path().into(),
            manifest: Manifest {
                schema_version: 1,
                models: BTreeMap::new(),
            },
            identities: BTreeMap::from([(path.clone(), identity)]),
        };
        assert!(installation.unchanged().is_ok());
        fs::write(&path, b"different").unwrap();
        assert!(installation.unchanged().is_err());
    }
    #[test]
    fn missing_installation_never_attempts_download() {
        let root = Path::new("/no-such-computa-grounder-fixture/models");
        assert!(matches!(
            VerifiedGroundingInstallation::verify(root, || true),
            Err(GroundingError::Unavailable)
        ));
    }
}
