//! Trusted AppKit controls. Page IPC cannot resolve these prompts or set access
//! mode. Completion events carry the exact native request identity for the host
//! to claim once. AppKit modal sheets fence the containing WebViews while open.
use crate::{AutomationError, Result};
use block2::RcBlock;
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained, sel,
};
use objc2_app_kit::{NSAlert, NSModalResponse, NSPopUpButton, NSTextField, NSView, NSWindow};
use objc2_foundation::{NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NativeAccessMode {
    AskEveryTime,
    FullAccess,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NativeControlEvent {
    AccessModeChanged(NativeAccessMode),
    RequestPairingUi,
    DisconnectChrome,
    RequestTemporaryTabGrant,
    ApprovalResolved { id: String, approved: bool },
    PairingResolved { id: String, remember: bool },
    TemporaryTabGrantResolved { id: String, approved: bool },
    RequestAccessibility,
    RequestScreenRecording,
}
#[derive(Clone, Debug, Eq, PartialEq)]
enum Prompt {
    Approval(String),
    Pairing(String),
    Temporary(String),
}
impl Prompt {
    fn id(&self) -> &str {
        match self {
            Self::Approval(id) | Self::Pairing(id) | Self::Temporary(id) => id,
        }
    }
}
struct TargetIvars {
    callback: Rc<dyn Fn(NativeControlEvent)>,
    mode: Cell<NativeAccessMode>,
    mode_button: RefCell<Option<Retained<NSPopUpButton>>>,
    chrome_button: RefCell<Option<Retained<NSPopUpButton>>>,
    pending: Rc<RefCell<Option<Prompt>>>,
}
define_class!(
    // SAFETY: NSObject has no subclassing invariants. Ivars never implement Drop
    // against foreign state and the class is constrained to the AppKit thread.
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[ivars = TargetIvars]
    struct ControlTarget;
    // SAFETY: NSObjectProtocol has no additional implementation requirements.
    unsafe impl NSObjectProtocol for ControlTarget {}
    impl ControlTarget {
        // SAFETY: this selector is connected only to the retained NSPopUpButton
        // with the exact Objective-C target/action signature.
        #[unsafe(method(modeChanged:))]
        fn mode_changed(&self,sender:&NSPopUpButton){
            if self.ivars().mode_button.borrow().as_ref().is_none_or(|b|!std::ptr::eq(&**b,sender)){return}
            let mode=match sender.indexOfSelectedItem(){0=>NativeAccessMode::AskEveryTime,1=>NativeAccessMode::FullAccess,_=>return};
            self.ivars().mode.set(mode);(self.ivars().callback)(NativeControlEvent::AccessModeChanged(mode));
        }
        // SAFETY: exact native sender and action signature, no page-controlled input.
        #[unsafe(method(chromeChanged:))]
        fn chrome_changed(&self,sender:&NSPopUpButton){
            if self.ivars().chrome_button.borrow().as_ref().is_none_or(|b|!std::ptr::eq(&**b,sender)){return}
            let event=match sender.indexOfSelectedItem(){1=>Some(NativeControlEvent::RequestPairingUi),2=>Some(NativeControlEvent::DisconnectChrome),3=>Some(NativeControlEvent::RequestTemporaryTabGrant),4=>Some(NativeControlEvent::RequestAccessibility),5=>Some(NativeControlEvent::RequestScreenRecording),_=>None};
            sender.selectItemAtIndex(0);if let Some(event)=event{(self.ivars().callback)(event)}
        }
    }
);
impl ControlTarget {
    fn new(mtm: MainThreadMarker, callback: Rc<dyn Fn(NativeControlEvent)>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars {
            callback,
            mode: Cell::new(NativeAccessMode::AskEveryTime),
            mode_button: RefCell::new(None),
            chrome_button: RefCell::new(None),
            pending: Rc::new(RefCell::new(None)),
        });
        // SAFETY: superclass init is called once after Rust ivars initialization.
        unsafe { msg_send![super(this), init] }
    }
}
pub struct TrustedNativeControls {
    window: Retained<NSWindow>,
    view: Retained<NSView>,
    target: Retained<ControlTarget>,
    mode: Retained<NSPopUpButton>,
    chrome: Retained<NSPopUpButton>,
    status: Retained<NSTextField>,
    alert: Option<Retained<NSAlert>>,
}
impl TrustedNativeControls {
    pub fn new(window: &NSWindow, callback: Rc<dyn Fn(NativeControlEvent)>) -> Result<Self> {
        let mtm = MainThreadMarker::new().ok_or(AutomationError::WrongThread)?;
        let content = window
            .contentView()
            .ok_or(AutomationError::WindowUnavailable)?;
        let target = ControlTarget::new(mtm, callback);
        let view = NSView::initWithFrame(
            NSView::alloc(mtm),
            NSRect::new(
                NSPoint::new(0., 0.),
                NSSize::new(content.frame().size.width, 34.),
            ),
        );
        let mode = NSPopUpButton::initWithFrame_pullsDown(
            NSPopUpButton::alloc(mtm),
            NSRect::new(NSPoint::new(8., 3.), NSSize::new(155., 28.)),
            false,
        );
        for title in ["Ask every time", "Full access"] {
            mode.addItemWithTitle(&NSString::from_str(title))
        }
        let chrome = NSPopUpButton::initWithFrame_pullsDown(
            NSPopUpButton::alloc(mtm),
            NSRect::new(NSPoint::new(170., 3.), NSSize::new(190., 28.)),
            false,
        );
        for title in [
            "Chrome connection",
            "Pair extension…",
            "Disconnect Chrome",
            "Allow temporary tabs…",
            "Accessibility Settings…",
            "Screen Recording Settings…",
        ] {
            chrome.addItemWithTitle(&NSString::from_str(title))
        }
        let status = NSTextField::labelWithString(&NSString::from_str("Runtime disconnected"), mtm);
        status.setFrame(NSRect::new(NSPoint::new(375., 8.), NSSize::new(550., 20.)));
        // SAFETY: targets have the matching selector ABI and are retained for
        // the complete controls lifetime; views belong to this live NSWindow.
        unsafe {
            mode.setTarget(Some(&target));
            mode.setAction(Some(sel!(modeChanged:)));
            chrome.setTarget(Some(&target));
            chrome.setAction(Some(sel!(chromeChanged:)));
            view.addSubview(&mode);
            view.addSubview(&chrome);
            view.addSubview(&status);
            content.addSubview(&view);
        }
        *target.ivars().mode_button.borrow_mut() = Some(mode.clone());
        *target.ivars().chrome_button.borrow_mut() = Some(chrome.clone());
        // SAFETY: a live borrowed window is retained before long-term storage.
        let window = unsafe { Retained::retain(window as *const NSWindow as *mut NSWindow) }
            .ok_or(AutomationError::WindowUnavailable)?;
        Ok(Self {
            window,
            view,
            target,
            mode,
            chrome,
            status,
            alert: None,
        })
    }
    pub fn set_access_mode(&self, mode: NativeAccessMode) {
        self.target.ivars().mode.set(mode);
        self.mode
            .selectItemAtIndex(if mode == NativeAccessMode::AskEveryTime {
                0
            } else {
                1
            });
    }
    pub fn update_status(&self, text: &str) {
        self.status.setStringValue(&NSString::from_str(text));
    }
    pub fn resize(&self, width: f64) {
        if width.is_finite() && width > 0. {
            self.view
                .setFrame(NSRect::new(NSPoint::new(0., 0.), NSSize::new(width, 34.)));
            self.status.setFrame(NSRect::new(
                NSPoint::new(375., 8.),
                NSSize::new((width - 385.).max(1.), 20.),
            ));
        }
    }
    pub fn interaction_blocked(&self) -> bool {
        self.target.ivars().pending.borrow().is_some()
    }
    pub fn pending_id(&self) -> Option<String> {
        self.target
            .ivars()
            .pending
            .borrow()
            .as_ref()
            .map(|p| p.id().to_owned())
    }
    pub fn present_approval(
        &mut self,
        id: &str,
        title: &str,
        summary: &str,
        details: &str,
    ) -> Result<()> {
        validate_id(id)?;
        self.present(
            Prompt::Approval(id.into()),
            title,
            &format!("Requested action\n{summary}\n\nExact request details\n{details}"),
            "Allow once",
        )
    }
    pub fn present_pairing(
        &mut self,
        id: &str,
        extension_id: &str,
        installation_id: &str,
    ) -> Result<()> {
        validate_id(id)?;
        self.present(Prompt::Pairing(id.into()),"Pair Chrome extension",&format!("Allow the Computa Chrome extension to connect?\nExtension: {extension_id}\nInstallation: {installation_id}\n\nPairing is stored in your macOS Keychain. Browser and computer actions remain subject to your access mode and capability checks."),"Pair and remember")
    }
    pub fn present_temporary_tab_grant(&mut self, id: &str) -> Result<()> {
        validate_id(id)?;
        self.present(Prompt::Temporary(id.into()),"Allow temporary Chrome tabs", "Allow Computa to create an inactive temporary copy of an observed Chrome tab for an authorized task? The grant belongs to this paired connection. User activation relinquishes ownership; Computa closes only tabs it can still prove it owns.","Allow temporary tabs")
    }
    fn present(&mut self, prompt: Prompt, title: &str, detail: &str, accept: &str) -> Result<()> {
        let mtm = MainThreadMarker::new().ok_or(AutomationError::WrongThread)?;
        if self.interaction_blocked() {
            return Err(AutomationError::Invalid(
                "another native prompt is pending".into(),
            ));
        }
        let alert = NSAlert::new(mtm);
        alert.setMessageText(&NSString::from_str(title));
        alert.setInformativeText(&NSString::from_str(detail));
        let decline = alert.addButtonWithTitle(&NSString::from_str("Decline"));
        decline.setKeyEquivalent(&NSString::from_str("\u{1b}"));
        alert.addButtonWithTitle(&NSString::from_str(accept));
        let pending = self.target.ivars().pending.clone();
        *pending.borrow_mut() = Some(prompt.clone());
        let callback = self.target.ivars().callback.clone();
        let completion = RcBlock::new(move |response: NSModalResponse| {
            let matches = pending.borrow().as_ref() == Some(&prompt);
            if !matches {
                return;
            }
            *pending.borrow_mut() = None;
            let approved = response == 1001;
            let id = prompt.id().to_owned();
            callback(match prompt {
                Prompt::Approval(_) => NativeControlEvent::ApprovalResolved { id, approved },
                Prompt::Pairing(_) => NativeControlEvent::PairingResolved {
                    id,
                    remember: approved,
                },
                Prompt::Temporary(_) => {
                    NativeControlEvent::TemporaryTabGrantResolved { id, approved }
                }
            });
        });
        alert.beginSheetModalForWindow_completionHandler(&self.window, Some(&completion));
        self.alert = Some(alert);
        Ok(())
    }
    /// A stale cancellation cannot dismiss a replacement request.
    pub fn dismiss_prompt(&mut self, id: &str) -> bool {
        if self.pending_id().as_deref() != Some(id) {
            return false;
        }
        if let Some(alert) = self.alert.take() {
            self.window.endSheet_returnCode(&alert.window(), -1000);
            true
        } else {
            false
        }
    }
}
impl Drop for TrustedNativeControls {
    fn drop(&mut self) {
        if let Some(id) = self.pending_id() {
            self.dismiss_prompt(&id);
        }
        self.mode.setEnabled(false);
        self.chrome.setEnabled(false);
        // SAFETY: targets are disconnected before their owner is destroyed.
        unsafe {
            self.mode.setTarget(None);
            self.chrome.setTarget(None);
            self.view.removeFromSuperview();
        }
    }
}
fn validate_id(id: &str) -> Result<()> {
    if id.is_empty() || id.len() > 256 || id.chars().any(char::is_control) {
        return Err(AutomationError::Invalid("native request identity".into()));
    }
    Ok(())
}
