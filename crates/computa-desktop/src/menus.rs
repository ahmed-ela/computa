//! Native AppKit menus. Edit commands follow the first-responder chain;
//! application Quit is delivered to the host's asynchronous cleanup path.
use computa_contracts::ui::NativeAction;
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, rc::Retained,
    runtime::Sel, sel,
};
use objc2_app_kit::{
    NSApplication, NSEventModifierFlags, NSMenu, NSMenuItem, NSMenuItemValidation,
};
use objc2_foundation::{NSObject, NSObjectProtocol, NSString};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    rc::Rc,
};

#[derive(Clone, Debug)]
pub enum MenuEvent {
    Action(NativeAction),
    Quit,
}
#[derive(Debug, thiserror::Error)]
#[error("Native menus must be created on the AppKit thread")]
pub struct MenuError;
struct TargetIvars {
    callback: Rc<dyn Fn(MenuEvent)>,
    items: RefCell<HashMap<usize, MenuEvent>>,
    enabled: Cell<bool>,
}
define_class!(
    // SAFETY: NSObject has no subclassing invariants; all ivars stay on AppKit's thread.
    #[unsafe(super=NSObject)]
    #[thread_kind=MainThreadOnly]
    #[ivars=TargetIvars]
    struct MenuTarget;
    // SAFETY: NSObjectProtocol adds no implementation requirements.
    unsafe impl NSObjectProtocol for MenuTarget{}
    // SAFETY: the selector has NSMenuItemValidation's exact sender/result ABI.
    unsafe impl NSMenuItemValidation for MenuTarget{
        #[unsafe(method(validateMenuItem:))]
        fn validate_menu_item(&self,sender:&NSMenuItem)->bool{
            self.ivars().items.borrow().get(&item_identity(sender)).is_some_and(|event|matches!(event,MenuEvent::Quit)||self.ivars().enabled.get())
        }
    }
    impl MenuTarget{
        // SAFETY: connected only to our retained native menu items with this exact ABI.
        #[unsafe(method(computaMenuAction:))]
        fn menu_action(&self,sender:&NSMenuItem){
            let event=self.ivars().items.borrow().get(&item_identity(sender)).cloned();
            if let Some(event)=event.filter(|event|matches!(event,MenuEvent::Quit)||self.ivars().enabled.get()){
                (self.ivars().callback)(event);
            }
        }
    }
);
impl MenuTarget {
    fn new(mtm: MainThreadMarker, callback: Rc<dyn Fn(MenuEvent)>) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(TargetIvars {
            callback,
            items: RefCell::new(HashMap::new()),
            enabled: Cell::new(true),
        });
        // SAFETY: call NSObject init exactly once after initializing the Rust ivars.
        unsafe { msg_send![super(this), init] }
    }
}
fn item_identity(item: &NSMenuItem) -> usize {
    item as *const NSMenuItem as usize
}
fn item(
    mtm: MainThreadMarker,
    title: &str,
    key: &str,
    modifiers: NSEventModifierFlags,
    action: Option<Sel>,
) -> Retained<NSMenuItem> {
    // SAFETY: all actions are fixed AppKit selectors or our exact MenuTarget selector.
    let item = unsafe {
        NSMenuItem::initWithTitle_action_keyEquivalent(
            NSMenuItem::alloc(mtm),
            &NSString::from_str(title),
            action,
            &NSString::from_str(key),
        )
    };
    item.setKeyEquivalentModifierMask(modifiers);
    item
}
fn submenu(mtm: MainThreadMarker, parent: &NSMenu, title: &str) -> Retained<NSMenu> {
    let menu = NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str(title));
    let entry = item(mtm, title, "", NSEventModifierFlags::empty(), None);
    entry.setSubmenu(Some(&menu));
    parent.addItem(&entry);
    menu
}
fn responder(
    mtm: MainThreadMarker,
    menu: &NSMenu,
    title: &str,
    key: &str,
    modifiers: NSEventModifierFlags,
    action: Sel,
) {
    let entry = item(mtm, title, key, modifiers, Some(action));
    // SAFETY: a nil target intentionally resolves the fixed selector on AppKit's responder chain.
    unsafe { entry.setTarget(None) }
    menu.addItem(&entry);
}
fn owned(
    mtm: MainThreadMarker,
    menu: &NSMenu,
    target: &MenuTarget,
    title: &str,
    key: &str,
    modifiers: NSEventModifierFlags,
    event: MenuEvent,
) {
    let entry = item(mtm, title, key, modifiers, Some(sel!(computaMenuAction:)));
    target
        .ivars()
        .items
        .borrow_mut()
        .insert(item_identity(&entry), event);
    // SAFETY: NativeMenus retains target until its menu is removed from NSApplication.
    unsafe { entry.setTarget(Some(target)) }
    menu.addItem(&entry);
}
pub struct NativeMenus {
    application: Retained<NSApplication>,
    main: Retained<NSMenu>,
    target: Retained<MenuTarget>,
    previous_main: Option<Retained<NSMenu>>,
    previous_services: Option<Retained<NSMenu>>,
    previous_windows: Option<Retained<NSMenu>>,
    services: Retained<NSMenu>,
    windows: Retained<NSMenu>,
}
impl NativeMenus {
    pub fn new(callback: Rc<dyn Fn(MenuEvent)>) -> Result<Self, MenuError> {
        let mtm = MainThreadMarker::new().ok_or(MenuError)?;
        let application = NSApplication::sharedApplication(mtm);
        let previous_main = application.mainMenu();
        let previous_services = application.servicesMenu();
        let previous_windows = application.windowsMenu();
        let main = NSMenu::initWithTitle(NSMenu::alloc(mtm), &NSString::from_str("Computa"));
        let target = MenuTarget::new(mtm, callback);
        let command = NSEventModifierFlags::Command;
        let shift_command = command | NSEventModifierFlags::Shift;
        let app = submenu(mtm, &main, "Computa");
        responder(
            mtm,
            &app,
            "About Computa",
            "",
            NSEventModifierFlags::empty(),
            sel!(orderFrontStandardAboutPanel:),
        );
        app.addItem(&NSMenuItem::separatorItem(mtm));
        owned(
            mtm,
            &app,
            &target,
            "Settings…",
            ",",
            command,
            MenuEvent::Action(NativeAction::ShowSettings),
        );
        app.addItem(&NSMenuItem::separatorItem(mtm));
        let services = submenu(mtm, &app, "Services");
        application.setServicesMenu(Some(&services));
        app.addItem(&NSMenuItem::separatorItem(mtm));
        responder(mtm, &app, "Hide Computa", "h", command, sel!(hide:));
        responder(
            mtm,
            &app,
            "Hide Others",
            "h",
            command | NSEventModifierFlags::Option,
            sel!(hideOtherApplications:),
        );
        responder(
            mtm,
            &app,
            "Show All",
            "",
            NSEventModifierFlags::empty(),
            sel!(unhideAllApplications:),
        );
        app.addItem(&NSMenuItem::separatorItem(mtm));
        owned(
            mtm,
            &app,
            &target,
            "Quit Computa",
            "q",
            command,
            MenuEvent::Quit,
        );
        let file = submenu(mtm, &main, "File");
        owned(
            mtm,
            &file,
            &target,
            "New Task",
            "n",
            shift_command,
            MenuEvent::Action(NativeAction::CreateTask),
        );
        responder(mtm, &file, "Close", "w", command, sel!(performClose:));
        let edit = submenu(mtm, &main, "Edit");
        responder(mtm, &edit, "Undo", "z", command, sel!(undo:));
        responder(mtm, &edit, "Redo", "z", shift_command, sel!(redo:));
        edit.addItem(&NSMenuItem::separatorItem(mtm));
        for (title, key, selector) in [
            ("Cut", "x", sel!(cut:)),
            ("Copy", "c", sel!(copy:)),
            ("Paste", "v", sel!(paste:)),
            ("Select All", "a", sel!(selectAll:)),
        ] {
            responder(mtm, &edit, title, key, command, selector);
        }
        let view = submenu(mtm, &main, "View");
        owned(
            mtm,
            &view,
            &target,
            "Browser",
            "b",
            command,
            MenuEvent::Action(NativeAction::ToggleBrowser),
        );
        owned(
            mtm,
            &view,
            &target,
            "Inspector",
            "i",
            command,
            MenuEvent::Action(NativeAction::ToggleInspector),
        );
        let windows = submenu(mtm, &main, "Window");
        responder(
            mtm,
            &windows,
            "Minimize",
            "m",
            command,
            sel!(performMiniaturize:),
        );
        responder(
            mtm,
            &windows,
            "Zoom",
            "",
            NSEventModifierFlags::empty(),
            sel!(performZoom:),
        );
        windows.addItem(&NSMenuItem::separatorItem(mtm));
        responder(
            mtm,
            &windows,
            "Bring All to Front",
            "",
            NSEventModifierFlags::empty(),
            sel!(arrangeInFront:),
        );
        application.setWindowsMenu(Some(&windows));
        application.setMainMenu(Some(&main));
        Ok(Self {
            application,
            main,
            target,
            previous_main,
            previous_services,
            previous_windows,
            services,
            windows,
        })
    }
    /// Fence settings/task/view actions while a native approval sheet is open.
    /// Quit remains available so the host can cancel and clean up its work.
    pub fn set_actions_enabled(&self, enabled: bool) {
        self.target.ivars().enabled.set(enabled);
    }
}
impl Drop for NativeMenus {
    fn drop(&mut self) {
        if self
            .application
            .mainMenu()
            .is_some_and(|menu| std::ptr::eq(&*menu, &*self.main))
        {
            self.application.setMainMenu(self.previous_main.as_deref());
        }
        if self
            .application
            .servicesMenu()
            .is_some_and(|menu| std::ptr::eq(&*menu, &*self.services))
        {
            self.application
                .setServicesMenu(self.previous_services.as_deref());
        }
        if self
            .application
            .windowsMenu()
            .is_some_and(|menu| std::ptr::eq(&*menu, &*self.windows))
        {
            self.application
                .setWindowsMenu(self.previous_windows.as_deref());
        }
    }
}
