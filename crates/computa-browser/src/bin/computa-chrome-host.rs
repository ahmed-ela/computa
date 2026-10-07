fn main() {
    // SAFETY: ignoring SIGPIPE is process-local and prevents a disconnected peer from terminating a framed write.
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let arguments: Vec<_> = std::env::args().collect();
    if arguments.len() != 2 || computa_browser::relay::run(&arguments[1]).is_err() {
        std::process::exit(1);
    }
}
