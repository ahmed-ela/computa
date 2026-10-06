//! Trusted human browser controls. Native events select exact retained tab IDs;
//! website content receives no IPC path to navigation or native app authority.
use crate::{AutomationError, Result};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained, sel,
};
use objc2_app_kit::{NSButton, NSPopUpButton, NSTextField, NSView};
use objc2_foundation::{NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use uuid::Uuid;

pub const MAX_HUMAN_BROWSER_TABS: usize = 8;
pub const NATIVE_BROWSER_TOOLBAR_HEIGHT: f64 = 88.;
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidatedBrowserAddress(String);
impl ValidatedBrowserAddress {
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn normalize(address: &str) -> Result<Self> {
        let value = address.trim();
        if value.is_empty()
            || value.len() > 8192
            || value.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return Err(AutomationError::Invalid(
                "Enter a website address, such as https://example.com.".into(),
            ));
        }
        if value == "about:blank" {
            return Ok(Self(value.into()));
        }
        let candidate = if value.contains("://") {
            value.to_owned()
        } else {
            let authority = value.split('/').next().unwrap_or("");
            if let Some((_, port)) = authority.rsplit_once(':')
                && !authority.starts_with('[')
                && (port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()))
            {
                return Err(AutomationError::Invalid(
                    "This browser supports only HTTP, HTTPS, and about:blank.".into(),
                ));
            }
            if authority != "localhost"
                && !authority.starts_with("localhost:")
                && !authority.contains('.')
                && !authority.starts_with('[')
            {
                return Err(AutomationError::Invalid(
                    "Enter a website address, such as https://example.com.".into(),
                ));
            }
            format!("https://{value}")
        };
        let url = url::Url::parse(&candidate)
            .map_err(|_| AutomationError::Invalid("website address".into()))?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(AutomationError::Invalid(
                "This browser supports only HTTP, HTTPS, and about:blank.".into(),
            ));
        }
        if url.host_str().is_none_or(str::is_empty) || url.port() == Some(0) {
            return Err(AutomationError::Invalid("website host or port".into()));
        }
        if !url.username().is_empty()
            || url.password().is_some()
            || candidate
                .split_once("://")
                .is_some_and(|(_, rest)| rest.split('/').next().unwrap_or("").contains('@'))
        {
            return Err(AutomationError::Invalid(
                "Addresses containing a username or password are not supported.".into(),
            ));
        }
        Ok(Self(url.to_string()))
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NativeBrowserEvent {
    NewTab,
    SelectTab {
        tab_id: Uuid,
    },
    CloseTab {
        tab_id: Uuid,
    },
    Back {
        tab_id: Uuid,
    },
    Forward {
        tab_id: Uuid,
    },
    Reload {
        tab_id: Uuid,
    },
    Stop {
        tab_id: Uuid,
    },
    Navigate {
        tab_id: Option<Uuid>,
        address: ValidatedBrowserAddress,
    },
    HidePane,
}
#[derive(Clone, Debug)]
pub struct NativeBrowserTab {
    pub id: Uuid,
    pub title: String,
    pub url: Option<String>,
    pub is_loading: bool,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    pub error: Option<String>,
}
struct BrowserIvars {
    callback: Rc<dyn Fn(NativeBrowserEvent)>,
    tabs: RefCell<Vec<NativeBrowserTab>>,
    selected: Cell<Option<Uuid>>,
    blocked: Cell<bool>,
    selector: RefCell<Option<Retained<NSPopUpButton>>>,
    address: RefCell<Option<Retained<NSTextField>>>,
    status: RefCell<Option<Retained<NSTextField>>>,
    buttons: RefCell<Vec<Retained<NSButton>>>,
}
define_class!(
    // SAFETY: NSObject has no subclassing invariants; all references and state
    // stay on the AppKit thread, and target/action signatures match their senders.
    #[unsafe(super=NSObject)]#[thread_kind=MainThreadOnly]#[ivars=BrowserIvars]
    struct BrowserTarget;
    // SAFETY: NSObjectProtocol adds no implementation invariants.
    unsafe impl NSObjectProtocol for BrowserTarget{}
    impl BrowserTarget{
        // SAFETY: exact retained popup sender checked before interpreting its index.
        #[unsafe(method(selectBrowserTab:))]
        fn select(&self,sender:&NSPopUpButton){
            if self.ivars().blocked.get()||self.ivars().selector.borrow().as_ref().is_none_or(|button|!std::ptr::eq(&**button,sender)){return}
            let index=sender.indexOfSelectedItem();
            if index<0{return}

            if let Some(tab)=self.ivars().tabs.borrow().get(index as usize){(self.ivars().callback)(NativeBrowserEvent::SelectTab{tab_id:tab.id})}
        }
        // SAFETY: only the exact native address field is connected to this selector.
        #[unsafe(method(submitBrowserAddress:))]fn submit(&self,sender:&NSTextField){if self.ivars().address.borrow().as_ref().is_some_and(|field|std::ptr::eq(&**field,sender)){self.navigate()}}
        // SAFETY: button index comes from exact retained native sender identity.
        #[unsafe(method(browserButton:))]fn button(&self,sender:&NSButton){if self.ivars().blocked.get(){return}let Some(index)=self.ivars().buttons.borrow().iter().position(|button|std::ptr::eq(&**button,sender))else{return};let selected=self.ivars().selected.get();let tab=self.ivars().tabs.borrow().iter().find(|tab|Some(tab.id)==selected).cloned();let event=match(index,tab){
            (0,_)if self.ivars().tabs.borrow().len()<MAX_HUMAN_BROWSER_TABS=>Some(NativeBrowserEvent::NewTab),
            (1,Some(tab))=>Some(NativeBrowserEvent::CloseTab{tab_id:tab.id}),
            (2,Some(tab))if tab.can_go_back=>Some(NativeBrowserEvent::Back{tab_id:tab.id}),
            (3,Some(tab))if tab.can_go_forward=>Some(NativeBrowserEvent::Forward{tab_id:tab.id}),
            (4,Some(tab))=>Some(if tab.is_loading{NativeBrowserEvent::Stop{tab_id:tab.id}}else{NativeBrowserEvent::Reload{tab_id:tab.id}}),
            (5,_)=>{self.navigate();None},(6,_)=>Some(NativeBrowserEvent::HidePane),_=>None};if let Some(event)=event{(self.ivars().callback)(event)}}
    }
);
impl BrowserTarget {
    fn new(mtm: MainThreadMarker, callback: Rc<dyn Fn(NativeBrowserEvent)>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(BrowserIvars {
            callback,
            tabs: RefCell::new(vec![]),
            selected: Cell::new(None),
            blocked: Cell::new(false),
            selector: RefCell::new(None),
            address: RefCell::new(None),
            status: RefCell::new(None),
            buttons: RefCell::new(vec![]),
        });
        // SAFETY: initialize NSObject exactly once after installing local Rust ivars.
        unsafe { msg_send![super(this), init] }
    }
    fn navigate(&self) {
        if self.ivars().blocked.get() {
            return;
        }
        let Some(field) = self.ivars().address.borrow().clone() else {
            return;
        };
        match ValidatedBrowserAddress::normalize(&field.stringValue().to_string()) {
            Ok(address) => {
                if self.ivars().selected.get().is_none()
                    && self.ivars().tabs.borrow().len() >= MAX_HUMAN_BROWSER_TABS
                {
                    return;
                }
                (self.ivars().callback)(NativeBrowserEvent::Navigate {
                    tab_id: self.ivars().selected.get(),
                    address,
                })
            }
            Err(error) => {
                if let Some(status) = self.ivars().status.borrow().as_ref() {
                    status.setStringValue(&NSString::from_str(&error.to_string()))
                }
            }
        }
    }
}
/// The parent reserves this view's native toolbar frame above the selected
/// website WebView. Hiding it leaves the host-owned pages and session intact.
pub struct TrustedNativeBrowserControls {
    view: Retained<NSView>,
    target: Retained<BrowserTarget>,
    selector: Retained<NSPopUpButton>,
    address: Retained<NSTextField>,
    status: Retained<NSTextField>,
    buttons: Vec<Retained<NSButton>>,
}
impl TrustedNativeBrowserControls {
    pub fn new(
        parent: &NSView,
        frame: NSRect,
        callback: Rc<dyn Fn(NativeBrowserEvent)>,
    ) -> Result<Self> {
        let mtm = MainThreadMarker::new().ok_or(AutomationError::WrongThread)?;
        let target = BrowserTarget::new(mtm, callback);
        let view = NSView::initWithFrame(NSView::alloc(mtm), frame);
        let selector = NSPopUpButton::initWithFrame_pullsDown(
            NSPopUpButton::alloc(mtm),
            NSRect::new(NSPoint::new(8., 42.), NSSize::new(280., 26.)),
            false,
        );
        let address = NSTextField::initWithFrame(
            NSTextField::alloc(mtm),
            NSRect::new(NSPoint::new(105., 12.), NSSize::new(340., 24.)),
        );
        address.setPlaceholderString(Some(&NSString::from_str("Enter a website address")));
        let status = NSTextField::labelWithString(
            &NSString::from_str("Your browser inside Computa — sign in separately from Chrome"),
            mtm,
        );
        status.setFrame(NSRect::new(NSPoint::new(8., -8.), NSSize::new(550., 20.)));
        let mut buttons = vec![];
        for title in ["+", "Close tab", "Back", "Forward", "Reload", "Go", "Hide"] {
            let button = NSButton::initWithFrame(
                NSButton::alloc(mtm),
                NSRect::new(NSPoint::new(0., 0.), NSSize::new(70., 26.)),
            );
            button.setTitle(&NSString::from_str(title));
            buttons.push(button);
        }
        // SAFETY: native selectors have checked concrete sender signatures; all
        // target and control objects are retained throughout toolbar lifetime.
        unsafe {
            selector.setTarget(Some(&target));
            selector.setAction(Some(sel!(selectBrowserTab:)));
            address.setTarget(Some(&target));
            address.setAction(Some(sel!(submitBrowserAddress:)));
            for button in &buttons {
                button.setTarget(Some(&target));
                button.setAction(Some(sel!(browserButton:)));
                view.addSubview(button);
            }
            view.addSubview(&selector);
            view.addSubview(&address);
            view.addSubview(&status);
            parent.addSubview(&view);
        }
        *target.ivars().selector.borrow_mut() = Some(selector.clone());
        *target.ivars().address.borrow_mut() = Some(address.clone());
        *target.ivars().status.borrow_mut() = Some(status.clone());
        *target.ivars().buttons.borrow_mut() = buttons.clone();
        let controls = Self {
            view,
            target,
            selector,
            address,
            status,
            buttons,
        };
        controls.resize(frame);
        controls.refresh_enabled();
        Ok(controls)
    }
    pub fn update(
        &self,
        tabs: &[NativeBrowserTab],
        selected: Option<Uuid>,
        blocked: bool,
    ) -> Result<()> {
        if tabs.len() > MAX_HUMAN_BROWSER_TABS
            || tabs.iter().enumerate().any(|(i, tab)| {
                tab.id.is_nil() || tabs[..i].iter().any(|previous| previous.id == tab.id)
            })
            || selected.is_some_and(|id| !tabs.iter().any(|tab| tab.id == id))
        {
            return Err(AutomationError::Invalid("native browser tab state".into()));
        }
        let changed = self.target.ivars().selected.get() != selected;
        *self.target.ivars().tabs.borrow_mut() = tabs.to_vec();
        self.target.ivars().selected.set(selected);
        self.target.ivars().blocked.set(blocked);
        self.selector.removeAllItems();
        for tab in tabs {
            let title = if tab.title.trim().is_empty() {
                "New tab"
            } else {
                &tab.title
            };
            let title: String = title.chars().take(100).collect();
            self.selector.addItemWithTitle(&NSString::from_str(&format!(
                "{}{}",
                if tab.is_loading { "Loading… " } else { "" },
                title
            )));
        }
        if let Some(index) = tabs.iter().position(|tab| Some(tab.id) == selected) {
            self.selector.selectItemAtIndex(index as isize)
        }
        let tab = tabs.iter().find(|tab| Some(tab.id) == selected);
        if let Some(tab) = tab {
            self.buttons[4].setTitle(&NSString::from_str(if tab.is_loading {
                "Stop"
            } else {
                "Reload"
            }));
            if (changed || blocked || self.address.currentEditor().is_none())
                && (!tab.is_loading || tab.url.is_some())
            {
                self.address
                    .setStringValue(&NSString::from_str(tab.url.as_deref().unwrap_or("")))
            }
            self.status
                .setStringValue(&NSString::from_str(tab.error.as_deref().unwrap_or(
                    if tab.is_loading {
                        "Loading website…"
                    } else {
                        "Browse websites here. Sign in to your accounts as usual."
                    },
                )));
        } else {
            self.address.setStringValue(&NSString::from_str(""));
            self.status.setStringValue(&NSString::from_str(
                "Enter a website address to get started.",
            ));
        }
        self.refresh_enabled();
        Ok(())
    }
    fn refresh_enabled(&self) {
        let active = !self.target.ivars().blocked.get();
        let tabs = self.target.ivars().tabs.borrow();
        let tab = tabs
            .iter()
            .find(|tab| Some(tab.id) == self.target.ivars().selected.get());
        self.selector.setEnabled(active && !tabs.is_empty());
        self.address.setEnabled(active);
        self.buttons[0].setEnabled(active && tabs.len() < MAX_HUMAN_BROWSER_TABS);
        self.buttons[1].setEnabled(active && tab.is_some());
        self.buttons[2].setEnabled(active && tab.is_some_and(|tab| tab.can_go_back));
        self.buttons[3].setEnabled(active && tab.is_some_and(|tab| tab.can_go_forward));
        self.buttons[4]
            .setEnabled(active && tab.is_some_and(|tab| tab.is_loading || tab.url.is_some()));
        self.buttons[5].setEnabled(active);
        self.buttons[6].setEnabled(active);
    }
    pub fn resize(&self, frame: NSRect) {
        if frame.size.width.is_finite() && frame.size.width > 0. {
            self.view.setFrame(frame);
            let width = frame.size.width;
            self.selector.setFrame(NSRect::new(
                NSPoint::new(8., 55.),
                NSSize::new((width - 245.).max(100.), 26.),
            ));
            let positions = [
                (width - 224., 45., 32.),
                (width - 188., 55., 96.),
                (8., 15., 60.),
                (70., 15., 68.),
                (142., 15., 68.),
                (width - 56., 15., 48.),
                (width - 86., 45., 78.),
            ];
            for (button, (x, y, w)) in self.buttons.iter().zip(positions) {
                button.setFrame(NSRect::new(NSPoint::new(x, y), NSSize::new(w, 26.)))
            }
            self.address.setFrame(NSRect::new(
                NSPoint::new(215., 26.),
                NSSize::new((width - 277.).max(1.), 24.),
            ));
            self.status.setFrame(NSRect::new(
                NSPoint::new(8., 2.),
                NSSize::new((width - 16.).max(1.), 18.),
            ));
        }
    }
    pub fn set_hidden(&self, hidden: bool) {
        self.view.setHidden(hidden)
    }
}
impl Drop for TrustedNativeBrowserControls {
    fn drop(&mut self) {
        self.target.ivars().blocked.set(true);
        // SAFETY: selectors are disconnected before the retained target is dropped.
        unsafe {
            self.selector.setTarget(None);
            self.address.setTarget(None);
            for button in &self.buttons {
                button.setTarget(None);
            }
            self.view.removeFromSuperview();
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_url_policy_matches_human_browser_without_search_or_external_schemes() {
        for value in [
            "example.com/path",
            "localhost:8080",
            "[::1]:8443/path",
            "https://example.com/",
            "about:blank",
        ] {
            assert!(ValidatedBrowserAddress::normalize(value).is_ok(), "{value}")
        }
        for value in [
            "hello world",
            "mail:foo@example.com",
            "file:///private/tmp/a",
            "javascript:alert(1)",
            "https://u:p@example.com/",
            "https://@example.com/",
            "http://example.com:0/",
            "https://example.com/a\nb",
        ] {
            assert!(
                ValidatedBrowserAddress::normalize(value).is_err(),
                "{value}"
            )
        }
    }
}
