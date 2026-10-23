//! The dedicated signed-bundle runtime only; no PATH or installed Codex fallback.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
};
pub const SOURCE_COMMIT: &str = "4607249e430dac1c961df4dc615beae88e33cec8";
pub const PATCH_SHA256: &str = "6378734f6ff07431b239751f6d5c26909122685faf45c1799296153ffaafe11a";
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
}
#[derive(Clone, Debug)]
pub struct RuntimeArtifact {
    pub executable: PathBuf,
    pub manifest: Manifest,
}
#[derive(Debug, thiserror::Error)]
pub enum ArtifactError {
    #[error("Computa's dedicated Agent Runtime is missing or unreadable: {0}")]
    Io(#[from] io::Error),
    #[error("Computa's dedicated Agent Runtime manifest is invalid.")]
    Manifest,
    #[error("Computa's dedicated Agent Runtime rejected an unsafe file.")]
    UnsafeFile,
    #[error("Computa's dedicated Agent Runtime changed while being verified.")]
    Changed,
    #[error("Computa's dedicated Agent Runtime checksum does not match its manifest.")]
    Checksum,
    #[error("Computa's dedicated Agent Runtime requires a thin macOS arm64 executable.")]
    Architecture,
}
impl RuntimeArtifact {
    pub fn resolve(resources: &Path) -> Result<Self, ArtifactError> {
        let dir = resources.join("AgentRuntime");
        let md = fs::symlink_metadata(&dir)?;
        if !md.is_dir() || md.file_type().is_symlink() {
            return Err(ArtifactError::UnsafeFile);
        }
        let (mut file, before) = open_regular(&dir.join("manifest.json"), false)?;
        if before.len() == 0 || before.len() > 16 * 1024 {
            return Err(ArtifactError::Manifest);
        }
        let mut bytes = Vec::new();
        file.by_ref().take(16 * 1024 + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 != before.len() || !same(&before, &file.metadata()?) {
            return Err(ArtifactError::Changed);
        }
        let manifest: Manifest =
            serde_json::from_slice(&bytes).map_err(|_| ArtifactError::Manifest)?;
        manifest.validate()?;
        let path = dir.join("codex-app-server");
        let (mut binary, metadata) = open_regular(&path, true)?;
        if metadata.len() != manifest.binary_size {
            return Err(ArtifactError::Changed);
        }
        let mut hash = Sha256::new();
        let mut header = Vec::new();
        let mut total = 0u64;
        let mut buffer = vec![0u8; 1024 * 1024];
        loop {
            let n = binary.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > manifest.binary_size {
                return Err(ArtifactError::Changed);
            }
            hash.update(&buffer[..n]);
            if header.len() < 32 {
                header.extend_from_slice(&buffer[..n.min(32 - header.len())]);
            }
        }
        if !same(&metadata, &binary.metadata()?) || total != manifest.binary_size {
            return Err(ArtifactError::Changed);
        }
        if !arm64_macho(&header, total) {
            return Err(ArtifactError::Architecture);
        }
        if hex::encode(hash.finalize()) != manifest.binary_sha256 {
            return Err(ArtifactError::Checksum);
        }
        Ok(Self {
            executable: path,
            manifest,
        })
    }
}
impl Manifest {
    fn validate(&self) -> Result<(), ArtifactError> {
        let valid_version = !self.runtime_version.is_empty()
            && self.runtime_version.len() <= 64
            && self
                .runtime_version
                .bytes()
                .enumerate()
                .all(|(i, b)| b.is_ascii_alphanumeric() || (i > 0 && b"._+-".contains(&b)));
        let caps = match (self.schema_version, &self.capabilities) {
            (1, None) => true,
            (2, Some(c)) => {
                let mut names = std::collections::HashSet::new();
                c.iter()
                    .all(|s| s == "threadDynamicToolsV1" && names.insert(s))
            }
            _ => false,
        };
        if !valid_version
            || !caps
            || self.source_commit != SOURCE_COMMIT
            || self.patch_sha256 != PATCH_SHA256
            || !digest(&self.binary_sha256)
            || !(32..=512 * 1024 * 1024).contains(&self.binary_size)
            || self.platform != "macos"
            || self.architecture != "arm64"
            || self.executable != "codex-app-server"
        {
            return Err(ArtifactError::Manifest);
        }
        Ok(())
    }
}
fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && s.bytes().any(|b| b != b'0')
}
fn open_regular(path: &Path, executable: bool) -> Result<(File, fs::Metadata), ArtifactError> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let m = f.metadata()?;
    if !m.is_file() || executable && m.mode() & 0o111 == 0 {
        return Err(ArtifactError::UnsafeFile);
    }
    Ok((f, m))
}
fn same(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.len() == b.len()
        && a.mode() == b.mode()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
fn arm64_macho(h: &[u8], size: u64) -> bool {
    if h.len() < 32 {
        return false;
    }
    let u = |i| u32::from_le_bytes(h[i..i + 4].try_into().unwrap());
    u(0) == 0xfeedfacf && u(4) == 0x0100000c && u(12) == 2 && u(16) > 0 && u(20) as u64 <= size - 32
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn runtime_identity_matches_reviewed_source_lock_and_patch_bytes() {
        let lock: serde_json::Value =
            serde_json::from_str(include_str!("../../../Runtime/codex-source.lock.json")).unwrap();
        assert_eq!(lock["sourceCommit"], SOURCE_COMMIT);
        assert_eq!(lock["patchSHA256"], PATCH_SHA256);
        assert_eq!(
            hex::encode(Sha256::digest(include_bytes!(
                "../../../Runtime/patches/compaction-retention.patch"
            ))),
            PATCH_SHA256
        );
    }

    #[test]
    fn manifest_enforces_exact_upstream_patch() {
        let mut m: Manifest = serde_json::from_str(include_str!(
            "../../../Sources/Computa/Resources/AgentRuntime/manifest.json"
        ))
        .unwrap();
        assert!(m.validate().is_ok());
        m.patch_sha256 = "1".repeat(64);
        assert!(m.validate().is_err());
    }
}
