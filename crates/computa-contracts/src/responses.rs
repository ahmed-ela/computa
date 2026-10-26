//! Browser inference boundary. No browser snapshot confers computer-tool authority.
use crate::models::WebProvider;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum BrowserOperation {
    #[serde(rename = "webProviderStart")]
    Start { provider: WebProvider },
    #[serde(rename = "webProviderPoll")]
    Poll {
        #[serde(rename = "sessionToken")]
        session_token: Uuid,
    },
    #[serde(rename = "webProviderSend")]
    Send {
        #[serde(rename = "sessionToken")]
        session_token: Uuid,
        prompt: String,
    },
    #[serde(rename = "webProviderFinish")]
    Finish {
        #[serde(rename = "sessionToken")]
        session_token: Uuid,
    },
    #[serde(rename = "webProviderCancel")]
    Cancel {
        #[serde(rename = "sessionToken")]
        session_token: Uuid,
    },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BrowserState {
    Loading,
    Ready,
    Running,
    Complete,
    NeedsSignIn,
    Failed,
    Finished,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserSnapshot {
    pub session_token: Uuid,
    pub provider: WebProvider,
    pub state: BrowserState,
    #[serde(default)]
    pub sequence: u64,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub cleanup: Option<BrowserCleanup>,
    #[serde(default)]
    pub error: Option<BrowserFailure>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BrowserCleanup {
    pub closed: bool,
    #[serde(default)]
    pub error: Option<BrowserFailure>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BrowserFailure {
    pub code: BrowserFailureCode,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize, thiserror::Error)]
pub enum BrowserFailureCode {
    #[serde(rename = "web_sign_in_required")]
    #[error("Sign in to the selected website in the built-in browser, then retry the task.")]
    SignInRequired,
    #[serde(rename = "web_tab_closed")]
    #[error("The owned website tab was closed.")]
    TabClosed,
    #[serde(rename = "web_temporary_mode_unverified")]
    #[error("The website's temporary mode could not be verified.")]
    TemporaryModeUnverified,
    #[serde(rename = "web_temporary_mode_unavailable")]
    #[error("Temporary mode is unavailable on this website.")]
    TemporaryModeUnavailable,
    #[serde(rename = "web_composer_unavailable")]
    #[error("The website's message composer is unavailable.")]
    ComposerUnavailable,
    #[serde(rename = "web_composer_not_empty")]
    #[error("The website's composer contains unexpected text.")]
    ComposerNotEmpty,
    #[serde(rename = "web_prompt_not_inserted")]
    #[error("The website did not accept the complete prompt.")]
    PromptNotInserted,
    #[serde(rename = "web_send_unavailable")]
    #[error("The website's send button is unavailable.")]
    SendUnavailable,
    #[serde(rename = "web_document_changed")]
    #[error("The owned browser document changed; the request was stopped.")]
    DocumentChanged,
    #[serde(rename = "web_invalid_document")]
    #[error("The browser document cannot be verified.")]
    InvalidDocument,
    #[serde(rename = "web_conversation_changed")]
    #[error("The owned website conversation changed; the request was stopped.")]
    ConversationChanged,
    #[serde(rename = "web_not_fresh")]
    #[error("The website conversation is not empty.")]
    NotFresh,
    #[serde(rename = "web_not_ready")]
    #[error("The website has not finished preparing the temporary conversation.")]
    NotReady,
    #[serde(rename = "web_stale_session")]
    #[error("The browser session is stale.")]
    StaleSession,
    #[serde(rename = "web_ready_timeout")]
    #[error("The website took too long to prepare the conversation.")]
    ReadyTimeout,
    #[serde(rename = "web_response_timeout")]
    #[error("The website took too long to return a response.")]
    ResponseTimeout,
    #[serde(rename = "web_response_interrupted")]
    #[error("The website response was interrupted before completion.")]
    ResponseInterrupted,
    #[serde(rename = "web_response_too_large")]
    #[error("The website response exceeds its byte limit.")]
    ResponseTooLarge,
    #[serde(rename = "web_tab_unavailable")]
    #[error("The owned browser tab is unavailable.")]
    TabUnavailable,
    #[serde(rename = "web_tab_detached")]
    #[error("The owned browser tab disconnected.")]
    TabDetached,
    #[serde(rename = "web_capacity_exceeded")]
    #[error("The browser session capacity has been reached.")]
    CapacityExceeded,
    #[serde(rename = "web_send_failed")]
    #[error("The website could not send this request.")]
    SendFailed,
    #[serde(rename = "web_operation_failed")]
    #[error("The website could not complete the operation.")]
    OperationFailed,
    #[serde(rename = "web_cleanup_unverified")]
    #[error("Closing the temporary browser conversation could not be verified.")]
    CleanupUnverified,
    #[serde(rename = "web_cleanup_failed")]
    #[error("The temporary browser conversation could not be closed.")]
    CleanupFailed,
    #[serde(other)]
    #[error(
        "The website could not produce a response. Check its sign-in, usage limit, or error in the built-in browser."
    )]
    Unknown,
}
#[derive(Clone, Debug, thiserror::Error)]
pub enum BrowserTransportError {
    #[error("Sign in to the selected website in the built-in browser, then retry the task.")]
    SignInRequired,
    #[error("The built-in website model transport is unavailable.")]
    Disconnected,
    #[error("The website model transport rejected this request.")]
    Rejected,
    #[error("The website model transport response was invalid.")]
    InvalidResponse,
    #[error("The website model transport request timed out.")]
    Timeout,
    #[error("{0}")]
    Website(BrowserFailureCode),
    #[error("Browser inference was cancelled.")]
    Cancelled,
}
#[async_trait]
pub trait BrowserTransport: Send + Sync {
    async fn request(
        &self,
        operation: BrowserOperation,
    ) -> Result<BrowserSnapshot, BrowserTransportError>;
}
