//! Freeze and colocate the exact Metal library emitted by the pinned MLX build.
use sha2::{Digest, Sha256};
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};
fn regular(path: &Path) -> io::Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > 512 * 1024 * 1024
    {
        return Err(io::Error::other(
            "MLX Metal artifact is not a bounded regular file",
        ));
    }
    fs::read(path)
}
fn write_if_changed(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if path.exists() && regular(path)? == bytes {
        return Ok(());
    }
    if fs::symlink_metadata(path).is_ok_and(|m| !m.is_file() || m.file_type().is_symlink()) {
        return Err(io::Error::other(
            "Invalid native build resource destination",
        ));
    }
    fs::write(path, bytes)
}
fn main() {
    println!("cargo:rerun-if-env-changed=DEP_MLXC_METALLIB");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos")
        || env::var("CARGO_CFG_TARGET_ARCH").as_deref() != Ok("aarch64")
        || env::var_os("CARGO_FEATURE_NATIVE_MLX").is_none()
    {
        return;
    }
    let source = PathBuf::from(
        env::var_os("DEP_MLXC_METALLIB").expect("Pinned MLX build must publish its Metal library"),
    );
    let bytes = regular(&source).expect("Read pinned Metal library");
    assert!(
        bytes.starts_with(b"MTLB"),
        "Native MLX artifact must be a Metal library"
    );
    let hash = hex::encode(Sha256::digest(&bytes));
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let profile = out
        .ancestors()
        .nth(3)
        .expect("Cargo profile output directory");
    let resources = profile.join("NativeInferenceResources");
    fs::create_dir_all(&resources).expect("Create native build resource directory");
    let resource_meta = fs::symlink_metadata(&resources).unwrap();
    assert!(
        resource_meta.is_dir() && !resource_meta.file_type().is_symlink(),
        "Native build resource directory is not regular"
    );
    let library = resources.join("mlx.metallib");
    let manifest = resources.join("manifest.json");
    let metadata = format!(
        "{{\"schemaVersion\":1,\"backend\":\"mlex-0.1.3\",\"file\":\"mlx.metallib\",\"bytes\":{},\"sha256\":\"{hash}\"}}\n",
        bytes.len()
    );
    write_if_changed(&library, &bytes).expect("Colocate native Metal library");
    write_if_changed(&manifest, metadata.as_bytes()).expect("Write native Metal resource pin");
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", library.display());
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rustc-env=COMPUTA_BUILT_METAL_SHA256={hash}");
    println!("cargo:rustc-env=COMPUTA_BUILT_METAL_BYTES={}", bytes.len());
}
