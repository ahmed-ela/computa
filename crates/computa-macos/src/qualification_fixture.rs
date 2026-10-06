//! Trusted disposable fixture ownership for explicit native qualification.
//! Never accepts an app choice from page IPC or tool arguments.
use crate::{AutomationError, BoundApplication, NativeBackend, Result};
use block2::RcBlock;
use objc2::rc::Retained;
use objc2_app_kit::{NSRunningApplication, NSWorkspace, NSWorkspaceOpenConfiguration};
use objc2_foundation::{NSArray, NSBundle, NSDate, NSError, NSRunLoop, NSString, NSURL};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};
pub const BUNDLE_ID: &str = "com.computa.rust.NativeAXQualification";
pub const DIGIT_ID: &str = "computa.qualification.digit-one";
pub const DISPLAY_ID: &str = "computa.qualification.display";
pub struct OwnedQualificationFixture {
    application: Retained<NSRunningApplication>,
    executable: PathBuf,
}
pub fn pump() {
    NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.02));
}
impl OwnedQualificationFixture {
    pub fn launch(executable: &Path) -> Result<Self> {
        let executable = executable
            .canonicalize()
            .map_err(|_| AutomationError::NotRunning)?;
        let app_path = executable
            .parent()
            .and_then(Path::parent)
            .and_then(Path::parent)
            .ok_or(AutomationError::NotRunning)?;
        let url = NSURL::fileURLWithPath(&NSString::from_str(
            app_path.to_str().ok_or(AutomationError::NotRunning)?,
        ));
        let bundle = NSBundle::bundleWithURL(&url).ok_or(AutomationError::NotRunning)?;
        if bundle.bundleIdentifier().map(|s| s.to_string()).as_deref() != Some(BUNDLE_ID)
            || bundle
                .executableURL()
                .and_then(|u| u.path())
                .map(|s| PathBuf::from(s.to_string()))
                .as_ref()
                != Some(&executable)
        {
            return Err(AutomationError::TargetChanged);
        }
        let config = NSWorkspaceOpenConfiguration::new();
        config.setActivates(false);
        config.setCreatesNewApplicationInstance(true);
        config.setArguments(&NSArray::from_retained_slice(&[
            NSString::from_str("--qualification-parent-pid"),
            NSString::from_str(&std::process::id().to_string()),
        ]));
        let (tx, rx) = mpsc::sync_channel(1);
        let tx = Arc::new(Mutex::new(Some(tx)));
        let callback = RcBlock::new(move |app: *mut NSRunningApplication, error: *mut NSError| {
            // SAFETY: AppKit owns borrowed callback objects for this invocation.
            // Only its exact returned scalar PID/error crosses the channel.
            let result = unsafe {
                if let Some(e) = error.as_ref() {
                    Err(e.code())
                } else if let Some(a) = app.as_ref() {
                    Ok(a.processIdentifier())
                } else {
                    Err(-1)
                }
            };
            if let Ok(mut tx) = tx.lock()
                && let Some(tx) = tx.take()
            {
                let _ = tx.send(result);
            }
        });
        NSWorkspace::sharedWorkspace().openApplicationAtURL_configuration_completionHandler(
            &url,
            &config,
            Some(&callback),
        );
        let started = Instant::now();
        let pid = loop {
            match rx.try_recv() {
                Ok(Ok(pid)) => break pid,
                Ok(Err(_)) | Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(AutomationError::NotRunning);
                }
                Err(mpsc::TryRecvError::Empty) if started.elapsed() < Duration::from_secs(15) => {
                    pump()
                }
                _ => return Err(AutomationError::NotRunning),
            }
        };
        let application = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
            .ok_or(AutomationError::NotRunning)?;
        let child = Self {
            application,
            executable,
        };
        let mut backend = NativeBackend::new()?;
        let started = Instant::now();
        loop {
            if child.application.isTerminated() {
                return Err(AutomationError::NotRunning);
            }
            match backend.bind_exact_process(pid, BUNDLE_ID) {
                Ok(_) => return Ok(child),
                Err(_) if started.elapsed() < Duration::from_secs(10) => pump(),
                Err(e) => return Err(e),
            }
        }
    }
    pub fn process_identifier(&self) -> i32 {
        self.application.processIdentifier()
    }
    pub fn executable(&self) -> &Path {
        &self.executable
    }
    pub fn exact_binding(&self, backend: &mut NativeBackend) -> Result<BoundApplication> {
        backend.bind_exact_process(self.process_identifier(), BUNDLE_ID)
    }
    pub fn close(&self) -> Result<()> {
        if !self.application.isTerminated() {
            let _ = self.application.terminate();
            let started = Instant::now();
            while !self.application.isTerminated() && started.elapsed() < Duration::from_secs(3) {
                pump();
            }
            if !self.application.isTerminated() {
                let _ = self.application.forceTerminate();
                let started = Instant::now();
                while !self.application.isTerminated() && started.elapsed() < Duration::from_secs(3)
                {
                    pump();
                }
            }
        }
        if self.application.isTerminated() {
            Ok(())
        } else {
            Err(AutomationError::TargetChanged)
        }
    }
}
impl Drop for OwnedQualificationFixture {
    fn drop(&mut self) {
        if self.close().is_err() {
            eprintln!(
                "NATIVE_FIXTURE_CLEANUP_UNCONFIRMED exact_pid={}",
                self.process_identifier()
            )
        }
    }
}
