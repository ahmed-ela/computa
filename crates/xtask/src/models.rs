//! Explicit, pinned model provisioning. No runtime environment or conversations
//! are read, and an existing model is verified offline without replacement.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

pub const REVIEWED_LOCK: &[u8] = include_bytes!("../../../Scripts/mlx-model.lock.json");
pub const REVIEWED_9B_LOCK: &[u8] = include_bytes!("../../../Scripts/mlx-model-9b.lock.json");
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReviewedModel {
    FourB,
    NineB,
}
impl ReviewedModel {
    pub fn parse(value: &str) -> io::Result<Self> {
        match value {
            "4b" => Ok(Self::FourB),
            "9b" => Ok(Self::NineB),
            _ => Err(invalid("Expected exactly reviewed model 4b or 9b")),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelFile {
    pub path: String,
    pub size: u64,
    pub sha256: Option<String>,
    #[serde(rename = "gitBlobSHA1")]
    pub git_blob_sha1: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelManifest {
    pub schema_version: u32,
    pub repo: String,
    pub revision: String,
    pub total_bytes: u64,
    pub files: Vec<ModelFile>,
}
fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}
fn parse(bytes: &[u8]) -> io::Result<ModelManifest> {
    let value = computa_contracts::strict_json::parse(bytes).map_err(invalid)?;
    let manifest: ModelManifest = serde_json::from_value(value).map_err(invalid)?;
    let mut names = std::collections::HashSet::new();
    let hex = |s: &str, n| {
        s.len() == n
            && s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    };
    if manifest.schema_version != 1
        || !matches!(
            manifest.repo.as_str(),
            "lmstudio-community/Qwen3.5-4B-MLX-4bit" | "lmstudio-community/Qwen3.5-9B-MLX-4bit"
        )
        || !hex(&manifest.revision, 40)
        || manifest.files.is_empty()
    {
        return Err(invalid("Invalid reviewed model pin"));
    }
    let mut total = 0u64;
    for file in &manifest.files {
        if file.path.is_empty()
            || matches!(file.path.as_str(), "." | "..")
            || Path::new(&file.path).file_name().and_then(|s| s.to_str()) != Some(&file.path)
            || file.path.contains(['\\', '\0'])
            || !names.insert(file.path.clone())
        {
            return Err(invalid("Invalid model file path"));
        }
        match (&file.sha256, &file.git_blob_sha1) {
            (Some(hash), None) if hex(hash, 64) => {}
            (None, Some(hash)) if hex(hash, 40) => {}
            _ => return Err(invalid("Invalid pinned file digest")),
        }
        total = total
            .checked_add(file.size)
            .ok_or_else(|| invalid("Model size overflow"))?;
    }
    if total != manifest.total_bytes
        || !["config.json", "tokenizer.json"]
            .iter()
            .all(|s| names.contains(*s))
        || !names.iter().any(|name| name.ends_with(".safetensors"))
    {
        return Err(invalid("Incomplete model pin"));
    }
    Ok(manifest)
}
pub fn reviewed_manifest() -> io::Result<ModelManifest> {
    reviewed_manifest_for(ReviewedModel::FourB)
}
pub fn reviewed_manifest_for(model: ReviewedModel) -> io::Result<ModelManifest> {
    parse(match model {
        ReviewedModel::FourB => REVIEWED_LOCK,
        ReviewedModel::NineB => REVIEWED_9B_LOCK,
    })
}
pub fn load_manifest(path: &Path) -> io::Result<ModelManifest> {
    let bytes = read_regular(path, 64 * 1024)?;
    let manifest = parse(&bytes)?;
    let selected = match manifest.repo.as_str() {
        "lmstudio-community/Qwen3.5-4B-MLX-4bit" => ReviewedModel::FourB,
        "lmstudio-community/Qwen3.5-9B-MLX-4bit" => ReviewedModel::NineB,
        _ => return Err(invalid("Unreviewed model repository")),
    };
    if manifest != reviewed_manifest_for(selected)? {
        return Err(invalid(
            "Model lock differs from the reviewed repository, revision or hashes",
        ));
    }
    Ok(manifest)
}
pub fn safe_directory(path: &Path, create: bool) -> io::Result<()> {
    if !path.is_absolute()
        || path == Path::new("/")
        || path
            .components()
            .any(|p| matches!(p, std::path::Component::ParentDir))
    {
        return Err(invalid("Expected an absolute safe directory"));
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
            Ok(_) => return Err(invalid("Directory or ancestor is nonregular or symlinked")),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    if create && !path.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
    } else if !path.is_dir() {
        return Err(invalid("Directory is missing"));
    }
    Ok(())
}
pub fn read_regular(path: &Path, max: u64) -> io::Result<Vec<u8>> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > max || metadata.nlink() != 1 {
        return Err(invalid(
            "File is nonregular, linked or exceeds its byte limit",
        ));
    }
    let mut bytes = Vec::new();
    file.take(max + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > max {
        return Err(invalid("File exceeds its byte limit"));
    }
    Ok(bytes)
}
fn verify_file(path: &Path, pin: &ModelFile) -> io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let before = file.metadata()?;
    if !before.is_file() || before.len() != pin.size || before.nlink() != 1 {
        return Err(invalid(
            "Pinned model file is missing, nonregular or changed size",
        ));
    }
    let mut sha256 = Sha256::new();
    let mut sha1 = sha1::Sha1::new();
    sha1.update(format!("blob {}\0", pin.size).as_bytes());
    let mut buffer = [0u8; 1024 * 1024];
    let mut total = 0u64;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        total = total
            .checked_add(count as u64)
            .ok_or_else(|| invalid("File size overflow"))?;
        if total > pin.size {
            return Err(invalid("Model file grew during verification"));
        }
        if pin.sha256.is_some() {
            sha256.update(&buffer[..count]);
        } else {
            sha1.update(&buffer[..count]);
        }
    }
    let after = file.metadata()?;
    if total != pin.size
        || before.dev() != after.dev()
        || before.ino() != after.ino()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return Err(invalid("Model file changed during verification"));
    }
    let actual = if pin.sha256.is_some() {
        hex::encode(sha256.finalize())
    } else {
        hex::encode(sha1.finalize())
    };
    if Some(&actual) != pin.sha256.as_ref().or(pin.git_blob_sha1.as_ref()) {
        return Err(invalid(
            "Pinned model digest mismatch; existing files were left untouched",
        ));
    }
    Ok(())
}
pub fn verify_model(directory: &Path, manifest: &ModelManifest) -> io::Result<()> {
    safe_directory(directory, false)?;
    let names: std::collections::HashSet<_> =
        manifest.files.iter().map(|f| f.path.as_str()).collect();
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name
            .to_str()
            .ok_or_else(|| invalid("Invalid model filename"))?;
        if !names.contains(name) && name != ".cache" {
            return Err(invalid(
                "Model directory contains unreviewed files; it was left untouched",
            ));
        }
    }
    for file in &manifest.files {
        verify_file(&directory.join(&file.path), file)?;
    }
    Ok(())
}
#[allow(async_fn_in_trait)]
pub trait ModelDownloader {
    async fn download(
        &self,
        manifest: &ModelManifest,
        file: &ModelFile,
        destination: &Path,
    ) -> io::Result<()>;
}
pub struct HttpModelDownloader {
    client: reqwest::Client,
    #[cfg(test)]
    endpoint: Option<String>,
}
impl HttpModelDownloader {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            #[cfg(test)]
            endpoint: None,
            client: reqwest::Client::builder()
                .no_proxy()
                .https_only(true)
                .redirect(reqwest::redirect::Policy::limited(5))
                .connect_timeout(std::time::Duration::from_secs(20))
                .timeout(std::time::Duration::from_secs(60 * 60))
                .build()
                .map_err(invalid)?,
        })
    }
}
impl ModelDownloader for HttpModelDownloader {
    async fn download(
        &self,
        manifest: &ModelManifest,
        pin: &ModelFile,
        destination: &Path,
    ) -> io::Result<()> {
        let url = format!(
            "https://huggingface.co/{}/resolve/{}/{}?download=true",
            manifest.repo, manifest.revision, pin.path
        );
        #[cfg(test)]
        let url = self.endpoint.clone().unwrap_or(url);
        let existing = match fs::symlink_metadata(destination) {
            Ok(metadata)
                if metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.nlink() == 1
                    && metadata.len() <= pin.size =>
            {
                metadata.len()
            }
            Ok(_) => return Err(invalid("Download cache file is nonregular or oversized")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error),
        };
        if existing == pin.size {
            return verify_file(destination, pin);
        }
        let mut request = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT_ENCODING, "identity");
        if existing > 0 {
            request = request.header(reqwest::header::RANGE, format!("bytes={existing}-"));
        }
        let mut response = request
            .send()
            .await
            .map_err(|_| invalid("Pinned model download failed"))?
            .error_for_status()
            .map_err(|_| invalid("Pinned model server rejected download"))?;
        let resume = existing > 0 && response.status() == reqwest::StatusCode::PARTIAL_CONTENT;
        if resume {
            let content_range = response
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok());
            if content_range
                != Some(format!("bytes {existing}-{}/{}", pin.size - 1, pin.size).as_str())
            {
                return Err(invalid("Pinned model resume range mismatch"));
            }
        } else if response.status() != reqwest::StatusCode::OK {
            return Err(invalid(
                "Pinned model download returned an unexpected HTTP status",
            ));
        }
        let expected = if resume {
            pin.size - existing
        } else {
            pin.size
        };
        if response.content_length().is_some_and(|n| n != expected) {
            return Err(invalid("Pinned model response size mismatch"));
        }
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .append(resume)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(destination)?;
        if !output.metadata()?.is_file() || output.metadata()?.nlink() != 1 {
            return Err(invalid("Download cache changed during opening"));
        }
        if !resume {
            output.set_len(0)?;
        }
        let mut size = if resume { existing } else { 0 };
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| invalid("Pinned model download was interrupted"))?
        {
            size = size
                .checked_add(chunk.len() as u64)
                .ok_or_else(|| invalid("Download overflow"))?;
            if size > pin.size {
                return Err(invalid("Pinned model download exceeded expected size"));
            }
            output.write_all(&chunk)?;
        }
        output.sync_all()?;
        if size != pin.size {
            return Err(invalid("Pinned model download has incomplete size"));
        }
        Ok(())
    }
}
/// Authorization is explicit; existing installations always take the offline
/// verification path. Retained verified cache files can be reused after a retry.
pub async fn install_model(model_root: &Path, allow_download: bool) -> io::Result<PathBuf> {
    install_reviewed_model(model_root, ReviewedModel::FourB, allow_download).await
}
pub async fn install_reviewed_model(
    model_root: &Path,
    model: ReviewedModel,
    allow_download: bool,
) -> io::Result<PathBuf> {
    let manifest = reviewed_manifest_for(model)?;
    install_with(
        model_root,
        &manifest,
        allow_download,
        &HttpModelDownloader::new()?,
    )
    .await
}
pub(crate) async fn install_with<D: ModelDownloader>(
    root: &Path,
    manifest: &ModelManifest,
    allow_download: bool,
    downloader: &D,
) -> io::Result<PathBuf> {
    let destination = root.join(&manifest.repo);
    if fs::symlink_metadata(&destination).is_ok() {
        verify_model(&destination, manifest)?;
        return Ok(destination);
    }
    if !allow_download {
        return Err(invalid(
            "The pinned model is not installed; --download-model is required to authorize weights download",
        ));
    }
    safe_directory(root, true)?;
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("Missing model namespace"))?;
    safe_directory(parent, true)?;
    if fs2::available_space(parent)?
        < manifest
            .total_bytes
            .checked_mul(2)
            .and_then(|v| v.checked_add(512 * 1024 * 1024))
            .ok_or_else(|| invalid("Model size overflow"))?
    {
        return Err(invalid(
            "Insufficient disk space for pinned model and reusable download cache",
        ));
    }
    let cache = root
        .join(".computa-download-cache")
        .join(&manifest.revision);
    safe_directory(&cache, true)?;
    let stage = tempfile::Builder::new()
        .prefix(".qwen-install-")
        .tempdir_in(parent)?;
    let staged = stage.path().join("model");
    fs::DirBuilder::new().mode(0o700).create(&staged)?;
    for pin in &manifest.files {
        let cached = cache.join(&pin.path);
        if fs::symlink_metadata(&cached).is_ok() {
            verify_file(&cached, pin)?;
        } else {
            let partial = cache.join(format!(".{}.partial", pin.path));
            downloader.download(manifest, pin, &partial).await?;
            verify_file(&partial, pin)?;
            if fs::symlink_metadata(&cached).is_ok() {
                verify_file(&cached, pin)?;
            } else {
                fs::rename(&partial, &cached)?;
            }
        }
        fs::copy(&cached, staged.join(&pin.path))?;
    }
    verify_model(&staged, manifest)?;
    if fs::symlink_metadata(&destination).is_ok() {
        return Err(invalid(
            "Model destination changed during download; no replacement attempted",
        ));
    }
    fs::rename(staged, &destination)?;
    fs::File::open(parent)?.sync_all()?;
    Ok(destination)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn model_selection_keeps_both_closed_reviewed_pins_and_accepts_9b_shards() {
        let nine = reviewed_manifest_for(ReviewedModel::NineB).unwrap();
        assert_eq!(nine.revision, "b455506b0f574c74616dbcd56879bde38fafcff3");
        assert_eq!(nine.total_bytes, 5977082681);
        assert_eq!(
            nine.files
                .iter()
                .filter(|f| f.path.ends_with(".safetensors"))
                .count(),
            2
        );
        let four = reviewed_manifest().unwrap();
        assert_ne!(four.repo, nine.repo);
        assert!(ReviewedModel::parse("27b").is_err());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("9b.json");
        fs::write(&path, REVIEWED_9B_LOCK).unwrap();
        assert_eq!(load_manifest(&path).unwrap(), nine);
        let mut changed = nine.clone();
        changed.files[0].size += 1;
        changed.total_bytes += 1;
        fs::write(&path, serde_json::to_vec(&changed).unwrap()).unwrap();
        assert!(load_manifest(&path).is_err());
    }
    fn fixture() -> ModelManifest {
        let contents = b"verified";
        ModelManifest {
            schema_version: 1,
            repo: "lmstudio-community/Qwen3.5-4B-MLX-4bit".into(),
            revision: "c43ee1d65576a5d98de1e8405cac93c371a655c1".into(),
            total_bytes: 24,
            files: ["config.json", "model.safetensors", "tokenizer.json"]
                .into_iter()
                .map(|name| ModelFile {
                    path: name.into(),
                    size: 8,
                    sha256: Some(hex::encode(Sha256::digest(contents))),
                    git_blob_sha1: None,
                })
                .collect(),
        }
    }
    struct Fake(std::sync::atomic::AtomicUsize);
    impl ModelDownloader for Fake {
        async fn download(&self, _: &ModelManifest, _: &ModelFile, path: &Path) -> io::Result<()> {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            fs::write(path, b"verified")
        }
    }
    #[test]
    fn pin_cannot_change_revision_or_hashes() {
        let pin = reviewed_manifest().unwrap();
        assert_eq!(pin.total_bytes, 3061140963);
        let temp = tempfile::NamedTempFile::new().unwrap();
        let mut changed = pin;
        changed.files[0].size += 1;
        fs::write(temp.path(), serde_json::to_vec(&changed).unwrap()).unwrap();
        assert!(load_manifest(temp.path()).is_err());
    }
    #[tokio::test]
    async fn downloads_are_opt_in_and_existing_installation_is_verified_offline() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("models");
        let pin = fixture();
        let downloader = Fake(std::sync::atomic::AtomicUsize::new(0));
        assert!(install_with(&root, &pin, false, &downloader).await.is_err());
        assert!(!root.exists());
        let destination = install_with(&root, &pin, true, &downloader).await.unwrap();
        assert_eq!(downloader.0.load(std::sync::atomic::Ordering::SeqCst), 3);
        install_with(&root, &pin, false, &downloader).await.unwrap();
        assert_eq!(downloader.0.load(std::sync::atomic::Ordering::SeqCst), 3);
        fs::write(destination.join("config.json"), b"corrupt!").unwrap();
        assert!(install_with(&root, &pin, true, &downloader).await.is_err());
        assert_eq!(
            fs::read(destination.join("config.json")).unwrap(),
            b"corrupt!"
        );
    }
    #[tokio::test]
    async fn symlink_models_never_publish_or_overwrite_targets() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("models");
        let namespace = root.join("lmstudio-community");
        fs::create_dir_all(&namespace).unwrap();
        let outside = temp.path().join("outside");
        fs::create_dir(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, namespace.join("Qwen3.5-4B-MLX-4bit")).unwrap();
        assert!(
            install_with(
                &root,
                &fixture(),
                true,
                &Fake(std::sync::atomic::AtomicUsize::new(0))
            )
            .await
            .is_err()
        );
        assert_eq!(fs::read_dir(outside).unwrap().count(), 0);
    }
    #[test]
    fn git_blob_hash_includes_header_and_is_distinct_from_plain_sha1() {
        let temp = tempfile::NamedTempFile::new().unwrap();
        fs::write(temp.path(), b"verified").unwrap();
        let mut hash = sha1::Sha1::new();
        hash.update(b"blob 8\0verified");
        let mut pin = ModelFile {
            path: "config.json".into(),
            size: 8,
            sha256: None,
            git_blob_sha1: Some(hex::encode(hash.finalize())),
        };
        verify_file(temp.path(), &pin).unwrap();
        pin.git_blob_sha1 = Some(hex::encode(sha1::Sha1::digest(b"verified")));
        assert!(verify_file(temp.path(), &pin).is_err());
    }
    #[tokio::test]
    async fn interrupted_download_resumes_only_an_exact_content_range() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut data = vec![0; 4096];
            let count = socket.read(&mut data).await.unwrap();
            let request = String::from_utf8_lossy(&data[..count]).to_ascii_lowercase();
            assert!(request.contains("range: bytes=3-"));
            socket.write_all(b"HTTP/1.1 206 Partial Content\r\nContent-Length: 5\r\nContent-Range: bytes 3-7/8\r\nConnection: close\r\n\r\nified").await.unwrap();
        });
        let temp = tempfile::NamedTempFile::new().unwrap();
        fs::write(temp.path(), b"ver").unwrap();
        let downloader = HttpModelDownloader {
            client: reqwest::Client::builder().no_proxy().build().unwrap(),
            endpoint: Some(format!("http://{address}/model")),
        };
        let manifest = fixture();
        downloader
            .download(&manifest, &manifest.files[0], temp.path())
            .await
            .unwrap();
        verify_file(temp.path(), &manifest.files[0]).unwrap();
        assert_eq!(fs::read(temp.path()).unwrap(), b"verified");
        server.await.unwrap();
    }
}
