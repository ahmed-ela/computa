//! Persistent human browsing. These views have no privileged protocol, native
//! message handler, model tool bridge, injected script, or automatic window grant.
use computa_macos::browser_controls::{
    MAX_HUMAN_BROWSER_TABS, NativeBrowserEvent, NativeBrowserTab, ValidatedBrowserAddress,
};
use std::{collections::HashMap, rc::Rc};
use tao::window::Window;
use uuid::Uuid;
use wry::{
    NewWindowResponse, PageLoadEvent, Rect, WebView, WebViewBuilder, WebViewBuilderExtDarwin,
    WebViewExtMacOS,
};
#[derive(Clone, Debug)]
pub enum HumanEvent {
    Title {
        tab: Uuid,
        title: String,
    },
    Load {
        tab: Uuid,
        loading: bool,
        url: String,
    },
    Popup {
        source: Uuid,
        url: String,
    },
}
struct Tab {
    view: WebView,
    metadata: NativeBrowserTab,
    document: Uuid,
}
pub struct HumanBrowser {
    tabs: HashMap<Uuid, Tab>,
    order: Vec<Uuid>,
    selected: Option<Uuid>,
    profile: Uuid,
    private: bool,
    visible: bool,
    bounds: Rect,
    callback: Rc<dyn Fn(HumanEvent)>,
}
impl HumanBrowser {
    pub fn new(
        profile: Uuid,
        private: bool,
        bounds: Rect,
        callback: Rc<dyn Fn(HumanEvent)>,
    ) -> Self {
        Self {
            tabs: HashMap::new(),
            order: vec![],
            selected: None,
            profile,
            private,
            visible: false,
            bounds,
            callback,
        }
    }
    pub fn selected(&self) -> Option<Uuid> {
        self.selected
    }
    pub fn metadata(&self) -> Vec<NativeBrowserTab> {
        self.order
            .iter()
            .filter_map(|id| {
                self.tabs.get(id).map(|entry| {
                    let mut tab = entry.metadata.clone();
                    let native = entry.view.webview();
                    // SAFETY: the retained WebView belongs to this human tab;
                    // all access stays on the owning AppKit thread.
                    unsafe {
                        tab.can_go_back = native.canGoBack();
                        tab.can_go_forward = native.canGoForward();
                        tab.is_loading = native.isLoading();
                        if let Some(url) = native.URL().and_then(|url| url.absoluteString()) {
                            let value = url.to_string();
                            if ValidatedBrowserAddress::validate(&value).is_ok() {
                                tab.url = Some(bounded(value, 8192));
                            }
                        }
                    }
                    tab
                })
            })
            .collect()
    }
    pub fn set_visible(&mut self, visible: bool) {
        self.visible = visible;
        for (id, tab) in &self.tabs {
            let _ = tab.view.set_visible(visible && Some(*id) == self.selected);
        }
    }
    pub fn set_bounds(&mut self, bounds: Rect) {
        self.bounds = bounds;
        for tab in self.tabs.values() {
            let _ = tab.view.set_bounds(bounds);
        }
    }
    pub fn create(
        &mut self,
        window: &Window,
        url: Option<ValidatedBrowserAddress>,
        select: bool,
    ) -> Result<Uuid, String> {
        if self.tabs.len() >= MAX_HUMAN_BROWSER_TABS {
            return Err("Close a browser tab before opening another (maximum 8).".into());
        }
        let id = Uuid::new_v4();
        let title_callback = self.callback.clone();
        let load_callback = self.callback.clone();
        let popup_callback = self.callback.clone();
        let mut builder = WebViewBuilder::new()
            .with_bounds(self.bounds)
            .with_visible(false)
            .with_devtools(false)
            .with_incognito(self.private)
            .with_data_store_identifier(*self.profile.as_bytes())
            .with_navigation_handler(|url| ValidatedBrowserAddress::validate(&url).is_ok())
            .with_new_window_req_handler(move |url, _| {
                if ValidatedBrowserAddress::validate(&url).is_ok() {
                    popup_callback(HumanEvent::Popup { source: id, url });
                }
                NewWindowResponse::Deny
            })
            .with_document_title_changed_handler(move |title| {
                title_callback(HumanEvent::Title { tab: id, title })
            })
            .with_on_page_load_handler(move |event, url| {
                load_callback(HumanEvent::Load {
                    tab: id,
                    loading: matches!(event, PageLoadEvent::Started),
                    url,
                })
            });
        if let Some(url) = &url {
            builder = builder.with_url(url.as_str());
        }
        let view = builder
            .build_as_child(window)
            .map_err(|_| "The browser tab could not be created.".to_owned())?;
        // SAFETY: this exact WKWebView and its preferences are live on the
        // AppKit thread. Blocking script-opened windows grants no web capability.
        unsafe {
            view.webview()
                .configuration()
                .preferences()
                .setJavaScriptCanOpenWindowsAutomatically(false);
        }
        self.tabs.insert(
            id,
            Tab {
                view,
                metadata: NativeBrowserTab {
                    id,
                    title: "New tab".into(),
                    url: url.map(|u| u.as_str().into()),
                    is_loading: false,
                    can_go_back: false,
                    can_go_forward: false,
                    error: None,
                },
                document: Uuid::new_v4(),
            },
        );
        self.order.push(id);
        if select {
            self.selected = Some(id);
        }
        self.set_visible(self.visible);
        Ok(id)
    }
    pub fn handle(
        &mut self,
        event: NativeBrowserEvent,
        window: &Window,
        blocked: bool,
    ) -> Result<(), String> {
        if blocked {
            return Err("The native prompt must be resolved first.".into());
        }
        match event {
            NativeBrowserEvent::NewTab => {
                self.create(window, None, true)?;
            }
            NativeBrowserEvent::SelectTab { tab_id } => {
                if !self.tabs.contains_key(&tab_id) {
                    return Err("That browser tab is closed.".into());
                }
                self.selected = Some(tab_id);
                self.set_visible(self.visible);
            }
            NativeBrowserEvent::CloseTab { tab_id } => {
                let Some(tab) = self.tabs.remove(&tab_id) else {
                    return Err("That browser tab is closed.".into());
                };
                stop(&tab.view);
                let index = self.order.iter().position(|id| *id == tab_id).unwrap();
                self.order.remove(index);
                if self.selected == Some(tab_id) {
                    self.selected = self
                        .order
                        .get(index.min(self.order.len().saturating_sub(1)))
                        .copied();
                }
                drop(tab);
                self.set_visible(self.visible);
            }
            NativeBrowserEvent::Navigate { tab_id, address } => {
                let id = match tab_id {
                    Some(id) => id,
                    None => self.create(window, None, true)?,
                };
                let tab = self
                    .tabs
                    .get_mut(&id)
                    .ok_or("That browser tab is closed.")?;
                tab.document = Uuid::new_v4();
                tab.metadata.error = None;
                tab.metadata.is_loading = true;
                tab.view
                    .load_url(address.as_str())
                    .map_err(|_| "The browser address could not be loaded.")?;
            }
            NativeBrowserEvent::Back { tab_id }
            | NativeBrowserEvent::Forward { tab_id }
            | NativeBrowserEvent::Reload { tab_id }
            | NativeBrowserEvent::Stop { tab_id } => {
                let tab = self
                    .tabs
                    .get_mut(&tab_id)
                    .ok_or("That browser tab is closed.")?;
                tab.document = Uuid::new_v4();
                let native = tab.view.webview();
                // SAFETY: these native navigation methods act only on the
                // retained tab selected by an exact native toolbar tab ID.
                unsafe {
                    match event {
                        NativeBrowserEvent::Back { .. } if native.canGoBack() => {
                            native.goBack();
                        }
                        NativeBrowserEvent::Forward { .. } if native.canGoForward() => {
                            native.goForward();
                        }
                        NativeBrowserEvent::Reload { .. } => {
                            native.reload();
                        }
                        NativeBrowserEvent::Stop { .. } => {
                            native.stopLoading();
                            tab.metadata.is_loading = false;
                        }
                        _ => {}
                    }
                }
            }
            NativeBrowserEvent::HidePane => self.set_visible(false),
        }
        Ok(())
    }
    pub fn receive(
        &mut self,
        event: HumanEvent,
        window: &Window,
        blocked: bool,
    ) -> Result<(), String> {
        match event {
            HumanEvent::Title { tab, title } => {
                if let Some(entry) = self.tabs.get_mut(&tab) {
                    entry.metadata.title = bounded(title, 512);
                }
            }
            HumanEvent::Load { tab, loading, url } => {
                if let Some(entry) = self.tabs.get_mut(&tab) {
                    entry.metadata.is_loading = loading;
                    if ValidatedBrowserAddress::validate(&url).is_ok() {
                        entry.metadata.url = Some(bounded(url, 8192));
                    }
                    if loading {
                        entry.document = Uuid::new_v4();
                    }
                }
            }
            HumanEvent::Popup { source, url } => {
                if self.tabs.contains_key(&source) && !blocked {
                    let address =
                        ValidatedBrowserAddress::validate(&url).map_err(|e| e.to_string())?;
                    self.create(window, Some(address), true)?;
                }
            }
        }
        Ok(())
    }
    pub fn shutdown(&mut self) {
        for tab in self.tabs.values() {
            stop(&tab.view);
        }
        self.tabs.clear();
        self.order.clear();
        self.selected = None;
    }
}
fn stop(view: &WebView) {
    // SAFETY: the retained view is owned by this main-thread human browser;
    // stopping it performs no navigation or access to a foreign browser.
    unsafe {
        view.webview().stopLoading();
    }
}
impl Drop for HumanBrowser {
    fn drop(&mut self) {
        self.shutdown();
    }
}
fn bounded(mut value: String, limit: usize) -> String {
    if value.len() > limit {
        let mut end = limit;
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        value.truncate(end);
    }
    value
}
