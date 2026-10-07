//! Disposable first-party AppKit fixture, never installed or used as a backend.
#[cfg(target_os = "macos")]
fn watch_owner() {
    let mut args = std::env::args().skip(1);
    let Some(flag) = args.next() else { return };
    if flag != "--qualification-parent-pid" {
        std::process::exit(2)
    }
    let pid = args
        .next()
        .and_then(|s| s.parse::<i32>().ok())
        .filter(|p| *p > 1)
        .unwrap_or_else(|| std::process::exit(2));
    if args.next().is_some() {
        std::process::exit(2)
    }
    // SAFETY: kqueue and the exact scalar parent PID observe exit only. No
    // signal is sent, and the fixture exits only its own disposable process.
    let fd = unsafe { libc::kqueue() };
    if fd < 0 {
        std::process::exit(2)
    }
    // SAFETY: fd is the new live queue; initialized kevent records have the
    // platform ABI. EVFILT_PROC is read-only and bound before launch completes.
    let registered = unsafe {
        let mut event: libc::kevent = std::mem::zeroed();
        event.ident = pid as usize;
        event.filter = libc::EVFILT_PROC;
        event.flags = libc::EV_ADD | libc::EV_ONESHOT;
        event.fflags = libc::NOTE_EXIT;
        libc::kevent(fd, &event, 1, std::ptr::null_mut(), 0, std::ptr::null())
    };
    if registered != 0 {
        std::process::exit(2)
    }
    std::thread::spawn(move || {
        // SAFETY: one writable event and the retained queue observe only the
        // registered parent's exit. Closing the queue consumes this owned fd.
        unsafe {
            let mut event: libc::kevent = std::mem::zeroed();
            let result = libc::kevent(fd, std::ptr::null(), 0, &mut event, 1, std::ptr::null());
            libc::close(fd);
            if result == 1 && event.ident == pid as usize && event.fflags & libc::NOTE_EXIT != 0 {
                std::process::exit(0)
            }
        }
    });
}
#[cfg(target_os = "macos")]
mod calculator {
    use objc2::{
        DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained,
    };
    use objc2_app_kit::{NSAccessibility, NSButton, NSTextField};
    use objc2_foundation::{NSObject, NSObjectProtocol, NSString};
    pub struct Ivars {
        display: Retained<NSTextField>,
    }
    define_class!(
        // SAFETY: NSObject has no subclass invariants; retained AppKit controls
        // stay on the main thread for the complete fixture process lifetime.
        #[unsafe(super = NSObject)]
        #[thread_kind = MainThreadOnly]
        #[ivars = Ivars]
        pub struct DigitTarget;
        // SAFETY: NSObjectProtocol adds no Rust implementation obligations.
        unsafe impl NSObjectProtocol for DigitTarget {}
        impl DigitTarget {
            // SAFETY: only the fixture's retained NSButton uses this target and
            // selector ABI. The effect is confined to its own read-only display.
            #[unsafe(method(pressOne:))]
            fn press_one(&self,sender:&NSButton) {
                let value=self.ivars().display.stringValue().to_string();
                self.ivars().display.setStringValue(&NSString::from_str(&if value=="0"{"1".to_owned()}else{format!("{value}1")}));
                sender.setAccessibilitySelected(true);
            }
        }
    );
    impl DigitTarget {
        pub fn new(mtm: MainThreadMarker, display: Retained<NSTextField>) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(Ivars { display });
            // SAFETY: exactly one superclass initializer follows initialized ivars.
            unsafe { msg_send![super(this), init] }
        }
    }
}
#[cfg(target_os = "macos")]
fn main() {
    watch_owner();
    use objc2::{MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSAccessibility, NSApplication, NSApplicationActivationPolicy, NSBackingStoreType,
        NSButton, NSTextField, NSView, NSWindow, NSWindowStyleMask,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
    let mtm = MainThreadMarker::new().expect("AppKit main thread");
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
    let frame = NSRect::new(NSPoint::new(80., 80.), NSSize::new(420., 160.));
    // SAFETY: main-thread allocation/init with concrete NSWindow dimensions and
    // standard AppKit style bits; the fixture retains the window for its run loop.
    let window = unsafe {
        NSWindow::initWithContentRect_styleMask_backing_defer(
            NSWindow::alloc(mtm),
            frame,
            NSWindowStyleMask::Titled | NSWindowStyleMask::Closable,
            NSBackingStoreType::Buffered,
            false,
        )
    };
    window.setTitle(&NSString::from_str("Computa disposable AX qualification"));
    // SAFETY: the Rust retained window owns its lifetime throughout app.run;
    // closing must not cause AppKit to release that separately retained owner.
    unsafe { window.setReleasedWhenClosed(false) };
    let content = NSView::initWithFrame(
        NSView::alloc(mtm),
        NSRect::new(NSPoint::new(0., 0.), NSSize::new(420., 160.)),
    );
    let heading =
        NSTextField::labelWithString(&NSString::from_str("Disposable native test field"), mtm);
    heading.setFrame(NSRect::new(NSPoint::new(20., 105.), NSSize::new(380., 24.)));
    let field = NSTextField::initWithFrame(
        NSTextField::alloc(mtm),
        NSRect::new(NSPoint::new(20., 60.), NSSize::new(380., 26.)),
    );
    field.setStringValue(&NSString::from_str("native baseline"));
    field.setAccessibilityLabel(Some(&NSString::from_str("Qualification value")));
    field.setAccessibilityIdentifier(Some(&NSString::from_str("computa.qualification.value")));
    content.addSubview(&heading);
    content.addSubview(&field);
    let display = NSTextField::labelWithString(&NSString::from_str("0"), mtm);
    display.setFrame(NSRect::new(NSPoint::new(20., 15.), NSSize::new(130., 30.)));
    display.setAccessibilityLabel(Some(&NSString::from_str("Qualification display")));
    display.setAccessibilityIdentifier(Some(&NSString::from_str("computa.qualification.display")));
    let button = NSButton::initWithFrame(
        NSButton::alloc(mtm),
        NSRect::new(NSPoint::new(220., 10.), NSSize::new(160., 38.)),
    );
    button.setTitle(&NSString::from_str("1"));
    button.setAccessibilitySelected(false);
    button.setAccessibilityIdentifier(Some(&NSString::from_str("computa.qualification.digit-one")));
    let target = calculator::DigitTarget::new(mtm, display.clone());
    // SAFETY: matching retained native target/action ABI, only fixture-local UI.
    unsafe {
        button.setTarget(Some(&target));
        button.setAction(Some(objc2::sel!(pressOne:)));
    }
    content.addSubview(&display);
    content.addSubview(&button);
    window.setContentView(Some(&content));
    window.orderFront(None);
    // AppKit requires a visible window before it can become the app's main
    // window. This changes only fixture-local window state, without activation.
    window.makeMainWindow();
    println!("fixture-ready pid={}", std::process::id());
    app.run();
}
#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("The disposable native fixture requires macOS");
    std::process::exit(1);
}
