//! Native macOS automation. Retained native objects never leave the UI thread.
//! Portable observations are values, not capabilities to send input.
pub mod backend;
#[cfg(target_os = "macos")]
pub mod controls;
pub mod coordinates;
pub mod filesystem;
pub use filesystem::rename_directory_exclusive;
#[cfg(target_os = "macos")]
mod native;
pub mod types;
pub use backend::{MacosBackend, NativeBackend};
pub use types::*;

#[cfg(unix)]
pub fn current_user_id() -> u32 {
    // SAFETY: getuid has no arguments and returns the calling process's UID.
    unsafe { libc::getuid() }
}

#[cfg(target_os = "macos")]
pub mod browser_controls;

/// Offscreen benchmark-only pixels and text recognition; no desktop authority.
#[cfg(target_os = "macos")]
pub mod benchmark_image;
/// Explicit disposable native qualification, never a model app selector.
#[cfg(target_os = "macos")]
pub mod qualification_fixture;
