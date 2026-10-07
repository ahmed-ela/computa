//! Development-only actual runtime qualifier; never included in a release bundle.
fn main() {
    #[cfg(target_os = "macos")]
    {
        let result = (|| -> std::io::Result<()> {
            let executable = std::env::current_exe()?;
            let contents = executable
                .parent()
                .and_then(|p| p.parent())
                .ok_or_else(|| std::io::Error::other("Qualifier bundle is unavailable"))?;
            if contents.file_name().is_none_or(|name| name != "Contents") {
                return Err(std::io::Error::other(
                    "Launch the dedicated qualifier bundle",
                ));
            }
            let directory = contents
                .parent()
                .and_then(|p| p.parent())
                .ok_or_else(|| std::io::Error::other("Qualifier directory is unavailable"))?;
            computa_desktop::native::run_with_options(computa_desktop::native::Options {
                resources: contents.join("Resources"),
                private_home: Some(directory.join("desktop-runtime-private")),
                fixture: false,
                inference_port: Some(32137),
            })
        })();
        if let Err(error) = result {
            eprintln!("Computa runtime qualification failed: {error}");
            std::process::exit(1);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("Runtime qualification requires macOS");
        std::process::exit(1);
    }
}
