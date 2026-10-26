//! The legacy defaults importer takes values from the native preferences API.
use computa_contracts::{
    models::ModelId,
    ui::{AccessMode, Appearance},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::File,
    os::fd::AsRawFd,
    sync::{Arc, Mutex, OnceLock, Weak},
};
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub default_model: ModelId,
    pub access_mode: AccessMode,
    pub appearance: Appearance,
    #[serde(default)]
    pub reference_tool_threads: Vec<String>,
}
impl Preferences {
    pub fn import_legacy(defaults: &serde_json::Map<String, Value>) -> Self {
        let mut p = Self::default();
        if let Some(v) = defaults
            .get("LocalCodex.defaultModelID")
            .and_then(Value::as_str)
            && let Ok(m) = ModelId::parse(v)
        {
            p.default_model = m;
        }
        if let Some(v) = defaults.get("HeyDash.accessMode")
            && let Ok(mode) = serde_json::from_value(v.clone())
        {
            p.access_mode = mode;
        }

        if let Some(v) = defaults
            .get("ComputaReferenceToolThreads.v1")
            .and_then(Value::as_array)
        {
            p.reference_tool_threads = v
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
        }
        p
    }
}

/// Runtime-owned preference fields.
#[derive(Clone, Debug)]
pub struct RuntimePreferences {
    pub default_model: ModelId,
    pub access_mode: AccessMode,
    pub appearance: Appearance,
    pub reference_tool_threads: Vec<String>,
}
static LOCKS: OnceLock<Mutex<HashMap<std::path::PathBuf, Weak<Mutex<()>>>>> = OnceLock::new();
struct DirectoryLock<'a>(&'a File);
impl<'a> DirectoryLock<'a> {
    fn acquire(file: &'a File) -> Result<Self, PreferencesError> {
        // SAFETY: the directory descriptor is owned and remains open for this guard.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self(file))
    }
}
impl Drop for DirectoryLock<'_> {
    fn drop(&mut self) {
        // SAFETY: the borrowed descriptor remains open until this guard is dropped.
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}
/// Native preferences survive restarts without changing the upstream SQLite DB.
#[derive(Clone, Debug)]
pub struct PreferencesStore {
    path: std::path::PathBuf,
    serial: Arc<Mutex<()>>,
    directory: Arc<File>,
}
#[derive(Debug, thiserror::Error)]
pub enum PreferencesError {
    #[error("Native preferences are invalid.")]
    Invalid,
    #[error("Native preferences could not be saved: {0}")]
    Io(#[from] std::io::Error),
}
impl PreferencesStore {
    pub fn open(home: &std::path::Path) -> Result<Self, PreferencesError> {
        use std::os::unix::fs::DirBuilderExt;
        let directory = home.join("computa-state");
        match std::fs::symlink_metadata(&directory) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => {}
            Ok(_) => return Err(PreferencesError::Invalid),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                std::fs::DirBuilder::new().mode(0o700).create(&directory)?
            }
            Err(e) => return Err(e.into()),
        }
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        let directory = directory.canonicalize()?;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(&directory)?;
        let metadata = file.metadata()?;
        // SAFETY: geteuid is a read-only native account identity query.
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o777 != 0o700 {
            return Err(PreferencesError::Invalid);
        }
        let serial = {
            let mut locks = LOCKS
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .map_err(|_| PreferencesError::Invalid)?;
            match locks.get(&directory).and_then(Weak::upgrade) {
                Some(lock) => lock,
                None => {
                    let lock = Arc::new(Mutex::new(()));
                    locks.insert(directory.clone(), Arc::downgrade(&lock));
                    lock
                }
            }
        };
        Ok(Self {
            path: directory.join("preferences-v1.json"),
            serial,
            directory: Arc::new(file),
        })
    }
    fn verify_directory(&self) -> Result<(), PreferencesError> {
        use std::os::unix::fs::MetadataExt;
        let path = std::fs::symlink_metadata(self.path.parent().ok_or(PreferencesError::Invalid)?)?;
        let fd = self.directory.metadata()?;
        if !path.is_dir()
            || path.file_type().is_symlink()
            || path.dev() != fd.dev()
            || path.ino() != fd.ino()
            || path.uid() != fd.uid()
            || path.mode() & 0o777 != 0o700
        {
            return Err(PreferencesError::Invalid);
        }
        Ok(())
    }
    pub fn load(&self) -> Result<Option<Preferences>, PreferencesError> {
        let _serial = self.serial.lock().map_err(|_| PreferencesError::Invalid)?;
        let _directory = DirectoryLock::acquire(&self.directory)?;
        self.verify_directory()?;
        self.load_unlocked()
    }
    /// Whole-document initialization/replacement. Runtime updates use the
    /// serialized typed update method below to preserve concurrent changes.
    pub fn save(&self, p: &Preferences) -> Result<(), PreferencesError> {
        let _serial = self.serial.lock().map_err(|_| PreferencesError::Invalid)?;
        let _directory = DirectoryLock::acquire(&self.directory)?;
        self.verify_directory()?;
        self.save_unlocked(p)
    }
    fn update<F: FnOnce(&mut Preferences)>(
        &self,
        defaults: &Preferences,
        change: F,
    ) -> Result<Preferences, PreferencesError> {
        let _serial = self.serial.lock().map_err(|_| PreferencesError::Invalid)?;
        let _directory = DirectoryLock::acquire(&self.directory)?;
        self.verify_directory()?;
        let mut latest = self.load_unlocked()?.unwrap_or_else(|| defaults.clone());
        change(&mut latest);
        self.save_unlocked(&latest)?;
        Ok(latest)
    }
    pub fn initialize(&self, defaults: &Preferences) -> Result<Preferences, PreferencesError> {
        self.update(defaults, |_| {})
    }
    pub fn update_runtime<F: FnOnce(&mut RuntimePreferences)>(
        &self,
        defaults: &Preferences,
        change: F,
    ) -> Result<Preferences, PreferencesError> {
        self.update(defaults, |latest| {
            let mut view = RuntimePreferences {
                default_model: latest.default_model.clone(),
                access_mode: latest.access_mode,
                appearance: latest.appearance,
                reference_tool_threads: latest.reference_tool_threads.clone(),
            };
            change(&mut view);
            latest.default_model = view.default_model;
            latest.access_mode = view.access_mode;
            latest.appearance = view.appearance;
            latest.reference_tool_threads = view.reference_tool_threads;
        })
    }
    fn load_unlocked(&self) -> Result<Option<Preferences>, PreferencesError> {
        use std::io::Read;
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        let file = match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(&self.path)
        {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let meta = file.metadata()?;
        // SAFETY: geteuid has no arguments or state preconditions.
        let owner_uid = unsafe { libc::geteuid() };
        if !meta.is_file()
            || meta.nlink() != 1
            || meta.uid() != owner_uid
            || meta.mode() & 0o777 != 0o600
            || meta.len() > 256 * 1024
        {
            return Err(PreferencesError::Invalid);
        }
        let mut bytes = Vec::new();
        file.take(256 * 1024 + 1).read_to_end(&mut bytes)?;
        let mut value =
            computa_contracts::strict_json::parse(&bytes).map_err(|_| PreferencesError::Invalid)?;
        if let Some(object) = value.as_object_mut() {
            // Read older preferences without retaining the removed connection feature.
            for key in [
                "rememberedChromeConnection",
                "extensionEnabled",
                "extensionInstallationId",
                "temporaryTabs",
            ] {
                object.remove(key);
            }
        }
        let p: Preferences =
            serde_json::from_value(value).map_err(|_| PreferencesError::Invalid)?;
        Ok(Some(p))
    }
    fn save_unlocked(&self, p: &Preferences) -> Result<(), PreferencesError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let bytes = serde_json::to_vec(p).map_err(|_| PreferencesError::Invalid)?;
        if bytes.len() > 256 * 1024 {
            return Err(PreferencesError::Invalid);
        }
        let temp = self
            .path
            .with_file_name(format!(".preferences-{}.tmp", uuid::Uuid::new_v4()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temp)?;
        let result = (|| {
            file.write_all(&bytes)?;
            file.sync_all()?;
            std::fs::rename(&temp, &self.path)?;
            std::fs::File::open(self.path.parent().ok_or(PreferencesError::Invalid)?)?
                .sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temp);
        }
        result
    }
}
#[cfg(test)]
mod persistence_tests {
    use super::*;
    #[test]
    fn legacy_model_unknown_ids_and_native_copy_survive() {
        let tmp = tempfile::tempdir().unwrap();
        let defaults = serde_json::json!({"LocalCodex.defaultModelID":"my-external-model","HeyDash.accessMode":"askEveryTime","ComputaReferenceToolThreads.v1":["oldthread"]});
        let p = Preferences::import_legacy(defaults.as_object().unwrap());
        assert_eq!(p.default_model.as_str(), "my-external-model");
        let store = PreferencesStore::open(tmp.path()).unwrap();
        assert!(store.load().unwrap().is_none());
        store.save(&p).unwrap();
        let saved = store.load().unwrap().unwrap();
        assert_eq!(saved.default_model, p.default_model);
        assert_eq!(saved.reference_tool_threads, vec!["oldthread"]);
    }
    #[test]
    fn old_connection_preferences_are_discarded_without_losing_runtime_settings() {
        let tmp = tempfile::tempdir().unwrap();
        let store = PreferencesStore::open(tmp.path()).unwrap();
        let preferences = Preferences {
            access_mode: AccessMode::FullAccess,
            reference_tool_threads: vec!["preserved-chat".into()],
            ..Preferences::default()
        };
        store.save(&preferences).unwrap();
        let mut legacy = serde_json::to_value(&preferences).unwrap();
        for key in [
            "rememberedChromeConnection",
            "extensionEnabled",
            "extensionInstallationId",
            "temporaryTabs",
        ] {
            legacy[key] = serde_json::json!({"retired":"value"});
        }
        std::fs::write(&store.path, serde_json::to_vec(&legacy).unwrap()).unwrap();
        let loaded = store.load().unwrap().unwrap();
        assert_eq!(loaded.access_mode, AccessMode::FullAccess);
        assert_eq!(loaded.reference_tool_threads, vec!["preserved-chat"]);
        store.save(&loaded).unwrap();
        let saved: Value = serde_json::from_slice(&std::fs::read(&store.path).unwrap()).unwrap();
        assert!(saved.get("rememberedChromeConnection").is_none());
        assert!(saved.get("extensionEnabled").is_none());
        legacy["unexpectedSetting"] = serde_json::json!(true);
        std::fs::write(&store.path, serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert!(store.load().is_err());
    }

    #[test]
    fn concurrent_updates_are_serialized_across_separately_opened_stores() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        let store = PreferencesStore::open(&home).unwrap();
        store.initialize(&Preferences::default()).unwrap();
        let workers = (0..16)
            .map(|n| {
                let home = home.clone();
                std::thread::spawn(move || {
                    let store = PreferencesStore::open(&home).unwrap();
                    store
                        .update_runtime(&Preferences::default(), |p| {
                            p.reference_tool_threads.push(format!("thread-{n}"));
                        })
                        .unwrap();
                })
            })
            .collect::<Vec<_>>();
        for worker in workers {
            worker.join().unwrap();
        }
        let latest = store.load().unwrap().unwrap();
        assert_eq!(latest.reference_tool_threads.len(), 16);
    }
    #[test]
    fn moved_directory_does_not_redirect_a_retained_preference_store() {
        use std::os::unix::fs::DirBuilderExt;
        let tmp = tempfile::tempdir().unwrap();
        let store = PreferencesStore::open(tmp.path()).unwrap();
        store.initialize(&Preferences::default()).unwrap();
        let original = tmp.path().join("computa-state");
        let moved = tmp.path().join("retained");
        std::fs::rename(&original, &moved).unwrap();
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&original)
            .unwrap();
        assert!(
            store
                .update_runtime(&Preferences::default(), |p| p.access_mode =
                    AccessMode::FullAccess)
                .is_err()
        );
        assert_eq!(std::fs::read_dir(&original).unwrap().count(), 0);
        assert!(moved.join("preferences-v1.json").is_file());
    }
}
