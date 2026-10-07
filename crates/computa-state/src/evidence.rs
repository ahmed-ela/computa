//! Compatible, bounded, private native failure evidence (the existing Swift v1 schema).
use computa_contracts::Identifier;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    sync::Mutex,
};
static PROCESS_LOCK: Mutex<()> = Mutex::new(());
pub const MAX_RECORDS: usize = 16;
pub const MAX_FILE_BYTES: usize = 64 * 1024;
/// Swift's JSONEncoder encodes Date as seconds from 2001-01-01.
pub const SWIFT_EPOCH_UNIX: f64 = 978_307_200.0;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FailureRecord {
    #[serde(rename = "threadID")]
    pub thread_id: String,
    #[serde(rename = "turnID")]
    pub turn_id: String,
    #[serde(rename = "callID")]
    pub call_id: String,
    pub tool_name: String,
    pub message: String,
    pub diagnostic_text: String,
    pub timestamp: f64,
}
impl FailureRecord {
    pub fn timestamp_unix(&self) -> f64 {
        self.timestamp + SWIFT_EPOCH_UNIX
    }
    fn same_evidence(&self, other: &Self) -> bool {
        self.thread_id == other.thread_id
            && self.turn_id == other.turn_id
            && self.call_id == other.call_id
            && self.tool_name == other.tool_name
            && self.message == other.message
            && self.diagnostic_text == other.diagnostic_text
    }
    pub fn validate(&self) -> Result<(), StoreError> {
        for s in [&self.thread_id, &self.turn_id, &self.call_id] {
            Identifier::new(s.clone()).map_err(|_| StoreError::Invalid)?;
        }
        if self.tool_name.is_empty()
            || self.tool_name.len() > 128
            || self.message.trim().is_empty()
            || self.message.len() > 2048
            || self.diagnostic_text.len() > 8192
            || !self.timestamp.is_finite()
        {
            return Err(StoreError::Invalid);
        }
        let d: Value =
            serde_json::from_str(&self.diagnostic_text).map_err(|_| StoreError::Invalid)?;
        let o = d.as_object().ok_or(StoreError::Invalid)?;
        let e = d["error"].as_object().ok_or(StoreError::Invalid)?;
        if !keys(e, &["code", "message"])
            || d["type"] != "native_tool_failure"
            || d["cause"] != "undetermined"
            || d["website_status"] != "not_observed"
            || d["next_step"].as_str().is_none_or(str::is_empty)
            || d["error"]["message"]
                .as_str()
                .is_none_or(|s| s.is_empty() || s.len() > 2048)
        {
            return Err(StoreError::Invalid);
        }
        let valid = match d["error"]["code"].as_str() {
            Some("application_activation_failed") => {
                keys(
                    o,
                    &[
                        "type",
                        "error",
                        "process_id",
                        "cause",
                        "website_status",
                        "action_outcome",
                        "next_step",
                    ],
                ) && d["process_id"]
                    .as_i64()
                    .is_some_and(|p| p > 0 && p <= i32::MAX as i64)
                    && d["action_outcome"] == "not_confirmed"
            }
            Some("chrome_navigation_recovery_required") => {
                keys(
                    o,
                    &[
                        "type",
                        "error",
                        "cause",
                        "website_status",
                        "action_outcome",
                        "tab_state",
                        "retry_policy",
                        "next_step",
                    ],
                ) && self.tool_name == "computer_v2_open"
                    && d["action_outcome"] == "navigation_not_confirmed"
                    && d["tab_state"] == "preserved_if_created"
                    && d["retry_policy"] == "stop_for_turn"
            }
            Some(code @ ("computer_outcome_unverified" | "runtime_recovery_exhausted")) => {
                let message = outcome_message(code);
                let unresolved = d["unresolved_operations"].as_u64();
                let failed = d["failed_operations"].as_u64();
                keys(
                    o,
                    &[
                        "type",
                        "error",
                        "cause",
                        "website_status",
                        "action_outcome",
                        "retry_policy",
                        "unresolved_operations",
                        "failed_operations",
                        "next_step",
                    ],
                ) && d["action_outcome"] == "unverified"
                    && d["retry_policy"] == "stop_for_turn"
                    && d["error"]["message"] == message
                    && self.message == message
                    && d["next_step"] == NEXT_STEP
                    && unresolved
                        .is_some_and(|u| (1..=64).contains(&u) && failed.is_some_and(|f| f <= u))
                    && if code == "computer_outcome_unverified" {
                        self.tool_name == "computer_outcome"
                    } else {
                        self.tool_name.starts_with("computer_v2_")
                            || self.tool_name == "computer"
                            || self.tool_name.starts_with("desktop_")
                    }
            }
            _ => false,
        };
        if valid {
            Ok(())
        } else {
            Err(StoreError::Invalid)
        }
    }
}
fn keys(o: &serde_json::Map<String, Value>, expected: &[&str]) -> bool {
    o.len() == expected.len() && expected.iter().all(|s| o.contains_key(*s))
}
pub const NEXT_STEP: &str = "Use fresh observations in a new attempt. Do not treat this failed attempt as a completed action or an empty result.";
fn outcome_message(code: &str) -> &'static str {
    if code == "runtime_recovery_exhausted" {
        "Computer-use recovery stopped after repeated or unavailable actions. The requested outcome remains unverified. You can continue in this chat."
    } else {
        "The requested computer-use outcome could not be verified. This attempt does not establish completion or an empty search result. You can continue in this chat."
    }
}
// The legacy receipt's four identity fields and finite outcome tuple stay
// explicit at native call sites; accepting unvalidated JSON would weaken it.
#[allow(clippy::too_many_arguments)]
pub fn outcome_record(
    thread_id: String,
    turn_id: String,
    call_id: String,
    tool_name: String,
    recovery: bool,
    unresolved: u64,
    failed: u64,
    timestamp_unix: f64,
) -> Result<FailureRecord, StoreError> {
    let code = if recovery {
        "runtime_recovery_exhausted"
    } else {
        "computer_outcome_unverified"
    };
    let message = outcome_message(code);
    let r=FailureRecord{thread_id,turn_id,call_id,tool_name,message:message.into(),timestamp:timestamp_unix-SWIFT_EPOCH_UNIX,diagnostic_text:json!({"type":"native_tool_failure","error":{"code":code,"message":message},"cause":"undetermined","website_status":"not_observed","action_outcome":"unverified","retry_policy":"stop_for_turn","unresolved_operations":unresolved,"failed_operations":failed,"next_step":NEXT_STEP}).to_string()};
    r.validate()?;
    Ok(r)
}
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("Native failure evidence is invalid.")]
    Invalid,
    #[error("Native failure evidence conflicts with an existing call.")]
    IdentityConflict,
    #[error("Native failure evidence reached its bounded capacity.")]
    Capacity,
    #[error("Native failure evidence could not be persisted: {0}")]
    Io(#[from] io::Error),
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Envelope {
    version: u32,
    #[serde(rename = "threadID")]
    thread_id: String,
    records: Vec<FailureRecord>,
}
#[derive(Clone, Debug)]
pub struct FailureStore {
    directory: PathBuf,
}
impl FailureStore {
    pub fn open(directory: impl Into<PathBuf>) -> Result<Self, StoreError> {
        let directory = directory.into();
        match fs::symlink_metadata(&directory) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
            Ok(_) => return Err(StoreError::Invalid),
            Err(e) if e.kind() == io::ErrorKind::NotFound => fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&directory)?,
            Err(e) => return Err(e.into()),
        }
        let store = Self { directory };
        let _ = store.directory(false)?;
        Ok(store)
    }
    fn directory(&self, exclusive: bool) -> Result<File, StoreError> {
        let f = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(&self.directory)?;
        let m = f.metadata()?;
        // SAFETY: geteuid has no preconditions and does not retain state.
        if m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o777 != 0o700 {
            return Err(StoreError::Invalid);
        }
        loop {
            // SAFETY: the descriptor remains live for the entire flock operation.
            if unsafe {
                libc::flock(
                    f.as_raw_fd(),
                    if exclusive {
                        libc::LOCK_EX
                    } else {
                        libc::LOCK_SH
                    },
                )
            } == 0
            {
                break;
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e.into());
            }
        }
        Ok(f)
    }
    pub fn load(&self, thread_id: &str) -> Result<Vec<FailureRecord>, StoreError> {
        Identifier::new(thread_id.to_owned()).map_err(|_| StoreError::Invalid)?;
        let _lock = PROCESS_LOCK.lock().map_err(|_| StoreError::Invalid)?;
        let dir = self.directory(false)?;
        self.load_locked(thread_id, &dir)
    }
    fn load_locked(&self, thread_id: &str, dir: &File) -> Result<Vec<FailureRecord>, StoreError> {
        let name = std::ffi::CString::new(filename(thread_id)).map_err(|_| StoreError::Invalid)?;
        // SAFETY: dir is live, name is NUL terminated, and openat returns a new owned FD.
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            let e = io::Error::last_os_error();
            return if e.kind() == io::ErrorKind::NotFound {
                Ok(vec![])
            } else {
                Err(e.into())
            };
        }
        // SAFETY: openat returned this distinct owned FD which is consumed exactly once.
        let mut f = unsafe { File::from_raw_fd(fd) };
        let before = f.metadata()?;
        // SAFETY: geteuid has no preconditions.
        let owner_uid = unsafe { libc::geteuid() };
        if !before.is_file()
            || before.nlink() != 1
            || before.uid() != owner_uid
            || before.mode() & 0o777 != 0o600
        {
            return Err(StoreError::Invalid);
        }
        if before.len() == 0 || before.len() > MAX_FILE_BYTES as u64 {
            return Err(StoreError::Capacity);
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        Read::by_ref(&mut f)
            .take((MAX_FILE_BYTES + 1) as u64)
            .read_to_end(&mut bytes)?;
        let after = f.metadata()?;
        if bytes.len() as u64 != before.len() || !unchanged(&before, &after) {
            return Err(StoreError::Invalid);
        }
        let e: Envelope = serde_json::from_slice(&bytes).map_err(|_| StoreError::Invalid)?;
        if e.version != 1
            || e.thread_id != thread_id
            || e.records.is_empty()
            || e.records.len() > MAX_RECORDS
        {
            return Err(StoreError::Invalid);
        }
        let mut ids = HashSet::new();
        for r in &e.records {
            r.validate()?;
            if r.thread_id != thread_id || !ids.insert((&r.turn_id, &r.call_id)) {
                return Err(StoreError::Invalid);
            }
        }
        Ok(e.records)
    }
    pub fn append(&self, record: FailureRecord) -> Result<FailureRecord, StoreError> {
        record.validate()?;
        let _lock = PROCESS_LOCK.lock().map_err(|_| StoreError::Invalid)?;
        let dir = self.directory(true)?;
        let mut records = self.load_locked(&record.thread_id, &dir)?;
        if let Some(old) = records
            .iter()
            .find(|r| r.turn_id == record.turn_id && r.call_id == record.call_id)
        {
            if !old.same_evidence(&record) {
                return Err(StoreError::IdentityConflict);
            }
            dir.sync_all()?;
            return Ok(old.clone());
        }
        if records.len() == MAX_RECORDS {
            return Err(StoreError::Capacity);
        }
        records.push(record.clone());
        let bytes = serde_json::to_vec(&Envelope {
            version: 1,
            thread_id: record.thread_id.clone(),
            records: records.clone(),
        })
        .map_err(|_| StoreError::Invalid)?;
        if bytes.len() > MAX_FILE_BYTES {
            return Err(StoreError::Capacity);
        }
        let name =
            std::ffi::CString::new(filename(&record.thread_id)).map_err(|_| StoreError::Invalid)?;
        let temp = std::ffi::CString::new(format!(".{}.tmp", uuid::Uuid::new_v4()))
            .map_err(|_| StoreError::Invalid)?;
        // SAFETY: names are NUL terminated; dir stays open; O_EXCL prevents following an existing file.
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                temp.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: the freshly-created owned FD is consumed once by File.
        let mut f = unsafe { File::from_raw_fd(fd) };
        let result = (|| -> Result<(), StoreError> {
            f.write_all(&bytes)?;
            f.sync_all()?;
            // SAFETY: both names are NUL terminated and the live descriptor is their common directory.
            if unsafe {
                libc::renameat(
                    dir.as_raw_fd(),
                    temp.as_ptr(),
                    dir.as_raw_fd(),
                    name.as_ptr(),
                )
            } != 0
            {
                return Err(io::Error::last_os_error().into());
            }
            dir.sync_all()?;
            if self.load_locked(&record.thread_id, &dir)? != records {
                return Err(StoreError::Invalid);
            }
            Ok(())
        })();
        if result.is_err() {
            // SAFETY: remove only the unique temporary name relative to our retained directory.
            unsafe { libc::unlinkat(dir.as_raw_fd(), temp.as_ptr(), 0) };
        }
        result?;
        Ok(record)
    }
    pub fn directory_path(&self) -> &Path {
        &self.directory
    }
}
fn filename(id: &str) -> String {
    format!("{}.json", hex::encode(Sha256::digest(id.as_bytes())))
}
fn unchanged(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.len() == b.len()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}
#[cfg(test)]
mod tests {
    use super::*;
    fn record(id: &str) -> FailureRecord {
        outcome_record(
            "thread".into(),
            "turn".into(),
            id.into(),
            "computer_outcome".into(),
            false,
            1,
            0,
            1_800_000_000.0,
        )
        .unwrap()
    }
    #[test]
    fn preserves_swift_schema_and_idempotency() {
        let tmp = tempfile::tempdir().unwrap();
        let s = FailureStore::open(tmp.path().join("evidence")).unwrap();
        let r = record("call");
        s.append(r.clone()).unwrap();
        let mut later = r.clone();
        later.timestamp += 10.0;
        assert_eq!(s.append(later).unwrap(), r);
        assert_eq!(s.load("thread").unwrap(), vec![r]);
        assert_eq!(s.load("absent").unwrap(), vec![]);
    }
    #[test]
    fn conflicting_identity_and_symlink_are_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let s = FailureStore::open(tmp.path().join("evidence")).unwrap();
        s.append(record("call")).unwrap();
        let mut r = record("call");
        r.tool_name = "computer_v2_open".into();
        assert!(s.append(r).is_err());
        let other = tmp.path().join("link");
        std::os::unix::fs::symlink(s.directory_path(), &other).unwrap();
        assert!(FailureStore::open(other).is_err());
    }
    #[test]
    fn no_eviction_at_capacity_and_no_untrusted_diagnostics() {
        let tmp = tempfile::tempdir().unwrap();
        let s = FailureStore::open(tmp.path().join("evidence")).unwrap();
        for i in 0..MAX_RECORDS {
            s.append(record(&i.to_string())).unwrap();
        }
        assert!(matches!(
            s.append(record("extra")),
            Err(StoreError::Capacity)
        ));
        let mut r = record("x");
        r.diagnostic_text =
            json!({"type":"native_tool_failure","error":{"code":"invented","message":"page text"}})
                .to_string();
        assert!(r.validate().is_err());
    }
}
