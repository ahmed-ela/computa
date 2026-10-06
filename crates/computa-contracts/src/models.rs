use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::{ContractError, Identifier};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WebProvider {
    Chatgpt,
    Gemini,
    Claude,
}

impl WebProvider {
    pub const fn model_id(self) -> &'static str {
        match self {
            Self::Chatgpt => "browser/chatgpt",
            Self::Gemini => "browser/gemini",
            Self::Claude => "browser/claude",
        }
    }

    pub const fn origin(self) -> &'static str {
        match self {
            Self::Chatgpt => "https://chatgpt.com",
            Self::Gemini => "https://gemini.google.com",
            Self::Claude => "https://claude.ai",
        }
    }

    pub const fn root_url(self) -> &'static str {
        match self {
            Self::Chatgpt => "https://chatgpt.com/?temporary-chat=true",
            Self::Gemini => "https://gemini.google.com/app",
            Self::Claude => "https://claude.ai/new",
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Chatgpt => "ChatGPT",
            Self::Gemini => "Gemini",
            Self::Claude => "Claude",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum LocalModel {
    Qwen35_4b,
    Qwen35_9b,
    Qwen36_35bA3b,
    Qwen38_27b,
}

impl LocalModel {
    pub const fn model_id(self) -> &'static str {
        match self {
            Self::Qwen35_4b => "lmstudio-community/Qwen3.5-4B-MLX-4bit",
            Self::Qwen35_9b => "lmstudio-community/Qwen3.5-9B-MLX-4bit",
            Self::Qwen36_35bA3b => "lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit",
            Self::Qwen38_27b => "mlx-community/Qwen3.8-27B-4bit",
        }
    }
    pub const fn supports_visual_grounding(self) -> bool {
        matches!(self, Self::Qwen35_4b | Self::Qwen35_9b)
    }
    pub const fn high_memory(self) -> bool {
        matches!(self, Self::Qwen36_35bA3b)
    }
    pub const fn supports_headless_mlx(self) -> bool {
        matches!(self, Self::Qwen35_4b | Self::Qwen35_9b)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum ModelId {
    Browser(WebProvider),
    Local(LocalModel),
    /// Preserve unknown persisted/external model IDs; never silently switch them.
    External(Identifier),
}

impl Default for ModelId {
    fn default() -> Self {
        Self::Local(LocalModel::Qwen35_4b)
    }
}

impl ModelId {
    pub fn parse(value: &str) -> Result<Self, ContractError> {
        for provider in [
            WebProvider::Chatgpt,
            WebProvider::Gemini,
            WebProvider::Claude,
        ] {
            if value == provider.model_id() {
                return Ok(Self::Browser(provider));
            }
        }
        for local in [
            LocalModel::Qwen35_4b,
            LocalModel::Qwen35_9b,
            LocalModel::Qwen36_35bA3b,
            LocalModel::Qwen38_27b,
        ] {
            if value == local.model_id() {
                return Ok(Self::Local(local));
            }
        }
        Ok(Self::External(Identifier::new(value)?))
    }

    pub fn as_str(&self) -> &str {
        match self {
            Self::Browser(provider) => provider.model_id(),
            Self::Local(local) => local.model_id(),
            Self::External(id) => id.as_str(),
        }
    }
}

impl Serialize for ModelId {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}
impl<'de> Deserialize<'de> for ModelId {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::parse(&String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn browser_models_cannot_enter_the_local_model_route() {
        for provider in [
            WebProvider::Chatgpt,
            WebProvider::Gemini,
            WebProvider::Claude,
        ] {
            let encoded = serde_json::to_string(&ModelId::Browser(provider)).unwrap();
            assert_eq!(
                serde_json::from_str::<ModelId>(&encoded).unwrap(),
                ModelId::Browser(provider)
            );
        }
    }
    #[test]
    fn saved_unknown_models_are_preserved_instead_of_defaulted() {
        let model = ModelId::parse("custom-local-model").unwrap();
        assert!(matches!(model, ModelId::External(_)));
        assert_eq!(model.as_str(), "custom-local-model");
    }
}
