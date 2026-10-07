//! Exact installed-product native-host registration. Planning is read only.
//! No Chrome API, caller-selected executable, PATH lookup or extension activation.
use crate::identity;
use computa_contracts::chrome::{APP_IDENTIFIER, EXTENSION_ID, HOST_IDENTIFIER, HOST_NAME};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};

const MAX_MANIFEST: u64 = 64 * 1024;
const MAX_HOST: u64 = 64 * 1024 * 1024;
#[derive(Debug, thiserror::Error)]
pub enum RegistrationError {
    #[error("Chrome host registration is skipped outside the installed Computa app.")]
    NotInstalled,
    #[error(
        "Chrome host registration requires the signed installed Computa app and bundled helper."
    )]
    Signing,
    #[error(
        "The existing Chrome host registration belongs to another or unverifiable helper; it was not replaced."
    )]
    ForeignRegistration,
    #[error("Chrome host registration changed during verification; no replacement was published.")]
    Changed,
    #[error("Chrome host registration paths or permissions could not be verified.")]
    UnsafePath,
    #[error("Chrome host registration could not be saved; inspect the retained private backup.")]
    SaveFailed,
}
type Result<T> = std::result::Result<T, RegistrationError>;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Manifest {
    name: String,
    description: String,
    path: PathBuf,
    #[serde(rename = "type")]
    kind: String,
    allowed_origins: Vec<String>,
}
impl Manifest {
    fn ours(&self) -> bool {
        self.name == HOST_NAME
            && self.kind == "stdio"
            && self.allowed_origins == [format!("chrome-extension://{EXTENSION_ID}/")]
            && self.path.is_absolute()
            && self.description.len() <= 1024
            && !self.description.contains('\0')
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Receipt {
    dev: u64,
    ino: u64,
    uid: u32,
    mode: u32,
    length: u64,
    modified: i64,
    nanoseconds: i64,
}
impl Receipt {
    fn of(m: &std::fs::Metadata) -> Self {
        Self {
            dev: m.dev(),
            ino: m.ino(),
            uid: m.uid(),
            mode: m.mode(),
            length: m.len(),
            modified: m.mtime(),
            nanoseconds: m.mtime_nsec(),
        }
    }
}
#[derive(Clone, Debug)]
struct ReadFile {
    receipt: Receipt,
    bytes: Vec<u8>,
}
#[derive(Clone, Debug)]
struct Directory {
    path: PathBuf,
    receipt: Option<(u64, u64, u32, u32)>,
}
/// Private fields prevent constructing a mutation plan from arbitrary caller paths.
#[derive(Clone, Debug)]
pub struct HostInstallPlan {
    home: PathBuf,
    app: PathBuf,
    host: PathBuf,
    team: String,
    destination: PathBuf,
    directories: Vec<Directory>,
    host_file: ReadFile,
    previous: Option<ReadFile>,
    previous_host: Option<(PathBuf, ReadFile)>,
    manifest: Vec<u8>,
    already_current: bool,
}
impl HostInstallPlan {
    pub fn report(&self) -> Value {
        let effective = if self.already_current {
            &self.previous.as_ref().unwrap().bytes
        } else {
            &self.manifest
        };
        json!({"protocol":"computa-native-host-registration-v1","state":if self.already_current{"already_current"}else if self.previous.is_some(){"matching_signed_old_registration"}else{"registration_missing"},"installedApp":self.app,"host":self.host,"hostSHA256":digest(&self.host_file.bytes),"signingTeam":self.team,"destination":self.destination,"manifest":serde_json::from_slice::<Value>(effective).unwrap_or(Value::Null),"manifestSHA256":digest(effective),"proposedManifestSHA256":digest(&self.manifest),"previousManifestSHA256":self.previous.as_ref().map(|f|digest(&f.bytes)),"previousHost":self.previous_host.as_ref().map(|(p,f)|json!({"path":p,"sha256":digest(&f.bytes)})),"changesBrowserState":false})
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct HostInstallReceipt {
    pub changed: bool,
    pub manifest: PathBuf,
    pub manifest_sha256: String,
    pub backup: Option<PathBuf>,
}
fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn uid() -> u32 {
    // SAFETY: getuid has no pointer arguments or preconditions.
    unsafe { libc::getuid() }
}
fn read_file(path: &Path, limit: u64, executable: bool) -> Result<ReadFile> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| RegistrationError::UnsafePath)?;
    read_open_file(file, limit, executable)
}
fn read_open_file(file: File, limit: u64, executable: bool) -> Result<ReadFile> {
    let before = file.metadata().map_err(|_| RegistrationError::UnsafePath)?;
    if !before.is_file()
        || before.uid() != uid()
        || before.mode() & 0o022 != 0
        || before.len() > limit
        || executable && before.mode() & 0o111 == 0
    {
        return Err(RegistrationError::UnsafePath);
    }
    let receipt = Receipt::of(&before);
    let mut bytes = vec![];
    (&file)
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| RegistrationError::UnsafePath)?;
    if bytes.len() as u64 != before.len()
        || Receipt::of(&file.metadata().map_err(|_| RegistrationError::UnsafePath)?) != receipt
    {
        return Err(RegistrationError::Changed);
    }
    Ok(ReadFile { receipt, bytes })
}
fn directory_receipt(path: &Path) -> Result<Option<(u64, u64, u32, u32)>> {
    match std::fs::symlink_metadata(path) {
        Ok(m)
            if m.is_dir()
                && !m.file_type().is_symlink()
                && m.uid() == uid()
                && m.mode() & 0o022 == 0 =>
        {
            Ok(Some((m.dev(), m.ino(), m.uid(), m.mode())))
        }
        Ok(_) => Err(RegistrationError::UnsafePath),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(RegistrationError::UnsafePath),
    }
}
fn absolute_chain(root: &Path, path: &Path, allow_missing: bool) -> Result<Vec<Directory>> {
    if !root.is_absolute()
        || !path.starts_with(root)
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(RegistrationError::UnsafePath);
    }
    let mut current = root.to_path_buf();
    let mut rows = vec![Directory {
        path: current.clone(),
        receipt: directory_receipt(&current)?,
    }];
    if rows[0].receipt.is_none() {
        return Err(RegistrationError::UnsafePath);
    }
    for part in path
        .strip_prefix(root)
        .map_err(|_| RegistrationError::UnsafePath)?
        .components()
    {
        if !matches!(part, std::path::Component::Normal(_)) {
            return Err(RegistrationError::UnsafePath);
        }
        current.push(part);
        let receipt = directory_receipt(&current)?;
        if receipt.is_none() && !allow_missing {
            return Err(RegistrationError::UnsafePath);
        }
        rows.push(Directory {
            path: current.clone(),
            receipt,
        });
    }
    Ok(rows)
}
trait Verifier {
    fn verify(&self, path: &Path, identifier: &str, team: &str) -> Result<()>;
}
struct SignedVerifier;
impl Verifier for SignedVerifier {
    fn verify(&self, path: &Path, identifier: &str, team: &str) -> Result<()> {
        identity::validate_static_code(path, identifier, team)
            .map_err(|_| RegistrationError::Signing)
    }
}
fn installed_paths(home: &Path, executable: &Path) -> Result<(PathBuf, PathBuf)> {
    let app = home.join("Applications/Computa.app");
    if executable != app.join("Contents/MacOS/Computa") {
        return Err(RegistrationError::NotInstalled);
    }
    Ok((
        app.clone(),
        app.join("Contents/Resources/ChromeBridge/ChromeBridgeHost"),
    ))
}
/// Derives only the current kernel executable and OS account home. No side effects.
pub fn plan_current_installation() -> Result<HostInstallPlan> {
    let home = identity::user_home().map_err(|_| RegistrationError::UnsafePath)?;
    let executable = std::env::current_exe().map_err(|_| RegistrationError::NotInstalled)?;
    let (app, _) = installed_paths(&home, &executable)?;
    absolute_chain(&home, &app.join("Contents/MacOS"), false)?;
    let team = identity::current_application_team().map_err(|_| RegistrationError::Signing)?;
    plan(&home, &app, &team, &SignedVerifier)
}
fn plan(home: &Path, app: &Path, team: &str, verifier: &dyn Verifier) -> Result<HostInstallPlan> {
    let host = app.join("Contents/Resources/ChromeBridge/ChromeBridgeHost");
    absolute_chain(
        home,
        host.parent().ok_or(RegistrationError::UnsafePath)?,
        false,
    )?;
    verifier.verify(app, APP_IDENTIFIER, team)?;
    let host_file = read_file(&host, MAX_HOST, true)?;
    verifier.verify(&host, HOST_IDENTIFIER, team)?;
    same_file(&host, &host_file, MAX_HOST, true)?;
    let destination = home
        .join("Library/Application Support/Google/Chrome/NativeMessagingHosts")
        .join(format!("{HOST_NAME}.json"));
    let mut directories = absolute_chain(
        home,
        destination.parent().ok_or(RegistrationError::UnsafePath)?,
        true,
    )?;
    let backup_root =
        home.join("Library/Application Support/LocalCodex/BrowserBridge/HostRegistrationBackups");
    for directory in absolute_chain(home, &backup_root, true)? {
        if !directories.iter().any(|row| row.path == directory.path) {
            directories.push(directory);
        }
    }
    let previous = match std::fs::symlink_metadata(&destination) {
        Ok(_) => Some(
            read_file(&destination, MAX_MANIFEST, false)
                .map_err(|_| RegistrationError::ForeignRegistration)?,
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err(RegistrationError::UnsafePath),
    };
    let mut previous_host = None;
    let mut already_current = false;
    if let Some(file) = &previous {
        let value = computa_contracts::strict_json::parse(&file.bytes)
            .map_err(|_| RegistrationError::ForeignRegistration)?;
        let old: Manifest =
            serde_json::from_value(value).map_err(|_| RegistrationError::ForeignRegistration)?;
        if !old.ours() || old.path.file_name().and_then(|v| v.to_str()) != Some("ChromeBridgeHost")
        {
            return Err(RegistrationError::ForeignRegistration);
        }
        let old_file = read_file(&old.path, MAX_HOST, true)
            .map_err(|_| RegistrationError::ForeignRegistration)?;
        verifier
            .verify(&old.path, HOST_IDENTIFIER, team)
            .map_err(|_| RegistrationError::ForeignRegistration)?;
        same_file(&old.path, &old_file, MAX_HOST, true)
            .map_err(|_| RegistrationError::ForeignRegistration)?;
        already_current = old.path == host;
        previous_host = Some((old.path, old_file));
    }
    let manifest = Manifest {
        name: HOST_NAME.into(),
        description: "Computa authenticated browser bridge".into(),
        path: host.clone(),
        kind: "stdio".into(),
        allowed_origins: vec![format!("chrome-extension://{EXTENSION_ID}/")],
    };
    let manifest =
        serde_json::to_vec_pretty(&manifest).map_err(|_| RegistrationError::UnsafePath)?;
    Ok(HostInstallPlan {
        home: home.into(),
        app: app.into(),
        host,
        team: team.into(),
        destination,
        directories,
        host_file,
        previous,
        previous_host,
        manifest,
        already_current,
    })
}
fn same_file(path: &Path, expected: &ReadFile, limit: u64, executable: bool) -> Result<()> {
    let actual = read_file(path, limit, executable).map_err(|_| RegistrationError::Changed)?;
    if actual.receipt != expected.receipt || actual.bytes != expected.bytes {
        return Err(RegistrationError::Changed);
    }
    Ok(())
}
fn revalidate(plan: &HostInstallPlan, verifier: &dyn Verifier) -> Result<()> {
    for directory in &plan.directories {
        if directory_receipt(&directory.path)? != directory.receipt {
            return Err(RegistrationError::Changed);
        }
    }
    revalidate_sources(plan, verifier)?;
    match &plan.previous {
        Some(file) => same_file(&plan.destination, file, MAX_MANIFEST, false)?,
        None if std::fs::symlink_metadata(&plan.destination).is_ok() => {
            return Err(RegistrationError::Changed);
        }
        None => {}
    }
    Ok(())
}
fn revalidate_sources(plan: &HostInstallPlan, verifier: &dyn Verifier) -> Result<()> {
    verifier.verify(&plan.app, APP_IDENTIFIER, &plan.team)?;
    same_file(&plan.host, &plan.host_file, MAX_HOST, true)?;
    verifier.verify(&plan.host, HOST_IDENTIFIER, &plan.team)?;
    same_file(&plan.host, &plan.host_file, MAX_HOST, true)?;
    if let Some((path, file)) = &plan.previous_host {
        same_file(path, file, MAX_HOST, true)?;
        verifier.verify(path, HOST_IDENTIFIER, &plan.team)?;
        same_file(path, file, MAX_HOST, true)?;
    }
    Ok(())
}
fn component(name: &std::ffi::OsStr) -> Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    let bytes = name.as_bytes();
    if bytes.is_empty()
        || bytes.len() > 255
        || bytes.contains(&b'/')
        || bytes == b"."
        || bytes == b".."
    {
        return Err(RegistrationError::UnsafePath);
    }
    std::ffi::CString::new(bytes).map_err(|_| RegistrationError::UnsafePath)
}
fn descriptor(fd: i32) -> Result<File> {
    if fd < 0 {
        return Err(RegistrationError::UnsafePath);
    }
    // SAFETY: successful open/openat supplied a new owned descriptor, transferred exactly once to File.
    Ok(unsafe { File::from_raw_fd(fd) })
}
fn open_chain(root: &Path, path: &Path) -> Result<File> {
    if !path.starts_with(root) {
        return Err(RegistrationError::UnsafePath);
    }
    let mut directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(root)
        .map_err(|_| RegistrationError::UnsafePath)?;
    let info = directory
        .metadata()
        .map_err(|_| RegistrationError::UnsafePath)?;
    if !info.is_dir() || info.uid() != uid() || info.mode() & 0o022 != 0 {
        return Err(RegistrationError::UnsafePath);
    }
    for part in path
        .strip_prefix(root)
        .map_err(|_| RegistrationError::UnsafePath)?
        .components()
    {
        if !matches!(part, std::path::Component::Normal(_)) {
            return Err(RegistrationError::UnsafePath);
        }
        let name = component(part.as_os_str())?;
        // SAFETY: the live parent descriptor anchors lookup; name is a single terminated component. Symlinks are rejected.
        directory = descriptor(unsafe {
            libc::openat(
                directory.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        let info = directory
            .metadata()
            .map_err(|_| RegistrationError::UnsafePath)?;
        if !info.is_dir() || info.uid() != uid() || info.mode() & 0o022 != 0 {
            return Err(RegistrationError::UnsafePath);
        }
    }
    Ok(directory)
}
fn read_named(directory: &File, name: &str) -> Result<ReadFile> {
    let name = component(std::ffi::OsStr::new(name))?;
    // SAFETY: directory remains owned and name is one terminated component; a leaf symlink cannot be followed.
    let file = descriptor(unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
        )
    })?;
    read_open_file(file, MAX_MANIFEST, false)
}
fn same_named(directory: &File, name: &str, expected: &ReadFile) -> Result<()> {
    let actual = read_named(directory, name).map_err(|_| RegistrationError::Changed)?;
    if actual.receipt != expected.receipt || actual.bytes != expected.bytes {
        return Err(RegistrationError::Changed);
    }
    Ok(())
}
fn create_directory(home: &Path, row: &Directory) -> Result<()> {
    if row.receipt.is_none() {
        let parent = open_chain(
            home,
            row.path.parent().ok_or(RegistrationError::UnsafePath)?,
        )?;
        let name = component(row.path.file_name().ok_or(RegistrationError::UnsafePath)?)?;
        // SAFETY: parent anchors the single component; mkdirat never replaces an existing entry.
        if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(RegistrationError::Changed);
        }
    } else {
        let directory = open_chain(home, &row.path)?;
        let info = directory
            .metadata()
            .map_err(|_| RegistrationError::UnsafePath)?;
        if Some((info.dev(), info.ino(), info.uid(), info.mode())) != row.receipt {
            return Err(RegistrationError::Changed);
        }
    }
    Ok(())
}
fn write_new(directory: &File, name: &str, bytes: &[u8]) -> Result<ReadFile> {
    let name_c = component(std::ffi::OsStr::new(name))?;
    // SAFETY: parent anchors an exclusive new private file; the single component is terminated and live.
    let mut file = descriptor(unsafe {
        libc::openat(
            directory.as_raw_fd(),
            name_c.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    })?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| RegistrationError::SaveFailed)?;
    read_named(directory, name)
}
#[cfg(target_os = "macos")]
fn rename_exclusive(
    source_directory: &File,
    source: &str,
    target_directory: &File,
    target: &str,
) -> Result<()> {
    let source = component(std::ffi::OsStr::new(source))?;
    let target = component(std::ffi::OsStr::new(target))?;
    // SAFETY: both paths are terminated and live. RENAME_EXCL rejects any target instead of replacing it.
    if unsafe {
        libc::renameatx_np(
            source_directory.as_raw_fd(),
            source.as_ptr(),
            target_directory.as_raw_fd(),
            target.as_ptr(),
            4,
        )
    } != 0
    {
        return Err(RegistrationError::Changed);
    }
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn rename_exclusive(
    _source_directory: &File,
    _source: &str,
    _target_directory: &File,
    _target: &str,
) -> Result<()> {
    Err(RegistrationError::SaveFailed)
}
fn remove_named(directory: &File, name: &str, expected: &ReadFile) -> Result<()> {
    same_named(directory, name, expected)?;
    let name = component(std::ffi::OsStr::new(name))?;
    // SAFETY: the retained directory anchors the verified private, instance-randomized file name; directories cannot be removed.
    if unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } != 0 {
        return Err(RegistrationError::SaveFailed);
    }
    Ok(())
}
/// Production-only repair; the immutable plan is rechecked against the current installed process.
/// No caller path can register a staged or qualification helper.
pub fn apply_current_installation(plan: &HostInstallPlan) -> Result<HostInstallReceipt> {
    let home = identity::user_home().map_err(|_| RegistrationError::UnsafePath)?;
    let executable = std::env::current_exe().map_err(|_| RegistrationError::NotInstalled)?;
    let (app, host) = installed_paths(&home, &executable)?;
    if home != plan.home || app != plan.app || host != plan.host {
        return Err(RegistrationError::NotInstalled);
    }
    if identity::current_application_team().map_err(|_| RegistrationError::Signing)? != plan.team {
        return Err(RegistrationError::Signing);
    }
    apply(plan, &SignedVerifier)
}
fn apply(plan: &HostInstallPlan, verifier: &dyn Verifier) -> Result<HostInstallReceipt> {
    revalidate(plan, verifier)?;
    if plan.already_current {
        return Ok(HostInstallReceipt {
            changed: false,
            manifest: plan.destination.clone(),
            manifest_sha256: digest(&plan.previous.as_ref().unwrap().bytes),
            backup: None,
        });
    }
    for directory in &plan.directories {
        create_directory(&plan.home, directory)?;
    }
    let backup_root = plan
        .home
        .join("Library/Application Support/LocalCodex/BrowserBridge/HostRegistrationBackups");
    let backups = open_chain(&plan.home, &backup_root)?;
    let info = backups
        .metadata()
        .map_err(|_| RegistrationError::UnsafePath)?;
    if info.mode() & 0o077 != 0 {
        return Err(RegistrationError::UnsafePath);
    }
    if std::fs::read_dir(&backup_root)
        .map_err(|_| RegistrationError::UnsafePath)?
        .take(65)
        .count()
        > 64
    {
        return Err(RegistrationError::SaveFailed);
    }
    let lock_name = c"registration.lock";
    // SAFETY: the retained private directory anchors the fixed lock name; symlink leaves are rejected.
    let lock = descriptor(unsafe {
        libc::openat(
            backups.as_raw_fd(),
            lock_name.as_ptr(),
            libc::O_CREAT | libc::O_RDWR | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    })?;
    let lock_info = lock.metadata().map_err(|_| RegistrationError::UnsafePath)?;
    if !lock_info.is_file() || lock_info.uid() != uid() || lock_info.mode() & 0o077 != 0 {
        return Err(RegistrationError::UnsafePath);
    }
    // SAFETY: lock is a retained descriptor; LOCK_NB prevents blocking startup on another installer.
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(RegistrationError::Changed);
    }
    let parent_path = plan.destination.parent().unwrap();
    let parent = open_chain(&plan.home, parent_path)?;
    let destination_name = plan
        .destination
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or(RegistrationError::UnsafePath)?;
    let nonce = uuid::Uuid::new_v4();
    let staged = format!(".{HOST_NAME}-{nonce}.pending");
    let new_file = write_new(&parent, &staged, &plan.manifest)?;
    let rotation = format!("{nonce}.retired");
    let backup_name = format!("{nonce}-previous.json");
    let backup = backup_root.join(&backup_name);
    let mut moved = false;
    let operation = (|| {
        // File receipts are checked again after taking the private installer lock.
        revalidate_sources(plan, verifier)?;
        if let Some(old) = &plan.previous {
            same_named(&parent, destination_name, old)?;
            write_new(&backups, &backup_name, &old.bytes)?;
            backups
                .sync_all()
                .map_err(|_| RegistrationError::SaveFailed)?;
            rename_exclusive(&parent, destination_name, &backups, &rotation)?;
            moved = true;
            // If another actor replaced the path in the check/rename interval,
            // restore it before publishing. Never overwrite any competing target.
            same_named(&backups, &rotation, old)?;
        }
        revalidate_sources(plan, verifier)?;
        rename_exclusive(&parent, &staged, &parent, destination_name)?;
        same_named(&parent, destination_name, &new_file)?;
        parent
            .sync_all()
            .map_err(|_| RegistrationError::SaveFailed)?;
        let observed = open_chain(&plan.home, parent_path)?
            .metadata()
            .map_err(|_| RegistrationError::UnsafePath)?;
        let original = parent
            .metadata()
            .map_err(|_| RegistrationError::UnsafePath)?;
        if (observed.dev(), observed.ino()) != (original.dev(), original.ino()) {
            return Err(RegistrationError::Changed);
        }
        Ok(())
    })();
    if let Err(error) = operation {
        if moved {
            // Exclusive restore never replaces a competing registration, even after a failed publication.
            let _ = rename_exclusive(&backups, &rotation, &parent, destination_name);
        }
        let _ = remove_named(&parent, &staged, &new_file);
        return Err(error);
    }
    if moved && same_named(&backups, &rotation, plan.previous.as_ref().unwrap()).is_ok() {
        remove_named(&backups, &rotation, plan.previous.as_ref().unwrap())?;
        backups
            .sync_all()
            .map_err(|_| RegistrationError::SaveFailed)?;
    }
    Ok(HostInstallReceipt {
        changed: true,
        manifest: plan.destination.clone(),
        manifest_sha256: digest(&plan.manifest),
        backup: plan.previous.as_ref().map(|_| backup),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};
    struct FakeVerifier {
        app: PathBuf,
        hosts: Vec<PathBuf>,
    }
    impl Verifier for FakeVerifier {
        fn verify(&self, path: &Path, identifier: &str, team: &str) -> Result<()> {
            if team == "ABCDEFGHIJ"
                && (identifier == APP_IDENTIFIER && path == self.app
                    || identifier == HOST_IDENTIFIER && self.hosts.iter().any(|host| host == path))
            {
                Ok(())
            } else {
                Err(RegistrationError::Signing)
            }
        }
    }
    fn fixture() -> (tempfile::TempDir, PathBuf, PathBuf, FakeVerifier) {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().canonicalize().unwrap();
        let app = home.join("Applications/Computa.app");
        let host = app.join("Contents/Resources/ChromeBridge/ChromeBridgeHost");
        std::fs::create_dir_all(host.parent().unwrap()).unwrap();
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::write(&host, b"fixed signed helper fixture").unwrap();
        std::fs::set_permissions(&host, std::fs::Permissions::from_mode(0o700)).unwrap();
        let verifier = FakeVerifier {
            app: app.clone(),
            hosts: vec![host],
        };
        (temp, home, app, verifier)
    }
    fn old_manifest(home: &Path, host: &Path) -> PathBuf {
        let path = home
            .join("Library/Application Support/Google/Chrome/NativeMessagingHosts")
            .join(format!("{HOST_NAME}.json"));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let value = json!({"name":HOST_NAME,"description":"Compatible prior release","path":host,"type":"stdio","allowed_origins":[format!("chrome-extension://{EXTENSION_ID}/")]});
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        path
    }
    #[test]
    fn uninstalled_and_staged_process_cannot_plan_or_apply_live_registration() {
        let home = Path::new("/Users/example");
        assert!(
            installed_paths(
                home,
                &home.join("Applications/Computa.app/Contents/MacOS/Computa")
            )
            .is_ok()
        );
        for executable in [
            home.join("work/Computa.app/Contents/MacOS/Computa"),
            PathBuf::from("/Applications/Computa.app/Contents/MacOS/Computa"),
            home.join("Applications/Computa.app/Contents/MacOS/Other"),
        ] {
            assert!(matches!(
                installed_paths(home, &executable),
                Err(RegistrationError::NotInstalled)
            ));
        }
        assert!(matches!(
            plan_current_installation(),
            Err(RegistrationError::NotInstalled)
        ));
        let (_temp, home, app, verifier) = fixture();
        let planned = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        assert!(matches!(
            apply_current_installation(&planned),
            Err(RegistrationError::NotInstalled)
        ));
        assert!(!home.join("Library").exists());
    }
    #[test]
    fn missing_registration_plan_is_read_only_and_apply_is_private_and_idempotent() {
        let (_temp, home, app, verifier) = fixture();
        let planned = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        assert_eq!(planned.report()["state"], "registration_missing");
        assert!(!home.join("Library").exists());
        let receipt = apply(&planned, &verifier).unwrap();
        assert!(receipt.changed && receipt.backup.is_none());
        let saved = read_file(&receipt.manifest, MAX_MANIFEST, false).unwrap();
        let manifest: Manifest = serde_json::from_slice(&saved.bytes).unwrap();
        assert!(manifest.ours());
        assert_eq!(manifest.path, verifier.hosts[0]);
        assert_eq!(saved.receipt.mode & 0o777, 0o600);
        assert_eq!(digest(&saved.bytes), receipt.manifest_sha256);
        let current = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        assert_eq!(current.report()["state"], "already_current");
        assert!(!apply(&current, &verifier).unwrap().changed);
    }
    #[test]
    fn only_exact_matching_signed_old_helper_is_backed_up_and_replaced() {
        let (_temp, home, app, mut verifier) = fixture();
        let legacy = home.join("Legacy/ChromeBridgeHost");
        std::fs::create_dir(legacy.parent().unwrap()).unwrap();
        std::fs::write(&legacy, b"prior signed helper").unwrap();
        std::fs::set_permissions(&legacy, std::fs::Permissions::from_mode(0o700)).unwrap();
        verifier.hosts.push(legacy.clone());
        let destination = old_manifest(&home, &legacy);
        let original = std::fs::read(&destination).unwrap();
        let planned = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        assert_eq!(
            planned.report()["state"],
            "matching_signed_old_registration"
        );
        let receipt = apply(&planned, &verifier).unwrap();
        let backup = receipt.backup.unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), original);
        assert_eq!(std::fs::metadata(&backup).unwrap().mode() & 0o777, 0o600);
        assert_eq!(
            std::fs::metadata(backup.parent().unwrap()).unwrap().mode() & 0o777,
            0o700
        );
        let saved: Manifest =
            serde_json::from_slice(&std::fs::read(&destination).unwrap()).unwrap();
        assert_eq!(saved.path, verifier.hosts[0]);
        assert_eq!(std::fs::read(&legacy).unwrap(), b"prior signed helper");
        assert!(
            !std::fs::read_dir(backup.parent().unwrap())
                .unwrap()
                .any(|entry| entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".retired"))
        );
    }
    #[test]
    fn foreign_changed_and_symlinked_registrations_are_never_adopted_or_overwritten() {
        let (_temp, home, app, verifier) = fixture();
        let destination = old_manifest(&home, &verifier.hosts[0]);
        let planned = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        let foreign = b"{\"name\":\"foreign\"}";
        std::fs::write(&destination, foreign).unwrap();
        assert!(matches!(
            apply(&planned, &verifier),
            Err(RegistrationError::Changed)
        ));
        assert_eq!(std::fs::read(&destination).unwrap(), foreign);
        assert!(matches!(
            plan(&home, &app, "ABCDEFGHIJ", &verifier),
            Err(RegistrationError::ForeignRegistration)
        ));
        std::fs::remove_file(&destination).unwrap();
        let other = home.join("other.json");
        std::fs::write(&other, foreign).unwrap();
        symlink(&other, &destination).unwrap();
        assert!(matches!(
            plan(&home, &app, "ABCDEFGHIJ", &verifier),
            Err(RegistrationError::ForeignRegistration)
        ));
        assert_eq!(std::fs::read(&other).unwrap(), foreign);
        assert!(!home.join("Library/Application Support/LocalCodex").exists());
    }
    #[test]
    fn changed_signed_helper_and_symlinked_parent_fail_closed_before_any_registration() {
        let (_temp, home, app, verifier) = fixture();
        let planned = plan(&home, &app, "ABCDEFGHIJ", &verifier).unwrap();
        std::fs::write(&verifier.hosts[0], b"changed helper").unwrap();
        assert!(matches!(
            apply(&planned, &verifier),
            Err(RegistrationError::Changed)
        ));
        assert!(!home.join("Library").exists());
        let foreign = home.join("outside");
        std::fs::create_dir(&foreign).unwrap();
        symlink(&foreign, home.join("Library")).unwrap();
        assert!(matches!(
            plan(&home, &app, "ABCDEFGHIJ", &verifier),
            Err(RegistrationError::UnsafePath)
        ));
        assert_eq!(std::fs::read_dir(&foreign).unwrap().count(), 0);
    }
}
