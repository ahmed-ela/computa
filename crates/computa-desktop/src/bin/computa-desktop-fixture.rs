//! Development-only UI qualifier. This binary is never copied into the product.
fn main() {
    #[cfg(target_os = "macos")]
    {
        let result = (|| -> std::io::Result<()> {
            let executable = std::env::current_exe()?;
            let contents = executable
                .parent()
                .and_then(|p| p.parent())
                .ok_or_else(|| std::io::Error::other("Fixture bundle is unavailable"))?;
            if contents.file_name().is_none_or(|name| name != "Contents") {
                return Err(std::io::Error::other(
                    "Launch the dedicated fixture app bundle",
                ));
            }
            let directory = contents
                .parent()
                .and_then(|p| p.parent())
                .ok_or_else(|| std::io::Error::other("Fixture directory is unavailable"))?;
            computa_desktop::native::run_with_options(computa_desktop::native::Options {
                resources: contents.join("Resources"),
                private_home: Some(directory.join(format!("ui-private-{}", uuid::Uuid::new_v4()))),
                fixture: true,
                inference_port: None,
            })
        })();
        if let Err(error) = result {
            eprintln!("Computa UI qualification failed: {error}");
            std::process::exit(1);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        eprintln!("UI qualification requires macOS");
        std::process::exit(1);
    }
}
