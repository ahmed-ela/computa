//! Inert, loopback-only lookup surfaces. Evaluator manifests, native fixtures,
//! oracle files, and repository paths are outside the exact page allowlist.
use super::*;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
};
const PAGES: [&str; 16] = [
    "archive.html",
    "sidebar.html",
    "toolbar.html",
    "document.html",
    "email.html",
    "no-landmarks.html",
    "long-field.html",
    "continued-field.html",
    "virtualized.html",
    "meridian-home.html",
    "meridian-search.html",
    "meridian-results.html",
    "meridian-record.html",
    "lumen-home.html",
    "lumen-results.html",
    "lumen-record.html",
];
const POLICY: &str = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; base-uri 'none'";
const MAX_PAGE: usize = 1024 * 1024;
fn load(directory: &Path) -> Result<HashMap<&'static str, Vec<u8>>> {
    ensure(
        directory.is_absolute(),
        "absolute_lookup_fixture_directory_required",
    )?;
    let meta = std::fs::symlink_metadata(directory)
        .map_err(|_| BenchmarkError("lookup_fixture_directory_missing"))?;
    ensure(
        meta.is_dir() && !meta.file_type().is_symlink(),
        "lookup_fixture_directory_invalid",
    )?;
    let mut pages = HashMap::new();
    for name in PAGES {
        let bytes = read(&directory.join(name))?;
        ensure(bytes.len() <= MAX_PAGE, "lookup_page_exceeds_bound")?;
        ensure(
            std::str::from_utf8(&bytes).is_ok(),
            "lookup_page_invalid_utf8",
        )?;
        pages.insert(name, bytes);
    }
    Ok(pages)
}
fn response(method: &str, target: &str, pages: &HashMap<&str, Vec<u8>>) -> Vec<u8> {
    let (status, body, html) = if !matches!(method, "GET" | "HEAD") {
        (405, "Method not allowed".as_bytes(), false)
    } else if let Some(body) = target
        .split('?')
        .next()
        .and_then(|path| path.strip_prefix('/'))
        .and_then(|name| pages.get(name))
    {
        (200, body.as_slice(), true)
    } else {
        (404, "Not found".as_bytes(), false)
    };
    let reason = match status {
        200 => "OK",
        405 => "Method Not Allowed",
        _ => "Not Found",
    };
    let mut output = format!(
        "HTTP/1.1 {status} {reason}\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    );
    if html {
        output.push_str(&format!("Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: {POLICY}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"));
    } else {
        output.push_str("Content-Type: text/plain; charset=utf-8\r\n");
    }
    output.push_str("\r\n");
    let mut bytes = output.into_bytes();
    if method != "HEAD" {
        bytes.extend_from_slice(body);
    }
    bytes
}
async fn connection(mut stream: TcpStream, pages: Arc<HashMap<&'static str, Vec<u8>>>) {
    let _ = tokio::time::timeout(Duration::from_secs(3), async {
        let mut header = vec![];
        let mut chunk = [0u8; 1024];
        loop {
            let count = stream.read(&mut chunk).await?;
            if count == 0 {
                return Ok::<_, std::io::Error>(());
            }
            header.extend_from_slice(&chunk[..count]);
            if header.len() > 8192 {
                return Ok(());
            }
            if header.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
                break;
            }
        }
        let text = match std::str::from_utf8(&header) {
            Ok(text) => text,
            Err(_) => return Ok(()),
        };
        let Some(line) = text.split("\r\n").next() else {
            return Ok(());
        };
        let mut fields = line.split(' ');
        let (Some(method), Some(target), Some(version), None) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            return Ok(());
        };
        if !matches!(version, "HTTP/1.1" | "HTTP/1.0")
            || !target.starts_with('/')
            || target.len() > 2048
            || target.chars().any(char::is_control)
        {
            return Ok(());
        }
        stream.write_all(&response(method, target, &pages)).await?;
        stream.shutdown().await
    })
    .await;
}
/// Runs only on 127.0.0.1, with 32 bounded connections. Ctrl-C closes the server;
/// it neither opens a browser nor runs a model evaluation.
pub async fn serve_lookup_fixtures(directory: &Path, port: u16) -> Result<()> {
    ensure(port >= 1024, "lookup_port_must_be_1024_through_65535")?;
    let pages = Arc::new(load(directory)?);
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .await
        .map_err(|_| BenchmarkError("lookup_loopback_bind_failed"))?;
    let permits = Arc::new(Semaphore::new(32));
    let mut connections = tokio::task::JoinSet::new();
    println!("Synthetic lookup fixtures: http://127.0.0.1:{port}/archive.html");
    println!("Inputs only; no model evaluation has run. Stop this process when finished.");
    loop {
        tokio::select! {
            _=tokio::signal::ctrl_c()=>break,
            Some(_)=connections.join_next(), if !connections.is_empty()=>{},
            accepted=listener.accept()=>{
                let (stream,peer)=accepted.map_err(|_|BenchmarkError("lookup_accept_failed"))?;
                if !peer.ip().is_loopback(){continue;}
                let Ok(permit)=permits.clone().try_acquire_owned() else {continue;};let pages=pages.clone();
                connections.spawn(async move{let _permit=permit;connection(stream,pages).await;});
            }
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn allowlist_never_serves_manifest_or_path_traversal() {
        let pages = HashMap::from([("archive.html", b"<h1>inert</h1>".to_vec())]);
        for target in [
            "/manifest.json",
            "/native-read.txt",
            "/../manifest.json",
            "//archive.html",
            "/%61rchive.html",
            "/archive.html/extra",
        ] {
            assert!(response("GET", target, &pages).starts_with(b"HTTP/1.1 404"));
        }
        let good = response("GET", "/archive.html?search=anything", &pages);
        assert!(good.starts_with(b"HTTP/1.1 200"));
        assert!(std::str::from_utf8(&good).unwrap().contains(POLICY));
        assert!(good.ends_with(b"<h1>inert</h1>"));
        assert!(!response("HEAD", "/archive.html", &pages).ends_with(b"<h1>inert</h1>"));
        assert!(response("POST", "/archive.html", &pages).starts_with(b"HTTP/1.1 405"));
    }
    #[test]
    fn complete_lookup_fixture_inventory_is_checked_before_listening() {
        let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("Benchmarks/LookupComparison/fixtures");
        assert_eq!(load(&directory).unwrap().len(), 16);
        let temp = tempfile::tempdir().unwrap();
        assert!(load(temp.path()).is_err());
    }
}
