//! Explicit native grounding provisioning from closed publisher data pins.
//! Source files are data only; Python/custom remote processors are never loaded.
use crate::models::{self, HttpModelDownloader, ModelManifest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

pub const SOURCE_MANIFEST: &[u8] =
    include_bytes!("../../computa-inference/src/grounding_backend/source-manifest.json");
pub const NATIVE_MANIFEST: &[u8] =
    include_bytes!("../../computa-inference/src/grounding_backend/native-model-manifest.json");
pub const NUMERICAL_PARITY: &[u8] =
    include_bytes!("../../computa-inference/src/grounding_backend/native-conversion-parity.json");
const MODEL_IDS: [&str; 3] = ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"];
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SourcePin {
    repo: String,
    revision: String,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeModel {
    source: SourcePin,
    files: BTreeMap<String, String>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeManifest {
    schema_version: u32,
    artifact_format: String,
    converter: String,
    source_manifest_sha256: String,
    numerical_parity_sha256: String,
    models: BTreeMap<String, NativeModel>,
}
#[derive(Serialize)]
#[serde(deny_unknown_fields)]
struct RecordedFile {
    bytes: u64,
    sha256: String,
}
#[derive(Serialize)]
struct RecordedModel {
    source: SourcePin,
    files: BTreeMap<String, RecordedFile>,
}
#[derive(Serialize)]
struct NativeReceipt {
    schema_version: u32,
    model_manifest_sha256: String,
    source_manifest_sha256: String,
    conversion_format: String,
    numerical_parity_sha256: String,
    models: BTreeMap<String, RecordedModel>,
    runtime: serde_json::Value,
}
fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn native_manifest() -> io::Result<NativeManifest> {
    let manifest: NativeManifest = serde_json::from_value(
        computa_contracts::strict_json::parse(NATIVE_MANIFEST).map_err(invalid)?,
    )
    .map_err(invalid)?;
    let sources = source_manifest()?;
    if manifest.schema_version != 1
        || manifest.artifact_format != "computa-native-grounding-v1"
        || manifest.converter != "computa-mlx-affine-v1"
        || manifest.source_manifest_sha256 != digest(SOURCE_MANIFEST)
        || manifest.numerical_parity_sha256 != digest(NUMERICAL_PARITY)
        || manifest
            .models
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>()
            != MODEL_IDS.into_iter().collect()
    {
        return Err(invalid("The compiled native grounding provenance differs"));
    }
    for (name, model) in &manifest.models {
        let source = &sources[name];
        if model.source.repo != source.repo
            || model.source.revision != source.revision
            || ![
                "config.json",
                "tokenizer.json",
                "model.safetensors",
                "model.safetensors.index.json",
            ]
            .into_iter()
            .all(|f| model.files.contains_key(f))
            || model.files.iter().any(|(name, hash)| {
                Path::new(name).file_name().and_then(|n| n.to_str()) != Some(name)
                    || name.contains(['\\', '\0'])
                    || hash.len() != 64
                    || !hash
                        .bytes()
                        .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            })
        {
            return Err(invalid("The compiled native grounding file pins differ"));
        }
    }
    Ok(manifest)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceManifest {
    schema_version: u32,
    models: BTreeMap<String, ModelManifest>,
}
fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}
pub fn source_manifest() -> io::Result<BTreeMap<String, ModelManifest>> {
    let value = computa_contracts::strict_json::parse(SOURCE_MANIFEST).map_err(invalid)?;
    let manifest: SourceManifest = serde_json::from_value(value).map_err(invalid)?;
    if manifest.schema_version != 1
        || manifest
            .models
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>()
            != ["goclick-base-4bit", "gui-owl-2b", "showui-2b-4bit"]
    {
        return Err(invalid("The closed grounding source manifest differs"));
    }
    Ok(manifest.models)
}
/// Existing source directories are verified offline. Only this explicit bool
/// authorizes publisher HTTP downloads; no existing invalid directory is replaced.
pub async fn download_sources(
    root: &Path,
    allow_download: bool,
) -> io::Result<BTreeMap<String, PathBuf>> {
    let downloader = HttpModelDownloader::new()?;
    let mut paths = BTreeMap::new();
    for (id, manifest) in source_manifest()? {
        let path = models::install_with(root, &manifest, allow_download, &downloader).await?;
        paths.insert(id, path);
    }
    Ok(paths)
}
/// Qualification and native installation use the same closed conversion code.
/// The caller selects a fresh staging directory; this does not publish a model.
pub fn convert_source(
    model: &str,
    source: &Path,
    destination: &Path,
) -> io::Result<serde_json::Value> {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        // The shipped installer is also an MLX client. It must use its own
        // immutable colocated library, rather than the developer build path.
        computa_inference::metal_resources::verify_colocated().map_err(invalid)?;
        serde_json::to_value(
            computa_inference::grounding_backend::native_conversion::convert(
                model,
                source,
                destination,
                || true,
            )
            .map_err(invalid)?,
        )
        .map_err(invalid)
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        let _ = (model, source, destination);
        Err(invalid(
            "Native grounding conversion requires Apple Silicon macOS",
        ))
    }
}

/// Verifies legacy schema 3 or closed native schema 4 without downloads,
/// interpreter execution, conversion, or any filesystem mutation.
pub fn verify_installation(root: &Path) -> io::Result<()> {
    models::safe_directory(root, false)?;
    computa_inference::grounding_backend::VerifiedGroundingInstallation::verify(
        &root.join("models"),
        || true,
    )
    .map(|_| ())
    .map_err(invalid)
}

fn artifact_manifest(directory: &Path, pin: &NativeModel) -> io::Result<ModelManifest> {
    models::safe_directory(directory, false)?;
    let actual = fs::read_dir(directory)?
        .map(|e| {
            e?.file_name()
                .into_string()
                .map_err(|_| invalid("Invalid native artifact filename"))
        })
        .collect::<io::Result<BTreeSet<_>>>()?;
    if actual != pin.files.keys().cloned().collect() {
        return Err(invalid(
            "Native artifact file list differs from the compiled pins",
        ));
    }
    let mut files = Vec::new();
    for (name, hash) in &pin.files {
        let m = fs::symlink_metadata(directory.join(name))?;
        if !m.is_file()
            || m.file_type().is_symlink()
            || m.nlink() != 1
            || m.len() > 16 * 1024 * 1024 * 1024
        {
            return Err(invalid(
                "Native artifact is linked, nonregular, or oversized",
            ));
        }
        files.push(models::ModelFile {
            path: name.clone(),
            size: m.len(),
            sha256: Some(hash.clone()),
            git_blob_sha1: None,
        });
    }
    let manifest = ModelManifest {
        schema_version: 1,
        repo: pin.source.repo.clone(),
        revision: pin.source.revision.clone(),
        total_bytes: files.iter().map(|f| f.size).sum(),
        files,
    };
    models::verify_model(directory, &manifest)?;
    Ok(manifest)
}

fn write_new(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    f.write_all(bytes)?;
    f.sync_all()
}

fn copy_artifacts(
    source: &Path,
    destination: &Path,
    pin: &NativeModel,
) -> io::Result<RecordedModel> {
    let manifest = artifact_manifest(source, pin)?;
    fs::create_dir(destination)?;
    fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;
    let mut recorded = BTreeMap::new();
    for file in &manifest.files {
        let mut input = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(source.join(&file.path))?;
        let before = input.metadata()?;
        if !before.is_file() || before.nlink() != 1 || before.len() != file.size {
            return Err(invalid("Native artifact changed before copying"));
        }
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(destination.join(&file.path))?;
        let bytes = io::copy(
            &mut std::io::Read::by_ref(&mut input).take(file.size + 1),
            &mut output,
        )?;
        let after = input.metadata()?;
        if bytes != file.size
            || before.dev() != after.dev()
            || before.ino() != after.ino()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
        {
            return Err(invalid("Native artifact changed while copying"));
        }
        output.sync_all()?;
        recorded.insert(
            file.path.clone(),
            RecordedFile {
                bytes,
                sha256: pin.files[&file.path].clone(),
            },
        );
    }
    // The published bytes, rather than an earlier source-path check, must match.
    models::verify_model(destination, &manifest)?;
    fs::File::open(destination)?.sync_all()?;
    Ok(RecordedModel {
        source: pin.source.clone(),
        files: recorded,
    })
}

fn publish_exclusive(source: &Path, destination: &Path) -> io::Result<()> {
    computa_macos::rename_directory_exclusive(source, destination)
}

fn publish_native(
    root: &Path,
    artifacts: &BTreeMap<String, PathBuf>,
    manifest: &NativeManifest,
) -> io::Result<PathBuf> {
    if root.symlink_metadata().is_ok() {
        return Err(invalid(
            "An existing grounding installation was left untouched",
        ));
    }
    let parent = root
        .parent()
        .ok_or_else(|| invalid("Expected an absolute grounding installation root"))?;
    models::safe_directory(parent, false)?;
    if !root.is_absolute()
        || artifacts.keys().collect::<BTreeSet<_>>() != manifest.models.keys().collect()
    {
        return Err(invalid(
            "Expected exactly the three closed native model artifacts",
        ));
    }
    let staging = tempfile::Builder::new()
        .prefix(".computa-grounding-")
        .tempdir_in(parent)?;
    fs::set_permissions(staging.path(), fs::Permissions::from_mode(0o700))?;
    let models_root = staging.path().join("models");
    fs::create_dir(&models_root)?;
    fs::set_permissions(&models_root, fs::Permissions::from_mode(0o700))?;
    let mut records = BTreeMap::new();
    for (name, pin) in &manifest.models {
        records.insert(
            name.clone(),
            copy_artifacts(&artifacts[name], &models_root.join(name), pin)?,
        );
    }
    let receipt = NativeReceipt {
        schema_version: 4,
        model_manifest_sha256: digest(NATIVE_MANIFEST),
        source_manifest_sha256: manifest.source_manifest_sha256.clone(),
        conversion_format: manifest.converter.clone(),
        numerical_parity_sha256: manifest.numerical_parity_sha256.clone(),
        models: records,
        runtime: serde_json::json!({"backend":"computa-rust-mlx","format":manifest.artifact_format}),
    };
    let mut bytes = serde_json::to_vec_pretty(&receipt).map_err(invalid)?;
    bytes.push(b'\n');
    write_new(&staging.path().join("installation.json"), &bytes)?;
    fs::File::open(&models_root)?.sync_all()?;
    fs::File::open(staging.path())?.sync_all()?;
    publish_exclusive(staging.path(), root)?;
    fs::File::open(parent)?.sync_all()?;
    Ok(root.join("models"))
}

/// Imports only byte-identical, compiled native artifact pins into a fresh
/// installation. An existing legacy or native installation is verified offline
/// and returned without conversion or replacement.
pub fn import_native(root: &Path, artifacts: &BTreeMap<String, PathBuf>) -> io::Result<PathBuf> {
    if root.symlink_metadata().is_ok() {
        verify_installation(root)?;
        return Ok(root.join("models"));
    }
    publish_native(root, artifacts, &native_manifest()?)
}

/// Fresh provisioning downloads only when explicitly authorized. Exact raw
/// sources may also be supplied offline. Conversion and publication run wholly
/// in Rust; legacy installations remain verified and untouched.
pub async fn install_native(
    root: &Path,
    source_root: &Path,
    allow_download: bool,
) -> io::Result<PathBuf> {
    if root.symlink_metadata().is_ok() {
        verify_installation(root)?;
        return Ok(root.join("models"));
    }
    let manifest = native_manifest()?;
    let parent = root
        .parent()
        .ok_or_else(|| invalid("Expected an absolute grounding installation root"))?;
    if !root.is_absolute() {
        return Err(invalid("Expected an absolute grounding installation root"));
    }
    models::safe_directory(parent, false)?;
    let sources = download_sources(source_root, allow_download).await?;
    let staging = tempfile::Builder::new()
        .prefix(".computa-grounding-conversion-")
        .tempdir_in(parent)?;
    let mut artifacts = BTreeMap::new();
    for name in MODEL_IDS {
        if name == "showui-2b-4bit" {
            artifacts.insert(name.into(), sources[name].clone());
        } else {
            let destination = staging.path().join(name);
            convert_source(name, &sources[name], &destination)?;
            artifacts.insert(name.into(), destination);
        }
    }
    publish_native(root, &artifacts, &manifest)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_outputs_bind_exact_sources_math_proof_and_florence_metadata() {
        let m = native_manifest().unwrap();
        let old: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../computa-inference/src/grounding_backend/model-manifest.json"
        ))
        .unwrap();
        assert_eq!(
            serde_json::to_value(&m.models["showui-2b-4bit"].files).unwrap(),
            old["models"]["showui-2b-4bit"]["files"]
        );
        assert_ne!(
            m.models["goclick-base-4bit"].files["tokenizer.json"],
            old["models"]["goclick-base-4bit"]["files"]["tokenizer.json"]
                .as_str()
                .unwrap()
        );
        let proof: serde_json::Value = serde_json::from_slice(NUMERICAL_PARITY).unwrap();
        assert_eq!(proof["florence_tokenizer"]["records"], 1030);
        for name in ["goclick-base-4bit", "gui-owl-2b"] {
            assert_eq!(proof["models"][name]["mismatches"], serde_json::json!([]));
            assert_eq!(proof["models"][name]["extra_names"], serde_json::json!([]));
            assert_eq!(
                proof["models"][name]["reference_tensors"],
                proof["models"][name]["native_tensors"]
            );
            assert!(m.models[name].files.keys().all(|n| !n.ends_with(".py")));
        }
    }
    fn fixture(temp: &Path) -> (NativeManifest, BTreeMap<String, PathBuf>) {
        let mut m = native_manifest().unwrap();
        let mut artifacts = BTreeMap::new();
        for name in MODEL_IDS {
            let source = temp.join(name);
            fs::create_dir(&source).unwrap();
            fs::write(source.join("tensor.bin"), name.as_bytes()).unwrap();
            m.models.get_mut(name).unwrap().files =
                BTreeMap::from([("tensor.bin".into(), digest(name.as_bytes()))]);
            artifacts.insert(name.into(), source);
        }
        (m, artifacts)
    }
    #[test]
    fn published_native_receipt_follows_verified_copies_and_preserves_sources() {
        let t = tempfile::tempdir().unwrap();
        let directory = fs::canonicalize(t.path()).unwrap();
        let (m, sources) = fixture(&directory);
        let root = directory.join("installation");
        assert_eq!(
            publish_native(&root, &sources, &m).unwrap(),
            root.join("models")
        );
        let receipt: serde_json::Value =
            serde_json::from_slice(&fs::read(root.join("installation.json")).unwrap()).unwrap();
        assert_eq!(receipt["schema_version"], 4);
        assert_eq!(receipt["model_manifest_sha256"], digest(NATIVE_MANIFEST));
        assert_eq!(
            receipt["runtime"],
            serde_json::json!({"backend":"computa-rust-mlx","format":"computa-native-grounding-v1"})
        );
        for name in MODEL_IDS {
            let output = root.join("models").join(name).join("tensor.bin");
            assert_ne!(
                fs::metadata(&output).unwrap().ino(),
                fs::metadata(sources[name].join("tensor.bin"))
                    .unwrap()
                    .ino()
            );
            fs::write(sources[name].join("tensor.bin"), b"changed source").unwrap();
            assert_eq!(fs::read(&output).unwrap(), name.as_bytes());
            assert_eq!(
                receipt["models"][name]["files"]["tensor.bin"]["sha256"],
                digest(name.as_bytes())
            );
        }
    }
    #[test]
    fn tampered_artifacts_and_existing_destination_never_publish_or_replace() {
        let t = tempfile::tempdir().unwrap();
        let directory = fs::canonicalize(t.path()).unwrap();
        let (m, sources) = fixture(&directory);
        let root = directory.join("installation");
        fs::write(sources["gui-owl-2b"].join("tensor.bin"), b"tampered").unwrap();
        assert!(publish_native(&root, &sources, &m).is_err());
        assert!(!root.exists());
        assert!(fs::read_dir(t.path()).unwrap().all(|e| {
            !e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".computa-")
        }));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("existing"), b"retained").unwrap();
        assert!(publish_native(&root, &sources, &m).is_err());
        assert_eq!(fs::read(root.join("existing")).unwrap(), b"retained");
    }
    #[test]
    fn publisher_inputs_are_closed_data_only_revisions_and_weights() {
        let models = source_manifest().unwrap();
        assert_eq!(
            models["goclick-base-4bit"].revision,
            "05633a495f9d2ce823372d0c7fd9b0b4bb67c6fa"
        );
        assert_eq!(
            models["gui-owl-2b"].revision,
            "528ceaec795bbfbe6103bd79e03db849feadfb24"
        );
        assert_eq!(
            models["showui-2b-4bit"].revision,
            "c80dc363dfd4e802ef21fe7fd50a0fab8694c59e"
        );
        for manifest in models.values() {
            assert_eq!(
                manifest.files.iter().map(|f| f.size).sum::<u64>(),
                manifest.total_bytes
            );
            assert!(manifest.files.iter().all(|f| !f.path.ends_with(".py")
                && !f.path.ends_with(".bin")
                && !f.path.ends_with(".pt")));
            assert_eq!(
                manifest
                    .files
                    .iter()
                    .filter(|f| f.path.ends_with(".safetensors"))
                    .count(),
                1
            );
        }
    }
    #[tokio::test]
    async fn absent_sources_without_download_permission_do_not_create_root() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("absent");
        assert!(download_sources(&root, false).await.is_err());
        assert!(!root.exists());
    }
}
