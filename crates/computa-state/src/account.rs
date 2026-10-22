//! Native account lookup independent of inherited process environment.
use std::path::PathBuf;
pub fn user_home() -> std::io::Result<PathBuf> {
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
            return Err(std::io::Error::other("Native account home is unavailable"));
        }
        // SAFETY: successful getpwuid_r returns a terminated pw_dir pointer inside the still-live buffer.
        let bytes = unsafe { std::ffi::CStr::from_ptr(account.pw_dir) }.to_bytes();
        let home = PathBuf::from(std::ffi::OsStr::from_bytes(bytes));
        if !home.is_absolute() {
            return Err(std::io::Error::other("Native account home is unavailable"));
        }
        return Ok(home);
    }
}
