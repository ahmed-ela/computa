//! Chrome-owned stdio relay. No buffering across disconnected app generations.
use crate::{BrowserError, framing, identity};
use computa_contracts::chrome::{APP_IDENTIFIER, EXTENSION_ID};
use std::{
    io,
    net::Shutdown,
    os::{fd::AsRawFd, unix::net::UnixStream},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};
pub fn run(origin: &str) -> Result<(), BrowserError> {
    if origin != format!("chrome-extension://{EXTENSION_ID}/") {
        return Err(BrowserError::Identity);
    }
    // SAFETY: getpid only returns the current process ID.
    let parent = identity::parent_pid(unsafe { libc::getpid() })?;
    identity::validate_code(parent, "com.google.Chrome", Some("EQHXZ8M8AV"))?;
    let directory = identity::default_directory()?;
    identity::prepare_directory(&directory)?;
    let current: Arc<Mutex<Option<Arc<UnixStream>>>> = Arc::new(Mutex::new(None));
    let stdout = Arc::new(Mutex::new(io::stdout()));
    let reader_current = current.clone();
    thread::spawn(move || {
        let mut stdin = io::stdin();
        while let Ok(Some(payload)) = framing::read_frame(&mut stdin) {
            if let Some(peer) = reader_current.lock().unwrap().clone() {
                let mut output = &*peer;
                if framing::write_frame(&mut output, &payload).is_err() {
                    let _ = peer.shutdown(Shutdown::Both);
                }
            }
        }
        if let Some(peer) = reader_current.lock().unwrap().take() {
            let _ = peer.shutdown(Shutdown::Both);
        }
        std::process::exit(0);
    });
    loop {
        // SAFETY: getppid has no pointer parameters and its result is compared with the initially authenticated parent.
        if unsafe { libc::getppid() } != parent {
            return Err(BrowserError::Identity);
        }
        identity::validate_code(parent, "com.google.Chrome", Some("EQHXZ8M8AV"))?;
        if let Ok(stream) = UnixStream::connect(directory.join("bridge.sock")) {
            let app_pid = identity::peer_pid(stream.as_raw_fd())?;
            identity::validate_code(app_pid, APP_IDENTIFIER, None)?;
            stream
                .set_write_timeout(Some(Duration::from_secs(3)))
                .map_err(|_| BrowserError::Unavailable)?;
            let peer = Arc::new(stream);
            *current.lock().unwrap() = Some(peer.clone());
            framing::write_frame(
                &mut *stdout.lock().unwrap(),
                br#"{"version":1,"event":"requestHello"}"#,
            )?;
            let mut input = &*peer;
            while let Ok(Some(payload)) = framing::read_frame(&mut input) {
                framing::write_frame(&mut *stdout.lock().unwrap(), &payload)?;
            }
            let mut lock = current.lock().unwrap();
            if lock.as_ref().is_some_and(|old| Arc::ptr_eq(old, &peer)) {
                *lock = None;
            }
            drop(lock);
            let _ = peer.shutdown(Shutdown::Both);
            framing::write_frame(
                &mut *stdout.lock().unwrap(),
                br#"{"version":1,"event":"appDisconnected"}"#,
            )?;
        }
        thread::sleep(Duration::from_secs(2));
    }
}
