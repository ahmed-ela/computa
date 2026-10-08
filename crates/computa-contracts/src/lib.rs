#![forbid(unsafe_code)]

//! Portable contracts shared by the native app, UI, and Chrome worker.
//! Untrusted wire data is validated before it becomes application state.

pub mod appserver;
pub mod chrome;
pub mod grounding;
pub mod models;
pub mod responses;
pub mod strict_json;
pub mod tools;
pub mod ui;

use serde::{Deserialize, Deserializer, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize)]
#[serde(transparent)]
pub struct Identifier(String);

impl Identifier {
    pub fn new(value: impl Into<String>) -> Result<Self, ContractError> {
        let value = value.into();
        if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
            return Err(ContractError::InvalidIdentifier);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for Identifier {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum ContractError {
    #[error("Invalid identifier")]
    InvalidIdentifier,
    #[error("The prompt is empty or exceeds its byte limit")]
    InvalidPrompt,
    #[error("Specific website model choices require the qualified Swift desktop runtime")]
    UnsupportedWebsiteModelChoice,
}

pub fn validate_prompt(prompt: &str) -> Result<(), ContractError> {
    if prompt.trim().is_empty() || prompt.trim().len() > 200_000 || prompt.contains('\0') {
        Err(ContractError::InvalidPrompt)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_validated_at_deserialization() {
        for value in ["", "line\nbreak", "nul\0value"] {
            assert!(serde_json::from_value::<Identifier>(serde_json::json!(value)).is_err());
        }
        assert!(Identifier::new("x".repeat(257)).is_err());
        let id: Identifier = serde_json::from_str("\"browser/claude\"").unwrap();
        assert_eq!(id.as_str(), "browser/claude");
    }

    #[test]
    fn prompt_limit_counts_utf8_bytes_without_truncation() {
        assert!(validate_prompt(&"a".repeat(200_000)).is_ok());
        assert!(validate_prompt(&"é".repeat(200_000)).is_err());
        assert!(validate_prompt(" \n\t").is_err());
        assert!(validate_prompt("hello\0world").is_err());
    }
}
