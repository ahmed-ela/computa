use crate::runtime_source::{path, run};
use std::{
    fs, io,
    path::{Path, PathBuf},
};
pub fn build_web(root: &Path, wasm_bindgen: &str, release: bool) -> io::Result<PathBuf> {
    let target = root.join("target");
    let profile = if release { "release" } else { "debug" };
    let mut args = vec![
        "build",
        "--locked",
        "--target",
        "wasm32-unknown-unknown",
        "--target-dir",
        path(&target)?,
        "-p",
        "computa-ui",
    ];
    if release {
        args.push("--release");
    }
    run("cargo", &args, root, false)?;
    let output = root.join("target/product-resources");
    for (crate_name, folder) in [("computa_ui", "WebUI")] {
        let destination = output.join(folder);
        fs::create_dir_all(&destination)?;
        let binary = target
            .join("wasm32-unknown-unknown")
            .join(profile)
            .join(format!("{crate_name}.wasm"));
        run(
            wasm_bindgen,
            &[
                "--target",
                "web",
                "--no-typescript",
                "--out-dir",
                path(&destination)?,
                path(&binary)?,
            ],
            root,
            false,
        )?;
    }
    let ui = output.join("WebUI");
    fs::copy(root.join("WebUI/src/styles.css"), ui.join("styles.css"))?;
    fs::write(
        ui.join("index.html"),
        r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; object-src 'none'; form-action 'none'"><link rel="stylesheet" href="styles.css"><title>Computa</title></head><body><div id="root"></div><script type="module" src="bootstrap.js"></script></body></html>"#,
    )?;
    fs::write(
        ui.join("bootstrap.js"),
        "import init from './computa_ui.js';\nawait init();\n",
    )?;
    Ok(output)
}
pub fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Artifact source contains a symlink",
        ));
    }
    if metadata.is_dir() {
        fs::create_dir_all(destination)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            copy_tree(&entry.path(), &destination.join(entry.file_name()))?;
        }
    } else if metadata.is_file() {
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(source, destination)?;
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Artifact source contains a special file",
        ));
    }
    Ok(())
}
pub fn website(root: &Path) -> io::Result<PathBuf> {
    let destination = root.join("target/website");
    fs::create_dir_all(&destination)?;
    fs::copy(
        root.join("Website/public/favicon.svg"),
        destination.join("favicon.svg"),
    )?;
    fs::copy(
        root.join("Website/src/style.css"),
        destination.join("style.css"),
    )?;
    fs::write(
        destination.join("index.html"),
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"icon\" type=\"image/svg+xml\" href=\"/favicon.svg\"><link rel=\"stylesheet\" href=\"style.css\"><title>Computa</title></head><body><div id=\"root\"><img src=\"/favicon.svg\" alt=\"Computa\"></div></body></html>",
    )?;
    Ok(destination)
}
