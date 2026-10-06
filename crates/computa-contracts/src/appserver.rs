//! App Server protocol and the channel-safe native tool dispatcher boundary.
use crate::{Identifier, tools::InteractionPolicy};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RpcId {
    Number(i64),
    String(String),
}
/// Missing `data` and explicit null are distinct wire values.
#[derive(Clone, Debug, PartialEq)]
pub enum ErrorData {
    Missing,
    Present(Value),
}
#[derive(Clone, Debug, PartialEq, thiserror::Error)]
#[error("App Server error {code}: {message}")]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    pub data: ErrorData,
}
impl RpcError {
    pub fn from_value(value: &Value) -> Option<Self> {
        Some(Self {
            code: value.get("code")?.as_i64()?,
            message: value.get("message")?.as_str()?.to_owned(),
            data: match value.get("data") {
                None => ErrorData::Missing,
                Some(v) => ErrorData::Present(v.clone()),
            },
        })
    }
    pub fn to_value(&self) -> Value {
        let mut object = serde_json::json!({"code":self.code,"message":self.message});
        if let ErrorData::Present(data) = &self.data {
            object["data"] = data.clone();
        }
        object
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExecutionScope {
    pub task_id: Identifier,
    pub thread_id: Identifier,
    pub turn_id: Identifier,
    pub generation: Uuid,
    pub policy: InteractionPolicy,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ContentItem {
    #[serde(rename = "inputText")]
    Text { text: String },
    #[serde(rename = "inputImage")]
    Image {
        #[serde(rename = "imageUrl")]
        image_url: String,
    },
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolOutput {
    #[serde(rename = "contentItems")]
    pub content: Vec<ContentItem>,
    pub success: bool,
}
impl ToolOutput {
    pub fn text(text: impl Into<String>, success: bool) -> Self {
        Self {
            content: vec![ContentItem::Text { text: text.into() }],
            success,
        }
    }
}
#[derive(Clone, Debug, thiserror::Error)]
pub enum DispatchError {
    #[error("The tool request belongs to a turn that is no longer active.")]
    StaleScope,
    #[error("The native computer harness is unavailable.")]
    Unavailable,
    #[error("The tool is not declared for this thread.")]
    UndeclaredTool,
    #[error("The native computer action failed verification.")]
    Unverified,
}
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TurnConclusion {
    pub unresolved_operations: u64,
    pub failed_operations: u64,
}
/// Implementations are Send channel facades. AX/window handles remain on their UI thread.
#[async_trait]
pub trait ToolDispatcher: Send + Sync {
    async fn begin_turn(&self, scope: ExecutionScope) -> Result<(), DispatchError>;
    async fn execute(
        &self,
        scope: ExecutionScope,
        call_id: Identifier,
        name: String,
        arguments: Value,
    ) -> Result<ToolOutput, DispatchError>;
    async fn end_turn(&self, scope: ExecutionScope) -> TurnConclusion;
}
