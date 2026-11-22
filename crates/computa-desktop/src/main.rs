fn main() {
    #[cfg(target_os = "macos")]
    if let Err(error) = computa_desktop::native::run() {
        eprintln!("Kolmogor could not start: {error}");
        std::process::exit(1);
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("Kolmogor desktop requires macOS.");
        std::process::exit(1);
    }
}
