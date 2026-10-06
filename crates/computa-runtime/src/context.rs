use computa_contracts::models::{LocalModel, ModelId};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ContextProfile {
    pub window: u64,
    pub compact_limit: u64,
}
impl ContextProfile {
    pub fn for_model(model: &ModelId) -> Self {
        match model {
            ModelId::Browser(_) => Self {
                window: 65_536,
                compact_limit: 49_152,
            },
            ModelId::Local(LocalModel::Qwen35_4b | LocalModel::Qwen35_9b) => Self {
                window: 16_384,
                compact_limit: 12_288,
            },
            _ => Self {
                window: 4096,
                compact_limit: 3072,
            },
        }
    }
    pub fn config(self) -> Value {
        json!({"model_context_window":self.window,"model_auto_compact_token_limit":self.compact_limit,"project_root_markers":[],"allow_login_shell":false,"features.shell_snapshot":false,"features.shell_snapshot_v2":false,"memories.use_memories":false,"skills.include_instructions":false,"include_permissions_instructions":false,"include_apps_instructions":false,"include_environment_context":false,"features.plugins":false,"features.apps":false,"features.browser_use":false,"features.computer_use":false,"features.goals":false,"features.image_generation":false,"features.in_app_browser":false,"features.multi_agent":false,"features.multi_agent_v2":false,"features.shell_tool":true,"features.sleep_tool":false,"features.unified_exec":true,"features.view_image":false,"features.workspace_dependencies":false,"web_search":"disabled"})
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct ContextUsage {
    pub used_tokens: u64,
    pub context_window: u64,
}
pub fn parse_usage(params: &Value, expected_turn: Option<&str>) -> Option<ContextUsage> {
    if let Some(turn) = expected_turn
        && params.get("turnId").and_then(Value::as_str) != Some(turn)
    {
        return None;
    }
    let usage = &params["tokenUsage"];
    let tokens = usage["last"]["totalTokens"]
        .as_u64()
        .or_else(|| usage["total"]["totalTokens"].as_u64())?;
    let window = usage["modelContextWindow"].as_u64()?;
    Some(ContextUsage {
        used_tokens: tokens,
        context_window: window,
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profiles_are_not_interchangeable() {
        let small = ContextProfile::for_model(&ModelId::Local(LocalModel::Qwen35_4b));
        assert_eq!(small.window, 16384);
        assert_eq!(
            small,
            ContextProfile::for_model(&ModelId::Local(LocalModel::Qwen35_9b))
        );
        assert_ne!(
            small,
            ContextProfile::for_model(&ModelId::Local(LocalModel::Qwen38_27b))
        );
    }
    #[test]
    fn usage_rejects_boolean_and_wrong_turn() {
        assert!(parse_usage(&json!({"turnId":"other","tokenUsage":{"last":{"totalTokens":4},"modelContextWindow":4096}}),Some("turn")).is_none());
        assert!(
            parse_usage(
                &json!({"tokenUsage":{"last":{"totalTokens":true},"modelContextWindow":4096}}),
                None
            )
            .is_none()
        );
    }
}
