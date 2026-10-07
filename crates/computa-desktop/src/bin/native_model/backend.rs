//! A test boundary around the actual native backend. Effects may target only
//! the exact NSWorkspace-created fixture, or a separately owned Chrome child.
use computa_macos::{
    qualification_fixture::{BUNDLE_ID, DIGIT_ID, DISPLAY_ID},
    *,
};
use std::{
    cell::RefCell,
    collections::HashMap,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    rc::Rc,
};
use uuid::Uuid;
#[derive(Default)]
pub struct Effects {
    pub mutations: usize,
    pub inputs: usize,
    pub displays: Vec<String>,
    pub foreground_preserved: bool,
    pub node_ids: HashMap<Uuid, String>,
    pub digit_frame: Option<Rect>,
}
pub struct RestrictedBackend {
    pub native: NativeBackend,
    pub pid: Option<i32>,
    pub executable: Option<PathBuf>,
    pub effects: Rc<RefCell<Effects>>,
    pub allow_chrome: bool,
    pub chrome_pid: Option<i32>,
    pub initial_foreground: Option<i32>,
}
impl RestrictedBackend {
    fn fixture(&self, b: &BoundApplication) -> Result<()> {
        let fixture = Some(b.application.process_identifier) == self.pid
            && b.application.bundle_identifier.as_deref() == Some(BUNDLE_ID);
        let chrome = self.allow_chrome
            && Some(b.application.process_identifier) == self.chrome_pid
            && b.application.bundle_identifier.as_deref() == Some("com.google.Chrome");
        if fixture || chrome {
            Ok(())
        } else {
            Err(AutomationError::TargetChanged)
        }
    }
}
impl MacosBackend for RestrictedBackend {
    fn permissions(&self) -> PermissionSnapshot {
        self.native.permissions()
    }
    fn request_accessibility(&self) -> PermissionSnapshot {
        self.native.permissions()
    }
    fn request_screen_recording(&self) -> PermissionSnapshot {
        self.native.permissions()
    }
    fn applications(&self) -> Result<Vec<RunningApplication>> {
        Ok(self
            .native
            .applications()?
            .into_iter()
            .filter(|a| Some(a.process_identifier) == self.pid)
            .collect())
    }
    fn bind(
        &mut self,
        bundle: &str,
        activate: bool,
        url: Option<&str>,
    ) -> Result<BoundApplication> {
        if bundle != BUNDLE_ID || activate || url.is_some() {
            return Err(AutomationError::TargetChanged);
        }
        self.native
            .bind_exact_process(self.pid.ok_or(AutomationError::NotRunning)?, BUNDLE_ID)
    }
    fn open<'a>(
        &'a mut self,
        bundle: &'a str,
        activate: bool,
        url: Option<&'a str>,
        before: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async move {
            if bundle != BUNDLE_ID || url.is_some() {
                return Err(AutomationError::TargetChanged);
            }
            let pid = self.pid.ok_or(AutomationError::NotRunning)?;
            if activate {
                let path = self.executable.clone().ok_or(AutomationError::NotRunning)?;
                self.native
                    .bind_owned_process(pid, &path, true, before)
                    .await
            } else {
                before()?;
                self.native.bind_exact_process(pid, BUNDLE_ID)
            }
        })
    }
    fn application_executable(&self, bundle: &str) -> Result<PathBuf> {
        if self.allow_chrome && bundle == "com.google.Chrome" {
            self.native.application_executable(bundle)
        } else {
            Err(AutomationError::TargetChanged)
        }
    }
    fn bind_owned_process<'a>(
        &'a mut self,
        pid: i32,
        path: &'a Path,
        activate: bool,
        before: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async move {
            if !self.allow_chrome {
                return Err(AutomationError::TargetChanged);
            }
            if self.native.application_executable("com.google.Chrome")? != path {
                return Err(AutomationError::TargetChanged);
            }
            let binding = self
                .native
                .bind_owned_process(pid, path, activate, before)
                .await?;
            if binding.application.process_identifier != pid
                || binding.application.bundle_identifier.as_deref() != Some("com.google.Chrome")
            {
                return Err(AutomationError::TargetChanged);
            }
            self.chrome_pid = Some(pid);
            Ok(binding)
        })
    }
    fn validate(&self, b: &BoundApplication) -> Result<()> {
        self.fixture(b)?;
        self.native.validate(b)
    }
    fn observe(&mut self, b: &BoundApplication, limits: TreeLimits) -> Result<AxSnapshot> {
        self.fixture(b)?;
        let snapshot = self.native.observe(b, limits)?;
        let mut e = self.effects.borrow_mut();
        for n in &snapshot.elements {
            if let Some(id) = &n.identifier {
                e.node_ids.insert(n.identity, id.clone());
                if id == DIGIT_ID {
                    e.digit_frame = n.frame;
                }
                if id == DISPLAY_ID
                    && let Some(value) = &n.value
                {
                    e.displays.push(value.clone())
                }
            }
        }
        Ok(snapshot)
    }
    fn mutate(
        &mut self,
        b: &BoundApplication,
        element: Uuid,
        mutation: NativeMutation,
        before: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()> {
        self.fixture(b)?;
        if self
            .effects
            .borrow()
            .node_ids
            .get(&element)
            .map(String::as_str)
            != Some(DIGIT_ID)
            || mutation != NativeMutation::Action("AXPress".into())
        {
            return Err(AutomationError::UnsupportedAction);
        }
        let effects = self.effects.clone();
        let mut boundary = || {
            before()?;
            effects.borrow_mut().mutations += 1;
            Ok(())
        };
        self.native.mutate(b, element, mutation, &mut boundary)?;
        if !b.activated {
            self.effects.borrow_mut().foreground_preserved =
                self.native.foreground_process_identifier()? == self.initial_foreground;
        }
        Ok(())
    }
    fn capture<'a>(
        &'a mut self,
        b: &'a BoundApplication,
        display: Option<u32>,
        cursor: bool,
    ) -> Pin<Box<dyn Future<Output = Result<CapturedImage>> + 'a>> {
        Box::pin(async move {
            self.fixture(b)?;
            if display.is_some() || cursor {
                return Err(AutomationError::Invalid(
                    "qualification captures only its exact window".into(),
                ));
            }
            self.native.capture(b, None, false).await
        })
    }
    fn input(
        &mut self,
        b: &BoundApplication,
        action: InputAction,
        before: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()> {
        self.fixture(b)?;
        let InputAction::Click(point) = action else {
            return Err(AutomationError::UnsupportedAction);
        };
        let frame = self
            .effects
            .borrow()
            .digit_frame
            .ok_or(AutomationError::StaleObservation)?;
        if !frame.contains(point) {
            return Err(AutomationError::Obscured);
        }
        let effects = self.effects.clone();
        let mut boundary = || {
            before()?;
            effects.borrow_mut().inputs += 1;
            Ok(())
        };
        self.native
            .input(b, InputAction::Click(point), &mut boundary)
    }
    fn displays(&self) -> Result<Vec<DisplayInfo>> {
        self.native.displays()
    }
    fn invalidate(&mut self) {
        self.native.invalidate()
    }
}
