use crate::*;
use std::{future::Future, pin::Pin};
use uuid::Uuid;

/// Implementations retain platform handles locally. A background binding is
/// never permission to activate, navigate, focus, or send global input.
pub trait MacosBackend {
    fn permissions(&self) -> PermissionSnapshot;
    fn request_accessibility(&self) -> PermissionSnapshot;
    fn request_screen_recording(&self) -> PermissionSnapshot;
    fn applications(&self) -> Result<Vec<RunningApplication>>;
    fn bind(
        &mut self,
        bundle_id: &str,
        activate: bool,
        url: Option<&str>,
    ) -> Result<BoundApplication>;
    /// Foreground launches and URL opening are asynchronous platform operations.
    /// The authority callback is invoked immediately before each native effect.
    fn open<'a>(
        &'a mut self,
        bundle_id: &'a str,
        activate: bool,
        url: Option<&'a str>,
        before_dispatch: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async move {
            before_dispatch()?;
            self.bind(bundle_id, activate, url)
        })
    }
    fn application_executable(&self, _bundle_id: &str) -> Result<std::path::PathBuf> {
        Err(AutomationError::UnsupportedPlatform)
    }
    fn bind_owned_process<'a>(
        &'a mut self,
        _pid: i32,
        _executable: &'a std::path::Path,
        _activate: bool,
        _before_dispatch: &'a mut dyn FnMut() -> Result<()>,
    ) -> Pin<Box<dyn Future<Output = Result<BoundApplication>> + 'a>> {
        Box::pin(async { Err(AutomationError::UnsupportedPlatform) })
    }
    fn validate(&self, binding: &BoundApplication) -> Result<()>;
    fn observe(&mut self, binding: &BoundApplication, limits: TreeLimits) -> Result<AxSnapshot>;
    /// `before_dispatch` runs after native identity/capability checks and
    /// immediately before the one mutation. It may revoke/cancel the dispatch.
    fn mutate(
        &mut self,
        binding: &BoundApplication,
        element: Uuid,
        mutation: NativeMutation,
        before_dispatch: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()>;
    fn capture<'a>(
        &'a mut self,
        binding: &'a BoundApplication,
        display_id: Option<u32>,
        shows_cursor: bool,
    ) -> Pin<Box<dyn Future<Output = Result<CapturedImage>> + 'a>>;
    fn input(
        &mut self,
        binding: &BoundApplication,
        action: InputAction,
        before_dispatch: &mut dyn FnMut() -> Result<()>,
    ) -> Result<()>;
    fn displays(&self) -> Result<Vec<DisplayInfo>>;
    fn invalidate(&mut self);
}

#[cfg(target_os = "macos")]
pub use crate::native::NativeBackend;
#[cfg(not(target_os = "macos"))]
pub struct NativeBackend;
#[cfg(not(target_os = "macos"))]
impl NativeBackend {
    pub fn new() -> Result<Self> {
        Err(AutomationError::UnsupportedPlatform)
    }
}
