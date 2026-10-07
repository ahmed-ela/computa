//! Owned process-group lifetime. Killing is scoped to the child we spawned.
use std::os::unix::process::CommandExt;
use std::{collections::BTreeMap, io, path::Path, time::Duration};
use tokio::{
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::Mutex,
};
mod lifecycle_identity;
pub use lifecycle_identity::OwnedDescendant;
#[derive(Debug, thiserror::Error)]
pub enum ProcessError {
    #[error("Could not launch Computa's Agent Runtime: {0}")]
    Io(#[from] io::Error),
    #[error("Owned runtime cleanup could not be verified.")]
    CleanupUnverified,
}
pub struct OwnedProcess {
    pid: i32,
    child: Mutex<Child>,
    stop: Mutex<Option<Result<(), String>>>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ObservedExit {
    Exited(i32),
    Signalled(i32),
}
impl std::fmt::Display for ObservedExit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Exited(code) => write!(f, "exit code {code}"),
            Self::Signalled(signal) => write!(f, "signal {signal}"),
        }
    }
}
pub(crate) fn diagnostic_phase(phase: &'static str) {
    if std::env::var("COMPUTA_RUNTIME_DIAGNOSTICS").as_deref() == Ok("1") {
        eprintln!("Computa runtime phase: {phase}");
    }
}
impl OwnedProcess {
    pub fn spawn(
        executable: &Path,
        args: &[String],
        cwd: &Path,
        environment: &BTreeMap<String, String>,
    ) -> Result<(Self, ChildStdin, ChildStdout), ProcessError> {
        let mut command = Command::new(executable);
        command
            .args(args)
            .current_dir(cwd)
            .env_clear()
            .envs(environment)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(false);
        // SAFETY: this pre-exec callback uses only async-signal-safe libc calls,
        // no allocation or locks. It isolates the child's group and signal mask.
        unsafe {
            command.as_std_mut().pre_exec(|| {
                if libc::setpgid(0, 0) != 0 {
                    return Err(io::Error::last_os_error());
                }
                let mut empty: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut empty);
                if libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut()) != 0 {
                    return Err(io::Error::last_os_error());
                }
                for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGPIPE, libc::SIGCHLD] {
                    libc::signal(signal, libc::SIG_DFL);
                }
                Ok(())
            });
        }
        diagnostic_phase("owned process before spawn");
        let mut child = command.spawn()?;
        diagnostic_phase("owned process spawn returned");
        let pid = child.id().ok_or(ProcessError::CleanupUnverified)? as i32;
        let stdin = child.stdin.take().ok_or(ProcessError::CleanupUnverified)?;
        let stdout = child.stdout.take().ok_or(ProcessError::CleanupUnverified)?;
        if let Some(mut stderr) = child.stderr.take() {
            tokio::spawn(async move {
                let mut sink = tokio::io::sink();
                let _ = tokio::io::copy(&mut stderr, &mut sink).await;
            });
        }
        Ok((
            Self {
                pid,
                child: Mutex::new(child),
                stop: Mutex::new(None),
            },
            stdin,
            stdout,
        ))
    }
    pub fn pid(&self) -> i32 {
        self.pid
    }
    /// Capture only a currently living direct descendant of this exact owned
    /// supervisor, matching the native executable and complete offered argv.
    pub async fn capture_descendant_for_lifecycle_probe(
        &self,
        pid: i32,
        executable: &Path,
        arguments: &[String],
    ) -> Result<OwnedDescendant, ProcessError> {
        let stopped = self.stop.lock().await;
        if stopped.is_some() || self.observed_exit()?.is_some() {
            return Err(ProcessError::CleanupUnverified);
        }
        lifecycle_identity::capture(self.pid, pid, executable, arguments)
    }
    /// Observe this exact owned child's terminal status without reaping it.
    /// Group cleanup still runs before wait(), retaining PID reuse protection.
    pub fn observed_exit(&self) -> Result<Option<ObservedExit>, ProcessError> {
        // SAFETY: initialized siginfo buffer is passed to the OS; WNOWAIT
        // explicitly leaves this known child's status available to stop().
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: info is valid writable storage and the requested PID is our
        // unreaped child. WNOWAIT preserves ownership for bounded group cleanup.
        if unsafe {
            libc::waitid(
                libc::P_PID,
                self.pid as libc::id_t,
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        } != 0
        {
            return Err(io::Error::last_os_error().into());
        }
        // SAFETY: waitid populated the SIGCHLD fields; si_pid==0 means that
        // WNOHANG found no terminal child. No signal payload is inspected.
        let observed_pid = unsafe { info.si_pid() };
        if observed_pid == 0 {
            return Ok(None);
        }
        if observed_pid != self.pid {
            return Err(ProcessError::CleanupUnverified);
        }
        // SAFETY: waitid returned SIGCHLD data for the exact owned child, so
        // accessing the status member of that union is valid.
        let status = unsafe { info.si_status() };
        match info.si_code {
            libc::CLD_EXITED if (0..=255).contains(&status) => {
                Ok(Some(ObservedExit::Exited(status)))
            }
            libc::CLD_KILLED | libc::CLD_DUMPED if (1..=127).contains(&status) => {
                Ok(Some(ObservedExit::Signalled(status)))
            }
            _ => Err(ProcessError::CleanupUnverified),
        }
    }
    /// Hard-crash the exact owned supervisor for the explicit parent-death
    /// qualification. Descendant groups are left alone so their parent watcher
    /// is actually exercised. WNOWAIT retains the leader until stop() cleanup.
    pub async fn crash_for_lifecycle_probe(&self) -> Result<ObservedExit, ProcessError> {
        let stopped = self.stop.lock().await;
        if stopped.is_some() {
            return Err(ProcessError::CleanupUnverified);
        }
        if let Some(status) = self.observed_exit()? {
            return Ok(status);
        }
        // SAFETY: this positive PID is our still-unreaped exact child. Holding
        // the stop lock prevents another owner operation from reaping it.
        if unsafe { libc::kill(self.pid, libc::SIGKILL) } != 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error.into());
            }
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = self.observed_exit()? {
                return Ok(status);
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(ProcessError::CleanupUnverified);
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
    pub async fn stop(&self) -> Result<(), ProcessError> {
        let mut stopped = self.stop.lock().await;
        if let Some(result) = stopped.as_ref() {
            return result.clone().map_err(|_| ProcessError::CleanupUnverified);
        }
        let result = self.stop_inner().await;
        *stopped = Some(result.as_ref().map(|_| ()).map_err(ToString::to_string));
        result
    }
    async fn stop_inner(&self) -> Result<(), ProcessError> {
        let term = signal_group(self.pid, libc::SIGTERM);
        tokio::time::sleep(Duration::from_millis(750)).await;
        // Kill the group before reaping the leader, preventing PID reuse between
        // verification and a group signal. No child.wait/try_wait runs earlier.
        let killed = signal_group(self.pid, libc::SIGKILL);
        let mut child = self.child.lock().await;
        let _status = tokio::time::timeout(Duration::from_secs(2), child.wait())
            .await
            .map_err(|_| ProcessError::CleanupUnverified)??;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            if group_absent(self.pid)? {
                for signal in [term, killed] {
                    if let Err(error) = signal
                        && !matches!(&error,ProcessError::Io(e) if e.raw_os_error()==Some(libc::EPERM))
                    {
                        return Err(error);
                    }
                }
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(ProcessError::CleanupUnverified);
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}
fn signal_group(pid: i32, signal: i32) -> Result<(), ProcessError> {
    // SAFETY: positive pid is the process group we created and have not reaped.
    if unsafe { libc::kill(-pid, signal) } == 0 {
        return Ok(());
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(e.into())
    }
}
fn group_absent(pid: i32) -> Result<bool, ProcessError> {
    // SAFETY: signal zero only inspects the process group; it cannot mutate it.
    if unsafe { libc::kill(-pid, 0) } == 0 {
        return Ok(false);
    }
    let e = io::Error::last_os_error();
    if e.raw_os_error() == Some(libc::ESRCH) {
        Ok(true)
    } else if e.raw_os_error() == Some(libc::EPERM) {
        Ok(false)
    } else {
        Err(e.into())
    }
}
pub fn isolated_environment(process_home: &Path, codex_home: &Path) -> BTreeMap<String, String> {
    let mut env = BTreeMap::from([
        ("HOME".into(), process_home.to_string_lossy().into_owned()),
        (
            "CODEX_HOME".into(),
            codex_home.to_string_lossy().into_owned(),
        ),
        (
            "PATH".into(),
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin".into(),
        ),
    ]);
    for key in [
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NUMERIC",
        "LC_TIME",
    ] {
        if let Ok(value) = std::env::var(key) {
            env.insert(key.into(), value);
        }
    }
    env
}
pub fn isolation_arguments() -> Vec<String> {
    [
        "--listen",
        "stdio://",
        "-c",
        "project_root_markers=[]",
        "-c",
        "cli_auth_credentials_store=\"file\"",
        "-c",
        "mcp_oauth_credentials_store=\"file\"",
        "-c",
        "features.shell_snapshot=false",
        "-c",
        "features.shell_snapshot_v2=false",
        "-c",
        "allow_login_shell=false",
    ]
    .iter()
    .map(|s| (*s).into())
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn lifecycle_crash_retains_exact_child_until_owned_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let (process, input, output) = OwnedProcess::spawn(
            Path::new("/bin/sleep"),
            &["30".into()],
            dir.path(),
            &BTreeMap::new(),
        )
        .unwrap();
        drop(input);
        drop(output);
        let killed = ObservedExit::Signalled(libc::SIGKILL);
        assert_eq!(process.crash_for_lifecycle_probe().await.unwrap(), killed);
        assert_eq!(process.observed_exit().unwrap(), Some(killed));
        assert_eq!(process.crash_for_lifecycle_probe().await.unwrap(), killed);
        process.stop().await.unwrap();
        process.stop().await.unwrap();
        assert!(process.crash_for_lifecycle_probe().await.is_err());
    }
    #[tokio::test]
    async fn exit_observation_never_reaps_before_group_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let (process, input, output) = OwnedProcess::spawn(
            Path::new("/usr/bin/false"),
            &[],
            dir.path(),
            &BTreeMap::new(),
        )
        .unwrap();
        drop(input);
        drop(output);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        loop {
            if process.observed_exit().unwrap() == Some(ObservedExit::Exited(1)) {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(
            process.observed_exit().unwrap(),
            Some(ObservedExit::Exited(1)),
            "WNOWAIT keeps the exact child waitable"
        );
        process.stop().await.unwrap();
        process.stop().await.unwrap();
    }
}
