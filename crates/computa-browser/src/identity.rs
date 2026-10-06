use crate::BrowserError;
use computa_contracts::chrome::{APP_IDENTIFIER, HOST_IDENTIFIER};
use std::{
    os::fd::RawFd,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};
#[derive(Debug, Clone, Copy)]
pub struct VerifiedPeer {
    pub helper_pid: i32,
    pub chrome_pid: i32,
}
pub trait PeerVerifier: Send + Sync {
    fn verify_host(&self, fd: RawFd) -> Result<VerifiedPeer, BrowserError>;
    fn verify_chrome(&self, pid: i32) -> Result<(), BrowserError>;
}
pub struct ApplePeerVerifier;
impl PeerVerifier for ApplePeerVerifier {
    fn verify_host(&self, fd: RawFd) -> Result<VerifiedPeer, BrowserError> {
        let helper_pid = peer_pid(fd)?;
        validate_code(helper_pid, HOST_IDENTIFIER, None)?;
        let chrome_pid = parent_pid(helper_pid)?;
        self.verify_chrome(chrome_pid)?;
        Ok(VerifiedPeer {
            helper_pid,
            chrome_pid,
        })
    }
    fn verify_chrome(&self, pid: i32) -> Result<(), BrowserError> {
        validate_code(pid, "com.google.Chrome", Some("EQHXZ8M8AV"))
    }
}
pub fn default_directory() -> Result<PathBuf, BrowserError> {
    Ok(user_home()?.join("Library/Application Support/LocalCodex/BrowserBridge"))
}
pub fn user_home() -> Result<PathBuf, BrowserError> {
    use std::os::unix::ffi::OsStrExt;
    let mut capacity = 16_384;
    loop {
        let mut buffer = vec![0u8; capacity];
        // SAFETY: passwd contains only integer and pointer fields, all valid initialized to zero before libc fills it.
        let mut account: libc::passwd = unsafe { std::mem::zeroed() };
        let mut result = std::ptr::null_mut();
        // SAFETY: account and result are writable outputs; buffer remains live for all returned account string pointers.
        let status = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                &mut account,
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                &mut result,
            )
        };
        if status == libc::ERANGE && capacity < 1_048_576 {
            capacity *= 2;
            continue;
        }
        if status != 0 || result.is_null() || account.pw_dir.is_null() {
            return Err(BrowserError::Identity);
        }
        // SAFETY: successful getpwuid_r returns a terminated pw_dir pointer inside the still-live buffer.
        let bytes = unsafe { std::ffi::CStr::from_ptr(account.pw_dir) }.to_bytes();
        let home = PathBuf::from(std::ffi::OsStr::from_bytes(bytes));
        if !home.is_absolute() {
            return Err(BrowserError::Identity);
        }
        return Ok(home);
    }
}
pub fn prepare_directory(directory: &Path) -> Result<(), BrowserError> {
    match std::fs::symlink_metadata(directory) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(directory).map_err(|_| BrowserError::Configuration)?;
            std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| BrowserError::Configuration)?;
        }
        Err(_) => return Err(BrowserError::Identity),
    }
    let info = std::fs::symlink_metadata(directory).map_err(|_| BrowserError::Identity)?;
    // SAFETY: getuid has no arguments or preconditions.
    let uid = unsafe { libc::getuid() };
    if !info.file_type().is_dir() || info.uid() != uid || info.mode() & 0o077 != 0 {
        return Err(BrowserError::Identity);
    }
    Ok(())
}
#[cfg(target_os = "macos")]
pub fn peer_pid(fd: RawFd) -> Result<i32, BrowserError> {
    let (mut uid, mut gid, mut pid) = (0, 0, 0i32);
    let mut size = std::mem::size_of::<i32>() as libc::socklen_t;
    // SAFETY: each output points to a live scalar and fd is caller-owned.
    let same_uid =
        unsafe { libc::getpeereid(fd, &mut uid, &mut gid) == 0 && uid == libc::getuid() };
    // SAFETY: output and length have correct sizes for LOCAL_PEERPID.
    let peer_status =
        unsafe { libc::getsockopt(fd, 0, 2, (&mut pid as *mut i32).cast(), &mut size) };
    if !same_uid || peer_status != 0 || pid <= 0 {
        return Err(BrowserError::Identity);
    }
    Ok(pid)
}
#[cfg(not(target_os = "macos"))]
pub fn peer_pid(_fd: RawFd) -> Result<i32, BrowserError> {
    Err(BrowserError::Identity)
}
#[cfg(target_os = "macos")]
pub fn parent_pid(pid: i32) -> Result<i32, BrowserError> {
    #[repr(C)]
    struct BsdInfo {
        flags: u32,
        status: u32,
        xstatus: u32,
        pid: u32,
        ppid: u32,
        uid: u32,
        gid: u32,
        ruid: u32,
        rgid: u32,
        svuid: u32,
        svgid: u32,
        reserved: u32,
        comm: [u8; 16],
        name: [u8; 32],
        nfiles: u32,
        pgid: u32,
        pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        nice: i32,
        start_tvsec: u64,
        start_tvusec: u64,
    }
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut std::ffi::c_void,
            size: i32,
        ) -> i32;
    }
    // SAFETY: all struct fields have valid zero representations.
    let mut info: BsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<BsdInfo>() as i32;
    // SAFETY: the output struct has the passed buffer size.
    let result = unsafe { proc_pidinfo(pid, 3, 0, (&mut info as *mut BsdInfo).cast(), size) };
    // SAFETY: getuid has no memory preconditions.
    if result != size || info.uid != unsafe { libc::getuid() } || info.ppid == 0 {
        return Err(BrowserError::Identity);
    }
    Ok(info.ppid as i32)
}
#[cfg(not(target_os = "macos"))]
pub fn parent_pid(_pid: i32) -> Result<i32, BrowserError> {
    Err(BrowserError::Identity)
}
pub fn apple_requirement(identifier: &str, team: &str) -> Result<String, BrowserError> {
    if ![APP_IDENTIFIER, HOST_IDENTIFIER, "com.google.Chrome"].contains(&identifier)
        || team.len() != 10
        || !team
            .bytes()
            .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        return Err(BrowserError::Identity);
    }
    Ok(format!(
        "identifier \"{identifier}\" and anchor apple generic and certificate leaf[subject.OU] = \"{team}\""
    ))
}
#[cfg(target_os = "macos")]
mod apple;
#[cfg(target_os = "macos")]
pub fn validate_code(pid: i32, identifier: &str, team: Option<&str>) -> Result<(), BrowserError> {
    apple::validate(pid, identifier, team)
}
#[cfg(not(target_os = "macos"))]
pub fn validate_code(
    _pid: i32,
    _identifier: &str,
    _team: Option<&str>,
) -> Result<(), BrowserError> {
    Err(BrowserError::Identity)
}
#[cfg(target_os = "macos")]
pub fn pairing_load(installation: &str) -> Result<Option<String>, BrowserError> {
    apple::keychain_load(installation)
}
#[cfg(target_os = "macos")]
pub fn pairing_save(installation: &str, token: &str) -> Result<(), BrowserError> {
    apple::keychain_save(installation, token)
}
#[cfg(target_os = "macos")]
pub fn pairing_forget(installation: &str) -> Result<(), BrowserError> {
    apple::keychain_forget(installation)
}
#[cfg(not(target_os = "macos"))]
pub fn pairing_load(_installation: &str) -> Result<Option<String>, BrowserError> {
    Err(BrowserError::Unavailable)
}
#[cfg(not(target_os = "macos"))]
pub fn pairing_save(_installation: &str, _token: &str) -> Result<(), BrowserError> {
    Err(BrowserError::Unavailable)
}
#[cfg(not(target_os = "macos"))]
pub fn pairing_forget(_installation: &str) -> Result<(), BrowserError> {
    Err(BrowserError::Unavailable)
}
#[cfg(target_os = "macos")]
pub fn verify_current_application() -> Result<(), BrowserError> {
    apple::verify_application()
}
#[cfg(target_os = "macos")]
pub(crate) fn current_application_team() -> Result<String, BrowserError> {
    apple::application_team()
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn current_application_team() -> Result<String, BrowserError> {
    Err(BrowserError::SigningRequired)
}
#[cfg(target_os = "macos")]
pub(crate) fn validate_static_code(
    path: &Path,
    identifier: &str,
    team: &str,
) -> Result<(), BrowserError> {
    apple::validate_static(path, identifier, team)
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn validate_static_code(
    _path: &Path,
    _identifier: &str,
    _team: &str,
) -> Result<(), BrowserError> {
    Err(BrowserError::SigningRequired)
}
#[cfg(not(target_os = "macos"))]
pub fn verify_current_application() -> Result<(), BrowserError> {
    Err(BrowserError::SigningRequired)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn requirement_is_not_injectable_or_ad_hoc() {
        assert!(apple_requirement(APP_IDENTIFIER, "ABCDEFGHIJ").is_ok());
        assert!(apple_requirement("evil", "ABCDEFGHIJ").is_err());
        assert!(apple_requirement(APP_IDENTIFIER, "ad-hoc").is_err());
    }
}
