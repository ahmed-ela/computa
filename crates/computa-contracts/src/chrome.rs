//! Bounded native-messaging wire types. Authority is never inferred from a URL.
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const EXTENSION_ID: &str = "gdghbmoiibghgkfmhjlckipjjlclnlbk";
pub const HOST_NAME: &str = "com.macndash.chrome_bridge";
pub const APP_IDENTIFIER: &str = "com.ahmedelamin.LocalCodex";
pub const HOST_IDENTIFIER: &str = "com.ahmedelamin.LocalCodex.ChromeBridgeHost";
pub const MAX_FRAME: usize = 512 * 1024;
pub const MAX_PENDING: usize = 32;
pub const TEMPORARY_TABS_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub id: String,
    pub operation: String,
    pub params: Value,
    pub generation: String,
}
impl Request {
    pub fn valid(&self) -> bool {
        self.version == 1
            && bounded_text(&self.id, 128)
            && bounded_text(&self.operation, 64)
            && bounded_text(&self.generation, 128)
            && self.params.is_object()
            && serde_json::to_vec(self).is_ok_and(|bytes| bytes.len() <= MAX_FRAME)
    }
}
pub fn bounded_text(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.chars().count() <= maximum && !value.contains('\0')
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireError {
    pub code: String,
    pub message: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Response {
    pub version: u32,
    pub id: String,
    pub generation: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<WireError>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Hello {
    pub version: u32,
    pub event: String,
    pub installation_id: String,
    pub extension_id: String,
    pub bridge_epoch: String,
    pub paired: bool,
    pub suspended: bool,
    #[serde(default)]
    pub pairing_token: Option<String>,
    #[serde(default)]
    pub pairing_nonce: Option<String>,
    #[serde(default)]
    pub capabilities: Option<Value>,
    #[serde(default)]
    pub cleanup_receipts: Vec<CleanupReceipt>,
}
impl Hello {
    pub fn valid(&self) -> bool {
        self.version == 1
            && matches!(self.event.as_str(), "hello" | "pairRequested")
            && self.extension_id == EXTENSION_ID
            && uuid_text(&self.installation_id)
            && uuid_text(&self.bridge_epoch)
            && self
                .pairing_token
                .as_ref()
                .is_none_or(|token| bounded_text(token, 256))
            && self
                .pairing_nonce
                .as_ref()
                .is_none_or(|nonce| uuid_text(nonce))
            && self.cleanup_receipts.len() <= 64
            && self.cleanup_receipts.iter().all(CleanupReceipt::valid)
    }
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CleanupReceipt {
    pub session_token: String,
    pub provider: crate::models::WebProvider,
    pub source_epoch: String,
    pub generation: String,
    pub cleanup: String,
}
impl CleanupReceipt {
    pub fn valid(&self) -> bool {
        uuid_text(&self.session_token)
            && uuid_text(&self.source_epoch)
            && bounded_text(&self.generation, 128)
            && matches!(self.cleanup.as_str(), "not_created" | "temporary_closed")
    }
}
pub fn uuid_text(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, byte)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub const PRESS_FUNCTION: &str = r##"function(expectedURL) {
  if (!(this instanceof HTMLElement) || !this.isConnected ||
      this.ownerDocument !== document || window !== window.top ||
      document.URL !== expectedURL || this.matches(":disabled") ||
      this.closest('[inert], [aria-disabled="true" i]')) return false;
  HTMLElement.prototype.click.call(this);
  return true;
}"##;

pub const SET_TEXT_FUNCTION: &str = r##"function(expectedURL, value) {
  if (!(this instanceof HTMLElement) || !this.isConnected ||
      this.ownerDocument !== document || window !== window.top ||
      document.URL !== expectedURL || this.matches(":disabled") ||
      this.closest('[inert], [aria-disabled="true" i], [aria-readonly="true" i]')) {
    return false;
  }
  if (this instanceof HTMLInputElement) {
    if (this.readOnly ||
        !["text", "search", "email", "url", "tel", "password"].includes(this.type)) {
      return false;
    }
    const setter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype, "value"
    ).set;
    setter.call(this, value);
  } else if (this instanceof HTMLTextAreaElement) {
    if (this.readOnly) return false;
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype, "value"
    ).set;
    setter.call(this, value);
  } else if (this.isContentEditable) {
    this.textContent = value;
  } else {
    return false;
  }
  this.dispatchEvent(new Event("input", { bubbles: true }));
  this.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
}"##;

#[path = "chrome_policy.rs"]
pub mod policy;
