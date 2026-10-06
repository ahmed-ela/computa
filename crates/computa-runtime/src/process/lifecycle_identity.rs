//! Retained native identity for the explicit owned-supervisor crash probe.
//! No bare PID, serialized receipt, or arbitrary discovered process is adopted.
use super::ProcessError;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

pub struct OwnedDescendant {
    identity: Identity,
    stop: tokio::sync::Mutex<Option<Result<(), String>>>,
}
#[derive(PartialEq, Eq)]
struct Identity {
    pid: i32,
    parent: i32,
    group: u32,
    uid: u32,
    start: (u64, u64),
    executable: PathBuf,
    argv: Vec<String>,
}
enum Presence {
    Living,
    Gone,
    Changed,
}
impl OwnedDescendant {
    pub fn pid(&self) -> i32 {
        self.identity.pid
    }
    pub fn start_time(&self) -> (u64, u64) {
        self.identity.start
    }
    pub fn matches_current(&self) -> Result<bool, ProcessError> {
        Ok(matches!(presence(&self.identity)?, Presence::Living))
    }
    /// Recheck birth, UID, group, executable and full argv before every signal.
    /// Reparenting after the original supervisor crash does not grant ownership
    /// of any replacement. A changed identity is reported without signaling it.
    pub async fn stop_for_lifecycle_probe(&self) -> Result<(), ProcessError> {
        let mut stopped = self.stop.lock().await;
        if let Some(result) = stopped.as_ref() {
            return result.clone().map_err(|_| ProcessError::CleanupUnverified);
        }
        let result = self.stop_inner().await;
        *stopped = Some(result.as_ref().map(|_| ()).map_err(ToString::to_string));
        result
    }
    async fn stop_inner(&self) -> Result<(), ProcessError> {
        for signal in [libc::SIGTERM, libc::SIGKILL] {
            match presence(&self.identity)? {
                Presence::Gone => return Ok(()),
                Presence::Changed => return Err(ProcessError::CleanupUnverified),
                Presence::Living => {}
            }
            // SAFETY: the positive PID is the captured direct child and the
            // complete current kernel identity was just revalidated above.
            if unsafe { libc::kill(self.identity.pid, signal) } != 0 {
                let error = std::io::Error::last_os_error();
                if error.raw_os_error() != Some(libc::ESRCH) {
                    return Err(error.into());
                }
            }
            let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
            loop {
                match presence(&self.identity)? {
                    Presence::Gone => return Ok(()),
                    Presence::Changed => return Err(ProcessError::CleanupUnverified),
                    Presence::Living => {}
                }
                if tokio::time::Instant::now() >= deadline {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
        Err(ProcessError::CleanupUnverified)
    }
}
pub(super) fn capture(
    parent: i32,
    pid: i32,
    executable: &Path,
    arguments: &[String],
) -> Result<OwnedDescendant, ProcessError> {
    if pid <= 0 || pid == parent || !executable.is_absolute() {
        return Err(ProcessError::CleanupUnverified);
    }
    let executable = std::fs::canonicalize(executable)?;
    let identity = identity(pid)?.ok_or(ProcessError::CleanupUnverified)?;
    if identity.parent != parent
        || identity.executable != executable
        || identity.argv.len() != arguments.len() + 1
        || identity.argv[1..] != *arguments
        || std::fs::canonicalize(&identity.argv[0])? != executable
    {
        return Err(ProcessError::CleanupUnverified);
    }
    if !matches!(presence(&identity)?, Presence::Living) {
        return Err(ProcessError::CleanupUnverified);
    }
    Ok(OwnedDescendant {
        identity,
        stop: tokio::sync::Mutex::new(None),
    })
}

#[cfg(target_os = "macos")]
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
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn proc_pidinfo(
        pid: i32,
        flavor: i32,
        arg: u64,
        buffer: *mut std::ffi::c_void,
        size: i32,
    ) -> i32;
    fn proc_pidpath(pid: i32, buffer: *mut std::ffi::c_void, size: u32) -> i32;
}
#[cfg(target_os = "macos")]
fn bsd(pid: i32) -> Result<Option<BsdInfo>, ProcessError> {
    // SAFETY: the ABI structure contains only integers and byte arrays.
    let mut value: BsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<BsdInfo>() as i32;
    // SAFETY: the output buffer is writable and exactly the documented size.
    let result = unsafe { proc_pidinfo(pid, 3, 0, (&mut value as *mut BsdInfo).cast(), size) };
    if result == 0 {
        let error = std::io::Error::last_os_error();
        return if matches!(error.raw_os_error(), Some(libc::ESRCH | libc::ENOENT)) {
            Ok(None)
        } else {
            Err(error.into())
        };
    }
    // SAFETY: geteuid has no memory preconditions.
    let uid = unsafe { libc::geteuid() };
    if result != size
        || value.pid != pid as u32
        || value.uid != uid
        || value.start_tvsec == 0
        || value.start_tvusec >= 1_000_000
    {
        return Err(ProcessError::CleanupUnverified);
    }
    Ok(Some(value))
}
#[cfg(target_os = "macos")]
fn argv(pid: i32) -> Result<Vec<String>, ProcessError> {
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut bytes = vec![0u8; 1_048_576];
    let mut length = bytes.len();
    // SAFETY: both kernel query buffers are valid and bounded; environment
    // bytes are never returned and are wiped immediately after argv parsing.
    let status = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            bytes.as_mut_ptr().cast(),
            &mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    let parsed = (|| {
        if status != 0 || length < 4 || length > bytes.len() {
            return None;
        }
        let count = u32::from_ne_bytes(bytes[..4].try_into().ok()?) as usize;
        if count == 0 || count > 4096 {
            return None;
        }
        let mut cursor = 4 + bytes[4..length].iter().position(|b| *b == 0)? + 1;
        while cursor < length && bytes[cursor] == 0 {
            cursor += 1
        }
        let mut values = Vec::with_capacity(count);
        for _ in 0..count {
            if cursor >= length {
                return None;
            }
            let end = cursor + bytes[cursor..length].iter().position(|b| *b == 0)?;
            values.push(std::str::from_utf8(&bytes[cursor..end]).ok()?.to_owned());
            cursor = end + 1;
        }
        Some(values)
    })();
    bytes.fill(0);
    parsed.ok_or(ProcessError::CleanupUnverified)
}
#[cfg(target_os = "macos")]
fn identity(pid: i32) -> Result<Option<Identity>, ProcessError> {
    let Some(before) = bsd(pid)? else {
        return Ok(None);
    };
    if before.status == 5 {
        return Ok(None);
    } // a zombie cannot retain model memory or serve requests
    let mut path = [0u8; 4096];
    // SAFETY: proc_pidpath receives a valid bounded output buffer.
    let size = unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    if size <= 0 || size as usize > path.len() {
        return Err(ProcessError::CleanupUnverified);
    }
    let end = path
        .iter()
        .position(|b| *b == 0)
        .ok_or(ProcessError::CleanupUnverified)?;
    let executable = std::fs::canonicalize(
        std::str::from_utf8(&path[..end]).map_err(|_| ProcessError::CleanupUnverified)?,
    )?;
    let argv = argv(pid)?;
    let Some(after) = bsd(pid)? else {
        return Ok(None);
    };
    if before.start_tvsec != after.start_tvsec
        || before.start_tvusec != after.start_tvusec
        || before.uid != after.uid
        || before.pgid != after.pgid
        || before.ppid != after.ppid
    {
        return Err(ProcessError::CleanupUnverified);
    }
    Ok(Some(Identity {
        pid,
        parent: after.ppid as i32,
        group: after.pgid,
        uid: after.uid,
        start: (after.start_tvsec, after.start_tvusec),
        executable,
        argv,
    }))
}
#[cfg(target_os = "macos")]
fn presence(expected: &Identity) -> Result<Presence, ProcessError> {
    let Some(current) = bsd(expected.pid)? else {
        return Ok(Presence::Gone);
    };
    if (current.start_tvsec, current.start_tvusec) != expected.start
        || current.uid != expected.uid
        || current.pgid != expected.group
    {
        return Ok(Presence::Changed);
    }
    if current.status == 5 {
        return Ok(Presence::Gone);
    }
    let observed = match identity(expected.pid) {
        Ok(Some(observed)) => observed,
        Ok(None) => return Ok(Presence::Gone),
        Err(error) => {
            // Exit may race proc_pidpath/argv after the first BSD snapshot.
            // Only a second kernel birth check can turn that read failure
            // into a terminal receipt; unreadable living identities fail.
            let Some(after) = bsd(expected.pid)? else {
                return Ok(Presence::Gone);
            };
            if (after.start_tvsec, after.start_tvusec) != expected.start
                || after.uid != expected.uid
                || after.pgid != expected.group
            {
                return Ok(Presence::Changed);
            }
            if after.status == 5 {
                return Ok(Presence::Gone);
            }
            return Err(error);
        }
    };
    Ok(
        if observed.start == expected.start
            && observed.uid == expected.uid
            && observed.group == expected.group
            && observed.executable == expected.executable
            && observed.argv == expected.argv
        {
            Presence::Living
        } else {
            Presence::Changed
        },
    )
}
#[cfg(not(target_os = "macos"))]
fn identity(_pid: i32) -> Result<Option<Identity>, ProcessError> {
    Err(ProcessError::CleanupUnverified)
}
#[cfg(not(target_os = "macos"))]
fn presence(_identity: &Identity) -> Result<Presence, ProcessError> {
    Err(ProcessError::CleanupUnverified)
}
