use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum AutomationError {
    #[error(
        "Accessibility permission is not granted. Enable it using the native Settings controls."
    )]
    AccessibilityPermission,
    #[error(
        "Screen Recording permission is not granted. Enable it using the native Settings controls."
    )]
    ScreenRecordingPermission,
    #[error("Native automation must execute on the application's main thread.")]
    WrongThread,
    #[error("The requested application is not running; no application was launched.")]
    NotRunning,
    #[error("The requested application has multiple running matches; no process was selected.")]
    AmbiguousApplication,
    #[error("The bound process, launch identity, or selected window changed; no input was sent.")]
    TargetChanged,
    #[error("The selected application does not expose a readable window.")]
    WindowUnavailable,
    #[error("The Accessibility observation or element is stale.")]
    StaleObservation,
    #[error("The element does not expose the requested supported Accessibility action.")]
    UnsupportedAction,
    #[error("The Accessibility field is not settable.")]
    NotSettable,
    #[error("The target is not foreground; no global input was sent.")]
    NotForeground,
    #[error("The point is outside the current window or obscured by another window.")]
    Obscured,
    #[error("Operation cancelled or its authority was revoked; no further input was sent.")]
    Cancelled,
    #[error(
        "Foreground changed during the background action. Dispatch may have occurred; this binding was revoked without restoring focus. Do not repeat the action."
    )]
    ForegroundChanged,
    #[error("Invalid automation argument: {0}")]
    Invalid(String),
    #[error("Native operation {operation} failed (code {code}).")]
    Native { operation: String, code: i32 },
    #[error(
        "Chrome navigation could not be confirmed safely. Any newly created tab was preserved; no additional tab or URL was submitted. Stop retrying this navigation and inspect Chrome."
    )]
    NavigationUnverified,
    #[error("The requested native capability is unavailable on this platform.")]
    UnsupportedPlatform,
}
pub type Result<T> = std::result::Result<T, AutomationError>;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PermissionSnapshot {
    pub accessibility: PermissionGrant,
    pub screen_recording: PermissionGrant,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, Eq, PartialEq)]
pub enum PermissionGrant {
    #[serde(rename = "granted")]
    Granted,
    #[serde(rename = "notGranted")]
    NotGranted,
}
impl PermissionSnapshot {
    pub fn inert() -> Self {
        Self {
            accessibility: PermissionGrant::NotGranted,
            screen_recording: PermissionGrant::NotGranted,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub fn validate(self) -> Result<Self> {
        if ![
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .iter()
        .all(|x| x.is_finite())
            || self.width <= 0.
            || self.height <= 0.
        {
            return Err(AutomationError::Invalid("window frame".into()));
        }
        Ok(self)
    }
    pub fn contains(self, point: Point) -> bool {
        point.x.is_finite()
            && point.y.is_finite()
            && point.x >= self.x
            && point.y >= self.y
            && point.x < self.x + self.width
            && point.y < self.y + self.height
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunningApplication {
    pub process_identifier: i32,
    pub bundle_identifier: Option<String>,
    pub localized_name: Option<String>,
    pub is_active: bool,
    pub is_terminated: bool,
    pub activation_policy: i64,
    pub launch_time: Option<f64>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WindowInfo {
    pub window_id: Option<u32>,
    pub process_identifier: i32,
    pub bundle_identifier: Option<String>,
    pub title: Option<String>,
    pub frame: Option<Rect>,
    pub is_main: bool,
    pub is_focused: bool,
    pub document: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BoundApplication {
    pub application: RunningApplication,
    pub window: WindowInfo,
    pub window_token: Uuid,
    pub generation: Uuid,
    pub activated: bool,
}
impl BoundApplication {
    pub fn same_process(&self, application: &RunningApplication) -> bool {
        self.application.process_identifier == application.process_identifier
            && self.application.bundle_identifier == application.bundle_identifier
            && self.application.launch_time == application.launch_time
            && application.launch_time.is_some_and(f64::is_finite)
            && !application.is_terminated
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TreeLimits {
    pub max_depth: usize,
    pub max_elements: usize,
    pub max_children_per_element: usize,
    pub max_actions_per_element: usize,
    pub max_text_length: usize,
}
impl Default for TreeLimits {
    fn default() -> Self {
        Self {
            max_depth: 16,
            max_elements: 400,
            max_children_per_element: 80,
            max_actions_per_element: 32,
            max_text_length: 16_384,
        }
    }
}
impl TreeLimits {
    pub fn validate(self) -> Result<Self> {
        if self.max_depth > 32
            || !(1..=2000).contains(&self.max_elements)
            || !(1..=500).contains(&self.max_children_per_element)
            || !(1..=128).contains(&self.max_actions_per_element)
            || !(1..=65536).contains(&self.max_text_length)
        {
            Err(AutomationError::Invalid("Accessibility tree limits".into()))
        } else {
            Ok(self)
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AxNode {
    pub index: usize,
    pub parent_index: Option<usize>,
    pub identity: Uuid,
    pub role: Option<String>,
    pub subrole: Option<String>,
    pub title: Option<String>,
    pub element_description: Option<String>,
    pub help: Option<String>,
    pub value: Option<String>,
    pub identifier: Option<String>,
    pub link_url: Option<String>,
    pub frame: Option<Rect>,
    pub is_enabled: Option<bool>,
    pub is_selected: Option<bool>,
    pub is_focused: Option<bool>,
    pub is_value_settable: bool,
    pub actions: Vec<String>,
    pub children_truncated: bool,
    pub text_truncated: bool,
}
impl AxNode {
    pub fn label(&self) -> String {
        [
            self.title.as_deref(),
            self.element_description.as_deref(),
            self.identifier.as_deref(),
            self.help.as_deref(),
        ]
        .into_iter()
        .flatten()
        .find(|s| !s.chars().all(char::is_whitespace))
        .unwrap_or_default()
        .to_owned()
    }
    pub fn is_region(&self) -> bool {
        matches!(
            self.role.as_deref(),
            Some(
                "AXGroup"
                    | "AXScrollArea"
                    | "AXSplitGroup"
                    | "AXLayoutArea"
                    | "AXToolbar"
                    | "AXTable"
                    | "AXList"
                    | "AXOutline"
                    | "AXWebArea"
                    | "AXWindow"
            )
        )
    }
    pub fn is_readable(&self) -> bool {
        matches!(
            self.role.as_deref(),
            Some("AXStaticText" | "AXTextArea" | "AXHeading" | "AXWebArea")
        )
    }
    pub fn is_heading(&self) -> bool {
        self.role.as_deref() == Some("AXHeading") || self.subrole.as_deref() == Some("AXHeading")
    }
    pub fn has_action(&self, action: &str) -> bool {
        self.actions.iter().any(|a| a == action)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AxSnapshot {
    pub id: Uuid,
    pub target_generation: Uuid,
    pub window: WindowInfo,
    pub elements: Vec<AxNode>,
    pub source_truncated: bool,
    pub captured_at: f64,
}
impl AxSnapshot {
    pub fn node(&self, index: usize) -> Result<&AxNode> {
        self.elements
            .iter()
            .find(|n| n.index == index)
            .ok_or(AutomationError::StaleObservation)
    }
    pub fn descendants(&self, index: usize) -> Vec<&AxNode> {
        self.elements
            .iter()
            .filter(|n| {
                let mut current = Some(n.index);
                let mut remaining = self.elements.len() + 1;
                while let Some(i) = current {
                    if i == index {
                        return true;
                    }
                    if remaining == 0 {
                        return false;
                    }
                    remaining -= 1;
                    current = self
                        .elements
                        .iter()
                        .find(|x| x.index == i)
                        .and_then(|x| x.parent_index);
                }
                false
            })
            .collect()
    }
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CapturedImage {
    pub id: Uuid,
    pub png: Vec<u8>,
    pub width: usize,
    pub height: usize,
    pub frame: Rect,
    pub captured_at: f64,
    pub window: WindowInfo,
    pub actionable: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub display_id: u32,
    pub frame: Rect,
    pub pixel_width: usize,
    pub pixel_height: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub enum NativeMutation {
    Action(String),
    SetValue(String),
}
#[derive(Clone, Debug, PartialEq)]
pub enum InputAction {
    Click(Point),
    Move(Point),
    DoubleClick(Point),
    RightClick(Point),
    Scroll {
        point: Point,
        delta_x: f64,
        delta_y: f64,
    },
    Key {
        key: String,
        modifiers: Vec<String>,
    },
    Type(String),
}

pub fn unix_time() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|x| x.as_secs_f64())
        .unwrap_or(f64::NAN)
}
