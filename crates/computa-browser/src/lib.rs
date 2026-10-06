//! Authenticated local Chrome native messaging. Requests are never replayed.
pub mod cleanup;
pub mod framing;
pub mod identity;
pub mod leases;
pub mod link;
pub mod owned;
pub mod qualification;
pub mod registration;
pub use cleanup::CleanupProofStore;
pub mod relay;
pub use identity::{ApplePeerVerifier, PeerVerifier, VerifiedPeer};
pub use link::{BridgeServer, ChromeLink, ExtensionBrowserTransport, LinkEvent};
pub use owned::OwnedBrowserController;

#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum BrowserError {
    #[error("The browser bridge identity could not be verified")]
    Identity,
    #[error("Chrome access requires an Apple signed app and helper")]
    SigningRequired,
    #[error("The browser bridge configuration is invalid")]
    Configuration,
    #[error("The browser bridge message is invalid or too large")]
    InvalidFrame,
    #[error("The browser bridge disconnected; the operation was not replayed")]
    Closed,
    #[error("The browser bridge timed out; the operation was not replayed")]
    Deadline,
    #[error("The browser bridge is unavailable")]
    Unavailable,
    #[error(
        "The installed Computa extension is out of date. Reload it once in Chrome, then retry; Computa reconnects automatically."
    )]
    ReloadRequired,
    #[error("The browser operation was rejected ({0})")]
    Rejected(String),
}
impl BrowserError {
    pub fn from_code(code: Option<&str>) -> Self {
        match code {
            Some("unsupported_operation") => Self::ReloadRequired,
            Some(value) if known_failure(value) => Self::Rejected(value.to_owned()),
            _ => Self::Rejected("rejected".into()),
        }
    }
}
pub fn known_failure(code: &str) -> bool {
    matches!(
        code,
        "target_busy"
            | "target_unavailable"
            | "unsupported_command"
            | "temporary_tabs_not_authorized"
            | "stale_temporary_lease"
            | "temporary_task_already_used"
            | "invalid_temporary_receipt"
            | "web_sign_in_required"
            | "web_temporary_mode_unverified"
            | "web_temporary_mode_unavailable"
            | "web_composer_unavailable"
            | "web_composer_not_empty"
            | "web_prompt_not_inserted"
            | "web_send_unavailable"
            | "web_document_changed"
            | "web_invalid_document"
            | "web_conversation_changed"
            | "web_not_fresh"
            | "web_not_ready"
            | "web_stale_session"
            | "web_ready_timeout"
            | "web_response_timeout"
            | "web_response_interrupted"
            | "web_response_too_large"
            | "web_tab_unavailable"
            | "web_tab_detached"
            | "web_tab_closed"
            | "web_capacity_exceeded"
            | "web_send_failed"
            | "web_operation_failed"
            | "web_cleanup_unverified"
            | "web_cleanup_failed"
            | "unauthorized"
            | "revoked"
            | "chrome_timeout"
            | "duplicate_request"
            | "duplicate_generation"
            | "capacity_exceeded"
            | "invalid_inventory"
            | "response_too_large"
    )
}
pub fn revokes_connection(code: Option<&str>) -> bool {
    code.is_none_or(|value| {
        matches!(
            value,
            "unauthorized"
                | "revoked"
                | "chrome_timeout"
                | "duplicate_request"
                | "duplicate_generation"
                | "capacity_exceeded"
                | "invalid_inventory"
                | "response_too_large"
        )
    })
}
