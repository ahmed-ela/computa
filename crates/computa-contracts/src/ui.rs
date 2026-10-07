use crate::{Identifier, models::ModelId};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tone {
    #[default]
    Neutral,
    Blue,
    Green,
    Orange,
    Red,
    Purple,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessMode {
    #[default]
    AskEveryTime,
    FullAccess,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConnectionSnapshot {
    pub state: ConnectionState,
    pub label: String,
    pub tone: Tone,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum PermissionStatus {
    Granted,
    #[serde(rename = "Not granted")]
    NotGranted,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionSnapshot {
    pub accessibility: PermissionStatus,
    pub screen_recording: PermissionStatus,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolSnapshot {
    pub name: String,
    pub summary: String,
    pub status: String,
    pub tone: Tone,
    pub input: String,
    pub output: Option<String>,
    pub duration: Option<f64>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    User,
    Assistant,
    Reasoning,
    Tool,
    System,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssistantPhase {
    Commentary,
    FinalAnswer,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntrySnapshot {
    pub id: Identifier,
    pub kind: EntryKind,
    pub title: String,
    pub body: String,
    pub timestamp: f64,
    pub worked_for_seconds: Option<f64>,
    pub is_streaming: Option<bool>,
    #[serde(rename = "activityGroupID")]
    pub activity_group_id: Option<Identifier>,
    pub assistant_phase: Option<AssistantPhase>,
    pub tool: Option<ToolSnapshot>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QueuedPromptStatus {
    Queued,
    Editing,
    Sending,
    Failed,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct QueuedPromptSnapshot {
    pub id: Identifier,
    pub text: String,
    pub status: QueuedPromptStatus,
    pub error: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PromptReceiptSnapshot {
    pub id: Identifier,
    #[serde(rename = "taskID")]
    pub task_id: Identifier,
    pub accepted: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskSnapshot {
    pub id: Identifier,
    pub title: String,
    pub summary: String,
    pub status: String,
    pub status_tone: Tone,
    pub updated_at: f64,
    pub active_turn_started_at: Option<f64>,
    #[serde(rename = "activeActivityGroupID")]
    pub active_activity_group_id: Option<Identifier>,
    pub workspace: String,
    pub model: ModelId,
    pub model_selectable: bool,
    pub branch: Option<String>,
    pub entries: Vec<EntrySnapshot>,
    pub queued_prompts: Vec<QueuedPromptSnapshot>,
    pub queue_paused: bool,
    pub can_steer: bool,
    pub is_busy: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelOption {
    pub id: ModelId,
    pub label: String,
    pub detail: String,
    pub high_memory: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub revision: u64,
    #[serde(rename = "selectedTaskID")]
    pub selected_task_id: Option<Identifier>,
    #[serde(rename = "selectedEntryID")]
    pub selected_entry_id: Option<Identifier>,
    pub tasks: Vec<TaskSnapshot>,
    pub prompt_receipts: Vec<PromptReceiptSnapshot>,
    pub pending_approval_count: usize,
    pub connection: ConnectionSnapshot,
    pub permissions: PermissionSnapshot,
    pub appearance: Appearance,
    pub access_mode: AccessMode,
    pub default_model: ModelId,
    pub model_options: Vec<ModelOption>,
    pub show_tool_payloads: bool,
    pub is_inspector_presented: bool,
    pub is_browser_presented: bool,
    pub is_settings_presented: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum NativeAction {
    Ready,
    SelectTask {
        id: Identifier,
    },
    SelectEntry {
        id: Identifier,
    },
    CreateTask,
    SubmitPrompt {
        #[serde(rename = "requestID")]
        request_id: Identifier,
        #[serde(rename = "taskID")]
        task_id: Identifier,
        prompt: String,
    },
    InterruptTask {
        #[serde(rename = "taskID")]
        task_id: Identifier,
    },
    BeginQueueEdit {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
    },
    EditQueuedPrompt {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
        prompt: String,
    },
    CancelQueueEdit {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
    },
    DeleteQueuedPrompt {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
    },
    MoveQueuedPrompt {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
        #[serde(rename = "beforeID")]
        before_id: Option<Identifier>,
    },
    SteerQueuedPrompt {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        id: Identifier,
    },
    ResumeQueue {
        #[serde(rename = "taskID")]
        task_id: Identifier,
    },
    ToggleInspector,
    ToggleBrowser,
    ShowSettings,
    DismissSettings,
    SetAppearance {
        value: Appearance,
    },
    SetDefaultModel {
        #[serde(rename = "modelID")]
        model_id: ModelId,
    },
    SetTaskModel {
        #[serde(rename = "taskID")]
        task_id: Identifier,
        #[serde(rename = "modelID")]
        model_id: ModelId,
    },
    SetShowToolPayloads {
        value: bool,
    },
    RefreshPermissions,
    RequestAccessibilityPermission,
    RequestScreenRecordingPermission,
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn model_change_wire_carries_a_typed_browser_model_and_exact_task() {
        let action: NativeAction = serde_json::from_str(
            r#"{"action":"setTaskModel","taskID":"task-1","modelID":"browser/claude"}"#,
        )
        .unwrap();
        assert!(matches!(
            action,
            NativeAction::SetTaskModel {
                model_id: ModelId::Browser(_),
                ..
            }
        ));
        assert!(serde_json::from_str::<NativeAction>(r#"{"action":"setTaskModel","taskID":"task-1","modelID":"browser/claude","approve":true}"#).is_err());
    }
    #[test]
    fn invalid_access_modes_fail_closed() {
        assert!(serde_json::from_str::<AccessMode>("\"everything\"").is_err());
        assert_eq!(AccessMode::default(), AccessMode::AskEveryTime);
    }
}
