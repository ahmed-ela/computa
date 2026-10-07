//! The moved worker must use its own verified Metal library, never a build path.
use sha2::{Digest, Sha256};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::{
    fs,
    io::{self, Read},
    path::Path,
};
pub const METAL_SHA256: Option<&str> = option_env!("COMPUTA_BUILT_METAL_SHA256");
pub const METAL_BYTES: Option<&str> = option_env!("COMPUTA_BUILT_METAL_BYTES");
pub fn verify_colocated() -> io::Result<()> {
    let executable = std::env::current_exe()?;
    verify_directory(
        executable
            .parent()
            .ok_or_else(|| io::Error::other("Native worker directory is unavailable"))?,
    )
}
pub fn verify_directory(directory: &Path) -> io::Result<()> {
    let expected = METAL_SHA256
        .ok_or_else(|| io::Error::other("Native MLX build has no compiled Metal resource pin"))?;
    let expected_bytes = METAL_BYTES
        .and_then(|s| s.parse::<u64>().ok())
        .ok_or_else(|| io::Error::other("Native MLX build has no Metal byte pin"))?;
    let path = directory.join("mlx.metallib");
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(&path)
        .map_err(|_| {
            io::Error::other("The native worker Metal library is missing or nonregular")
        })?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != expected_bytes {
        return Err(io::Error::other(
            "The native worker Metal library differs from its build",
        ));
    }
    let mut sha = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    let mut count = 0u64;
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        sha.update(&buffer[..n]);
        count += n as u64;
        if count > expected_bytes {
            return Err(io::Error::other(
                "The native worker Metal library exceeded its build byte pin",
            ));
        }
    }
    let after = file.metadata()?;
    if count != expected_bytes
        || metadata.dev() != after.dev()
        || metadata.ino() != after.ino()
        || metadata.mtime() != after.mtime()
        || metadata.mtime_nsec() != after.mtime_nsec()
        || metadata.ctime() != after.ctime()
        || metadata.ctime_nsec() != after.ctime_nsec()
        || after.len() != count
        || hex::encode(sha.finalize()) != expected
    {
        return Err(io::Error::other(
            "The native worker Metal library differs from its build",
        ));
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn missing_or_substituted_library_is_not_a_build_fallback() {
        let dir = tempfile::tempdir().unwrap();
        assert!(verify_directory(dir.path()).is_err());
        fs::write(dir.path().join("mlx.metallib"), b"MTLBwrong").unwrap();
        assert!(verify_directory(dir.path()).is_err());
    }
}
