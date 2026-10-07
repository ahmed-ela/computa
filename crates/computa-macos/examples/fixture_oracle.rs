//! Explicit real-AX fixture oracle, separate from model/tool verification.
//! It can only launch this reviewed disposable fixture and close its exact PID.
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("Native fixture qualification requires macOS");
    std::process::exit(1);
}
#[cfg(target_os = "macos")]
fn main() {
    if let Err(error) = run() {
        eprintln!("DISPOSABLE_FIXTURE_REFUSED {error}");
        std::process::exit(1);
    }
}
#[cfg(target_os = "macos")]
fn run() -> Result<(), Box<dyn std::error::Error>> {
    use computa_macos::qualification_fixture::{
        DIGIT_ID, DISPLAY_ID, OwnedQualificationFixture, pump,
    };
    use computa_macos::{MacosBackend, NativeBackend, NativeMutation, PermissionGrant, TreeLimits};
    use std::{
        path::PathBuf,
        time::{Duration, Instant},
    };
    let mut arguments = std::env::args_os().skip(1);
    let path = PathBuf::from(
        arguments
            .next()
            .ok_or("reviewed fixture executable required")?,
    );
    if arguments.next().is_some() {
        return Err("unexpected argument".into());
    }
    let mut backend = NativeBackend::new()?;
    if backend.permissions().accessibility != PermissionGrant::Granted {
        return Err("accessibility_not_granted_no_prompt_or_workaround".into());
    }
    let foreground = backend.foreground_process_identifier()?;
    let child = OwnedQualificationFixture::launch(&path)?;
    let binding = child.exact_binding(&mut backend)?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let baseline = loop {
        let snapshot = backend.observe(&binding, TreeLimits::default())?;
        if snapshot
            .elements
            .iter()
            .any(|n| n.identifier.as_deref() == Some(DISPLAY_ID))
        {
            break snapshot;
        }
        if Instant::now() >= deadline {
            return Err("disposable_fixture_ax_not_ready".into());
        }
        pump();
    };
    let digits = baseline
        .elements
        .iter()
        .filter(|n| n.identifier.as_deref() == Some(DIGIT_ID))
        .collect::<Vec<_>>();
    let displays = baseline
        .elements
        .iter()
        .filter(|n| n.identifier.as_deref() == Some(DISPLAY_ID))
        .collect::<Vec<_>>();
    if digits.len() != 1
        || displays.len() != 1
        || digits[0].is_selected != Some(false)
        || displays[0].value.as_deref() != Some("0")
        || !digits[0].actions.iter().any(|s| s == "AXPress")
    {
        return Err("disposable_fixture_unique_baseline_failed".into());
    }
    let mut dispatched = 0;
    backend.mutate(
        &binding,
        digits[0].identity,
        NativeMutation::Action("AXPress".into()),
        &mut || {
            dispatched += 1;
            Ok(())
        },
    )?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let verified = loop {
        let snapshot = backend.observe(&binding, TreeLimits::default())?;
        let display = snapshot
            .elements
            .iter()
            .filter(|n| n.identifier.as_deref() == Some(DISPLAY_ID))
            .collect::<Vec<_>>();
        let digit = snapshot
            .elements
            .iter()
            .filter(|n| n.identifier.as_deref() == Some(DIGIT_ID))
            .collect::<Vec<_>>();
        if display.len() == 1
            && digit.len() == 1
            && display[0].value.as_deref() == Some("1")
            && digit[0].is_selected == Some(true)
        {
            break snapshot;
        }
        if Instant::now() >= deadline {
            return Err("disposable_fixture_ax_transition_unverified".into());
        }
        pump();
    };
    if dispatched != 1
        || verified.window.window_id != baseline.window.window_id
        || backend.foreground_process_identifier()? != foreground
    {
        return Err("disposable_fixture_scope_or_focus_changed".into());
    }
    child.close()?;
    println!(
        "DISPOSABLE_FIXTURE_QUALIFIED exact_pid={} exact_window={} baseline=0 final=1 selection=true dispatches=1 background_focus_preserved=true child_closed=true",
        child.process_identifier(),
        verified
            .window
            .window_id
            .ok_or("exact_fixture_window_missing")?
    );
    Ok(())
}
