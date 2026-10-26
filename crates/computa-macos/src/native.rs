//! All raw Apple references below are owned by this module. CF ownership follows
//! Create/Copy rules; borrowed attributes are retained before storage. Native AX
//! objects are deliberately !Send and every operation checks the main thread.
use crate::*;
use block2::RcBlock;
use objc2::{AnyThread, MainThreadMarker};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationOptions, NSRunningApplication, NSWorkspace,
    NSWorkspaceOpenConfiguration,
};
use objc2_foundation::{NSArray, NSBundle, NSError, NSString, NSURL};
use objc2_screen_capture_kit::{
    SCContentFilter, SCScreenshotManager, SCShareableContent, SCStreamConfiguration,
};
use std::{
    collections::{HashMap, VecDeque},
    ffi::{c_char, c_void},
    future::Future,
    marker::PhantomData,
    pin::Pin,
    ptr::{self, NonNull},
    rc::Rc,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

type Raw = *const c_void;
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CPoint {
    x: f64,
    y: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CSize {
    width: f64,
    height: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CRect {
    origin: CPoint,
    size: CSize,
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRetain(value: Raw) -> Raw;
    fn CFRelease(value: Raw);
    fn CFEqual(a: Raw, b: Raw) -> u8;
    fn CFGetTypeID(value: Raw) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFArrayGetTypeID() -> usize;
    fn CFBooleanGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFStringCreateWithBytes(
        allocator: Raw,
        bytes: *const u8,
        length: isize,
        encoding: u32,
        external: u8,
    ) -> Raw;
    fn CFStringGetLength(value: Raw) -> isize;
    fn CFStringGetCString(value: Raw, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFArrayGetCount(value: Raw) -> isize;
    fn CFArrayGetValueAtIndex(value: Raw, index: isize) -> Raw;
    fn CFBooleanGetValue(value: Raw) -> u8;
    fn CFNumberGetValue(value: Raw, kind: i32, result: *mut c_void) -> u8;
    fn CFDictionaryGetValue(dictionary: Raw, key: Raw) -> Raw;
    fn CFDataCreateMutable(allocator: Raw, capacity: isize) -> Raw;
    fn CFDataGetLength(value: Raw) -> isize;
    fn CFDataGetBytePtr(value: Raw) -> *const u8;
}
#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> u8;
    fn AXIsProcessTrustedWithOptions(options: Raw) -> u8;
    fn AXUIElementGetTypeID() -> usize;
    fn AXValueGetTypeID() -> usize;
    fn AXUIElementCreateApplication(pid: i32) -> Raw;
    fn AXUIElementGetPid(element: Raw, pid: *mut i32) -> i32;
    fn AXUIElementCopyAttributeValue(element: Raw, attribute: Raw, value: *mut Raw) -> i32;
    fn AXUIElementCopyActionNames(element: Raw, names: *mut Raw) -> i32;
    fn AXUIElementIsAttributeSettable(element: Raw, attribute: Raw, settable: *mut u8) -> i32;
    fn AXUIElementSetAttributeValue(element: Raw, attribute: Raw, value: Raw) -> i32;
    fn AXUIElementPerformAction(element: Raw, action: Raw) -> i32;
    fn AXValueGetValue(value: Raw, kind: i32, result: *mut c_void) -> u8;
    fn AXUIElementSetMessagingTimeout(element: Raw, timeout: f32) -> i32;
    fn CFDictionaryCreate(
        allocator: Raw,
        keys: *const Raw,
        values: *const Raw,
        count: isize,
        key_callbacks: Raw,
        value_callbacks: Raw,
    ) -> Raw;
    static kCFBooleanTrue: Raw;
}
#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGPreflightScreenCaptureAccess() -> u8;
    fn CGRequestScreenCaptureAccess() -> u8;
    fn CGWindowListCopyWindowInfo(options: u32, relative: u32) -> Raw;
    fn CGRectMakeWithDictionaryRepresentation(value: Raw, rect: *mut CRect) -> u8;
    fn CGGetActiveDisplayList(max: u32, displays: *mut u32, count: *mut u32) -> i32;
    fn CGDisplayBounds(display: u32) -> CRect;
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
    fn CGEventSourceCreate(state: i32) -> Raw;
    fn CGEventCreateMouseEvent(source: Raw, kind: u32, point: CPoint, button: u32) -> Raw;
    fn CGEventCreateKeyboardEvent(source: Raw, key: u16, down: u8) -> Raw;
    fn CGEventKeyboardSetUnicodeString(event: Raw, count: usize, chars: *const u16);
    fn CGEventSetFlags(event: Raw, flags: u64);
    fn CGEventSetIntegerValueField(event: Raw, field: u32, value: i64);
    fn CGEventCreateScrollWheelEvent(source: Raw, units: u32, wheels: u32, ...) -> Raw;
    fn CGEventSetLocation(event: Raw, point: CPoint);
    fn CGEventPost(tap: u32, event: Raw);
    fn CGImageGetWidth(image: Raw) -> usize;
    fn CGImageGetHeight(image: Raw) -> usize;
}
#[link(name = "ImageIO", kind = "framework")]
unsafe extern "C" {
    fn CGImageDestinationCreateWithData(data: Raw, kind: Raw, count: usize, options: Raw) -> Raw;
    fn CGImageDestinationAddImage(destination: Raw, image: Raw, properties: Raw);
    fn CGImageDestinationFinalize(destination: Raw) -> u8;
}

struct OwnedCf {
    pointer: NonNull<c_void>,
    _local: PhantomData<Rc<()>>,
}
impl OwnedCf {
    /// The caller supplies an owned +1 CF reference, never an arbitrary pointer.
    unsafe fn owned(pointer: Raw) -> Option<Self> {
        NonNull::new(pointer.cast_mut()).map(|pointer| Self {
            pointer,
            _local: PhantomData,
        })
    }
    fn raw(&self) -> Raw {
        self.pointer.as_ptr().cast_const()
    }
    fn retained(&self) -> Self {
        // SAFETY: self owns a live CF reference; CFRetain supplies another +1.
        unsafe {
            Self::owned(CFRetain(self.raw())).expect("CFRetain cannot return null for a live value")
        }
    }
    fn same(&self, other: &Self) -> bool {
        // SAFETY: both values own valid live CF references.
        unsafe { CFEqual(self.raw(), other.raw()) != 0 }
    }
}
impl Drop for OwnedCf {
    fn drop(&mut self) {
        // SAFETY: every instance owns exactly one +1 CF reference.
        unsafe { CFRelease(self.raw()) }
    }
}
fn cf_string(value: &str) -> OwnedCf {
    // SAFETY: byte pointer is valid for value.len(); CF copies UTF-8 bytes.
    unsafe {
        OwnedCf::owned(CFStringCreateWithBytes(
            ptr::null(),
            value.as_ptr(),
            value.len() as isize,
            0x08000100,
            0,
        ))
        .expect("valid Rust UTF-8 CFString")
    }
}
fn string_value(value: Raw) -> Option<String> {
    if value.is_null() {
        return None;
    }
    // SAFETY: caller passes a live CF object; type is verified before string APIs.
    unsafe {
        if CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        let length = CFStringGetLength(value);
        if !(0..=1_048_576).contains(&length) {
            return None;
        }
        let mut bytes = vec![0u8; length as usize * 4 + 1];
        if CFStringGetCString(
            value,
            bytes.as_mut_ptr().cast(),
            bytes.len() as isize,
            0x08000100,
        ) == 0
        {
            return None;
        }
        let end = bytes.iter().position(|x| *x == 0)?;
        String::from_utf8(bytes[..end].to_vec()).ok()
    }
}
fn bool_value(value: Raw) -> Option<bool> {
    if value.is_null() {
        return None;
    }
    // SAFETY: live CF value is checked for the required runtime type.
    unsafe { (CFGetTypeID(value) == CFBooleanGetTypeID()).then(|| CFBooleanGetValue(value) != 0) }
}
fn number_value(value: Raw) -> Option<f64> {
    if value.is_null() {
        return None;
    }
    // SAFETY: type is checked before writing a double into a correctly-sized slot.
    unsafe {
        if CFGetTypeID(value) != CFNumberGetTypeID() {
            return None;
        }
        let mut x: f64 = 0.;
        (CFNumberGetValue(value, 13, (&mut x as *mut f64).cast()) != 0 && x.is_finite())
            .then_some(x)
    }
}
fn dictionary_value(dictionary: Raw, key: &str) -> Raw {
    let key = cf_string(key);
    // SAFETY: callers pass known CGWindow dictionaries; key is live through call.
    unsafe { CFDictionaryGetValue(dictionary, key.raw()) }
}
fn attribute(element: &OwnedCf, name: &str) -> Result<Option<OwnedCf>> {
    let name = cf_string(name);
    let mut value = ptr::null();
    // SAFETY: element and attribute are live CF/AX references; result owns +1 on success.
    let code = unsafe { AXUIElementCopyAttributeValue(element.raw(), name.raw(), &mut value) };
    match code {
        0 => {
            // SAFETY: successful Copy supplies ownership, including null for absent values.
            Ok(unsafe { OwnedCf::owned(value) })
        }
        -25205 | -25212 => Ok(None),
        _ => Err(AutomationError::Native {
            operation: "AXCopyAttribute".into(),
            code,
        }),
    }
}
fn string_attribute(element: &OwnedCf, name: &str) -> Result<Option<String>> {
    Ok(attribute(element, name)?.and_then(|x| string_value(x.raw())))
}
fn bool_attribute(element: &OwnedCf, name: &str) -> Result<Option<bool>> {
    Ok(attribute(element, name)?.and_then(|x| bool_value(x.raw())))
}
fn array_owned(value: &OwnedCf) -> Result<Vec<OwnedCf>> {
    // SAFETY: CF runtime type is checked; retained children remain live after array release.
    unsafe {
        if CFGetTypeID(value.raw()) != CFArrayGetTypeID() {
            return Err(AutomationError::Invalid("AX array type".into()));
        }
        let count = CFArrayGetCount(value.raw());
        if !(0..=100_000).contains(&count) {
            return Err(AutomationError::Invalid("AX array count".into()));
        }
        Ok((0..count)
            .filter_map(|i| {
                let p = CFArrayGetValueAtIndex(value.raw(), i);
                if p.is_null() {
                    None
                } else {
                    OwnedCf::owned(CFRetain(p))
                }
            })
            .collect())
    }
}
fn frame(element: &OwnedCf) -> Result<Option<Rect>> {
    let (Some(position), Some(size)) = (
        attribute(element, "AXPosition")?,
        attribute(element, "AXSize")?,
    ) else {
        return Ok(None);
    };
    let mut p = CPoint::default();
    let mut s = CSize::default();
    // SAFETY: AXValue APIs validate their type and write CGPoint/CGSize-sized slots.
    unsafe {
        if CFGetTypeID(position.raw()) != AXValueGetTypeID()
            || CFGetTypeID(size.raw()) != AXValueGetTypeID()
            || AXValueGetValue(position.raw(), 1, (&mut p as *mut CPoint).cast()) == 0
            || AXValueGetValue(size.raw(), 2, (&mut s as *mut CSize).cast()) == 0
        {
            return Ok(None);
        }
    }
    Ok(Rect {
        x: p.x,
        y: p.y,
        width: s.width,
        height: s.height,
    }
    .validate()
    .ok())
}
fn owner(element: &OwnedCf) -> Result<i32> {
    let mut pid = 0;
    // SAFETY: CF runtime type inspection is valid for every owned CF value.
    if unsafe { CFGetTypeID(element.raw()) != AXUIElementGetTypeID() } {
        return Err(AutomationError::Invalid("AX element type".into()));
    }
    // SAFETY: element is a retained AX object; pid slot has the documented ABI.
    let code = unsafe { AXUIElementGetPid(element.raw(), &mut pid) };
    if code != 0 || pid <= 0 {
        return Err(AutomationError::Native {
            operation: "AXGetPid".into(),
            code,
        });
    }
    Ok(pid)
}
fn actions(element: &OwnedCf) -> Result<Vec<String>> {
    let mut names = ptr::null();
    // SAFETY: Copy action list produces a +1 CFArray on success.
    let code = unsafe { AXUIElementCopyActionNames(element.raw(), &mut names) };
    if code == -25205 {
        return Ok(vec![]);
    }
    if code != 0 {
        return Err(AutomationError::Native {
            operation: "AXCopyActions".into(),
            code,
        });
    }
    // SAFETY: successful Copy transfers ownership.
    let Some(array) = (unsafe { OwnedCf::owned(names) }) else {
        return Ok(vec![]);
    };
    Ok(array_owned(&array)?
        .iter()
        .filter_map(|x| string_value(x.raw()))
        .collect())
}
fn settable(element: &OwnedCf) -> Result<bool> {
    let key = cf_string("AXValue");
    let mut value = 0;
    // SAFETY: live references and correctly sized Boolean output.
    let code = unsafe { AXUIElementIsAttributeSettable(element.raw(), key.raw(), &mut value) };
    if code == -25205 {
        return Ok(false);
    }
    if code != 0 {
        return Err(AutomationError::Native {
            operation: "AXIsSettable".into(),
            code,
        });
    }
    Ok(value != 0)
}
fn value_text(element: &OwnedCf) -> Result<Option<String>> {
    let Some(value) = attribute(element, "AXValue")? else {
        return Ok(None);
    };
    Ok(string_value(value.raw())
        .or_else(|| bool_value(value.raw()).map(|x| x.to_string()))
        .or_else(|| number_value(value.raw()).map(|x| x.to_string())))
}

#[derive(Clone)]
struct WindowRecord {
    id: u32,
    pid: i32,
    layer: i32,
    frame: Rect,
}
fn window_records() -> Result<Vec<WindowRecord>> {
    // SAFETY: Create/Copy supplies an owned CFArray of documented window dictionaries.
    let array = unsafe { OwnedCf::owned(CGWindowListCopyWindowInfo(1 | 16, 0)) }
        .ok_or(AutomationError::WindowUnavailable)?;
    let mut output = vec![];
    for entry in array_owned(&array)? {
        let mut rect = CRect::default();
        // SAFETY: the documented window-bounds dictionary and CGRect output ABI.
        let has_frame = unsafe {
            CGRectMakeWithDictionaryRepresentation(
                dictionary_value(entry.raw(), "kCGWindowBounds"),
                &mut rect,
            )
        } != 0;
        let frame = Rect {
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height,
        };
        let (Some(id), Some(pid), Some(layer)) = (
            number_value(dictionary_value(entry.raw(), "kCGWindowNumber")),
            number_value(dictionary_value(entry.raw(), "kCGWindowOwnerPID")),
            number_value(dictionary_value(entry.raw(), "kCGWindowLayer")),
        ) else {
            continue;
        };
        if has_frame && frame.validate().is_ok() {
            output.push(WindowRecord {
                id: id as u32,
                pid: pid as i32,
                layer: layer as i32,
                frame,
            })
        }
    }
    Ok(output)
}
fn same_frame(a: Rect, b: Rect) -> bool {
    (a.x - b.x).abs() < 1.
        && (a.y - b.y).abs() < 1.
        && (a.width - b.width).abs() < 1.
        && (a.height - b.height).abs() < 1.
}
fn describe_application(app: &NSRunningApplication) -> RunningApplication {
    RunningApplication {
        process_identifier: app.processIdentifier(),
        bundle_identifier: app.bundleIdentifier().map(|x| x.to_string()),
        localized_name: app.localizedName().map(|x| x.to_string()),
        is_active: app.isActive(),
        is_terminated: app.isTerminated(),
        activation_policy: app.activationPolicy().0 as i64,
        launch_time: app.launchDate().map(|x| x.timeIntervalSince1970()),
    }
}
fn process_arguments(pid: i32) -> Result<Vec<String>> {
    let mut mib = [1, 49, pid];
    let mut bytes = vec![0u8; 1_048_576];
    let mut len = bytes.len();
    // SAFETY: sysctl receives valid bounded buffers; argv is parsed before environment.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            3,
            bytes.as_mut_ptr().cast(),
            &mut len,
            ptr::null_mut(),
            0,
        )
    };
    let parsed = (|| {
        if result != 0 || len < 4 || len > bytes.len() {
            return None;
        }
        let argc = u32::from_ne_bytes(bytes[..4].try_into().ok()?) as usize;
        if argc == 0 || argc > 4096 {
            return None;
        }
        let mut cursor = 4 + bytes[4..len].iter().position(|x| *x == 0)? + 1;
        while cursor < len && bytes[cursor] == 0 {
            cursor += 1
        }
        let mut argv = vec![];
        for _ in 0..argc {
            if cursor >= len {
                return None;
            }
            let end = cursor + bytes[cursor..len].iter().position(|x| *x == 0)?;
            argv.push(std::str::from_utf8(&bytes[cursor..end]).ok()?.to_owned());
            cursor = end + 1
        }
        Some(argv)
    })();
    // Wipe the kernel block, which also contains environment values never exposed.
    bytes.fill(0);
    parsed.ok_or(AutomationError::Invalid(
        "Native process cannot be inspected".into(),
    ))
}

pub struct NativeBackend {
    _main: MainThreadMarker,
    binding: Option<BoundApplication>,
    selected_window: Option<OwnedCf>,
    nodes: HashMap<Uuid, OwnedCf>,
    previous_nodes: HashMap<Uuid, OwnedCf>,
}
impl NativeBackend {
    pub fn new() -> Result<Self> {
        Ok(Self {
            _main: MainThreadMarker::new().ok_or(AutomationError::WrongThread)?,
            binding: None,
            selected_window: None,
            nodes: HashMap::new(),
            previous_nodes: HashMap::new(),
        })
    }
    /// Host-owned exact process selection. This performs no inventory, launch,
    /// activation or navigation and requires the caller's already-known PID.
    pub fn bind_exact_process(&mut self, pid: i32, bundle_id: &str) -> Result<BoundApplication> {
        self.require_ax()?;
        if pid <= 0 || bundle_id.is_empty() || bundle_id.len() > 255 {
            return Err(AutomationError::Invalid("exact process identity".into()));
        }
        let application = self.application(pid)?;
        if application.bundle_identifier.as_deref() != Some(bundle_id)
            || application.is_terminated
            || !application.launch_time.is_some_and(f64::is_finite)
        {
            return Err(AutomationError::TargetChanged);
        }
        let (window, info) = self.selected(pid)?;
        let binding = BoundApplication {
            application,
            window: info,
            window_token: Uuid::new_v4(),
            generation: Uuid::new_v4(),
            activated: false,
        };
        self.nodes.clear();
        self.previous_nodes.clear();
        self.selected_window = Some(window);
        self.binding = Some(binding.clone());
        if let Err(error) = self.validate(&binding) {
            self.invalidate();
            return Err(error);
        }
        Ok(binding)
    }
    pub fn foreground_process_identifier(&self) -> Result<Option<i32>> {
        self.check_thread()?;
        Ok(NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .map(|app| app.processIdentifier()))
    }
    fn check_thread(&self) -> Result<()> {
        MainThreadMarker::new()
            .ok_or(AutomationError::WrongThread)
            .map(|_| ())
    }
    fn require_ax(&self) -> Result<()> {
        self.check_thread()?;
        if self.permissions().accessibility != PermissionGrant::Granted {
            return Err(AutomationError::AccessibilityPermission);
        }
        Ok(())
    }
    fn application(&self, pid: i32) -> Result<RunningApplication> {
        self.check_thread()?;
        NSRunningApplication::runningApplicationWithProcessIdentifier(pid)
            .map(|a| describe_application(&a))
            .ok_or(AutomationError::TargetChanged)
    }
    fn selected(&self, pid: i32) -> Result<(OwnedCf, WindowInfo)> {
        self.require_ax()?;
        // SAFETY: Create returns a retained AX application for the supplied positive PID.
        let app = unsafe { OwnedCf::owned(AXUIElementCreateApplication(pid)) }
            .ok_or(AutomationError::WindowUnavailable)?;
        // SAFETY: bounded timeout on a retained AX object; no input/activation occurs.
        let _ = unsafe { AXUIElementSetMessagingTimeout(app.raw(), 2.) };
        let focused = attribute(&app, "AXFocusedWindow")?;
        let main = attribute(&app, "AXMainWindow")?;
        let (window, is_focused, is_main) = match (focused, main) {
            (Some(w), Some(m)) => {
                let same = w.same(&m);
                (w, true, same)
            }
            (Some(w), None) => (w, true, false),
            (None, Some(w)) => (w, false, true),
            _ => return Err(AutomationError::WindowUnavailable),
        };
        if owner(&window)? != pid {
            return Err(AutomationError::TargetChanged);
        }
        let process = self.application(pid)?;
        let bounds = frame(&window)?;
        let matches: Vec<_> = window_records()?
            .into_iter()
            .filter(|w| {
                w.pid == pid && w.layer == 0 && bounds.is_some_and(|f| same_frame(f, w.frame))
            })
            .collect();
        let window_id = if matches.len() == 1 {
            Some(matches[0].id)
        } else {
            None
        };
        let info = WindowInfo {
            window_id,
            process_identifier: pid,
            bundle_identifier: process.bundle_identifier,
            title: string_attribute(&window, "AXTitle")?,
            frame: bounds,
            is_main,
            is_focused,
            document: string_attribute(&window, "AXDocument")?,
        };
        Ok((window, info))
    }
    fn require_foreground(&self, binding: &BoundApplication) -> Result<()> {
        self.validate(binding)?;
        let app = NSWorkspace::sharedWorkspace()
            .frontmostApplication()
            .ok_or(AutomationError::NotForeground)?;
        if app.processIdentifier() != binding.application.process_identifier {
            return Err(AutomationError::NotForeground);
        }
        let (_, current) = self.selected(binding.application.process_identifier)?;
        if !current.is_focused {
            return Err(AutomationError::NotForeground);
        }
        if current
            .frame
            .zip(binding.window.frame)
            .is_none_or(|(a, b)| !same_frame(a, b))
        {
            return Err(AutomationError::TargetChanged);
        }
        Ok(())
    }
    fn hit_test(&self, binding: &BoundApplication, point: Point) -> Result<()> {
        let bounds = binding
            .window
            .frame
            .ok_or(AutomationError::WindowUnavailable)?;
        if !bounds.contains(point) {
            return Err(AutomationError::Obscured);
        }
        let id = binding
            .window
            .window_id
            .ok_or(AutomationError::WindowUnavailable)?;
        for record in window_records()? {
            if record.frame.contains(point) {
                if record.id == id && record.pid == binding.application.process_identifier {
                    return Ok(());
                }
                if record.layer >= 0 {
                    return Err(AutomationError::Obscured);
                }
            }
        }
        Err(AutomationError::Obscured)
    }
    fn send_event(&self, event: OwnedCf) {
        // SAFETY: event owns a live CGEvent and posts only after all host checks.
        unsafe { CGEventPost(0, event.raw()) }
    }
}
impl MacosBackend for NativeBackend {
    fn permissions(&self) -> PermissionSnapshot {
        // SAFETY: these APIs inspect TCC state only and do not request permission.
        unsafe {
            PermissionSnapshot {
                accessibility: if AXIsProcessTrusted() != 0 {
                    PermissionGrant::Granted
                } else {
                    PermissionGrant::NotGranted
                },
                screen_recording: if CGPreflightScreenCaptureAccess() != 0 {
                    PermissionGrant::Granted
                } else {
                    PermissionGrant::NotGranted
                },
            }
        }
    }
    fn request_accessibility(&self) -> PermissionSnapshot {
        if self.check_thread().is_err() {
            return self.permissions();
        }
        let key = cf_string("AXTrustedCheckOptionPrompt");
        // SAFETY: this explicit human Settings path builds a one-entry CF dictionary.
        unsafe {
            let value = kCFBooleanTrue;
            if let Some(options) = OwnedCf::owned(CFDictionaryCreate(
                ptr::null(),
                &key.raw(),
                &value,
                1,
                ptr::null(),
                ptr::null(),
            )) {
                let _ = AXIsProcessTrustedWithOptions(options.raw());
            }
        }
        self.permissions()
    }
    fn request_screen_recording(&self) -> PermissionSnapshot {
        if self.check_thread().is_ok() {
            // SAFETY: only the native human Settings control invokes this explicit prompt.
            let _ = unsafe { CGRequestScreenCaptureAccess() };
        }
        self.permissions()
    }
    fn applications(&self) -> Result<Vec<RunningApplication>> {
        self.check_thread()?;
        Ok(NSWorkspace::sharedWorkspace()
            .runningApplications()
            .iter()
            .map(|x| describe_application(&x))
            .collect())
    }
    fn bind(
        &mut self,
        bundle_id: &str,
        activate: bool,
        url: Option<&str>,
    ) -> Result<BoundApplication> {
        self.require_ax()?;
        if bundle_id.is_empty()
            || bundle_id.len() > 255
            || !bundle_id
                .chars()
                .all(|x| x.is_alphanumeric() || x == '.' || x == '-')
        {
            return Err(AutomationError::Invalid("bundle_id".into()));
        }
        // The background path cannot cause navigation, even if a caller passes a URL.
        if !activate && url.is_some() {
            return Err(AutomationError::Invalid("background navigation".into()));
        }
        let mut matches: Vec<_> = self
            .applications()?
            .into_iter()
            .filter(|a| a.bundle_identifier.as_deref() == Some(bundle_id) && !a.is_terminated)
            .collect();
        if matches.is_empty() {
            return Err(AutomationError::NotRunning);
        }

        if matches.len() != 1 {
            return Err(AutomationError::AmbiguousApplication);
        }
        let application = matches.remove(0);
        if !application.launch_time.is_some_and(f64::is_finite) {
            return Err(AutomationError::TargetChanged);
        }
        if activate {
            let app = NSRunningApplication::runningApplicationWithProcessIdentifier(
                application.process_identifier,
            )
            .ok_or(AutomationError::TargetChanged)?;
            if !app.isActive()
                && !app.activateWithOptions(NSApplicationActivationOptions::ActivateAllWindows)
            {
                return Err(AutomationError::NotForeground);
            }
            if url.is_some() {
                return Err(AutomationError::Invalid(
                    "native URL navigation requires a qualified owned browser lane".into(),
                ));
            }
        }
        let (window, info) = self.selected(application.process_identifier)?;
        let binding = BoundApplication {
            application,
            window: info,
            window_token: Uuid::new_v4(),
            generation: Uuid::new_v4(),
            activated: activate,
        };
        self.nodes.clear();
        self.previous_nodes.clear();
        self.selected_window = Some(window);
        self.binding = Some(binding.clone());
        if let Err(e) = self.validate(&binding) {
            self.invalidate();
            return Err(e);
        }
        Ok(binding)
    }
    fn open<'a>(
        &'a mut self,
        bundle_id: &'a str,
        activate: bool,
        url: Option<&'a str>,
        before_dispatch: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async move {
            self.require_ax()?;
            validate_open_url(url)?;
            if !activate {
                before_dispatch()?;
                return self.bind(bundle_id, false, url);
            }
            let mut matches: Vec<_> = self
                .applications()?
                .into_iter()
                .filter(|a| a.bundle_identifier.as_deref() == Some(bundle_id) && !a.is_terminated)
                .collect();

            if matches.len() > 1 {
                return Err(AutomationError::AmbiguousApplication);
            }
            let application = if let Some(app) = matches.pop() {
                app
            } else {
                workspace_open(bundle_id, None, before_dispatch).await?
            };
            let mut binding = self.activate_and_bind(application, before_dispatch).await?;
            if let Some(url) = url {
                let opened = workspace_open(bundle_id, Some(url), before_dispatch).await?;
                if !binding.same_process(&opened) {
                    return Err(AutomationError::TargetChanged);
                }
                binding = self.activate_and_bind(opened, before_dispatch).await?;
            }
            self.validate(&binding)?;
            Ok(binding)
        })
    }
    fn application_executable(&self, bundle_id: &str) -> Result<std::path::PathBuf> {
        self.check_thread()?;
        let bundle_id = NSString::from_str(bundle_id);
        let url = NSWorkspace::sharedWorkspace()
            .URLForApplicationWithBundleIdentifier(&bundle_id)
            .ok_or(AutomationError::NotRunning)?;
        let bundle = NSBundle::bundleWithURL(&url).ok_or(AutomationError::NotRunning)?;
        if bundle.bundleIdentifier().as_ref().map(|s| s.to_string()) != Some(bundle_id.to_string())
        {
            return Err(AutomationError::TargetChanged);
        }
        let executable = bundle
            .executableURL()
            .and_then(|url| url.path())
            .ok_or(AutomationError::NotRunning)?;
        let path = std::path::PathBuf::from(executable.to_string());
        if !path.is_absolute() || !path.is_file() {
            return Err(AutomationError::NotRunning);
        }
        Ok(path)
    }
    fn bind_owned_process<'a>(
        &'a mut self,
        pid: i32,
        executable: &'a std::path::Path,
        activate: bool,
        before_dispatch: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async move {
            self.require_ax()?;
            if !activate {
                return Err(AutomationError::NotForeground);
            }
            let app = self.application(pid)?;
            let args = process_arguments(pid)?;
            let actual = args.first().ok_or(AutomationError::TargetChanged)?;
            if std::fs::canonicalize(actual).map_err(|_| AutomationError::TargetChanged)?
                != std::fs::canonicalize(executable).map_err(|_| AutomationError::TargetChanged)?
            {
                return Err(AutomationError::TargetChanged);
            }
            self.activate_and_bind(app, before_dispatch).await
        })
    }
    fn validate(&self, binding: &BoundApplication) -> Result<()> {
        self.require_ax()?;
        if self.binding.as_ref().is_none_or(|b| {
            b.generation != binding.generation || b.window_token != binding.window_token
        }) {
            return Err(AutomationError::TargetChanged);
        }
        if !binding.same_process(&self.application(binding.application.process_identifier)?) {
            return Err(AutomationError::TargetChanged);
        }
        let (current, _) = self.selected(binding.application.process_identifier)?;
        if self
            .selected_window
            .as_ref()
            .is_none_or(|w| !w.same(&current))
        {
            return Err(AutomationError::TargetChanged);
        }
        Ok(())
    }
    fn observe(&mut self, binding: &BoundApplication, limits: TreeLimits) -> Result<AxSnapshot> {
        self.validate(binding)?;
        let limits = limits.validate()?;
        let root = self
            .selected_window
            .as_ref()
            .ok_or(AutomationError::WindowUnavailable)?
            .retained();
        if !self.nodes.is_empty() {
            self.previous_nodes = std::mem::take(&mut self.nodes);
        }
        let mut nodes = HashMap::new();
        let mut elements = vec![];
        let mut pending = VecDeque::from([(root, None, 0usize)]);
        let mut truncated = false;
        let mut seen: Vec<OwnedCf> = vec![];
        while let Some((element, parent, depth)) = pending.pop_front() {
            self.validate(binding)?;
            if elements.len() >= limits.max_elements {
                truncated = true;
                break;
            }
            if owner(&element)? != binding.application.process_identifier {
                return Err(AutomationError::TargetChanged);
            }
            if seen.iter().any(|x| x.same(&element)) {
                truncated = true;
                continue;
            }
            seen.push(element.retained());
            let identity = self
                .previous_nodes
                .iter()
                .find(|(_, x)| x.same(&element))
                .map(|(id, _)| *id)
                .unwrap_or_else(Uuid::new_v4);
            let index = elements.len();
            let raw_children = attribute(&element, "AXChildren")?
                .map(|a| array_owned(&a))
                .transpose()?
                .unwrap_or_default();
            let children_truncated = raw_children.len() > limits.max_children_per_element
                || (depth == limits.max_depth && !raw_children.is_empty());
            let mut text_truncated = false;
            let mut bounded = |text: Option<String>| {
                text.map(|s| {
                    if s.chars().count() > limits.max_text_length {
                        text_truncated = true;
                        s.chars().take(limits.max_text_length).collect()
                    } else {
                        s
                    }
                })
            };
            let mut available = actions(&element)?;
            if available.len() > limits.max_actions_per_element {
                available.truncate(limits.max_actions_per_element);
                truncated = true
            }
            let node = AxNode {
                index,
                parent_index: parent,
                identity,
                role: string_attribute(&element, "AXRole")?,
                subrole: string_attribute(&element, "AXSubrole")?,
                title: bounded(string_attribute(&element, "AXTitle")?),
                element_description: bounded(string_attribute(&element, "AXDescription")?),
                help: bounded(string_attribute(&element, "AXHelp")?),
                value: bounded(value_text(&element)?),
                identifier: string_attribute(&element, "AXIdentifier")?,
                link_url: string_attribute(&element, "AXURL")?,
                frame: frame(&element)?,
                is_enabled: bool_attribute(&element, "AXEnabled")?,
                is_selected: bool_attribute(&element, "AXSelected")?,
                is_focused: bool_attribute(&element, "AXFocused")?,
                is_value_settable: settable(&element)?,
                actions: available,
                children_truncated,
                text_truncated,
            };
            truncated |= children_truncated || text_truncated;
            if depth < limits.max_depth {
                for child in raw_children
                    .into_iter()
                    .take(limits.max_children_per_element)
                {
                    pending.push_back((child, Some(index), depth + 1));
                }
            }
            nodes.insert(identity, element);
            elements.push(node);
        }
        if let Err(e) = self.validate(binding) {
            self.nodes.clear();
            return Err(e);
        }
        self.nodes = nodes;
        let (_, window) = self.selected(binding.application.process_identifier)?;
        Ok(AxSnapshot {
            id: Uuid::new_v4(),
            target_generation: binding.generation,
            window,
            elements,
            source_truncated: truncated,
            captured_at: unix_time(),
        })
    }
    fn mutate(
        &mut self,
        binding: &BoundApplication,
        element: Uuid,
        mutation: NativeMutation,
        before_dispatch: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()> {
        self.validate(binding)?;
        let target = self
            .nodes
            .get(&element)
            .ok_or(AutomationError::StaleObservation)?
            .retained();
        if owner(&target)? != binding.application.process_identifier {
            return Err(AutomationError::TargetChanged);
        }
        if bool_attribute(&target, "AXEnabled")? == Some(false) {
            return Err(AutomationError::UnsupportedAction);
        }
        let (key, value) = match mutation {
            NativeMutation::Action(action) => {
                if action == "AXRaise" && !binding.activated {
                    return Err(AutomationError::UnsupportedAction);
                }
                if !actions(&target)?.contains(&action) {
                    return Err(AutomationError::UnsupportedAction);
                }
                (cf_string(&action), None)
            }
            NativeMutation::SetValue(text) => {
                if !settable(&target)? {
                    return Err(AutomationError::NotSettable);
                }
                (cf_string("AXValue"), Some(cf_string(&text)))
            }
        };
        self.validate(binding)?;
        let foreground = if !binding.activated {
            Some(
                NSWorkspace::sharedWorkspace()
                    .frontmostApplication()
                    .map(|app| app.processIdentifier()),
            )
        } else {
            None
        };
        if foreground.is_some_and(|before| {
            before
                != NSWorkspace::sharedWorkspace()
                    .frontmostApplication()
                    .map(|app| app.processIdentifier())
        }) {
            return Err(AutomationError::ForegroundChanged);
        }
        before_dispatch()?;
        // Capabilities are consumed before dispatch, including failures with uncertain effect.
        self.previous_nodes = std::mem::take(&mut self.nodes);
        // SAFETY: checked retained AX target and action/attribute; dispatch occurs once.
        let code = unsafe {
            if let Some(value) = value {
                AXUIElementSetAttributeValue(target.raw(), key.raw(), value.raw())
            } else {
                AXUIElementPerformAction(target.raw(), key.raw())
            }
        };
        if foreground.is_some_and(|before| {
            before
                != NSWorkspace::sharedWorkspace()
                    .frontmostApplication()
                    .map(|app| app.processIdentifier())
        }) {
            self.invalidate();
            return Err(AutomationError::ForegroundChanged);
        }
        if code != 0 {
            return Err(AutomationError::Native {
                operation: "AXMutation".into(),
                code,
            });
        }
        self.validate(binding)
    }
    fn capture<'a>(
        &'a mut self,
        binding: &'a BoundApplication,
        display_id: Option<u32>,
        shows_cursor: bool,
    ) -> Pin<Box<dyn Future<Output = Result<CapturedImage>> + 'a>> {
        Box::pin(async move {
            self.validate(binding)?;
            if self.permissions().screen_recording != PermissionGrant::Granted {
                return Err(AutomationError::ScreenRecordingPermission);
            }
            if (display_id.is_some() || shows_cursor) && !binding.activated {
                return Err(AutomationError::NotForeground);
            }
            let (_, before) = self.selected(binding.application.process_identifier)?;
            let mut capture_binding = binding.clone();
            capture_binding.window = before.clone();
            let mut image = capture_image(capture_binding, display_id, shows_cursor).await?;
            self.validate(binding)?;
            let (_, after) = self.selected(binding.application.process_identifier)?;
            if before.window_id != after.window_id
                || before.frame != after.frame
                || before.document != after.document
                || before.title != after.title
            {
                return Err(AutomationError::TargetChanged);
            }
            image.window = after;
            if self.permissions().screen_recording != PermissionGrant::Granted {
                return Err(AutomationError::ScreenRecordingPermission);
            }
            Ok(image)
        })
    }
    fn input(
        &mut self,
        binding: &BoundApplication,
        action: InputAction,
        before_dispatch: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()> {
        if !binding.activated {
            return Err(AutomationError::NotForeground);
        }
        self.require_foreground(binding)?;
        let pointer = match &action {
            InputAction::Click(p)
            | InputAction::Move(p)
            | InputAction::DoubleClick(p)
            | InputAction::RightClick(p) => Some(*p),
            InputAction::Scroll { point, .. } => Some(*point),
            _ => None,
        };
        if let Some(p) = pointer {
            self.hit_test(binding, p)?
        }
        // SAFETY: source owns a valid CGEventSource reference using combined-session state.
        let source = unsafe { OwnedCf::owned(CGEventSourceCreate(0)) }
            .ok_or(AutomationError::Invalid("CGEventSource".into()))?;
        let mouse = |kind, point: Point, button| -> Result<OwnedCf> {
            // SAFETY: source is live; point validated against the exact window and occlusion.
            unsafe {
                OwnedCf::owned(CGEventCreateMouseEvent(
                    source.raw(),
                    kind,
                    CPoint {
                        x: point.x,
                        y: point.y,
                    },
                    button,
                ))
            }
            .ok_or(AutomationError::Invalid("mouse event".into()))
        };
        match action {
            InputAction::Move(p) => {
                let event = mouse(5, p, 0)?;
                self.require_foreground(binding)?;
                self.hit_test(binding, p)?;
                before_dispatch()?;
                self.send_event(event)
            }
            InputAction::Click(p) | InputAction::RightClick(p) | InputAction::DoubleClick(p) => {
                let (down, up, button, count) = match &action {
                    InputAction::RightClick(_) => (3, 4, 1, 1),
                    InputAction::DoubleClick(_) => (1, 2, 0, 2),
                    _ => (1, 2, 0, 1),
                };
                for click in 1..=count {
                    self.require_foreground(binding)?;
                    self.hit_test(binding, p)?;
                    let d = mouse(down, p, button)?;
                    let u = mouse(up, p, button)?;
                    // SAFETY: field 1 is mouse click state on a retained mouse event.
                    unsafe {
                        CGEventSetIntegerValueField(d.raw(), 1, click);
                        CGEventSetIntegerValueField(u.raw(), 1, click)
                    }
                    self.require_foreground(binding)?;
                    self.hit_test(binding, p)?;
                    before_dispatch()?;
                    self.send_event(d);
                    self.send_event(u);
                }
            }
            InputAction::Scroll {
                point,
                delta_x,
                delta_y,
            } => {
                if !delta_x.is_finite()
                    || !delta_y.is_finite()
                    || delta_x.abs() > 10_000.
                    || delta_y.abs() > 10_000.
                {
                    return Err(AutomationError::Invalid("scroll delta".into()));
                }
                // SAFETY: variadic arguments match the documented signed wheel delta ABI.
                let event = unsafe {
                    OwnedCf::owned(CGEventCreateScrollWheelEvent(
                        source.raw(),
                        0,
                        2,
                        delta_y as i32,
                        delta_x as i32,
                    ))
                }
                .ok_or(AutomationError::Invalid("scroll event".into()))?;
                // SAFETY: retained event with a checked window coordinate.
                unsafe {
                    CGEventSetLocation(
                        event.raw(),
                        CPoint {
                            x: point.x,
                            y: point.y,
                        },
                    )
                }
                self.require_foreground(binding)?;
                self.hit_test(binding, point)?;
                before_dispatch()?;
                self.send_event(event);
            }
            InputAction::Key { key, modifiers } => {
                let code = key_code(&key)?;
                let mut flags = 0u64;
                for modifier in modifiers {
                    flags |= match modifier.as_str() {
                        "command" => 1 << 20,
                        "control" => 1 << 18,
                        "option" => 1 << 19,
                        "shift" => 1 << 17,
                        "function" => 1 << 23,
                        _ => return Err(AutomationError::Invalid("key modifier".into())),
                    }
                }
                // SAFETY: valid live event source and closed hardware-key mapping.
                let down =
                    unsafe { OwnedCf::owned(CGEventCreateKeyboardEvent(source.raw(), code, 1)) }
                        .ok_or(AutomationError::Invalid("key event".into()))?;
                // SAFETY: key-up is allocated before any dispatch so release cannot fail allocation.
                let up =
                    unsafe { OwnedCf::owned(CGEventCreateKeyboardEvent(source.raw(), code, 0)) }
                        .ok_or(AutomationError::Invalid("key event".into()))?;
                // SAFETY: both events own live CGEvent references; flags are closed modifiers.
                unsafe {
                    CGEventSetFlags(down.raw(), flags);
                    CGEventSetFlags(up.raw(), flags)
                }
                self.require_foreground(binding)?;
                before_dispatch()?;
                self.send_event(down);
                self.send_event(up);
            }
            InputAction::Type(text) => {
                for chunk in utf16_chunks(&text) {
                    // SAFETY: source is valid; Unicode chunks preserve surrogate pairs.
                    let down =
                        unsafe { OwnedCf::owned(CGEventCreateKeyboardEvent(source.raw(), 0, 1)) }
                            .ok_or(AutomationError::Invalid("unicode event".into()))?;
                    // SAFETY: allocate key-up before dispatch; both owned references remain live.
                    let up =
                        unsafe { OwnedCf::owned(CGEventCreateKeyboardEvent(source.raw(), 0, 0)) }
                            .ok_or(AutomationError::Invalid("unicode event".into()))?;
                    // SAFETY: valid UTF-16 slices; the API copies the bounded code units.
                    unsafe {
                        CGEventKeyboardSetUnicodeString(down.raw(), chunk.len(), chunk.as_ptr());
                        CGEventKeyboardSetUnicodeString(up.raw(), chunk.len(), chunk.as_ptr())
                    }
                    self.require_foreground(binding)?;
                    before_dispatch()?;
                    self.send_event(down);
                    self.send_event(up);
                }
            }
        }
        self.nodes.clear();
        self.require_foreground(binding)
    }
    fn displays(&self) -> Result<Vec<DisplayInfo>> {
        self.check_thread()?;
        let mut ids = [0u32; 64];
        let mut count = 0;
        // SAFETY: bounded display buffer and correctly sized count slot.
        let code = unsafe { CGGetActiveDisplayList(64, ids.as_mut_ptr(), &mut count) };
        if code != 0 {
            return Err(AutomationError::Native {
                operation: "CGDisplayList".into(),
                code,
            });
        }
        Ok(ids[..(count as usize).min(64)]
            .iter()
            .map(|id| {
                // SAFETY: IDs came from the current active display inventory.
                unsafe {
                    let r = CGDisplayBounds(*id);
                    DisplayInfo {
                        display_id: *id,
                        frame: Rect {
                            x: r.origin.x,
                            y: r.origin.y,
                            width: r.size.width,
                            height: r.size.height,
                        },
                        pixel_width: CGDisplayPixelsWide(*id),
                        pixel_height: CGDisplayPixelsHigh(*id),
                    }
                }
            })
            .collect())
    }
    fn invalidate(&mut self) {
        self.nodes.clear();
        self.previous_nodes.clear();
        self.selected_window = None;
        self.binding = None;
    }
}

fn key_code(key: &str) -> Result<u16> {
    let lower = key.to_ascii_lowercase();
    let code = match lower.as_str() {
        "return" | "enter" => 36,
        "tab" => 48,
        "space" => 49,
        "delete" | "backspace" => 51,
        "escape" | "esc" => 53,
        "left" | "arrowleft" => 123,
        "right" | "arrowright" => 124,
        "down" | "arrowdown" => 125,
        "up" | "arrowup" => 126,
        "home" => 115,
        "end" => 119,
        "pageup" | "page_up" => 116,
        "pagedown" | "page_down" => 121,
        "forwarddelete" | "forward_delete" => 117,
        "a" => 0,
        "s" => 1,
        "d" => 2,
        "f" => 3,
        "h" => 4,
        "g" => 5,
        "z" => 6,
        "x" => 7,
        "c" => 8,
        "v" => 9,
        "b" => 11,
        "q" => 12,
        "w" => 13,
        "e" => 14,
        "r" => 15,
        "y" => 16,
        "t" => 17,
        "1" => 18,
        "2" => 19,
        "3" => 20,
        "4" => 21,
        "6" => 22,
        "5" => 23,
        "=" => 24,
        "9" => 25,
        "7" => 26,
        "-" => 27,
        "8" => 28,
        "0" => 29,
        "]" => 30,
        "o" => 31,
        "u" => 32,
        "[" => 33,
        "i" => 34,
        "p" => 35,
        "l" => 37,
        "j" => 38,
        "'" => 39,
        "k" => 40,
        ";" => 41,
        "\\" => 42,
        "," => 43,
        "/" => 44,
        "n" => 45,
        "m" => 46,
        "." => 47,
        "`" => 50,
        "f1" => 122,
        "f2" => 120,
        "f3" => 99,
        "f4" => 118,
        "f5" => 96,
        "f6" => 97,
        "f7" => 98,
        "f8" => 100,
        "f9" => 101,
        "f10" => 109,
        "f11" => 103,
        "f12" => 111,
        _ => return Err(AutomationError::Invalid("unsupported key".into())),
    };
    Ok(code)
}

fn png(image: Raw) -> Result<(Vec<u8>, usize, usize)> {
    // SAFETY: called while ScreenCaptureKit owns its callback's live CGImage.
    unsafe {
        let width = CGImageGetWidth(image);
        let height = CGImageGetHeight(image);
        if width == 0 || height == 0 || width.checked_mul(height).is_none_or(|x| x > 32_000_000) {
            return Err(AutomationError::Invalid("screenshot pixel budget".into()));
        }
        let data = OwnedCf::owned(CFDataCreateMutable(ptr::null(), 0))
            .ok_or(AutomationError::Invalid("PNG allocation".into()))?;
        let kind = cf_string("public.png");
        let destination = OwnedCf::owned(CGImageDestinationCreateWithData(
            data.raw(),
            kind.raw(),
            1,
            ptr::null(),
        ))
        .ok_or(AutomationError::Invalid("PNG encoder".into()))?;
        CGImageDestinationAddImage(destination.raw(), image, ptr::null());
        if CGImageDestinationFinalize(destination.raw()) == 0 {
            return Err(AutomationError::Invalid("PNG encoding".into()));
        }
        let len = CFDataGetLength(data.raw());
        // Base64 plus receipt text must fit the app-server 16 MiB frame budget.
        // Do not rescale a capture behind its qualified coordinate mapping.
        if !(1..=10_485_760).contains(&len) {
            return Err(AutomationError::Invalid("PNG byte budget".into()));
        }
        Ok((
            std::slice::from_raw_parts(CFDataGetBytePtr(data.raw()), len as usize).to_vec(),
            width,
            height,
        ))
    }
}
fn send_capture(
    sender: &Arc<Mutex<Option<tokio::sync::oneshot::Sender<Result<CapturedImage>>>>>,
    result: Result<CapturedImage>,
) {
    if let Ok(mut sender) = sender.lock()
        && let Some(sender) = sender.take()
    {
        let _ = sender.send(result);
    }
}
async fn capture_image(
    binding: BoundApplication,
    display_id: Option<u32>,
    shows_cursor: bool,
) -> Result<CapturedImage> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    let sender = Arc::new(Mutex::new(Some(tx)));
    let window = binding.window.clone();
    let block = RcBlock::new(
        move |content: *mut SCShareableContent, error: *mut NSError| {
            if content.is_null() || !error.is_null() {
                send_capture(
                    &sender,
                    Err(AutomationError::Native {
                        operation: "SCShareableContent".into(),
                        code: if error.is_null() {
                            -1
                        } else {
                            // SAFETY: the framework supplies a valid NSError during this callback.
                            unsafe { (*error).code() as i32 }
                        },
                    }),
                );
                return;
            }
            // SAFETY: content remains alive for this framework callback; allocations
            // and methods are called with documented class types. No AX handle is captured.
            unsafe {
                let content = &*content;
                let (filter, rect) = if let Some(display_id) = display_id {
                    let Some(display) = content
                        .displays()
                        .iter()
                        .find(|d| d.displayID() == display_id)
                    else {
                        send_capture(
                            &sender,
                            Err(AutomationError::Invalid("unavailable display".into())),
                        );
                        return;
                    };
                    let r = display.frame();
                    let empty = NSArray::new();
                    (
                        SCContentFilter::initWithDisplay_excludingWindows(
                            SCContentFilter::alloc(),
                            &display,
                            &empty,
                        ),
                        Rect {
                            x: r.origin.x,
                            y: r.origin.y,
                            width: r.size.width,
                            height: r.size.height,
                        },
                    )
                } else {
                    let matches: Vec<_> = content
                        .windows()
                        .iter()
                        .filter(|w| {
                            w.owningApplication()
                                .is_some_and(|a| a.processID() == window.process_identifier)
                                && window.frame.is_some_and(|f| {
                                    let r = w.frame();
                                    same_frame(
                                        f,
                                        Rect {
                                            x: r.origin.x,
                                            y: r.origin.y,
                                            width: r.size.width,
                                            height: r.size.height,
                                        },
                                    )
                                })
                                && window.window_id.is_none_or(|id| w.windowID() == id)
                        })
                        .collect();
                    if matches.len() != 1 {
                        send_capture(&sender, Err(AutomationError::TargetChanged));
                        return;
                    }
                    let w = &matches[0];
                    let r = w.frame();
                    (
                        SCContentFilter::initWithDesktopIndependentWindow(
                            SCContentFilter::alloc(),
                            w,
                        ),
                        Rect {
                            x: r.origin.x,
                            y: r.origin.y,
                            width: r.size.width,
                            height: r.size.height,
                        },
                    )
                };
                if rect.validate().is_err() {
                    send_capture(
                        &sender,
                        Err(AutomationError::Invalid("capture frame".into())),
                    );
                    return;
                }
                let configuration = SCStreamConfiguration::new();
                configuration.setWidth((rect.width * 2.).ceil() as usize);
                configuration.setHeight((rect.height * 2.).ceil() as usize);
                configuration.setShowsCursor(shows_cursor);
                let sender = sender.clone();
                let window = window.clone();
                let completion = RcBlock::new(
                    move |image: *mut objc2_core_graphics::CGImage, error: *mut NSError| {
                        let result = if image.is_null() || !error.is_null() {
                            Err(AutomationError::Native {
                                operation: "SCScreenshot".into(),
                                code: -1,
                            })
                        } else {
                            png(image.cast()).map(|(png, width, height)| CapturedImage {
                                id: Uuid::new_v4(),
                                png,
                                width,
                                height,
                                frame: rect,
                                captured_at: unix_time(),
                                window: window.clone(),
                                actionable: binding.activated,
                            })
                        };
                        send_capture(&sender, result);
                    },
                );
                SCScreenshotManager::captureImageWithFilter_configuration_completionHandler(
                    &filter,
                    &configuration,
                    Some(&completion),
                );
            }
        },
    );
    // SAFETY: native caller preflighted Screen Recording. The framework copies
    // the block; its captured values are thread-safe plain data and a mutex.
    unsafe { SCShareableContent::getShareableContentWithCompletionHandler(&block) };
    tokio::time::timeout(std::time::Duration::from_secs(15), rx)
        .await
        .map_err(|_| AutomationError::Native {
            operation: "SCScreenshot timeout".into(),
            code: -1,
        })?
        .map_err(|_| AutomationError::Cancelled)?
}

fn validate_open_url(url: Option<&str>) -> Result<()> {
    if let Some(raw) = url
        && (raw.is_empty()
            || raw.len() > 8192
            || raw.chars().any(char::is_control)
            || !raw.split_once(':').is_some_and(|(scheme, _)| {
                matches!(
                    scheme.to_ascii_lowercase().as_str(),
                    "http" | "https" | "file"
                )
            })
            || NSURL::URLWithString(&NSString::from_str(raw)).is_none())
    {
        return Err(AutomationError::Invalid("http, https, or file URL".into()));
    }
    Ok(())
}
/// AppKit owns the completion block until delivery. Only scalar/string process
/// identity leaves the callback, never an AX object or borrowed application.
async fn workspace_open(
    bundle_id: &str,
    url: Option<&str>,
    before: &mut dyn FnMut() -> Result<()>,
) -> Result<RunningApplication> {
    validate_open_url(url)?;
    let workspace = NSWorkspace::sharedWorkspace();
    let bundle_string = NSString::from_str(bundle_id);
    let application_url = workspace
        .URLForApplicationWithBundleIdentifier(&bundle_string)
        .ok_or(AutomationError::NotRunning)?;
    let bundle = NSBundle::bundleWithURL(&application_url).ok_or(AutomationError::NotRunning)?;
    if bundle
        .bundleIdentifier()
        .map(|id| id.to_string())
        .as_deref()
        != Some(bundle_id)
    {
        return Err(AutomationError::TargetChanged);
    }
    let configuration = NSWorkspaceOpenConfiguration::new();
    configuration.setActivates(true);
    configuration.setCreatesNewApplicationInstance(false);
    let (tx, rx) = tokio::sync::oneshot::channel();
    let sender = Arc::new(Mutex::new(Some(tx)));
    let copied = sender.clone();
    let completion = RcBlock::new(
        move |application: *mut NSRunningApplication, error: *mut NSError| {
            // SAFETY: AppKit supplies callback-lifetime object references, which are
            // read only here; no borrowed native reference is sent across threads.
            let value = unsafe {
                if let Some(error) = error.as_ref() {
                    Err(AutomationError::Native {
                        operation: "NSWorkspaceOpen".into(),
                        code: error.code() as i32,
                    })
                } else if let Some(application) = application.as_ref() {
                    Ok(describe_application(application))
                } else {
                    Err(AutomationError::NotRunning)
                }
            };
            if let Ok(mut sender) = copied.lock()
                && let Some(sender) = sender.take()
            {
                let _ = sender.send(value);
            }
        },
    );
    before()?;
    if let Some(url) = url {
        let url = NSURL::URLWithString(&NSString::from_str(url))
            .ok_or(AutomationError::Invalid("URL".into()))?;
        let urls = NSArray::from_retained_slice(&[url]);
        workspace.openURLs_withApplicationAtURL_configuration_completionHandler(
            &urls,
            &application_url,
            &configuration,
            Some(&completion),
        );
    } else {
        workspace.openApplicationAtURL_configuration_completionHandler(
            &application_url,
            &configuration,
            Some(&completion),
        );
    }
    let app = tokio::time::timeout(std::time::Duration::from_secs(15), rx)
        .await
        .map_err(|_| AutomationError::Native {
            operation: "NSWorkspaceOpenTimeout".into(),
            code: -1,
        })?
        .map_err(|_| AutomationError::Cancelled)??;
    if app.bundle_identifier.as_deref() != Some(bundle_id)
        || app.is_terminated
        || app.process_identifier <= 0
        || !app.launch_time.is_some_and(f64::is_finite)
    {
        return Err(AutomationError::TargetChanged);
    }
    Ok(app)
}
impl NativeBackend {
    async fn activate_and_bind(
        &mut self,
        identity: RunningApplication,
        before: &mut dyn FnMut() -> Result<()>,
    ) -> Result<BoundApplication> {
        self.require_ax()?;
        let app = NSRunningApplication::runningApplicationWithProcessIdentifier(
            identity.process_identifier,
        )
        .ok_or(AutomationError::TargetChanged)?;
        let current = describe_application(&app);
        if current.process_identifier != identity.process_identifier
            || current.bundle_identifier != identity.bundle_identifier
            || current.launch_time != identity.launch_time
            || current.is_terminated
        {
            return Err(AutomationError::TargetChanged);
        }
        if !app.isActive() {
            before()?;
            let source = NSRunningApplication::currentApplication();
            let own = NSApplication::sharedApplication(self._main);
            if own.isActive() {
                own.yieldActivationToApplication(&app);
                if !app.activateFromApplication_options(
                    &source,
                    NSApplicationActivationOptions::ActivateAllWindows,
                ) {
                    return Err(AutomationError::NotForeground);
                }
            } else if !app.activateWithOptions(NSApplicationActivationOptions::ActivateAllWindows) {
                return Err(AutomationError::NotForeground);
            }
        }
        for attempt in 0..100 {
            self.require_ax()?;
            before()?;
            let actual = self.application(identity.process_identifier)?;
            if actual.launch_time != identity.launch_time
                || actual.bundle_identifier != identity.bundle_identifier
                || actual.is_terminated
            {
                return Err(AutomationError::TargetChanged);
            }
            if NSWorkspace::sharedWorkspace()
                .frontmostApplication()
                .is_some_and(|front| front.processIdentifier() == identity.process_identifier)
                && let Ok((window, info)) = self.selected(identity.process_identifier)
                && info.is_focused
            {
                let binding = BoundApplication {
                    application: actual,
                    window: info,
                    window_token: Uuid::new_v4(),
                    generation: Uuid::new_v4(),
                    activated: true,
                };
                self.nodes.clear();
                self.previous_nodes.clear();
                self.selected_window = Some(window);
                self.binding = Some(binding.clone());
                self.require_foreground(&binding)?;
                return Ok(binding);
            }
            if attempt < 99 {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
        }
        Err(AutomationError::NotForeground)
    }
}

fn utf16_chunks(text: &str) -> Vec<Vec<u16>> {
    let units: Vec<_> = text.encode_utf16().collect();
    let mut start = 0;
    let mut out = vec![];
    while start < units.len() {
        let mut end = (start + 20).min(units.len());
        if end < units.len()
            && (0xD800..=0xDBFF).contains(&units[end - 1])
            && (0xDC00..=0xDFFF).contains(&units[end])
        {
            end -= 1
        }
        out.push(units[start..end].to_vec());
        start = end
    }
    out
}
#[cfg(test)]
mod input_tests {
    use super::*;
    #[test]
    fn unicode_chunks_do_not_split_surrogate_pairs() {
        let text = format!("{}😀{}", "a".repeat(19), "é".repeat(40));
        let chunks = utf16_chunks(&text);
        assert!(
            chunks
                .iter()
                .all(|c| c.len() <= 20 && String::from_utf16(c).is_ok())
        );
        assert_eq!(String::from_utf16(&chunks.concat()).unwrap(), text);
    }
}
