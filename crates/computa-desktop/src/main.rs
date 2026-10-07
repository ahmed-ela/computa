fn main() {
    #[cfg(target_os = "macos")]
    if let Err(error) = computa_desktop::native::run() {
        eprintln!("Computa could not start: {error}");
        std::process::exit(1);
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("Computa desktop requires macOS.");
        std::process::exit(1);
    }
}
