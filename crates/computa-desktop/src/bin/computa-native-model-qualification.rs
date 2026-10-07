//! Explicit disposable Production Runtime qualification, never production UI.
#[cfg(target_os = "macos")]
#[path = "native_model/mod.rs"]
mod native_model;
#[cfg(target_os = "macos")]
fn main() {
    if let Err(error) = native_model::run() {
        eprintln!("Native model qualification stopped: {error}");
        std::process::exit(1)
    }
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Native model qualification requires macOS");
    std::process::exit(1)
}
