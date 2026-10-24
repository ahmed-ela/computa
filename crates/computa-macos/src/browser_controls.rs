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
    /// Resolves input from the trusted human address field, including searches.
    pub fn normalize(address: &str) -> Result<Self> {
        let value = address.trim();
        if value.is_empty() || value.len() > 8192 || value.chars().any(char::is_control) {
            return Err(invalid_address());
        }
        if value.split_once(':').is_some_and(|(prefix, _)| {
            matches!(
                prefix.to_ascii_lowercase().as_str(),
                "site" | "inurl" | "intitle" | "intext" | "filetype" | "before" | "after"
            )
        }) {
            return Self::search(value);
        }
        let candidate = if value == "about:blank" || has_scheme_prefix(value) {
            value.to_owned()
        } else if !value.chars().any(char::is_whitespace) {
            let authority = authority(value);
            if let Some((_, port)) = authority.rsplit_once(':')
                && !authority.starts_with('[')
                && (port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()))
            {
                return Err(unsupported_scheme());
            }
            if authority == "localhost"
                || authority.starts_with("localhost:")
                || authority.contains('.')
                || authority.starts_with('[')
            {
                format!("https://{value}")
            } else {
                return Self::search(value);
            }
        } else {
            if value.split_once(':').is_some_and(|(prefix, _)| {
                matches!(
                    prefix.to_ascii_lowercase().as_str(),
                    "javascript"
                        | "data"
                        | "file"
                        | "mailto"
                        | "tel"
                        | "ftp"
                        | "about"
                        | "http"
                        | "https"
                )
            }) {
                return Err(unsupported_scheme());
            }
            return Self::search(value);
        };
        Self::validate(&candidate)
    }

    /// Validates an absolute website URL without address or search fallback.
    /// Website navigation, popups, and observed page URLs must use this path.
    pub fn validate(address: &str) -> Result<Self> {
        if address.is_empty() || address.len() > 8192 || address.chars().any(char::is_control) {
            return Err(invalid_address());
        }
        if address == "about:blank" {
            return Ok(Self(address.into()));
        }
        if !has_scheme_prefix(address) {
            return Err(unsupported_scheme());
        }
        let raw_authority = address.split_once("://").map(|(_, rest)| authority(rest));
        if raw_authority.is_none_or(str::is_empty) {
            return Err(invalid_address());
        }
        let url = url::Url::parse(address).map_err(|_| invalid_address())?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(unsupported_scheme());
        }
        if url.host_str().is_none_or(str::is_empty) || url.port() == Some(0) {
            return Err(invalid_address());
        }
        if !url.username().is_empty()
            || url.password().is_some()
            || raw_authority.is_some_and(|authority| authority.contains('@'))
        {
            return Err(AutomationError::Invalid(
                "Addresses containing a username or password are not supported.".into(),
            ));
        }
        Ok(Self(url.to_string()))
    }

    fn search(query: &str) -> Result<Self> {
        let mut url = url::Url::parse("https://www.google.com/search").expect("fixed search URL");
        url.query_pairs_mut().append_pair("q", query);
        Self::validate(url.as_str())
    }
}

fn authority(value: &str) -> &str {
    value.split(['/', '?', '#']).next().unwrap_or("")
}

fn has_scheme_prefix(value: &str) -> bool {
    let Some((scheme, _)) = value.split_once("://") else {
        return false;
    };
    let mut bytes = scheme.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphabetic())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}

fn invalid_address() -> AutomationError {
    AutomationError::Invalid("Enter a search or website address.".into())
}

fn unsupported_scheme() -> AutomationError {
    AutomationError::Invalid(
        "This browser supports only HTTP, HTTPS, and about:blank. No external application or file was opened.".into(),
    )
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
        address.setPlaceholderString(Some(&NSString::from_str(
            "Search or enter a website address",
        )));
        let status =
            NSTextField::labelWithString(&NSString::from_str("Your browser inside Computa"), mtm);
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
                "Enter a search or website address to get started.",
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
    fn native_url_policy_adds_https_and_preserves_web_addresses() {
        for (input, expected) in [
            ("example.com", "https://example.com/"),
            (
                "  https://example.com/path?q=1  ",
                "https://example.com/path?q=1",
            ),
            ("localhost:5181", "https://localhost:5181/"),
            ("example.com:443/path?q=1", "https://example.com/path?q=1"),
            (
                "example.com?hello=world",
                "https://example.com/?hello=world",
            ),
            ("example.com?q=a:b", "https://example.com/?q=a:b"),
            (
                "example.com/?next=https://example.org",
                "https://example.com/?next=https://example.org",
            ),
            ("[::1]:5181", "https://[::1]:5181/"),
            ("http://127.0.0.1:5181", "http://127.0.0.1:5181/"),
            ("about:blank", "about:blank"),
        ] {
            assert_eq!(
                ValidatedBrowserAddress::normalize(input).unwrap().as_str(),
                expected,
                "{input}"
            );
        }
    }

    #[test]
    fn native_url_policy_searches_words_operators_and_lossless_queries() {
        for input in [
            "hello",
            "search for papers",
            "site:example.com",
            "site:example.com cats",
            "INURL:example.com/path",
            "intitle:hello",
            "intext:hello",
            "filetype:pdf rust",
            "before:2026-01-01",
            "after:2026-01-01",
            "Rust: ownership guide",
            "compare https://example.com and https://example.org",
            "C++ & Swift #1",
            "café 東京",
            "  two words  ",
            "50% off + free",
        ] {
            let address = ValidatedBrowserAddress::normalize(input).unwrap();
            let url = url::Url::parse(address.as_str()).unwrap();
            assert_eq!(url.scheme(), "https", "{input}");
            assert_eq!(url.host_str(), Some("www.google.com"), "{input}");
            assert_eq!(url.path(), "/search", "{input}");
            assert_eq!(
                url.query_pairs().collect::<Vec<_>>(),
                vec![("q".into(), input.trim().into())],
                "{input}"
            );
        }
        assert!(
            ValidatedBrowserAddress::normalize("C++ & Swift #1")
                .unwrap()
                .as_str()
                .contains("C%2B%2B")
        );
    }

    #[test]
    fn native_url_policy_rejects_external_schemes_credentials_and_invalid_addresses() {
        for value in [
            "",
            "  ",
            "mail:foo@example.com",
            "file:///private/tmp/a",
            "custom://example.com",
            "javascript:alert(1)",
            "javascript:alert('hello world')",
            "data:text/html,x",
            "mailto:user@example.com",
            "about:config",
            "https://u:p@example.com/",
            "https://@example.com/",
            "https://",
            "https:///example.com",
            "http://example.com:0/",
            "https://example.com:65536/",
            "example.com:abc",
            "https://example.com/a\nb",
            "search\0text",
        ] {
            assert!(
                ValidatedBrowserAddress::normalize(value).is_err(),
                "{value}"
            )
        }
        assert!(ValidatedBrowserAddress::normalize(&"x".repeat(8193)).is_err());
    }

    #[test]
    fn native_url_policy_navigation_has_no_search_or_host_fallback() {
        for value in [
            "hello world",
            "example.com",
            "site:example.com cats",
            "Rust: ownership guide",
            "javascript:alert(1)",
            "file:///private/tmp/a",
            "data:text/html,x",
            "custom:search",
            "custom://example.com",
            "https:example.com",
            "https:///example.com",
            "https://@example.com/",
        ] {
            assert!(ValidatedBrowserAddress::validate(value).is_err(), "{value}");
        }
        for value in [
            "https://example.com?q=a@b",
            "https://example.com#someone@example.org",
            "https://example.com/?next=https://other.example",
            "http://localhost:8080/",
            "https://[::1]:8443/path",
            "about:blank",
        ] {
            assert!(ValidatedBrowserAddress::validate(value).is_ok(), "{value}");
        }
    }
}
