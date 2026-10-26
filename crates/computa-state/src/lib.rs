//! First-party durable state. The pinned upstream App Server continues to own
//! state_5.sqlite and rollouts; this crate never creates a replacement chat DB.
pub mod account;
pub mod evidence;
pub mod preferences;
use std::os::unix::fs::DirBuilderExt;
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct PrivateHome {
    pub codex_home: PathBuf,
    pub process_home: PathBuf,
    pub workspace: PathBuf,
    pub evidence: PathBuf,
}
impl PrivateHome {
    /// `user_home` is supplied by the native OS account API, never inherited HOME.
    pub fn existing_or_create(user_home: &Path) -> io::Result<Self> {
        let codex_home = user_home.join("Library/Application Support/LocalCodex/CodexHome");
        Self::at(codex_home)
    }
    pub fn at(codex_home: PathBuf) -> io::Result<Self> {
        let home = Self {
            process_home: codex_home.join("ProcessHome"),
            workspace: codex_home.join("Workspace"),
            evidence: codex_home.join("heydash-native-failures"),
            codex_home,
        };
        for path in [
            &home.codex_home,
            &home.process_home,
            &home.workspace,
            &home.evidence,
        ] {
            match fs::symlink_metadata(path) {
                Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "private state path is not a directory",
                    ));
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    let mut b = fs::DirBuilder::new();
                    b.recursive(true).mode(0o700).create(path)?;
                }
                Err(e) => return Err(e),
            }
        }
        Ok(home)
    }
    pub fn upstream_database(&self) -> PathBuf {
        self.codex_home.join("state_5.sqlite")
    }
}
