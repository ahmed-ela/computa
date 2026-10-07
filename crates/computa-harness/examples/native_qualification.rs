//! Explicit, disposable actual-AX qualification. No permission prompt, inventory
//! or user-app input occurs. The fixture path and exact bundle ID are supplied by
//! the trusted test launcher; the new child's PID is retained until reaped.
#[cfg(target_os = "macos")]
fn main() {
    if let Err(error) = qualify() {
        eprintln!("Native qualification failed: {error}");
        std::process::exit(1)
    }
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Actual native qualification requires macOS");
    std::process::exit(1)
}
#[cfg(target_os = "macos")]
fn qualify() -> Result<(), Box<dyn std::error::Error>> {
    use block2::RcBlock;
    use computa_contracts::tools::ReadArgs;
    use computa_harness::{
        semantic::SemanticReader,
        verification::{SemanticMutation, VerificationPlan},
    };
    use computa_macos::{MacosBackend, NativeBackend, NativeMutation, PermissionGrant, TreeLimits};
    use objc2::rc::Retained;
    use objc2_app_kit::{NSRunningApplication, NSWorkspace, NSWorkspaceOpenConfiguration};
    use objc2_foundation::{NSBundle, NSDate, NSError, NSRunLoop, NSURL};
    use std::{
        collections::HashSet,
        path::Path,
        sync::{Arc, Mutex, mpsc},
        time::{Duration, Instant},
    };
    struct OwnedFixture(Retained<NSRunningApplication>);
    let pump = || {
        // NSRunningApplication/NSWorkspace publish launch identity updates on
        // the current run loop; sleeping here would retain their cached state.
        NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.05));
    };
    impl Drop for OwnedFixture {
        fn drop(&mut self) {
            if !self.0.isTerminated() {
                let _ = self.0.terminate();
                let started = Instant::now();
                while !self.0.isTerminated() && started.elapsed() < Duration::from_secs(3) {
                    NSRunLoop::currentRunLoop()
                        .runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.05));
                }
                if !self.0.isTerminated() {
                    let _ = self.0.forceTerminate();
                    let started = Instant::now();
                    while !self.0.isTerminated() && started.elapsed() < Duration::from_secs(3) {
                        NSRunLoop::currentRunLoop()
                            .runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.05));
                    }
                }
                if !self.0.isTerminated() {
                    eprintln!(
                        "QUALIFICATION_CLEANUP_UNCONFIRMED exact_pid={}",
                        self.0.processIdentifier()
                    );
                }
            }
        }
    }
    let mut backend = NativeBackend::new()?;
    if backend.permissions().accessibility != PermissionGrant::Granted {
        println!(
            "QUALIFICATION_BLOCKED accessibility_permission_not_granted no_prompt_or_workaround"
        );
        return Ok(());
    }
    let mut arguments = std::env::args_os().skip(1);
    let path = arguments.next().ok_or("fixture executable required")?;
    let bundle = arguments
        .next()
        .ok_or("exact fixture bundle ID required")?
        .into_string()
        .map_err(|_| "bundle ID UTF8")?;
    if arguments.next().is_some() {
        return Err("unexpected argument".into());
    }
    let foreground = backend.foreground_process_identifier()?;
    // NSWorkspace launches the private bundle with a real launch identity. A
    // bare fork/exec AppKit process may have no NSRunningApplication.launchDate.
    let executable = Path::new(&path).canonicalize()?;
    let app_path = executable
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or("fixture bundle path")?;
    let app_url = NSURL::fileURLWithPath(&objc2_foundation::NSString::from_str(
        app_path.to_str().ok_or("fixture path UTF8")?,
    ));
    let app_bundle = NSBundle::bundleWithURL(&app_url).ok_or("private fixture bundle required")?;
    if app_bundle
        .bundleIdentifier()
        .map(|value| value.to_string())
        .as_deref()
        != Some(bundle.as_str())
        || app_bundle
            .executableURL()
            .and_then(|value| value.path())
            .map(|value| Path::new(&value.to_string()).to_owned())
            .as_ref()
            != Some(&executable)
    {
        return Err("exact private fixture executable or bundle mismatch".into());
    }
    let configuration = NSWorkspaceOpenConfiguration::new();
    configuration.setActivates(false);
    configuration.setCreatesNewApplicationInstance(true);
    let (tx, rx) = mpsc::sync_channel(1);
    let sender = Arc::new(Mutex::new(Some(tx)));
    let callback = RcBlock::new(
        move |application: *mut NSRunningApplication, error: *mut NSError| {
            // SAFETY: these references live for the AppKit completion callback. Only
            // the supplied child's scalar PID/error is sent, never an AppKit object.
            let result = unsafe {
                if let Some(error) = error.as_ref() {
                    Err(error.code())
                } else if let Some(application) = application.as_ref() {
                    Ok(application.processIdentifier())
                } else {
                    Err(-1)
                }
            };
            if let Ok(mut sender) = sender.lock()
                && let Some(sender) = sender.take()
            {
                let _ = sender.send(result);
            }
        },
    );
    NSWorkspace::sharedWorkspace().openApplicationAtURL_configuration_completionHandler(
        &app_url,
        &configuration,
        Some(&callback),
    );
    let started = Instant::now();
    let pid = loop {
        match rx.try_recv() {
            Ok(Ok(pid)) => break pid,
            Ok(Err(code)) => return Err(format!("private NSWorkspace launch error {code}").into()),
            Err(mpsc::TryRecvError::Disconnected) => {
                return Err("private launch callback lost".into());
            }
            Err(mpsc::TryRecvError::Empty) if started.elapsed() < Duration::from_secs(15) => pump(),
            Err(_) => return Err("private launch callback timeout".into()),
        }
    };
    let application = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
        .ok_or("exact launched child missing")?;
    let child = OwnedFixture(application);
    let started = Instant::now();
    let binding = loop {
        if child.0.isTerminated() {
            return Err("private fixture exited".into());
        }
        match backend.bind_exact_process(pid, &bundle) {
            Ok(binding) => break binding,
            Err(error) if started.elapsed() < Duration::from_secs(10) => {
                let _ = error;
                pump();
            }
            Err(error) => {
                let exact =
                    objc2_app_kit::NSRunningApplication::runningApplicationWithProcessIdentifier(
                        pid,
                    );
                eprintln!(
                    "Exact disposable child identity: pid={pid} bundle={} launched={} terminated={}",
                    serde_json::to_string(
                        &exact
                            .as_ref()
                            .and_then(|app| app.bundleIdentifier())
                            .map(|value| value.to_string())
                    )?,
                    exact.as_ref().and_then(|app| app.launchDate()).is_some(),
                    exact.as_ref().is_none_or(|app| app.isTerminated())
                );
                return Err(error.into());
            }
        }
    };
    if binding.application.process_identifier != pid || binding.activated {
        return Err("exact non-activating fixture binding failed".into());
    }
    let snapshot = backend.observe(&binding, TreeLimits::default())?;
    let mut reader = SemanticReader::default();
    let publication = reader.start(snapshot, ReadArgs::default(), None, 16384)?;
    let fields: Vec<_> = publication
        .snapshot
        .elements
        .iter()
        .filter(|node| {
            node.identifier.as_deref() == Some("computa.qualification.value")
                && node.is_value_settable
                && publication.exposed.contains(&node.index)
        })
        .collect();
    if fields.len() != 1 {
        return Err("exact exposed fixture field not found".into());
    }
    let index = fields[0].index;
    let replacement = "qualified native Rust value";
    let mutation = SemanticMutation::SetText(replacement.into());
    let plan = VerificationPlan::compile(
        None,
        &mutation,
        index,
        &publication.snapshot,
        &publication.exposed,
    )?;
    let fresh = backend.observe(&binding, TreeLimits::default())?;
    let target = plan.revalidate(&fresh)?;
    let mut dispatched = false;
    backend.mutate(
        &binding,
        target,
        NativeMutation::SetValue(replacement.into()),
        &mut || {
            dispatched = true;
            Ok(())
        },
    )?;
    if !dispatched {
        return Err("native boundary was not reached".into());
    }
    let mut proof = None;
    for _ in 0..10 {
        let observation = backend.observe(&binding, TreeLimits::default())?;
        if let Ok(verified) = plan.evaluate(&observation) {
            proof = Some(verified);
            break;
        }
        pump();
    }
    let proof = proof.ok_or("actual field value postcondition was not verified")?;
    if backend.foreground_process_identifier() != Ok(foreground) {
        return Err("background mutation changed the foreground application".into());
    }
    let exposed: HashSet<_> = publication.exposed.clone();
    println!(
        "QUALIFICATION_PASSED exact_pid={pid} bundle={bundle} exposed_rows={} dispatched_once=true property={} expected={} foreground_preserved=true",
        exposed.len(),
        proof.property,
        serde_json::to_string(&proof.expected_value)?
    );
    drop(backend);
    drop(child);
    Ok(())
}
