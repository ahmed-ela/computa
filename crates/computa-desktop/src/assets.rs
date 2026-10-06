//! The privileged view serves a fixed private resource origin. Its navigation,
//! frame, media, file and network authority is independent of the human browser.
use std::{fs, io, path::PathBuf};
pub const UI_DOCUMENT: &str = "computaui://app/index.html";
pub const UI_CSP: &str = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";
const MAX_ASSET: u64 = 16 * 1024 * 1024;
#[derive(Clone)]
pub struct Assets {
    root: PathBuf,
}
impl Assets {
    pub fn open(root: PathBuf) -> io::Result<Self> {
        let metadata = fs::symlink_metadata(&root)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "UI resources must be a real directory",
            ));
        }
        Ok(Self {
            root: root.canonicalize()?,
        })
    }
    pub fn read(&self, uri: &str) -> io::Result<(&'static str, Vec<u8>)> {
        if uri.contains('%') || uri.split('/').any(|part| part == ".." || part == ".") {
            return Err(invalid("Encoded or relative UI resource path"));
        }
        let url = url::Url::parse(uri).map_err(invalid)?;
        if url.scheme() != "computaui"
            || url.host_str() != Some("app")
            || url.port().is_some()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(invalid("UI resource origin"));
        }
        let mut path = self.root.clone();
        for part in url.path().trim_start_matches('/').split('/') {
            if part.is_empty()
                || part.starts_with('.')
                || !part
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
            {
                return Err(invalid("UI resource path"));
            }
            path.push(part);
            let metadata = fs::symlink_metadata(&path)?;
            if metadata.file_type().is_symlink() {
                return Err(invalid("UI resource symlink"));
            }
        }
        let metadata = fs::symlink_metadata(&path)?;
        if !metadata.is_file()
            || metadata.len() > MAX_ASSET
            || !path.canonicalize()?.starts_with(&self.root)
        {
            return Err(invalid("UI resource file"));
        }
        let mime = match path.extension().and_then(|s| s.to_str()) {
            Some("html") => "text/html; charset=utf-8",
            Some("js") => "text/javascript; charset=utf-8",
            Some("css") => "text/css; charset=utf-8",
            Some("wasm") => "application/wasm",
            Some("png") => "image/png",
            Some("svg") => "image/svg+xml",
            Some("woff2") => "font/woff2",
            _ => return Err(invalid("UI resource kind")),
        };
        let bytes = fs::read(path)?;
        if bytes.len() as u64 > MAX_ASSET {
            return Err(invalid("UI resource size changed"));
        }
        Ok((mime, bytes))
    }
}
pub fn accepts_ipc(origin: &str, body: &str, blocked: bool) -> bool {
    !blocked
        && origin == UI_DOCUMENT
        && !body.is_empty()
        && body.len() <= 256 * 1024
        && !body.contains('\0')
}
fn invalid(error: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error.to_string())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn asset_origin_encoded_paths_and_symlinks_cannot_read_files() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("index.html"), b"ok").unwrap();
        let assets = Assets::open(temp.path().into()).unwrap();
        assert_eq!(assets.read(UI_DOCUMENT).unwrap().1, b"ok");
        for uri in [
            "https://app/index.html",
            "computaui://elsewhere/index.html",
            "computaui://app/index.html?x=1",
            "computaui://user@app/index.html",
            "computaui://app/%2e%2e/private",
            "computaui://app/%2fetc/passwd",
            "computaui://app/.hidden",
        ] {
            assert!(assets.read(uri).is_err(), "{uri}");
        }
        std::os::unix::fs::symlink("index.html", temp.path().join("alias.html")).unwrap();
        assert!(assets.read("computaui://app/alias.html").is_err());
    }
    #[test]
    fn exact_document_and_native_sheet_fence_every_page_action() {
        for origin in [
            "https://claude.ai/",
            "computaui://app/other.html",
            "about:blank",
            "",
        ] {
            assert!(!accepts_ipc(origin, "{}", false));
        }
        assert!(!accepts_ipc(UI_DOCUMENT, "{}", true));
        assert!(accepts_ipc(UI_DOCUMENT, "{}", false));
    }
}
