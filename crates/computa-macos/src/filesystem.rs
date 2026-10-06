//! Narrow native publication boundary. Callers supply a fresh staging directory
//! and an explicit destination; publication never replaces an existing entry.
use std::{io, path::Path};

#[cfg(not(target_os = "macos"))]
pub fn rename_directory_exclusive(_source: &Path, _destination: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Exclusive native directory publication requires macOS",
    ))
}
#[cfg(target_os = "macos")]
pub fn rename_directory_exclusive(source: &Path, destination: &Path) -> io::Result<()> {
    use std::{
        ffi::CString,
        fs::{self, OpenOptions},
        os::{
            fd::AsRawFd,
            unix::{
                ffi::OsStrExt,
                fs::{MetadataExt, OpenOptionsExt},
            },
        },
    };
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "Publication requires exact regular directories under the same canonical parent",
        )
    };
    if !source.is_absolute() || !destination.is_absolute() || source == destination {
        return Err(invalid());
    }
    let parent = source.parent().ok_or_else(invalid)?;
    if destination.parent() != Some(parent) || parent.canonicalize()? != parent {
        return Err(invalid());
    }
    let before = fs::symlink_metadata(parent)?;
    if !before.is_dir() || before.file_type().is_symlink() {
        return Err(invalid());
    }
    let parent_handle = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(parent)?;
    let opened = parent_handle.metadata()?;
    if before.dev() != opened.dev() || before.ino() != opened.ino() {
        return Err(invalid());
    }
    let source_meta = fs::symlink_metadata(source)?;
    if !source_meta.is_dir() || source_meta.file_type().is_symlink() {
        return Err(invalid());
    }
    let source_handle = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(source)?;
    let source_opened = source_handle.metadata()?;
    if source_meta.dev() != source_opened.dev() || source_meta.ino() != source_opened.ino() {
        return Err(invalid());
    }
    match fs::symlink_metadata(destination) {
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "Publication destination already exists",
            ));
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    let source_name =
        CString::new(source.file_name().ok_or_else(invalid)?.as_bytes()).map_err(|_| invalid())?;
    let destination_name = CString::new(destination.file_name().ok_or_else(invalid)?.as_bytes())
        .map_err(|_| invalid())?;
    // SAFETY: both NUL-terminated leaf names are relative to the same retained
    // live directory descriptor. RENAME_EXCL atomically refuses every existing
    // destination. No pointer outlives this call; the moved inode is verified
    // against the retained source handle before success is reported.
    let result = unsafe {
        libc::renameatx_np(
            parent_handle.as_raw_fd(),
            source_name.as_ptr(),
            parent_handle.as_raw_fd(),
            destination_name.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    let published = fs::symlink_metadata(destination)?;
    let current_parent = fs::symlink_metadata(parent)?;
    if !published.is_dir()
        || published.file_type().is_symlink()
        || published.dev() != source_opened.dev()
        || published.ino() != source_opened.ino()
        || current_parent.dev() != opened.dev()
        || current_parent.ino() != opened.ino()
    {
        // An unexpected concurrent rename is unverified. Do not delete or
        // roll back a destination whose identity no longer belongs to us.
        return Err(io::Error::other(
            "Exclusive directory publication ownership could not be verified",
        ));
    }
    parent_handle.sync_all()
}
#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    #[test]
    fn exclusive_publication_moves_the_exact_directory_and_never_replaces() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let source = root.join("staging");
        let destination = root.join("installed");
        std::fs::create_dir(&source).unwrap();
        std::fs::write(source.join("proof"), b"exact").unwrap();
        rename_directory_exclusive(&source, &destination).unwrap();
        assert!(!source.exists());
        assert_eq!(std::fs::read(destination.join("proof")).unwrap(), b"exact");
        std::fs::create_dir(&source).unwrap();
        assert_eq!(
            rename_directory_exclusive(&source, &destination)
                .unwrap_err()
                .kind(),
            io::ErrorKind::AlreadyExists
        );
        assert!(source.is_dir());
        assert_eq!(std::fs::read(destination.join("proof")).unwrap(), b"exact");
    }
    #[test]
    fn links_and_different_parents_cannot_select_a_publication() {
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let source = root.join("staging");
        std::fs::create_dir(&source).unwrap();
        let alias = root.join("alias");
        symlink(&source, &alias).unwrap();
        assert!(rename_directory_exclusive(&alias, &root.join("installed")).is_err());
        let other = root.join("other");
        std::fs::create_dir(&other).unwrap();
        assert!(rename_directory_exclusive(&source, &other.join("installed")).is_err());
        let destination = root.join("installed");
        symlink(&source, &destination).unwrap();
        assert_eq!(
            rename_directory_exclusive(&source, &destination)
                .unwrap_err()
                .kind(),
            io::ErrorKind::AlreadyExists
        );
        assert!(source.is_dir());
    }
}
