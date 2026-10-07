//! Versioned computer tool wire contract. No decoded argument is authority.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InteractionPolicy {
    #[default]
    BackgroundOnly,
    Foreground,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivationMode {
    #[default]
    None,
    Foreground,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserMode {
    Existing,
    Isolated,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadView {
    #[default]
    All,
    Overview,
    Content,
    Headings,
    Links,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AxAction {
    #[serde(rename = "AXPress")]
    Press,
    #[serde(rename = "AXConfirm")]
    Confirm,
    #[serde(rename = "AXCancel")]
    Cancel,
    #[serde(rename = "AXIncrement")]
    Increment,
    #[serde(rename = "AXDecrement")]
    Decrement,
    #[serde(rename = "AXShowMenu")]
    ShowMenu,
    #[serde(rename = "AXRaise")]
    Raise,
    #[serde(rename = "AXPick")]
    Pick,
}
impl AxAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Press => "AXPress",
            Self::Confirm => "AXConfirm",
            Self::Cancel => "AXCancel",
            Self::Increment => "AXIncrement",
            Self::Decrement => "AXDecrement",
            Self::ShowMenu => "AXShowMenu",
            Self::Raise => "AXRaise",
            Self::Pick => "AXPick",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PostconditionKind {
    DocumentUrl,
    Value,
    RegionText,
    RegionChanged,
    DialogOpened,
    DetailView,
    Selection,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Postcondition {
    pub kind: PostconditionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub element_index: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail_element_index: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyArgs {}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppsArgs {
    #[serde(default)]
    pub query: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OpenArgs {
    pub bundle_id: String,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub browser_mode: Option<BrowserMode>,
    #[serde(default)]
    pub activation: ActivationMode,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabsArgs {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub page_size: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CursorArgs {
    pub cursor: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CandidateArgs {
    pub candidate_token: String,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReadArgs {
    #[serde(default)]
    pub query: Option<String>,
    #[serde(default)]
    pub view: Option<ReadView>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub snapshot_id: Option<String>,
    #[serde(default)]
    pub element_index: Option<usize>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ElementArgs {
    pub snapshot_id: String,
    pub element_index: usize,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionArgs {
    pub snapshot_id: String,
    pub element_index: usize,
    pub ax_action: AxAction,
    #[serde(default)]
    pub postcondition: Option<Postcondition>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetTextArgs {
    pub snapshot_id: String,
    pub element_index: usize,
    pub text: String,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CaptureArgs {
    #[serde(default)]
    pub display_id: Option<u32>,
    #[serde(default)]
    pub shows_cursor: bool,
    #[serde(default)]
    pub include_accessibility: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GroundArgs {
    pub capture_id: String,
    pub target: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PointArgs {
    pub capture_id: String,
    pub x: f64,
    pub y: f64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerAction {
    Move,
    DoubleClick,
    RightClick,
    Scroll,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PointerArgs {
    pub capture_id: String,
    pub x: f64,
    pub y: f64,
    pub action: PointerAction,
    #[serde(default)]
    pub delta_x: Option<f64>,
    #[serde(default)]
    pub delta_y: Option<f64>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Modifier {
    Command,
    Control,
    Option,
    Shift,
    Function,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeyArgs {
    pub key: String,
    #[serde(default)]
    pub modifiers: Vec<Modifier>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TextArgs {
    pub text: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegionArgs {
    pub region_ref: String,
    #[serde(default)]
    pub query: Option<String>,
    #[serde(default)]
    pub view: Option<ReadView>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PressArgs {
    pub action_ref: String,
    #[serde(default)]
    pub postcondition: Option<ReferencePostcondition>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FollowArgs {
    pub link_ref: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferencePostcondition {
    pub kind: PostconditionKind,
    #[serde(default)]
    pub expected: Option<String>,
    #[serde(default)]
    pub region_ref: Option<String>,
    #[serde(default)]
    pub detail_ref: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FillArgs {
    pub field_ref: String,
    pub text: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VerifyArgs {
    pub operation_id: String,
    #[serde(default)]
    pub snapshot_id: Option<String>,
    #[serde(default)]
    pub property: Option<String>,
    #[serde(default)]
    pub element_index: Option<usize>,
    #[serde(default)]
    pub expected: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ToolCall {
    Status,
    Apps(AppsArgs),
    Open(OpenArgs),
    Tabs(TabsArgs),
    Continue(CursorArgs),
    BindTab(CandidateArgs),
    CreateWorkspace(CandidateArgs),
    Snapshot(ReadArgs),
    FollowLink(ElementArgs),
    Ax(ActionArgs),
    SetText(SetTextArgs),
    Capture(CaptureArgs),
    GroundClick(GroundArgs),
    Click(PointArgs),
    Pointer(PointerArgs),
    Keypress(KeyArgs),
    Type(TextArgs),
    ReadPage(ReadArgs),
    ReadRegion(RegionArgs),
    Press(PressArgs),
    Follow(FollowArgs),
    Fill(FillArgs),
    Verify(VerifyArgs),
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum ToolValidationError {
    #[error("Unknown computer tool: {0}")]
    Unknown(String),
    #[error("Invalid computer tool arguments: {0}")]
    Invalid(String),
}

pub fn parse_tool(name: &str, arguments: Value) -> Result<ToolCall, ToolValidationError> {
    fn read<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ToolValidationError> {
        serde_json::from_value(value)
            .map_err(|error| ToolValidationError::Invalid(error.to_string()))
    }
    if serde_json::to_vec(&arguments).map_or(true, |bytes| bytes.len() > 131_072) {
        return Err(ToolValidationError::Invalid(
            "argument byte budget exceeded".into(),
        ));
    }
    Ok(match name {
        "computer_v2_status" => {
            read::<EmptyArgs>(arguments)?;
            ToolCall::Status
        }
        "computer_v2_apps" => ToolCall::Apps(read(arguments)?),
        "computer_v2_open" => ToolCall::Open(read(arguments)?),
        "computer_v2_tabs" => ToolCall::Tabs(read(arguments)?),
        "computer_v2_continue" => ToolCall::Continue(read(arguments)?),
        "computer_v2_bind_tab" => ToolCall::BindTab(read(arguments)?),
        "computer_v2_create_workspace" => ToolCall::CreateWorkspace(read(arguments)?),
        "computer_v2_snapshot" => ToolCall::Snapshot(read(arguments)?),
        "computer_v2_follow_link" => ToolCall::FollowLink(read(arguments)?),
        "computer_v2_ax" => ToolCall::Ax(read(arguments)?),
        "computer_v2_set_text" => ToolCall::SetText(read(arguments)?),
        "computer_v2_capture" => ToolCall::Capture(read(arguments)?),
        "computer_v2_ground_click" => ToolCall::GroundClick(read(arguments)?),
        "computer_v2_click" => ToolCall::Click(read(arguments)?),
        "computer_v2_pointer" => ToolCall::Pointer(read(arguments)?),
        "computer_v2_keypress" => ToolCall::Keypress(read(arguments)?),
        "computer_v2_type" => ToolCall::Type(read(arguments)?),
        "computer_v2_read_page" => {
            if arguments.as_object().is_none_or(|object| {
                object
                    .keys()
                    .any(|key| !matches!(key.as_str(), "query" | "view"))
            }) {
                return Err(ToolValidationError::Invalid(
                    "read_page accepts query/view only; use observed region_ref or next_cursor"
                        .into(),
                ));
            }
            ToolCall::ReadPage(read(arguments)?)
        }
        "computer_v2_read_region" => ToolCall::ReadRegion(read(arguments)?),
        "computer_v2_press" => ToolCall::Press(read(arguments)?),
        "computer_v2_follow" => ToolCall::Follow(read(arguments)?),
        "computer_v2_fill" => ToolCall::Fill(read(arguments)?),
        "computer_v2_verify" => ToolCall::Verify(read(arguments)?),
        _ => return Err(ToolValidationError::Unknown(name.into())),
    })
}

/// Thread/start DynamicToolSpec shapes. Execution always revalidates arguments.
pub fn tool_specs(policy: InteractionPolicy, browser_model: bool) -> Vec<Value> {
    let string = json!({"type":"string"});
    let reference = json!({"type":"string","minLength":1,"maxLength":256});
    let mut entries: Vec<(&str, &str, Value, Vec<&str>)> = vec![
        (
            "computer_v2_status",
            "Read permission and current binding state; never requests permissions.",
            json!({}),
            vec![],
        ),
        (
            "computer_v2_apps",
            "Discover running user-facing applications. query also searches helpers.",
            json!({"query":{"type":"string","minLength":1,"maxLength":200}}),
            vec![],
        ),
        (
            "computer_v2_open",
            "Bind an already-running app without activation. Exact bundle_id required. No navigation or new tabs in background mode.",
            json!({"bundle_id":{"type":"string","maxLength":255},"activation":{"type":"string","enum":["none","foreground"]},"url":string,"browser_mode":{"type":"string","enum":["existing","isolated"]}}),
            vec!["bundle_id"],
        ),
        (
            "computer_v2_tabs",
            "Enumerate approved Chrome tabs. Exhaust next_cursor before claiming a tab is absent.",
            json!({"cursor":reference,"page_size":{"type":"integer","minimum":1,"maximum":100}}),
            vec![],
        ),
        (
            "computer_v2_bind_tab",
            "Bind an observed candidate_token from this turn. Preserves tabs and logins without activation.",
            json!({"candidate_token":reference}),
            vec!["candidate_token"],
        ),
        (
            "computer_v2_create_workspace",
            "Create an inactive temporary copy of an observed candidate only with an explicit temporary-tab grant.",
            json!({"candidate_token":reference}),
            vec!["candidate_token"],
        ),
        (
            "computer_v2_read_page",
            "Read the bound app or page. Browser overview is discovery, not exhaustive content. Continue with next_cursor; only exposed references grant actions. Truncated reads cannot prove absence.",
            json!({"query":{"type":"string","maxLength":200},"view":{"type":"string","enum":["all","overview","content","headings","links"]}}),
            vec![],
        ),
        (
            "computer_v2_read_region",
            "Read below an observed current region_ref. References are scoped to this turn and document.",
            json!({"region_ref":reference,"query":{"type":"string","maxLength":200},"view":{"type":"string","enum":["all","content","headings","links"]}}),
            vec!["region_ref"],
        ),
        (
            "computer_v2_continue",
            "Continue exactly the retained read or tab inventory using next_cursor. No changed filters or guessed cursors.",
            json!({"cursor":reference}),
            vec!["cursor"],
        ),
        (
            "computer_v2_verify",
            "Read-only receipt lookup or bounded verification. Planned actions retain their original intended result. For unplanned foreground input, supply the current snapshot_id, exposed element_index, property=text for label or value for value, and exact expected: proof requires a changed property on the same control from a known pre-input baseline. No input is replayed. Historical status and a verified property do not prove whole-task completion.",
            json!({"operation_id":reference,"snapshot_id":reference,"property":{"type":"string","enum":["text","value","document_url"]},"element_index":{"type":"integer","minimum":0},"expected":{"type":"string","maxLength":8192}}),
            vec!["operation_id"],
        ),
        (
            "computer_v2_press",
            "Press an observed action_ref once. Its host-owned postcondition must be verified. Dispatch is not success; do not replay uncertain actions.",
            json!({"action_ref":reference,"postcondition":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string","enum":["document_url","value","region_text","region_changed","dialog_opened","detail_view","selection"]},"expected":{"type":"string","maxLength":4096},"region_ref":reference,"detail_ref":reference},"required":["kind"]}}),
            vec!["action_ref"],
        ),
        (
            "computer_v2_follow",
            "Follow an observed link_ref; exact destination verification is automatic. Read the destination before claiming task completion.",
            json!({"link_ref":reference}),
            vec!["link_ref"],
        ),
        (
            "computer_v2_fill",
            "Fill an observed field_ref without focus or submission. Exact resulting value is verified automatically.",
            json!({"field_ref":reference,"text":{"type":"string","maxLength":4096}}),
            vec!["field_ref", "text"],
        ),
    ];
    if let Some(open) = entries
        .iter_mut()
        .find(|entry| entry.0 == "computer_v2_open")
    {
        if policy == InteractionPolicy::BackgroundOnly {
            open.2 = json!({"bundle_id":{"type":"string","minLength":1,"maxLength":255},"activation":{"type":"string","enum":["none"]},"browser_mode":{"type":"string","enum":["existing"]}});
        } else {
            open.1 = "Bind or launch an exact application after native approval. Navigation/isolated Chrome require foreground mode; opening does not prove the destination loaded.";
        }
    }
    if !browser_model {
        entries.push(("computer_v2_capture", "Capture the exact bound app window. Background captures are observation-only and never grant input authority.", json!({"display_id":{"type":"integer","minimum":1},"shows_cursor":{"type":"boolean"},"include_accessibility":{"type":"boolean"}}), vec![]));
    }
    if policy == InteractionPolicy::Foreground {
        if !browser_model {
            entries.extend([
            ("computer_v2_ground_click", "Use a qualified local vision cascade to locate a visible native target from a current capture. Native approval and fresh window checks are required.", json!({"capture_id":reference,"target":{"type":"string","maxLength":512}}), vec!["capture_id","target"]),
            ("computer_v2_click", "Click a point from the current actionable capture after foreground and hit-test validation.", json!({"capture_id":reference,"x":{"type":"number","minimum":0},"y":{"type":"number","minimum":0}}), vec!["capture_id","x","y"]),
            ("computer_v2_pointer", "Perform bounded pointer input using the current actionable capture.", json!({"capture_id":reference,"x":{"type":"number","minimum":0},"y":{"type":"number","minimum":0},"action":{"type":"string","enum":["move","double_click","right_click","scroll"]},"delta_x":{"type":"number"},"delta_y":{"type":"number"}}), vec!["capture_id","x","y","action"]),
        ]);
        }
        entries.extend([
            ("computer_v2_keypress", "Send one supported key chord only to the same foreground bound window.", json!({"key":string,"modifiers":{"type":"array","uniqueItems":true,"items":{"type":"string","enum":["command","control","option","shift","function"]}}}), vec!["key"]),
            ("computer_v2_type", "Type text only into the same foreground bound window after approval.", json!({"text":{"type":"string","maxLength":4096}}), vec!["text"]),
        ]);
    }
    entries.into_iter().map(|(name, description, properties, required)| json!({"type":"function","name":name,"description":description,"inputSchema":{"type":"object","additionalProperties":false,"properties":properties,"required":required}})).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wire_decoder_rejects_boolean_indices_extra_fields_and_bad_actions() {
        assert!(
            parse_tool(
                "computer_v2_set_text",
                json!({"snapshot_id":"id","element_index":true,"text":"x"})
            )
            .is_err()
        );
        assert!(parse_tool("computer_v2_status", json!({"activate":true})).is_err());
        assert!(
            parse_tool(
                "computer_v2_ax",
                json!({"snapshot_id":"id","element_index":0,"ax_action":"AXInvented"})
            )
            .is_err()
        );
    }
    #[test]
    fn browser_and_background_capabilities_are_omitted_from_thread_schema() {
        let names: Vec<_> = tool_specs(InteractionPolicy::BackgroundOnly, true)
            .iter()
            .map(|v| v["name"].as_str().unwrap().to_owned())
            .collect();
        assert!(
            !names
                .iter()
                .any(|n| n.contains("capture") || n.contains("keypress") || n.contains("click"))
        );
        assert!(names.iter().any(|n| n == "computer_v2_read_region"));
        let foreground = tool_specs(InteractionPolicy::Foreground, true);
        assert!(!foreground.iter().any(|spec| matches!(
            spec["name"].as_str(),
            Some(
                "computer_v2_capture"
                    | "computer_v2_ground_click"
                    | "computer_v2_click"
                    | "computer_v2_pointer"
            )
        )));
        assert!(
            foreground
                .iter()
                .any(|spec| spec["name"] == "computer_v2_keypress")
        );
    }
    #[test]
    fn aliases_cannot_smuggle_index_authority_and_background_open_advertises_no_navigation() {
        assert!(
            parse_tool(
                "computer_v2_read_page",
                json!({"snapshot_id":"guessed","element_index":0})
            )
            .is_err()
        );
        let specs = tool_specs(InteractionPolicy::BackgroundOnly, false);
        let open = specs
            .iter()
            .find(|tool| tool["name"] == "computer_v2_open")
            .unwrap();
        assert_eq!(
            open["inputSchema"]["properties"]["activation"]["enum"],
            json!(["none"])
        );
        assert!(open["inputSchema"]["properties"].get("url").is_none());
    }
}
